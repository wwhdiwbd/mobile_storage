# ============================================================
# FIO 4K / 16K Sequential Read & Write Performance Test
# ------------------------------------------------------------
# Phase 1 : numjobs sweep  (1, 2, 4)   – iodepth=1 fixed
# Phase 2 : iodepth sweep  (1-8)       – numjobs=1 fixed
# Block sizes : 4k, 16k
# NOTE: This device's fio only supports ioengine=sync.
#       With sync engine iodepth > 1 has no effect on actual concurrency;
#       the iodepth sweep records the parameter for completeness.
# Each config repeats 3 times; all raw values + average saved
# Output : fio_numjobs_results_<ts>.csv / fio_iodepth_results_<ts>.csv
# ============================================================

$testDir   = "/data/local/tmp"
$fioPath   = "$testDir/fio"
$testFile  = "$testDir/fio_test"

$logFile = Join-Path $PSScriptRoot ("fio_test_log_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
Start-Transcript -Path $logFile -Append | Out-Null
Write-Host "Transcript logging to: $logFile"

$size          = "2G"
$runs          = 3
$blockSizes    = @("4k", "16k")
$numjobsList   = @(1, 2, 4)
$iodepthList   = @(1, 2, 3, 4, 5, 6, 7, 8)
$rwModes       = @("read", "write")
$timestamp     = Get-Date -Format "yyyyMMdd_HHmmss"

# ---- helpers -----------------------------------------------

function Show-Banner {
    param([string]$text, [string]$color = "Cyan")
    Write-Host ("`n" + ("=" * 72)) -ForegroundColor $color
    Write-Host "  $text" -ForegroundColor $color
    Write-Host ("=" * 72) -ForegroundColor $color
}

# Run one fio job via adb and return a hashtable with BW/IOPS/Lat
function Invoke-FioRun {
    param(
        [string]$bs,
        [string]$rw,
        [int]   $numjobs,
        [int]   $iodepth
    )

    $cmd = "$fioPath " +
           "--name=fio_test " +
           "--ioengine=sync " +
           "--direct=1 " +
           "--group_reporting " +
           "--bs=$bs " +
           "--size=$size " +
           "--numjobs=$numjobs " +
           "--iodepth=$iodepth " +
           "--rw=$rw " +
           "--filename=$testFile " +
           "--output-format=json"

    # Capture stdout+stderr; ignore non-zero exit so PS doesn't throw
    $raw = (adb shell "$cmd" 2>&1) -join "`n"

    try {
        # Strip any leading non-JSON lines (adb warnings, etc.)
        $jsonStart = $raw.IndexOf('{')
        if ($jsonStart -gt 0) { $raw = $raw.Substring($jsonStart) }

        $j = ($raw | ConvertFrom-Json).jobs[0]

        if ($rw -eq "read") {
            $section = $j.read
        } else {
            $section = $j.write
        }

        $bw   = [math]::Round($section.bw   / 1024, 2)          # KB/s -> MB/s
        $iops = [math]::Round($section.iops,         2)

        # fio ≥3.14 uses lat_ns; older versions use lat (µs)
        if ($section.PSObject.Properties["lat_ns"]) {
            $lat = [math]::Round($section.lat_ns.mean / 1000, 2) # ns -> µs
        } elseif ($section.PSObject.Properties["lat"]) {
            $lat = [math]::Round($section.lat.mean,    2)         # already µs
        } else {
            $lat = 0
        }

        return @{ BW = $bw; IOPS = $iops; Lat = $lat; OK = $true }

    } catch {
        Write-Host "    [WARN] Failed to parse fio output: $_" -ForegroundColor Red
        return @{ BW = 0; IOPS = 0; Lat = 0; OK = $false }
    }
}

# Collect N runs and return a row object
function Run-Config {
    param(
        [string]$bs,
        [string]$rw,
        [int]   $numjobs,
        [int]   $iodepth
    )

    $rwLabel = if ($rw -eq "read") { "SeqRead" } else { "SeqWrite" }
    Write-Host ("  [BS=$bs numjobs=$numjobs iodepth=$iodepth $rwLabel]") -ForegroundColor Cyan

    $bwArr = @(); $iopsArr = @(); $latArr = @()

    for ($r = 1; $r -le $runs; $r++) {
        Write-Host ("    Run $r/$runs ...") -ForegroundColor Gray -NoNewline
        $res = Invoke-FioRun -bs $bs -rw $rw -numjobs $numjobs -iodepth $iodepth
        $bwArr   += $res.BW
        $iopsArr += $res.IOPS
        $latArr  += $res.Lat
        Write-Host (" BW=$($res.BW) MB/s  IOPS=$($res.IOPS)  Lat=$($res.Lat) µs") -ForegroundColor Green
    }

    $avgBW   = [math]::Round(($bwArr   | Measure-Object -Average).Average, 2)
    $avgIOPS = [math]::Round(($iopsArr | Measure-Object -Average).Average, 2)
    $avgLat  = [math]::Round(($latArr  | Measure-Object -Average).Average, 2)

    Write-Host ("    => Avg  BW=$avgBW MB/s  IOPS=$avgIOPS  Lat=$avgLat µs") -ForegroundColor Yellow

    return [PSCustomObject]@{
        BlockSize      = $bs
        RW             = $rwLabel
        numjobs        = $numjobs
        iodepth        = $iodepth
        Run1_BW_MBps   = $bwArr[0]
        Run2_BW_MBps   = $bwArr[1]
        Run3_BW_MBps   = $bwArr[2]
        Avg_BW_MBps    = $avgBW
        Run1_IOPS      = $iopsArr[0]
        Run2_IOPS      = $iopsArr[1]
        Run3_IOPS      = $iopsArr[2]
        Avg_IOPS       = $avgIOPS
        Run1_Lat_us    = $latArr[0]
        Run2_Lat_us    = $latArr[1]
        Run3_Lat_us    = $latArr[2]
        Avg_Lat_us     = $avgLat
    }
}

# ============================================================
#   MAIN
# ============================================================

Show-Banner "FIO 4K / 16K Sequential Read & Write Performance Test" "Green"
Write-Host ""
Write-Host "  Parameters:" -ForegroundColor Yellow
  Write-Host "    ioengine=sync  direct=1  group_reporting  size=$size  runs=$runs (each run reads/writes full $size)"
Write-Host "    Block sizes  : $($blockSizes -join ', ')"
Write-Host "    numjobs sweep: $($numjobsList -join ', ')  (iodepth fixed=1)"
Write-Host "    iodepth sweep: $($iodepthList -join ', ')  (numjobs fixed=1)"
Write-Host ""

$totalConfigs = ($blockSizes.Count * $numjobsList.Count * $rwModes.Count) +
                ($blockSizes.Count * $iodepthList.Count * $rwModes.Count)
Write-Host "  Total configurations: $totalConfigs x $runs runs = $($totalConfigs * $runs) fio jobs" -ForegroundColor Cyan
Write-Host ""

$numjobsResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$iodepthResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# --------------------------------------------------
# Phase 1 : numjobs sweep  (iodepth = 1)
# --------------------------------------------------
Show-Banner "Phase 1 – numjobs Sweep  [iodepth=1 fixed]" "Yellow"

foreach ($bs in $blockSizes) {
    foreach ($nj in $numjobsList) {
        foreach ($rw in $rwModes) {
            $row = Run-Config -bs $bs -rw $rw -numjobs $nj -iodepth 1
            $numjobsResults.Add($row)
        }
    }
}

# --------------------------------------------------
# Phase 2 : iodepth sweep  (numjobs = 1)
# --------------------------------------------------
Show-Banner "Phase 2 – iodepth Sweep  [numjobs=1 fixed, NOTE: sync engine ignores iodepth>1]" "Yellow"

foreach ($bs in $blockSizes) {
    foreach ($depth in $iodepthList) {
        foreach ($rw in $rwModes) {
            $row = Run-Config -bs $bs -rw $rw -numjobs 1 -iodepth $depth
            $iodepthResults.Add($row)
        }
    }
}

# --------------------------------------------------
# Cleanup
# --------------------------------------------------
Write-Host "`nCleaning up test file on device..." -ForegroundColor Cyan
adb shell "rm -f $testFile"

# --------------------------------------------------
# Save CSVs
# --------------------------------------------------
$csvNumjobs = "fio_numjobs_results_${timestamp}.csv"
$csvIodepth = "fio_iodepth_results_${timestamp}.csv"

$numjobsResults | Export-Csv -Path $csvNumjobs -NoTypeInformation -Encoding UTF8
$iodepthResults | Export-Csv -Path $csvIodepth -NoTypeInformation -Encoding UTF8

# --------------------------------------------------
# Print summary tables
# --------------------------------------------------
Show-Banner "Results – Phase 1: numjobs Sweep" "Green"
$numjobsResults | Format-Table BlockSize, RW, numjobs, iodepth,
    Run1_BW_MBps, Run2_BW_MBps, Run3_BW_MBps, Avg_BW_MBps,
    Run1_IOPS, Run2_IOPS, Run3_IOPS, Avg_IOPS,
    Run1_Lat_us, Run2_Lat_us, Run3_Lat_us, Avg_Lat_us -AutoSize

Show-Banner "Results – Phase 2: iodepth Sweep" "Green"
$iodepthResults | Format-Table BlockSize, RW, numjobs, iodepth,
    Run1_BW_MBps, Run2_BW_MBps, Run3_BW_MBps, Avg_BW_MBps,
    Run1_IOPS, Run2_IOPS, Run3_IOPS, Avg_IOPS,
    Run1_Lat_us, Run2_Lat_us, Run3_Lat_us, Avg_Lat_us -AutoSize

Show-Banner "All Done" "Green"
Write-Host "  Results saved to:" -ForegroundColor Yellow
Write-Host "    $csvNumjobs" -ForegroundColor Cyan
Write-Host "    $csvIodepth" -ForegroundColor Cyan
Write-Host ("=" * 72) -ForegroundColor Green
Stop-Transcript | Out-Null
