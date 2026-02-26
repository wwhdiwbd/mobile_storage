# =============================================================================
# fill_storage_and_test.ps1
# Android Storage Fragmentation Simulation + Disk Performance + Cold-Start Test
#
# PURPOSE
#   Simulate a phone that has been heavily used: storage filled with thousands
#   of small fragmented files, leaving only ~10% free space.
#
# STRATEGY (Two-phase fill, all reversible)
#   Phase 1 - Fragmentation:
#       Write ~5 GB of small random files (1-100 KB, /dev/urandom data) spread
#       across $NumDirs subdirectories in strict round-robin order.
#       Round-robin forces the filesystem to allocate non-contiguous extents,
#       creating real on-disk fragmentation.  /dev/urandom = incompressible,
#       defeating SSD compression engines.
#   Phase 2 - Bulk fill:
#       Fill remaining free space to the target with medium files (4-32 MB,
#       /dev/zero) still round-robined across the same dirs.  /dev/zero is
#       much faster to generate, cutting total runtime from days to hours.
#
# RECOVERY
#   All created files live under $FragBase (/sdcard/fragment_test/).
#   One command restores the device:  adb shell "rm -rf /sdcard/fragment_test"
#   Or run this script with -CleanupOnly.
#
# USAGE
#   .\fill_storage_and_test.ps1                        # full run
#   .\fill_storage_and_test.ps1 -SkipFill              # test only, no fill
#   .\fill_storage_and_test.ps1 -CleanupOnly           # delete fragment files
#   .\fill_storage_and_test.ps1 -SkipBaseline          # skip pre-fill tests
#   .\fill_storage_and_test.ps1 -TargetFreePercent 5   # fill to 5% free
#   .\fill_storage_and_test.ps1 -SkipColdStartTest     # FIO only, no app test
# =============================================================================

param(
    [int]    $TargetFreePercent    = 10,
    [int]    $NumDirs              = 64,
    [int]    $FragMinKB            = 1,
    [int]    $FragMaxKB            = 100,
    [string] $FragBase             = "/sdcard/fragment_test",
    [string] $FioPath              = "/data/local/tmp/fio",
    [string] $PackageName          = "tv.danmaku.bili",
    [string] $ActivityName         = ".MainActivityV2",
    [int]    $ColdStartIterations  = 3,
    [switch] $SkipFill,
    [switch] $SkipBaseline,
    [switch] $SkipPerformanceTest,
    [switch] $SkipColdStartTest,
    [switch] $CleanupOnly,
    [switch] $SkipFinalCleanup,    # skip the interactive cleanup prompt at the end
    [string] $OutputDir            = $PSScriptRoot
)

Set-StrictMode -Off

# ---------------------------------------------------------------------------
#  Output helpers (all ASCII to avoid encoding issues on Windows PS5)
# ---------------------------------------------------------------------------
function Write-Title { param($m)
    Write-Host ("`n" + ("="*68)) -ForegroundColor Cyan
    Write-Host ("  " + $m)       -ForegroundColor Cyan
    Write-Host ("="*68)          -ForegroundColor Cyan
}
function Write-Step  { param($m) Write-Host ("`n>>> " + $m) -ForegroundColor Yellow }
function Write-OK    { param($m) Write-Host ("[OK]  " + $m) -ForegroundColor Green  }
function Write-Warn  { param($m) Write-Host ("[WARN] " + $m) -ForegroundColor DarkYellow }
function Write-Fail  { param($m) Write-Host ("[ERR] " + $m) -ForegroundColor Red    }
function Write-Info  { param($m) Write-Host ("      " + $m) -ForegroundColor Gray   }

# ---------------------------------------------------------------------------
#  ADB helpers
# ---------------------------------------------------------------------------
function Adb-Shell {
    param([string]$cmd)
    return adb shell $cmd 2>$null
}

