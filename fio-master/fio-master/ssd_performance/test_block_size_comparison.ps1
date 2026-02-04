# Block Size Comparison Test: 4x4K vs 1x16K Sequential Read
# Test the performance difference between multiple small I/Os vs single large I/O

$testDir = "/data/local/tmp"
$fioPath = "$testDir/fio"
$testFile = "$testDir/fio_test"

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Block Size I/O Efficiency Comparison Test" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan

Write-Host ""
Write-Host "[Test Objective]" -ForegroundColor Yellow
Write-Host "  Compare the performance difference when reading the same amount of data:" -ForegroundColor Gray
Write-Host "  * Method 1: 4 concurrent 4K reads (iodepth=4, 4 I/O operations)" -ForegroundColor Cyan
Write-Host "  * Method 2: 1 single 16K read     (iodepth=1, 1 I/O operation)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Both methods read 16K total data, but with different I/O patterns." -ForegroundColor Gray
Write-Host "  Using psync engine with iodepth to simulate concurrent I/Os." -ForegroundColor Gray
Write-Host ""

# Prepare test file
Write-Host "Preparing test file (2GB)..." -ForegroundColor Cyan
$prepCmd = "$fioPath --name=prep --ioengine=sync --direct=1 --bs=1m --size=2G --rw=write --filename=$testFile"
adb shell "$prepCmd" | Out-Null
Write-Host "Test file ready!" -ForegroundColor Green

# Test configurations - comparing 4x4K vs 1x16K with proper iodepth
$testConfigs = @(
    @{Name="4K_4Concurrent"; BS="4k"; IODepth=4; Desc="4 concurrent 4K reads (iodepth=4)"; Color="Yellow"},
    @{Name="16K_Single"; BS="16k"; IODepth=1; Desc="1 single 16K read (iodepth=1)"; Color="Green"}
)

Write-Host "`n" + ("=" * 80) -ForegroundColor Yellow
Write-Host "Performance Test - Sequential Read Comparison" -ForegroundColor Yellow
Write-Host ("=" * 80) -ForegroundColor Yellow
Write-Host ""

$results = @()
$runtime = 30

foreach ($config in $testConfigs) {
    $bs = $config.BS
    $name = $config.Name
    $desc = $config.Desc
    $iodepth = $config.IODepth
    
    Write-Host "Testing: $desc (bs=$bs, iodepth=$iodepth)" -ForegroundColor $config.Color
    Write-Host "  Running 30s test..." -ForegroundColor Gray
    
    # Sequential read test with proper iodepth control
    $readCmd = "$fioPath --name=$name --ioengine=psync --direct=1 --bs=$bs --iodepth=$iodepth --size=2G --runtime=$runtime --time_based --rw=read --filename=$testFile --output-format=json"
    $readResult = adb shell "$readCmd" | ConvertFrom-Json
    
    $bw_MBps = [math]::Round($readResult.jobs[0].read.bw / 1024, 2)
    $iops = [math]::Round($readResult.jobs[0].read.iops, 0)
    $lat_us = [math]::Round($readResult.jobs[0].read.lat_ns.mean / 1000, 2)
    
    # Calculate effective throughput for reading 16KB data
    $blockSizeKB = switch ($bs) {
        "4k" { 4 }
        "8k" { 8 }
        "16k" { 16 }
        "32k" { 32 }
        "64k" { 64 }
    }
    
    $io_per_16KB = [math]::Ceiling(16 / $blockSizeKB)
    $effective_16KB_ops = [math]::Round($iops / $io_per_16KB, 0)
    $effective_bw_16KB = [math]::Round($effective_16KB_ops * 16 / 1024, 2)
    
    Write-Host "    Bandwidth: $bw_MBps MB/s" -ForegroundColor White
    Write-Host "    IOPS: $iops" -ForegroundColor White
    Write-Host "    Latency: $lat_us μs" -ForegroundColor White
    Write-Host "    Effective 16KB read rate: $effective_16KB_ops times/sec" -ForegroundColor Cyan
    Write-Host ""
    
    $results += [PSCustomObject]@{
        IODepth = $iodepth
        BlockSize = $bs
        Description = $desc
        Bandwidth_MBps = $bw_MBps
        IOPS = $iops
        Latency_us = $lat_us
        IO_per_16KB = $io_per_16KB
        Effective_16KB_Reads_per_sec = $effective_16KB_ops
        Effective_16KB_Bandwidth_MBps = $effective_bw_16KB
    }
}

# Cleanup
Write-Host "Cleaning up test files..." -ForegroundColor Cyan
adb shell "rm -f $testFile"

# Save results
$csvFile = "fio_block_comparison_results.csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8

Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host "Test Complete!" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan

Write-Host "`n[Results Summary]" -ForegroundColor Yellow
$results | Format-Table -AutoSize

Write-Host "`n[Key Findings]" -ForegroundColor Yellow
Write-Host ""

# Calculate 4K vs 16K comparison
$result_4k = $results | Where-Object { $_.BlockSize -eq "4k" }
$result_16k = $results | Where-Object { $_.BlockSize -eq "16k" }

if ($result_4k -and $result_16k) {
    $bw_ratio = [math]::Round($result_16k.Bandwidth_MBps / $result_4k.Bandwidth_MBps, 2)
    $lat_ratio = [math]::Round($result_4k.Latency_us / $result_16k.Latency_us, 2)
    $effective_ratio = [math]::Round($result_16k.Effective_16KB_Reads_per_sec / $result_4k.Effective_16KB_Reads_per_sec, 2)
    
    Write-Host "4x4K (iodepth=4) vs 1x16K (iodepth=1) Performance Comparison:" -ForegroundColor Cyan
    Write-Host "  * Bandwidth improvement: ${bw_ratio}x" -ForegroundColor White
    Write-Host "    (16K: $($result_16k.Bandwidth_MBps) MB/s vs 4K: $($result_4k.Bandwidth_MBps) MB/s)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  * Latency comparison: 4K is ${lat_ratio}x faster (but requires 4 I/Os)" -ForegroundColor White
    Write-Host "    (4K: $($result_4k.Latency_us) μs vs 16K: $($result_16k.Latency_us) μs)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  * Effective 16KB read rate improvement: ${effective_ratio}x" -ForegroundColor White
    Write-Host "    (16K: $($result_16k.Effective_16KB_Reads_per_sec) reads/s vs 4K: $($result_4k.Effective_16KB_Reads_per_sec) reads/s)" -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "[Why is 1x16K faster than 4x4K?]" -ForegroundColor Yellow
    Write-Host "  1. Single large request vs 4 small requests" -ForegroundColor Gray
    Write-Host "  2. Lower overhead: 1 syscall vs 4 syscalls" -ForegroundColor Gray
    Write-Host "  3. Better I/O merging at block layer" -ForegroundColor Gray
    Write-Host "  4. Less CPU time spent on I/O management" -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "[Practical Implications]" -ForegroundColor Yellow
    Write-Host "  * For sequential file reading: Use larger block sizes (16K-64K)" -ForegroundColor Gray
    Write-Host "  * For video/media playback: Larger blocks = smoother playback" -ForegroundColor Gray
    Write-Host "  * For app cold start: Batch adjacent files into larger reads" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Results saved to: $csvFile" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan
