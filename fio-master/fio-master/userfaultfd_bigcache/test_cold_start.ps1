# Simple Cold Start Test Script matching the user's manual loop
# Does NOT clear application data/cache files, only system page cache and stop the process.

$packageName = "tv.danmaku.bili"
$activityName = "$packageName/.MainActivityV2"
$iterations = 5

Write-Host "Starting Cold Start Test for $packageName ($iterations iterations)..." -ForegroundColor Cyan

for ($i = 1; $i -le $iterations; $i++) {
    Write-Host "`n--- Iteration ${i}: Cold Start (No Warmup) ---" -ForegroundColor Yellow
    
    # 1. Force stop the app
    adb shell am force-stop $packageName
    
    # 2. Sync and Drop system page caches (requires root shell usually)
    # Using a single adb shell command to ensure they run together in the shell environment
    adb shell "sync; echo 3 > /proc/sys/vm/drop_caches"
    
    # 3. Sleep to let system settle
    Start-Sleep -Seconds 2
    
    # 4. Start the app and measure time
    Write-Host "Launching app..." -NoNewline
    $output = adb shell am start -W $activityName
    
    # 5. Extract TotalTime
    $totalTimeLine = $output | Where-Object { $_ -match "TotalTime" }
    
    if ($totalTimeLine) {
        # Extract just the number for cleaner output
        # Format usually: TotalTime: 1234
        $time = $totalTimeLine -replace "TotalTime:\s*", ""
        Write-Host " Done. TotalTime: $time ms" -ForegroundColor Green
    } else {
        Write-Host " Failed to capture TotalTime." -ForegroundColor Red
        Write-Host "$output" -ForegroundColor Gray
    }
}

# --- BigCache Test Section ---

$tracerLocalPath = ".\android_build\tracer"
$tracerRemotePath = "/data/local/tmp/tracer"
$cacheRemotePath = "/data/local/tmp/bigcache_real.bin"
$wrapperRemotePath = "/data/local/tmp/tracer_wrapper.sh"

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "       BigCache Cold Start Performance       " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Setup Tracer & Wrapper
if (Test-Path $tracerLocalPath) {
    Write-Host "Pushing tracer to device..." -ForegroundColor Gray
    adb push $tracerLocalPath $tracerRemotePath
    adb shell "chmod 755 $tracerRemotePath"
} else {
    Write-Host "Warning: Tracer binary not found at $tracerLocalPath." -ForegroundColor Yellow
}

Write-Host "Setting up wrapper script..." -ForegroundColor Gray
# Create wrapper script that execs tracer
# Note: quoting for powershell to pass through to adb shell
adb shell "echo '#!/system/bin/sh' > $wrapperRemotePath"
# We want: exec ... -- "$@"
# Powershell escaping: "`$@" becomes $@
adb shell "echo 'exec $tracerRemotePath $cacheRemotePath -- ""`$@""' >> $wrapperRemotePath"
adb shell "chmod 755 $wrapperRemotePath"

# 2. Enable Wrapper Property
# This tells Zygote to run our wrapper instead of starting the app process directly
Write-Host "Enabling wrap property: wrap.$packageName" -ForegroundColor Yellow
adb shell "setprop wrap.$packageName $wrapperRemotePath"

# 3. Test Loop
for ($i = 1; $i -le $iterations; $i++) {
    Write-Host "`n--- Iteration ${i}: BigCache Start ---" -ForegroundColor Yellow
    
    # Force stop to ensure next start picks up the wrapper property (or kills existing process)
    adb shell am force-stop $packageName
    adb shell "sync; echo 3 > /proc/sys/vm/drop_caches"
    Start-Sleep -Seconds 2
    
    Write-Host "Launching with BigCache..." -NoNewline
    
    # Just run standard AM Start. The wrapper handles the interception.
    $output = adb shell am start -W $activityName
    
    $totalTimeLine = $output | Where-Object { $_ -match "TotalTime" }
    
    if ($totalTimeLine) {
        $time = $totalTimeLine -replace "TotalTime:\s*", ""
        Write-Host " Done. TotalTime: $time ms" -ForegroundColor Green
    } else {
        Write-Host " Failed." -ForegroundColor Red
        # Check if it crashed
        Write-Host "Output: $output" -ForegroundColor Gray
    }
}

# 4. Cleanup
Write-Host "`nCleaning up..." -ForegroundColor Cyan
adb shell "setprop wrap.$packageName ''"
adb shell "rm $wrapperRemotePath"