# ---------------------------------------------------------------------------
#  Step 0: ADB check
# ---------------------------------------------------------------------------
function Assert-AdbDevice {
    Write-Step "Checking ADB device connection..."
    $devices   = adb devices 2>&1
    $connected = $devices | Where-Object { $_ -match "device$" }
    if (-not $connected) {
        Write-Fail "No ADB device detected.  Connect device and enable USB Debugging."
        exit 1
    }
    Write-OK ("Device connected: " + $connected[0])
}

# ---------------------------------------------------------------------------
#  Step 1: Storage query
# ---------------------------------------------------------------------------
function Get-StorageInfo {
    $raw  = adb shell "df -k /sdcard" 2>$null
    $line = $raw | Select-Object -Last 1
    if ($line -match '\s+(\d+)\s+(\d+)\s+(\d+)') {
        $t = [long]$Matches[1]; $u = [long]$Matches[2]; $f = [long]$Matches[3]
        return [PSCustomObject]@{
            TotalKB     = $t
            UsedKB      = $u
            FreeKB      = $f
            TotalGB     = [math]::Round($t / 1048576.0, 2)
            UsedGB      = [math]::Round($u / 1048576.0, 2)
            FreeGB      = [math]::Round($f / 1048576.0, 2)
            FreePercent = [math]::Round($f * 100.0 / $t, 1)
        }
    }
    return $null
}

function Show-StorageInfo {
    param($info, [string]$label)
    if ($null -eq $info) { Write-Warn "Cannot read storage info"; return }
    Write-Host ("  [" + $label + "]") -ForegroundColor Magenta
    Write-Info ("Total : " + $info.TotalGB + " GB")
    Write-Info ("Used  : " + $info.UsedGB  + " GB")
    Write-Info ("Free  : " + $info.FreeGB  + " GB  (" + $info.FreePercent + "%)")
}

# ---------------------------------------------------------------------------
#  Step 2: Build & push worker shell script to device
#
#  The worker script runs ENTIRELY on the device (not over ADB per-file).
#  This gives full device write speed (~200-500 MB/s) rather than ADB overhead.
# ---------------------------------------------------------------------------
function Push-WorkerScript {

    # Single-quoted @'...'@ heredoc: PS never expands $ inside, so all
    # shell variables/arithmetic ($var, $(( )), etc.) pass through verbatim.
    # Token placeholders (ALL_CAPS_VAL) are substituted with -replace afterwards.
    $body = @'
#!/system/bin/sh
TARGET_FREE_PERCENT=TARGET_FREE_PERCENT_VAL
FRAG_BASE=FRAG_BASE_VAL
NUM_DIRS=NUM_DIRS_VAL
MIN_KB=FRAG_MIN_KB_VAL
MAX_KB=FRAG_MAX_KB_VAL
RANGE_KB=$(( MAX_KB - MIN_KB + 1 ))
BULK_MIN_KB=4096
BULK_MAX_KB=32768
BULK_RANGE=$(( BULK_MAX_KB - BULK_MIN_KB + 1 ))
FRAG_PHASE_GB=5

echo "[W] Creating $NUM_DIRS fragmentation dirs..."
i=1
while [ $i -le $NUM_DIRS ]; do
    dname=$(printf "d%04d" $i)
    mkdir -p "$FRAG_BASE/frag/$dname"
    mkdir -p "$FRAG_BASE/bulk/$dname"
    i=$(( i + 1 ))
done

TOTAL_KB=$(df -k /sdcard 2>/dev/null | awk "END{print \$2}")
TARGET_FREE_KB=$(( TOTAL_KB / 100 * TARGET_FREE_PERCENT ))
FRAG_TARGET_KB=$(( FRAG_PHASE_GB * 1024 * 1024 ))
echo "[W] Total=${TOTAL_KB}KB  TargetFree=${TARGET_FREE_KB}KB (${TARGET_FREE_PERCENT}%)"
echo "[W] === Phase 1: ~${FRAG_PHASE_GB}GB small urandom files for fragmentation ==="

fc=0
wk=0
rnd=0

while true; do
    FREE_KB=$(df -k /sdcard 2>/dev/null | awk "END{print \$4}")
    [ -z "$FREE_KB" ] && FREE_KB=0
    if [ $FREE_KB -le $TARGET_FREE_KB ]; then
        echo "[W] P1: global target reached"; break
    fi
    if [ $wk -ge $FRAG_TARGET_KB ]; then
        echo "[W] P1: frag quota reached (${wk}KB written)"; break
    fi
    rnd=$(( rnd + 1 ))
    if [ $(( rnd % 20 )) -eq 0 ]; then
        PCT=$(( (FREE_KB / 1024) * 100 / (TOTAL_KB / 1024) ))
        echo "[W] P1 round=$rnd files=$fc written=${wk}KB free=${FREE_KB}KB(${PCT}%)"
    fi
    di=1
    while [ $di -le $NUM_DIRS ]; do
        sk=$(( (RANDOM % RANGE_KB) + MIN_KB ))
        sb=$(( sk * 1024 ))
        dname=$(printf "d%04d" $di)
        fc=$(( fc + 1 ))
        wk=$(( wk + sk ))
        dd if=/dev/urandom of="$FRAG_BASE/frag/$dname/f_$fc" bs=$sb count=1 2>/dev/null
        di=$(( di + 1 ))
        if [ $(( fc % 128 )) -eq 0 ]; then
            FREE_KB=$(df -k /sdcard 2>/dev/null | awk "END{print \$4}")
            [ -z "$FREE_KB" ] && FREE_KB=0
            if [ $FREE_KB -le $TARGET_FREE_KB ] || [ $wk -ge $FRAG_TARGET_KB ]; then break; fi
        fi
    done
done

FRAG_FILES=$fc
echo "[W] Phase1 done: $FRAG_FILES files, ${wk}KB written"

# ------ Phase 2: bulk fill with zero-data (fast) ------
FREE_KB=$(df -k /sdcard 2>/dev/null | awk "END{print \$4}")
[ -z "$FREE_KB" ] && FREE_KB=0
if [ $FREE_KB -le $TARGET_FREE_KB ]; then
    echo "[W] Phase2 skip: target already met"
else
    echo "[W] === Phase 2: bulk fill with /dev/zero ==="
    bc=0
    while true; do
        FREE_KB=$(df -k /sdcard 2>/dev/null | awk "END{print \$4}")
        [ -z "$FREE_KB" ] && FREE_KB=0
        if [ $FREE_KB -le $TARGET_FREE_KB ]; then
            echo "[W] P2: target met free=${FREE_KB}KB"; break
        fi
        PCT=$(( (FREE_KB / 1024) * 100 / (TOTAL_KB / 1024) ))
        echo "[W] P2 bulk=$bc free=${FREE_KB}KB(${PCT}%) target=${TARGET_FREE_PERCENT}%"
        di=1
        while [ $di -le $NUM_DIRS ]; do
            FREE_KB=$(df -k /sdcard 2>/dev/null | awk "END{print \$4}")
            [ -z "$FREE_KB" ] && FREE_KB=0
            [ $FREE_KB -le $TARGET_FREE_KB ] && break
            avail=$(( FREE_KB - TARGET_FREE_KB ))
            if [ $avail -lt $BULK_MIN_KB ]; then
                sk=$avail
            else
                sk=$(( (RANDOM % BULK_RANGE) + BULK_MIN_KB ))
                [ $sk -gt $avail ] && sk=$avail
            fi
            [ $sk -le 0 ] && break
            sb=$(( sk * 1024 ))
            dname=$(printf "d%04d" $di)
            bc=$(( bc + 1 ))
            dd if=/dev/zero of="$FRAG_BASE/bulk/$dname/b_$bc" bs=$sb count=1 2>/dev/null
            di=$(( di + 1 ))
        done
    done
    echo "[W] Phase2 done: $bc bulk files"
fi

# ------ Final report ------
FREE_KB=$(df -k /sdcard 2>/dev/null | awk "END{print \$4}")
[ -z "$FREE_KB" ] && FREE_KB=0
FREE_PCT=$(( (FREE_KB / 1024) * 100 / (TOTAL_KB / 1024) ))
echo "[W] === ALL DONE ==="
echo "[W] Frag files: $FRAG_FILES   Free: ${FREE_KB}KB (${FREE_PCT}%)"
echo "RESULT:frag_files=$FRAG_FILES:free_kb=$FREE_KB:free_pct=$FREE_PCT"
'@

    $body = $body `
        -replace "TARGET_FREE_PERCENT_VAL", $TargetFreePercent `
        -replace "FRAG_BASE_VAL",           $FragBase `
        -replace "NUM_DIRS_VAL",            $NumDirs `
        -replace "FRAG_MIN_KB_VAL",         $FragMinKB `
        -replace "FRAG_MAX_KB_VAL",         $FragMaxKB

    $localTmp = Join-Path $env:TEMP "fragfill_worker.sh"
    [System.IO.File]::WriteAllText($localTmp, $body.Replace("`r`n", "`n"))

    Write-Step "Pushing worker script to device (/data/local/tmp/fragfill_worker.sh)..."
    adb push $localTmp /data/local/tmp/fragfill_worker.sh 2>&1 | Out-Null
    adb shell "chmod 755 /data/local/tmp/fragfill_worker.sh" 2>&1 | Out-Null
    Write-OK "Worker script pushed."
    Remove-Item $localTmp -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
#  Step 3: Execute fill (runs worker on device, streams progress)
# ---------------------------------------------------------------------------
function Invoke-FragmentFill {
    param($storInfo)
    if ($storInfo.FreePercent -le $TargetFreePercent) {
        Write-Warn ("Free space (" + $storInfo.FreePercent + "%) already <= target (" + $TargetFreePercent + "%), skipping fill.")
        return
    }

    Write-Step ("Starting fragment fill  target=" + $TargetFreePercent + "%  current=" + $storInfo.FreePercent + "%")
    Write-Info  ("Dirs=" + $NumDirs + "  FragFiles=" + $FragMinKB + "-" + $FragMaxKB + " KB")
    Write-Info  ("Phase1 ~5 GB urandom small files -> fragmentation")
    Write-Info  ("Phase2 bulk /dev/zero files -> fill remaining ~" +
                 [math]::Round($storInfo.FreeGB - $storInfo.TotalGB * $TargetFreePercent / 100, 1) + " GB")
    Write-Warn  "This will take a long time (filling tens of GB).  Please wait..."

    $t0 = Get-Date
    $resultLine = $null

    # Stream output live — avoids adb PTY-detach issue with Start-Process redirect
    & adb shell "sh /data/local/tmp/fragfill_worker.sh" 2>&1 | ForEach-Object {
        $line = $_
        if ($line -match "^RESULT:") {
            $resultLine = $line
        } elseif ($line -match "\[W\]") {
            if     ($line -match "ALL DONE|done:")         { Write-OK   $line }
            elseif ($line -match "P[12] round|P[12] bulk") { Write-Info $line }
            else { Write-Host ("  " + $line) -ForegroundColor Gray }
        } elseif ($line -match "error|Error|not found|Permission") {
            Write-Warn ("  [stderr] " + $line)
        }
    }

    $elapsed = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    Write-OK ("Fill phase completed in " + $elapsed + " min")

    if ($resultLine -match "frag_files=(\d+):free_kb=(\d+):free_pct=(\d+)") {
        $nf  = $Matches[1]
        $fgb = [math]::Round([long]$Matches[2] / 1048576.0, 2)
        $fp  = $Matches[3]
        Write-Host ""
        Write-Host ("  Frag files written : " + $nf)                           -ForegroundColor Green
        Write-Host ("  Free space after   : " + $fgb + " GB  (" + $fp + "%)") -ForegroundColor Green
    } else {
        Write-Fail "Fill worker did not return RESULT line — fill likely failed or was interrupted."
        throw "FillFailed"
    }
}

# ---------------------------------------------------------------------------
#  Step 4: FIO performance test  (4K random + sequential, before/after fill)
# ---------------------------------------------------------------------------
function Invoke-FioTest {
    param([string]$label)
    Write-Step ("FIO performance test  [" + $label + "]")

    $fioPresent = adb shell "ls $FioPath" 2>$null
    if (-not ($fioPresent -like "*fio*")) {
        Write-Warn ("fio not found at " + $FioPath)
        Write-Warn ("Push it first: adb push system\xbin\fio /data/local/tmp/fio")
        return $null
    }

    $tf = "/data/local/tmp/fio_bench_tmp"   # /data is real fs (ext4/f2fs), not FUSE
    adb shell "mkdir -p /data/local/tmp" 2>$null

    $testCases = @(
        [PSCustomObject]@{ Name = "4k_randread";  Args = "--rw=randread  --bs=4k   --size=512m" },
        [PSCustomObject]@{ Name = "4k_randwrite"; Args = "--rw=randwrite --bs=4k   --size=512m" },
        [PSCustomObject]@{ Name = "4k_seq_read";     Args = "--rw=read    --bs=4k --size=512m"   },
        [PSCustomObject]@{ Name = "4k_seq_write";    Args = "--rw=write   --bs=4k --size=512m"   },
        [PSCustomObject]@{ Name = "16k_randread";  Args = "--rw=randread  --bs=16k   --size=512m" },
        [PSCustomObject]@{ Name = "16k_randwrite"; Args = "--rw=randwrite --bs=16k   --size=512m" },
        [PSCustomObject]@{ Name = "16k_seq_read";     Args = "--rw=read   --bs=16k --size=512m"   },
        [PSCustomObject]@{ Name = "16k_seq_write";    Args = "--rw=write  --bs=16k --size=512m"   }
    )
    $results = @{}

    foreach ($tc in $testCases) {
        Write-Info ("Running: " + $tc.Name + " ...")

        # Drop page cache before read tests so we measure physical NAND
        if ($tc.Name -like "*read*") {
            adb shell "sync" 2>$null
            adb shell "sh -c 'echo 3 > /proc/sys/vm/drop_caches'" 2>$null
            Start-Sleep -Milliseconds 500
        }

        # $cmd = $FioPath + " --name=" + $tc.Name + " --ioengine=sync --direct=1 " + $tc.Args +
        #        " --filename=" + $tf + " --numjobs=1 --runtime=20 --time_based" +
        #        " --output-format=json"
        $cmd = $FioPath + " --name=" + $tc.Name + " --ioengine=sync --direct=1 " + $tc.Args +
               " --filename=" + $tf + " --numjobs=1 --runtime=60 --time_based" +
               " --output-format=json"

        $rawLines = adb shell $cmd 2>$null
        $rawJson = ($rawLines -join "`n")

        if ($rawJson -and $rawJson -match "\{") {
            $jsonObj = $null
            try {
                $jsonObj = $rawJson | ConvertFrom-Json
            } catch {
                $jsonObj = $null
            }

            if ($null -ne $jsonObj -and $jsonObj.jobs -and $jsonObj.jobs.Count -gt 0) {
                $job = $jsonObj.jobs[0]
                $readBwBytes = [double]$job.read.bw_bytes
                $readIops    = [double]$job.read.iops
                $writeBwBytes = [double]$job.write.bw_bytes
                $writeIops    = [double]$job.write.iops

                # bytes/s -> MB/s
                $readBwMB  = [math]::Round($readBwBytes / 1048576.0, 2)
                $writeBwMB = [math]::Round($writeBwBytes / 1048576.0, 2)

            if ($tc.Name -like "*read*") {
                    $bw   = $readBwMB
                    $iops = [math]::Round($readIops, 0)
            } else {
                    $bw   = $writeBwMB
                    $iops = [math]::Round($writeIops, 0)
                }

                $results[$tc.Name] = [PSCustomObject]@{ BW_MBs = $bw; IOPS = $iops; Label = $label }
                Write-OK ($tc.Name + ": " + $bw + " MB/s  IOPS=" + $iops)
            } else {
                Write-Warn ($tc.Name + ": JSON parse failed.  Last 3 lines:")
                $rawLines | Select-Object -Last 3 | ForEach-Object { Write-Info ("  " + $_) }
                $results[$tc.Name] = [PSCustomObject]@{ BW_MBs = "N/A"; IOPS = "N/A"; Label = $label }
            }
        } else {
            Write-Warn ($tc.Name + ": no JSON output.  Last 3 lines:")
            $rawLines | Select-Object -Last 3 | ForEach-Object { Write-Info ("  " + $_) }
            $results[$tc.Name] = [PSCustomObject]@{ BW_MBs = "N/A"; IOPS = "N/A"; Label = $label }
        }
    }

    adb shell "rm -f /data/local/tmp/fio_bench_tmp" 2>$null
    return $results
}

# ---------------------------------------------------------------------------
#  Step 5: Cold-start test  (mirrors test_cold_start_bilibili.ps1)
# ---------------------------------------------------------------------------
function Invoke-ColdStartTest {
    param([string]$label)
    Write-Step ("Cold-start test  [" + $label + "]  iterations=" + $ColdStartIterations)
    $all = @()

    function Local:Drop-PageCache {
        adb shell "am force-stop $PackageName" 2>$null
        Start-Sleep -Milliseconds 800
        adb shell "sync" 2>$null
        adb shell "sh -c 'echo 3 > /proc/sys/vm/drop_caches'" 2>$null
        Start-Sleep -Milliseconds 600
    }

    function Local:Drop-AllCache {
        adb shell "am force-stop $PackageName" 2>$null
        Start-Sleep -Milliseconds 800
        adb shell "rm -rf /data/data/$PackageName/cache/*"      2>$null
        adb shell "rm -rf /data/data/$PackageName/code_cache/*" 2>$null
        adb shell "sync" 2>$null
        adb shell "sh -c 'echo 3 > /proc/sys/vm/drop_caches'" 2>$null
        Start-Sleep -Milliseconds 600
    }

    function Local:Measure-Start {
        param([string]$sc)
        $out     = adb shell "am start -W -n ${PackageName}/${ActivityName}" 2>$null
        $total   = "N/A"
        $display = "N/A"
        $out | ForEach-Object {
            if ($_ -match "TotalTime:\s*(\d+)")  { $total   = $Matches[1] }
            if ($_ -match "ThisTime:\s*(\d+)")   { $display = $Matches[1] }
        }
        Write-Info ("  " + $sc + "  Total=" + $total + "ms  Display=" + $display + "ms")
        return [PSCustomObject]@{
            Label       = $label
            Scenario    = $sc
            TotalTime   = $total
            DisplayTime = $display
            Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
    }

    # A: Warm start (app stopped, caches intact)
    Write-Host ("  [A] WarmStart x" + $ColdStartIterations) -ForegroundColor Magenta
    for ($i = 1; $i -le $ColdStartIterations; $i++) {
        adb shell "am force-stop $PackageName" 2>$null
        Start-Sleep -Seconds 1
        $all += Local:Measure-Start "WarmStart"
        Start-Sleep -Seconds 2
    }

    # B: Cold start (page cache dropped, simulates cold boot)
    Write-Host ("  [B] ColdStart_NoPageCache x" + $ColdStartIterations) -ForegroundColor Magenta
    for ($i = 1; $i -le $ColdStartIterations; $i++) {
        Local:Drop-PageCache
        $all += Local:Measure-Start "ColdStart_NoPageCache"
        Start-Sleep -Seconds 2
    }

    # C: Fully cold start (all caches cleared)
    Write-Host ("  [C] ColdStart_AllCleared x" + $ColdStartIterations) -ForegroundColor Magenta
    for ($i = 1; $i -le $ColdStartIterations; $i++) {
        Local:Drop-AllCache
        $all += Local:Measure-Start "ColdStart_AllCleared"
        Start-Sleep -Seconds 2
    }

    return $all
}

# ---------------------------------------------------------------------------
#  Step 6: Cleanup
# ---------------------------------------------------------------------------
function Invoke-Cleanup {
    Write-Step ("Removing all fragment files from device (" + $FragBase + ")")
    $confirm = Read-Host "Delete $FragBase on device? [y/N]"
    if ($confirm -eq "y" -or $confirm -eq "Y") {
        adb shell "rm -rf $FragBase" 2>$null
        Write-OK "Cleanup complete.  Storage restored."
        $info = Get-StorageInfo
        if ($info) { Show-StorageInfo $info "After cleanup" }
    } else {
        Write-Warn ("Cleanup skipped.  Files remain at " + $FragBase)
    }
}

# ---------------------------------------------------------------------------
#  Step 7: Consolidated report + CSV export
# ---------------------------------------------------------------------------
function Save-Report {
    param($sBefore, $sAfter, $fioBefore, $fioAfter, $coldResults)
    $ts   = Get-Date -Format "yyyyMMdd_HHmmss"
    $base = Join-Path $OutputDir ("frag_test_" + $ts)

    # Storage overview
    Write-Title "Storage Change Summary"
    if ($sBefore) { Show-StorageInfo $sBefore "Before fill" }
    if ($sAfter)  { Show-StorageInfo $sAfter  "After fill"  }

    # FIO comparison table
    if ($fioBefore -or $fioAfter) {
        Write-Title "FIO Performance Comparison"
        $tbl  = @()
        $keys = if ($fioBefore) { $fioBefore.Keys } else { $fioAfter.Keys }
        foreach ($k in $keys) {
            $b    = if ($fioBefore -and $fioBefore.ContainsKey($k)) { $fioBefore[$k] } else { $null }
            $a    = if ($fioAfter  -and $fioAfter.ContainsKey($k))  { $fioAfter[$k]  } else { $null }
            $bBW  = if ($b) { $b.BW_MBs } else { "N/A" }
            $aBW  = if ($a) { $a.BW_MBs } else { "N/A" }
            $diff = "N/A"
            if ($bBW -ne "N/A" -and $aBW -ne "N/A" -and [double]$bBW -gt 0) {
                $pct  = [math]::Round(([double]$aBW - [double]$bBW) / [double]$bBW * 100, 1)
                $diff = $pct.ToString() + "%"
            }
            $row  = [PSCustomObject]@{
                Test           = $k
                Before_BW_MBs  = $bBW
                After_BW_MBs   = $aBW
                BW_Change_Pct  = $diff
                Before_IOPS    = if ($b) { $b.IOPS } else { "N/A" }
                After_IOPS     = if ($a) { $a.IOPS } else { "N/A" }
            }
            $tbl += $row
            $color = "Green"
            if ($diff -ne "N/A") {
                $pctVal = [double]($diff -replace "%", "")
                if ($pctVal -lt 0) { $color = "Red" }
            }
            Write-Host ("  " + ("{0,-18}" -f $k) +
                        " Before=" + ("{0,8}" -f $bBW) + " MB/s" +
                        "  After=" + ("{0,8}" -f $aBW) + " MB/s" +
                        "  Change=" + ("{0,8}" -f $diff)) -ForegroundColor $color
        }
        $fioFile = $base + "_fio.csv"
        $tbl | Export-Csv -Path $fioFile -NoTypeInformation -Encoding UTF8
        Write-OK ("FIO results saved -> " + $fioFile)
    }

    # Cold-start comparison table
    if ($coldResults -and $coldResults.Count -gt 0) {
        Write-Title "Cold-Start Time Comparison"
        $coldFile = $base + "_coldstart.csv"
        $coldResults | Export-Csv -Path $coldFile -NoTypeInformation -Encoding UTF8

        $scenarios = $coldResults | Select-Object -ExpandProperty Scenario -Unique
        $labels    = $coldResults | Select-Object -ExpandProperty Label    -Unique
        foreach ($sc in $scenarios) {
            Write-Host ("`n  [" + $sc + "]") -ForegroundColor Magenta
            foreach ($lbl in $labels) {
                $rows = $coldResults | Where-Object {
                    $_.Scenario -eq $sc -and $_.Label -eq $lbl -and $_.TotalTime -ne "N/A"
                }
                if ($rows) {
                    $nums = @($rows | ForEach-Object { [double]$_.TotalTime })
                    $avg  = [math]::Round(($nums | Measure-Object -Average).Average, 0)
                    Write-Host ("    " + ("{0,-22}" -f $lbl) +
                                " avg TotalTime = " + ("{0,6}" -f $avg) + " ms") -ForegroundColor White
                }
            }
        }
        Write-OK ("Cold-start results saved -> " + $coldFile)
    }

    Write-Title "All Done"
    Write-Host ("  Output dir : " + $OutputDir)                       -ForegroundColor Cyan
    Write-Host ("  To cleanup : adb shell " + [char]34 + "rm -rf $FragBase" + [char]34) -ForegroundColor Yellow
    Write-Host ("  Or run     : .\fill_storage_and_test.ps1 -CleanupOnly") -ForegroundColor Yellow
}

# ===========================================================================
#  Main flow
# ===========================================================================
Write-Title "Android Storage Fragmentation Simulation + Test"
Write-Info ("Target free    : " + $TargetFreePercent + "%")
Write-Info ("Subdirs        : " + $NumDirs)
Write-Info ("Frag file size : " + $FragMinKB + " - " + $FragMaxKB + " KB  (Phase1 /dev/urandom)")
Write-Info ("Bulk file size : 4096 - 32768 KB  (Phase2 /dev/zero)")
Write-Info ("Fragment base  : " + $FragBase)
Write-Info ("Package        : " + $PackageName)

Assert-AdbDevice

# Cleanup-only mode
if ($CleanupOnly) {
    Invoke-Cleanup
    exit 0
}

# Pre-fill baseline
Write-Step "Reading pre-fill storage info..."
$sBefore = Get-StorageInfo
Show-StorageInfo $sBefore "Before fill"

$fioBefore  = $null
$coldBefore = @()

if (-not $SkipBaseline) {
    if (-not $SkipPerformanceTest) { $fioBefore  = Invoke-FioTest      -label "Before_Fill" }
    if (-not $SkipColdStartTest)   { $coldBefore = Invoke-ColdStartTest -label "Before_Fill" }
}

# Fill phase
if (-not $SkipFill) {
    Push-WorkerScript
    Invoke-FragmentFill -storInfo $sBefore
}

# Post-fill measurements
Write-Step "Reading post-fill storage info..."
$sAfter = Get-StorageInfo
Show-StorageInfo $sAfter "After fill"

$fioAfter  = $null
$coldAfter = @()
if (-not $SkipPerformanceTest) { $fioAfter  = Invoke-FioTest      -label "After_Fill" }
if (-not $SkipColdStartTest)   { $coldAfter = Invoke-ColdStartTest -label "After_Fill" }

# Report
Save-Report -sBefore $sBefore -sAfter $sAfter `
            -fioBefore $fioBefore -fioAfter $fioAfter `
            -coldResults ($coldBefore + $coldAfter)

# Optional immediate cleanup
if (-not $SkipFinalCleanup) {
    $clean = Read-Host "`nCleanup fragment files on device now? [y/N]"
    if ($clean -eq "y" -or $clean -eq "Y") {
        adb shell "rm -rf $FragBase" 2>$null
        Write-OK "Fragment files removed."
        $ci = Get-StorageInfo
        if ($ci) { Show-StorageInfo $ci "After cleanup" }
    }
} else {
    Write-Info "Skipping cleanup (use -CleanupOnly to clean up later)."
}
