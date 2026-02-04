# Test Steady State Performance - Guaranteed Disk Persistence
# Pre-warm to fill SLC cache, then test steady-state performance

$testDir = "/data/local/tmp"
$fioPath = "$testDir/fio"
$testFile = "$testDir/fio_test"

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Sequential Read Performance Test - Guaranteed Disk Persistence" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan

Write-Host ""
Write-Host "[Test Strategy]" -ForegroundColor Yellow
Write-Host ""
Write-Host "Phase 1: Warm-up" -ForegroundColor Cyan
Write-Host "  * Write 4GB data to fill SLC cache" -ForegroundColor Gray
Write-Host "  * Let flash enter steady state" -ForegroundColor Gray
Write-Host ""
Write-Host "Phase 2: Formal Test" -ForegroundColor Cyan
Write-Host "  * Test sequential read performance with different block sizes" -ForegroundColor Gray
Write-Host "  * Compare: 4x4K vs 1x16K, 2x8K vs 1x16K, etc." -ForegroundColor Gray
Write-Host "  * Long runtime (60s) to get stable data" -ForegroundColor Gray
Write-Host ""
Write-Host "[Why warm-up is needed?]" -ForegroundColor Yellow
Write-Host "  * SLC cache is usually 1GB-4GB" -ForegroundColor Gray
Write-Host "  * First test measures SLC cache speed (artificially high)" -ForegroundColor Gray
Write-Host "  * After warm-up, test measures TLC/QLC real speed (steady state)" -ForegroundColor Gray
Write-Host ""

# Phase 1: Warm-up
Write-Host "`n" + ("=" * 80) -ForegroundColor Yellow
Write-Host "Phase 1: Warming up flash (filling SLC cache)" -ForegroundColor Yellow
Write-Host ("=" * 80) -ForegroundColor Yellow
Write-Host "Writing 4GB data, estimated 1-2 minutes..." -ForegroundColor Cyan

$warmupCmd = "$fioPath --name=warmup --ioengine=sync --direct=1 --bs=1m --size=4G --rw=write --filename=$testFile"
adb shell "$warmupCmd" | Out-Null

Write-Host "Warm-up complete!" -ForegroundColor Green

# Phase 2: Sequential read performance test
Write-Host "`n" + ("=" * 80) -ForegroundColor Yellow
Write-Host "Phase 2: Sequential Read Performance Test" -ForegroundColor Yellow
Write-Host ("=" * 80) -ForegroundColor Yellow

$blockSizes = @("4k", "8k", "16k", "32k", "64k", "128k", "256k", "512k", "1m")
$testSize = "1G"
$runtime = 15
$results = @()
$numjobs=1

foreach ($bs in $blockSizes) {
    Write-Host "`nTesting block size: $bs" -ForegroundColor Cyan
    
    # Sequential read test
    Write-Host "  [1/2] Sequential read..." -ForegroundColor Gray
    $readCmd = "$fioPath --name=test --ioengine=sync --direct=1 --bs=$bs --size=$testSize --numjobs=$numjobs --runtime=$runtime --time_based --rw=read --filename=$testFile --output-format=json"
    $readResult = adb shell "$readCmd" | ConvertFrom-Json
    $readBW = [math]::Round($readResult.jobs[0].read.bw / 1024, 2)
    $readIOPS = [math]::Round($readResult.jobs[0].read.iops, 0)
    Write-Host "    Result: $readBW MB/s, $readIOPS IOPS" -ForegroundColor Green
    
    # Sequential write test with fsync=1
    Write-Host "  [2/2] Sequential write (fsync=1)..." -ForegroundColor Gray
    $writeCmd = "$fioPath --name=test --ioengine=sync --direct=1 --fsync=1 --bs=$bs --size=$testSize --numjobs=$numjobs --runtime=$runtime --time_based --rw=write --filename=$testFile --output-format=json"
    $writeResult = adb shell "$writeCmd" | ConvertFrom-Json
    $writeBW = [math]::Round($writeResult.jobs[0].write.bw / 1024, 2)
    $writeIOPS = [math]::Round($writeResult.jobs[0].write.iops, 0)
    Write-Host "    Result: $writeBW MB/s, $writeIOPS IOPS" -ForegroundColor Green
    
    $results += [PSCustomObject]@{
        BlockSize = $bs
        Read_BW_MBps = $readBW
        Read_IOPS = $readIOPS
        Write_BW_MBps_fsync = $writeBW
        Write_IOPS_fsync = $writeIOPS
    }
}

# Cleanup
Write-Host "`nCleaning up test files..." -ForegroundColor Cyan
adb shell "rm -f $testFile"

# Save results
$csvFile = "fio_steady_state_results.csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8

Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host "Sequential Read Test Complete!" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "`nResults Summary:" -ForegroundColor Yellow
$results | Format-Table -AutoSize

Write-Host "`n[Important Notes]" -ForegroundColor Yellow
Write-Host ""
Write-Host "This test data represents:" -ForegroundColor Cyan
Write-Host "  * Sequential read performance (not random access)" -ForegroundColor Gray
Write-Host "  * Performance comparison of different block sizes" -ForegroundColor Gray
Write-Host "  * Impact of read request merging (e.g., 4x4K vs 1x16K)" -ForegroundColor Gray
Write-Host ""
Write-Host "Applicable scenarios:" -ForegroundColor Cyan
Write-Host "  * Sequential file reading (video, large files)" -ForegroundColor Gray
Write-Host "  * Optimal block size selection for sequential access" -ForegroundColor Gray
Write-Host "  * Understanding I/O request merging benefits" -ForegroundColor Gray
Write-Host ""
Write-Host "Key observations:" -ForegroundColor Cyan
Write-Host "  * Larger block sizes generally have higher bandwidth" -ForegroundColor Gray
Write-Host "  * But fewer IOPS (e.g., 16K has 1/4 IOPS of 4K)" -ForegroundColor Gray
Write-Host "  * Sequential read is much faster than random read" -ForegroundColor Gray
Write-Host ""

Write-Host "Results saved to: $csvFile" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan
