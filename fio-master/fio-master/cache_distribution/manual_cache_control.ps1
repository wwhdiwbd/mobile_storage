# Advanced Cold Start Test - Manual Cache Control
# This script provides manual control over different cache types

param(
    [string]$packageName = "tv.danmaku.bili"
)

Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "          Advanced Cold Start Test - Cache Control                  " -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan

# Get app info
Write-Host "`nGetting app information..." -ForegroundColor Yellow
$appPath = (adb shell pm path $packageName 2>$null) -replace "package:", "" | ForEach-Object { $_.Trim() }
$appDir = $appPath -replace "/base\.apk$", ""

Write-Host "App Path: $appPath" -ForegroundColor Green
Write-Host "App Dir: $appDir" -ForegroundColor Green

# Display current cache status
Write-Host "`n----- Current Cache Status -----" -ForegroundColor Magenta

Write-Host "`n1. Page Cache (file system cache):" -ForegroundColor Yellow
$pageCache = adb shell "cat /proc/meminfo | grep -E 'Cached:|Buffers:'" 2>$null
Write-Host $pageCache

Write-Host "`n2. OAT/DEX compiled files:" -ForegroundColor Yellow
$oatFiles = adb shell "ls -lh $appDir/oat/" 2>$null
Write-Host $oatFiles

Write-Host "`n3. App cache directories:" -ForegroundColor Yellow
$appCache = adb shell "du -sh /data/data/$packageName/cache 2>/dev/null" 2>$null
$codeCache = adb shell "du -sh /data/data/$packageName/code_cache 2>/dev/null" 2>$null
Write-Host "Cache: $appCache"
Write-Host "Code Cache: $codeCache"

# Provide options
Write-Host "`n=====================================================================" -ForegroundColor Cyan
Write-Host "                      CACHE CLEARING OPTIONS                         " -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan

Write-Host "`nAvailable cache clearing operations:" -ForegroundColor Yellow
Write-Host "1. Force stop app only (fastest restart)" -ForegroundColor White
Write-Host "2. Clear page cache only (drop_caches=1)" -ForegroundColor White
Write-Host "3. Clear page cache + dentries (drop_caches=2)" -ForegroundColor White
Write-Host "4. Clear all kernel caches (drop_caches=3) - TRUE COLD START" -ForegroundColor White
Write-Host "5. Clear app cache directories" -ForegroundColor White
Write-Host "6. Clear compiled code (OAT files)" -ForegroundColor White
Write-Host "7. FULL RESET: All of the above" -ForegroundColor White
Write-Host "8. Run comparison test (all scenarios)" -ForegroundColor White
Write-Host "9. Exit" -ForegroundColor White

$choice = Read-Host "`nSelect option (1-9)"

switch ($choice) {
    "1" {
        Write-Host "`nForce stopping app..." -ForegroundColor Yellow
        adb shell am force-stop $packageName
        Write-Host "Done. App is stopped but all caches intact." -ForegroundColor Green
    }
    "2" {
        Write-Host "`nClearing page cache (drop_caches=1)..." -ForegroundColor Yellow
        adb shell am force-stop $packageName
        adb shell "sync"
        adb shell "echo 1 > /proc/sys/vm/drop_caches"
        Write-Host "Done. Page cache cleared." -ForegroundColor Green
    }
    "3" {
        Write-Host "`nClearing page cache + dentries (drop_caches=2)..." -ForegroundColor Yellow
        adb shell am force-stop $packageName
        adb shell "sync"
        adb shell "echo 2 > /proc/sys/vm/drop_caches"
        Write-Host "Done. Page cache and dentries cleared." -ForegroundColor Green
    }
    "4" {
        Write-Host "`nClearing ALL kernel caches (drop_caches=3)..." -ForegroundColor Yellow
        adb shell am force-stop $packageName
        adb shell "sync"
        adb shell "echo 3 > /proc/sys/vm/drop_caches"
        Write-Host "Done. All kernel caches cleared - TRUE COLD START!" -ForegroundColor Green
    }
    "5" {
        Write-Host "`nClearing app cache directories..." -ForegroundColor Yellow
        adb shell am force-stop $packageName
        adb shell "rm -rf /data/data/$packageName/cache/*"
        adb shell "rm -rf /data/data/$packageName/code_cache/*"
        Write-Host "Done. App cache directories cleared." -ForegroundColor Green
    }
    "6" {
        Write-Host "`nClearing compiled code (OAT files)..." -ForegroundColor Yellow
        adb shell am force-stop $packageName
        adb shell "rm -rf $appDir/oat/*"
        Write-Host "Done. OAT files removed. Next launch will recompile." -ForegroundColor Green
        Write-Host "NOTE: This will significantly slow down the first launch!" -ForegroundColor Red
    }
    "7" {
        Write-Host "`nFULL RESET - Clearing everything..." -ForegroundColor Yellow
        adb shell am force-stop $packageName
        Write-Host "  - Clearing app cache..." -ForegroundColor Gray
        adb shell "rm -rf /data/data/$packageName/cache/*"
        adb shell "rm -rf /data/data/$packageName/code_cache/*"
        Write-Host "  - Clearing OAT files..." -ForegroundColor Gray
        adb shell "rm -rf $appDir/oat/*"
        Write-Host "  - Syncing filesystems..." -ForegroundColor Gray
        adb shell "sync"
        Write-Host "  - Dropping all kernel caches..." -ForegroundColor Gray
        adb shell "echo 3 > /proc/sys/vm/drop_caches"
        Write-Host "Done. COMPLETE COLD START environment ready!" -ForegroundColor Green
    }
    "8" {
        Write-Host "`nRunning comparison test..." -ForegroundColor Yellow
        & "$PSScriptRoot\test_cold_start_bilibili.ps1"
        return
    }
    "9" {
        Write-Host "`nExiting..." -ForegroundColor Yellow
        return
    }
    default {
        Write-Host "`nInvalid option!" -ForegroundColor Red
        return
    }
}

Write-Host "`n=====================================================================" -ForegroundColor Cyan
Write-Host "Ready to launch app with selected cache configuration" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan

$launch = Read-Host "`nLaunch app now? (y/n)"
if ($launch -eq "y") {
    Write-Host "`nLaunching app and measuring time..." -ForegroundColor Yellow
    $output = adb shell "am start -W -n $packageName/.ui.splash.SplashActivity"
    Write-Host $output
    
    foreach ($line in $output) {
        if ($line -match "TotalTime:\s*(\d+)") {
            Write-Host "`nTotalTime: $($matches[1]) ms" -ForegroundColor Green
        }
        if ($line -match "ThisTime:\s*(\d+)") {
            Write-Host "DisplayTime: $($matches[1]) ms" -ForegroundColor Green
        }
    }
}

Write-Host "`n=====================================================================" -ForegroundColor Green
Write-Host "EXPLANATION OF CACHE TYPES:" -ForegroundColor Yellow
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host "1. Page Cache: Kernel caches file contents in RAM" -ForegroundColor White
Write-Host "   - Keeps recently read APK data in memory" -ForegroundColor Gray
Write-Host "   - drop_caches=1 clears this" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Dentries/Inodes: Directory and file metadata cache" -ForegroundColor White
Write-Host "   - Speeds up file path lookups" -ForegroundColor Gray
Write-Host "   - drop_caches=2 clears this" -ForegroundColor Gray
Write-Host ""
Write-Host "3. OAT files: Pre-compiled app code (ART ahead-of-time)" -ForegroundColor White
Write-Host "   - Located in /data/app/.../oat/" -ForegroundColor Gray
Write-Host "   - Removing forces recompilation on next launch" -ForegroundColor Gray
Write-Host ""
Write-Host "4. App Cache: Application's own cached data" -ForegroundColor White
Write-Host "   - Located in /data/data/.../cache/" -ForegroundColor Gray
Write-Host ""
Write-Host "For TRUE cold start: Use option 4 or 7" -ForegroundColor Yellow
Write-Host "=====================================================================" -ForegroundColor Green
