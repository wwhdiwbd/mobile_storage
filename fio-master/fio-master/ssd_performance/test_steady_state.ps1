# Test Steady State Performance - Guaranteed Disk Persistence
# Pre-warm to fill SLC cache, then test steady-state performance

$testDir = "/data/local/tmp"
$fioPath = "$testDir/fio"
$testFile = "$testDir/fio_test"

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Steady State Performance Test - Guaranteed Disk Persistence" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan

Write-Host ""
Write-Host "[Test Strategy]" -ForegroundColor Yellow
Write-Host ""
Write-Host "Phase 1: Warm-up" -ForegroundColor Cyan
Write-Host "  * Write 4GB data to fill SLC cache" -ForegroundColor Gray
Write-Host "  * Let flash enter steady state" -ForegroundColor Gray
Write-Host ""
Write-Host "Phase 2: Formal Test" -ForegroundColor Cyan
Write-Host "  * Test steady-state performance with different block sizes" -ForegroundColor Gray
Write-Host "  * Use fsync=1 to ensure complete persistence" -ForegroundColor Gray
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

# Phase 2: Steady-state performance test
Write-Host "`n" + ("=" * 80) -ForegroundColor Yellow
Write-Host "Phase 2: Steady State Performance Test (Guaranteed Persistence)" -ForegroundColor Yellow
Write-Host ("=" * 80) -ForegroundColor Yellow

$blockSizes = @("4k", "8k", "16k", "32k", "64k", "128k", "256k", "512k", "1m")
$testSize = "1G"
$runtime = 60
$results = @()
$numjobs=4

foreach ($bs in $blockSizes) {
    Write-Host "`nTesting block size: $bs" -ForegroundColor Cyan
    
    # Random read test
    Write-Host "  [1/2] Random read..." -ForegroundColor Gray
    $readCmd = "$fioPath --name=test --ioengine=sync --direct=1 --bs=$bs --size=$testSize --numjobs=$numjobs --runtime=$runtime --time_based --rw=randread --filename=$testFile --output-format=json"
    $readResult = adb shell "$readCmd" | ConvertFrom-Json
    $readBW = [math]::Round($readResult.jobs[0].read.bw / 1024, 2)
    $readIOPS = [math]::Round($readResult.jobs[0].read.iops, 0)
    Write-Host "    Result: $readBW MB/s, $readIOPS IOPS" -ForegroundColor Green
    
    # Random write test with fsync=1
    Write-Host "  [2/2] Random write (fsync=1)..." -ForegroundColor Gray
    $writeCmd = "$fioPath --name=test --ioengine=sync --direct=1 --fsync=1 --bs=$bs --size=$testSize --numjobs=$numjobs --runtime=$runtime --time_based --rw=randwrite --filename=$testFile --output-format=json"
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
Write-Host "Steady State Test Complete!" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "`nResults Summary:" -ForegroundColor Yellow
$results | Format-Table -AutoSize

Write-Host "`n[Important Notes]" -ForegroundColor Yellow
Write-Host ""
Write-Host "This test data represents:" -ForegroundColor Cyan
Write-Host "  * Steady-state performance after warm-up (not SLC cache speed)" -ForegroundColor Gray
Write-Host "  * True performance with complete persistence (using fsync=1)" -ForegroundColor Gray
Write-Host "  * Stable I/O throughput over long period (60s test)" -ForegroundColor Gray
Write-Host ""
Write-Host "Applicable scenarios:" -ForegroundColor Cyan
Write-Host "  * Database sustained write performance evaluation" -ForegroundColor Gray
Write-Host "  * Applications with long-duration heavy writes" -ForegroundColor Gray
Write-Host "  * Scenarios requiring data safety guarantees" -ForegroundColor Gray
Write-Host ""
Write-Host "Compared to previous tests:" -ForegroundColor Cyan
Write-Host "  * Previous tests may be affected by SLC cache" -ForegroundColor Gray
Write-Host "  * This test shows true underlying flash performance" -ForegroundColor Gray
Write-Host "  * Write performance may be significantly lower (this is normal)" -ForegroundColor Gray
Write-Host ""

Write-Host "Results saved to: $csvFile" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan
