Write-Host "=== Bilibili IO Trace ===" -ForegroundColor Cyan
Write-Host "WARNING: This script will run 2 tests with device cooling time between them" -ForegroundColor Yellow
Write-Host ""

function Clear-PageCacheOnly {
    Write-Host "Clearing page cache only..." -ForegroundColor Yellow
    
    # Force stop app
    adb shell am force-stop tv.danmaku.bili 2>$null
    Start-Sleep -Seconds 1
    
    # Drop page cache only
    Write-Host "  - Dropping page cache (requires root)" -ForegroundColor Gray
    adb shell "sync" 2>$null
    adb shell "echo 3 > /proc/sys/vm/drop_caches" 2>$null
    
    Start-Sleep -Seconds 3
}

function Prepare-ColdStart {
    Write-Host "Preparing for truly cold start..." -ForegroundColor Yellow
    
    # Force stop app
    adb shell am force-stop tv.danmaku.bili 2>$null
    
    # Clear app cache
    Write-Host "  - Clearing app cache" -ForegroundColor Gray
    adb shell "rm -rf /data/data/tv.danmaku.bili/cache/*" 2>$null
    adb shell "rm -rf /data/data/tv.danmaku.bili/code_cache/*" 2>$null
    
    # Drop all caches
    Write-Host "  - Dropping all system caches (requires root)" -ForegroundColor Gray
    adb shell "sync" 2>$null
    adb shell "echo 3 > /proc/sys/vm/drop_caches" 2>$null
    
    Start-Sleep -Seconds 5
}

# ===================================================================
# Test 1: WITHOUT PageCache (True Cold Start)
# Run this first to avoid any warm-up effects
# ===================================================================
Write-Host "`n=== Test 1: WITHOUT PageCache (True Cold Start) ===" -ForegroundColor Magenta
Prepare-ColdStart
$result = adb shell "am start -W -n tv.danmaku.bili/.MainActivityV2" 2>$null
Write-Host $result -ForegroundColor Green
Prepare-ColdStart

Write-Host "1. Starting atrace..." -ForegroundColor Yellow
adb shell "atrace --async_start -b 32768 disk sched am wm view dalvik"
Start-Sleep -Seconds 1

Write-Host "2. Launching Bilibili..." -ForegroundColor Yellow
$result = adb shell "am start -W -n tv.danmaku.bili/.MainActivityV2" 2>$null
Write-Host $result -ForegroundColor Green

Write-Host "3. Waiting for app startup..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

Write-Host "4. Stopping trace..." -ForegroundColor Yellow
adb shell "atrace --async_stop -z -o /data/local/tmp/bili_io_trace_without_pagecache.z"

Write-Host "5. Pulling trace file..." -ForegroundColor Yellow
adb pull /data/local/tmp/bili_io_trace_without_pagecache.z

Write-Host "`nTest 1 Complete. Cooling down device..." -ForegroundColor Green
Write-Host "Waiting 15 seconds for device to stabilize..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# ===================================================================
# Test 2: WITH PageCache (Warm Start)
# Run after device has cooled down
# ===================================================================
Write-Host "`n=== Test 2: WITH PageCache (Warm Start) ===" -ForegroundColor Magenta

# Pre-warm the cache by running the app once
Write-Host "Pre-warming pagecache..." -ForegroundColor Yellow
adb shell am force-stop tv.danmaku.bili 2>$null
adb shell "am start -n tv.danmaku.bili/.MainActivityV2" 2>$null
Start-Sleep -Seconds 5
adb shell am force-stop tv.danmaku.bili 2>$null
Start-Sleep -Seconds 2

Write-Host "1. Starting atrace..." -ForegroundColor Yellow
adb shell "atrace --async_start -b 32768 disk sched am wm view dalvik"
Start-Sleep -Seconds 1

Write-Host "2. Launching Bilibili..." -ForegroundColor Yellow
$result = adb shell "am start -W -n tv.danmaku.bili/.MainActivityV2"
Write-Host $result -ForegroundColor Green

Write-Host "3. Waiting for app startup..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

Write-Host "4. Stopping trace..." -ForegroundColor Yellow
adb shell "atrace --async_stop -z -o /data/local/tmp/bili_io_trace_with_pagecache.z"

Write-Host "`n=====================================================================" -ForegroundColor Cyan
Write-Host "                        TRACE COLLECTION COMPLETE                    " -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan

$file1 = Get-Item .\bili_io_trace_without_pagecache.z -ErrorAction SilentlyContinue
$file2 = Get-Item .\bili_io_trace_with_pagecache.z -ErrorAction SilentlyContinue

if ($file1 -and $file2) {
    $size1MB = [math]::Round($file1.Length/1MB, 2)
    $size2MB = [math]::Round($file2.Length/1MB, 2)
    
    Write-Host "`nGenerated trace files:" -ForegroundColor Green
    Write-Host "  1. WITHOUT PageCache: .\bili_io_trace_without_pagecache.z ($size1MB MB)" -ForegroundColor White
    Write-Host "  2. WITH PageCache:    .\bili_io_trace_with_pagecache.z ($size2MB MB)" -ForegroundColor White
    
    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "  1. Open https://ui.perfetto.dev in browser" -ForegroundColor White
    Write-Host "  2. Drag and drop the trace files to analyze" -ForegroundColor White
    Write-Host "`nNote: The WITHOUT PageCache test was run first to capture true cold start behavior" -ForegroundColor Gray
} else {
    Write-Host "Error: Trace files not generated properly" -ForegroundColor Red
    if (-not $file1) { Write-Host "  Missing: bili_io_trace_without_pagecache.z" -ForegroundColor Red }
    if (-not $file2) { Write-Host "  Missing: bili_io_trace_with_pagecache.z" -ForegroundColor Red }dColor White
    Write-Host "Then drag in: .\bili_io_trace_with_pagecache.z" -ForegroundColor White
} else {
    Write-Host "Error: Trace file not generated" -ForegroundColor Red
}