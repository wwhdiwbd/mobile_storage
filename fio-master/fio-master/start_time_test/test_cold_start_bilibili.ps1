# Bilibili Cold Start Performance Test Script
# This script tests app launch performance with different cache scenarios

param(
    [int]$iterations = 3,
    [string]$packageName = "tv.danmaku.bili",
    [string]$activityName = ".MainActivityV2"
)

$reportFile = "bilibili_cold_start_report.csv"

Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "           Bilibili Cold Start Performance Test                     " -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "Package: $packageName" -ForegroundColor Green
Write-Host "Iterations: $iterations" -ForegroundColor Green
Write-Host ""

# Prepare CSV report
$results = @()
$results += [PSCustomObject]@{
    TestNumber = "Test"
    Scenario = "Scenario"
    TotalTime = "TotalTime(ms)"
    DisplayTime = "DisplayTime(ms)"
    Timestamp = "Timestamp"
}

function Clear-AllCaches {
    Write-Host "Clearing all caches..." -ForegroundColor Yellow
    
    # Force stop app
    Write-Host "  - Force stopping app" -ForegroundColor Gray
    adb shell am force-stop $packageName 2>$null
    Start-Sleep -Seconds 1
    
    # Clear app data (optional - includes user data)
    # Uncomment if you want to clear app data as well
    # Write-Host "  - Clearing app data" -ForegroundColor Gray
    # adb shell pm clear $packageName 2>$null
    
    # Clear app cache only
    Write-Host "  - Clearing app cache" -ForegroundColor Gray
    adb shell "rm -rf /data/data/$packageName/cache/*" 2>$null
    adb shell "rm -rf /data/data/$packageName/code_cache/*" 2>$null
    
    # Drop page cache, dentries and inodes
    Write-Host "  - Dropping system caches (requires root)" -ForegroundColor Gray
    adb shell "sync" 2>$null
    adb shell "echo 3 > /proc/sys/vm/drop_caches" 2>$null
    
    Start-Sleep -Seconds 2
}

function Clear-PageCacheOnly {
    Write-Host "Clearing page cache only..." -ForegroundColor Yellow
    
    # Force stop app
    adb shell am force-stop $packageName 2>$null
    Start-Sleep -Seconds 1
    
    # Drop page cache only
    Write-Host "  - Dropping page cache (requires root)" -ForegroundColor Gray
    adb shell "sync" 2>$null
    adb shell "echo 3 > /proc/sys/vm/drop_caches" 2>$null
    
    Start-Sleep -Seconds 2
}

function Start-AppAndMeasure {
    param([string]$scenario)
    
    Write-Host "  Starting app: $scenario" -ForegroundColor Cyan
    
    # Launch and measure
    $output = adb shell "am start -W -n $packageName/$activityName" 2>$null
    # adb shell "am start -W -n tv.danmaku.bili/.MainActivityV2" 2>$null
    # Parse output
    # Output format:
    # Status: ok
    # Activity: ...
    # ThisTime: 1234
    # TotalTime: 5678
    # WaitTime: 5678
    # Complete
    
    $totalTime = "N/A"
    $displayTime = "N/A"
    
    foreach ($line in $output) {
        if ($line -match "TotalTime:\s*(\d+)") {
            $totalTime = $matches[1]
        }
        if ($line -match "ThisTime:\s*(\d+)") {
            $displayTime = $matches[1]
        }
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    Write-Host "    TotalTime: ${totalTime}ms" -ForegroundColor Green
    Write-Host "    DisplayTime: ${displayTime}ms" -ForegroundColor Green
    
    return [PSCustomObject]@{
        Scenario = $scenario
        TotalTime = $totalTime
        DisplayTime = $displayTime
        Timestamp = $timestamp
    }
}

# Test 1: Warm Start (with cache)
Write-Host "`n----- Test 1: Warm Start (with all caches) -----" -ForegroundColor Magenta
for ($i = 1; $i -le $iterations; $i++) {
    Write-Host "`nIteration $i of ${iterations}:" -ForegroundColor Yellow
    adb shell am force-stop $packageName 2>$null
    Start-Sleep -Seconds 1
    
    $result = Start-AppAndMeasure -scenario "WarmStart"
    $result | Add-Member -NotePropertyName TestNumber -NotePropertyValue $i
    $results += $result
    
    Start-Sleep -Seconds 3
}

# Test 2: Cold Start (no page cache)
Write-Host "`n----- Test 2: Cold Start (page cache dropped) -----" -ForegroundColor Magenta
for ($i = 1; $i -le $iterations; $i++) {
    Write-Host "`nIteration $i of ${iterations}:" -ForegroundColor Yellow
    Clear-PageCacheOnly
    
    $result = Start-AppAndMeasure -scenario "ColdStart_NoPageCache"
    $result | Add-Member -NotePropertyName TestNumber -NotePropertyValue $i
    $results += $result
    
    Start-Sleep -Seconds 3
}

# Test 3: Completely Cold Start (all caches dropped)
Write-Host "`n----- Test 3: Completely Cold Start (all caches dropped) -----" -ForegroundColor Magenta
for ($i = 1; $i -le $iterations; $i++) {
    Write-Host "`nIteration $i of ${iterations}:" -ForegroundColor Yellow
    Clear-AllCaches
    
    $result = Start-AppAndMeasure -scenario "ColdStart_NoCaches"
    $result | Add-Member -NotePropertyName TestNumber -NotePropertyValue $i
    $results += $result
    
    Start-Sleep -Seconds 3
}

# Save results
$results | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8

# Calculate averages
Write-Host "`n=====================================================================" -ForegroundColor Cyan
Write-Host "                        TEST RESULTS SUMMARY                         " -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan

$scenarios = @("WarmStart", "ColdStart_NoPageCache", "ColdStart_NoCaches")
foreach ($scenario in $scenarios) {
    $scenarioResults = $results | Where-Object { $_.Scenario -eq $scenario -and $_.TotalTime -ne "N/A" }
    
    if ($scenarioResults) {
        $avgTotal = ($scenarioResults | Measure-Object -Property TotalTime -Average).Average
        $avgDisplay = ($scenarioResults | Measure-Object -Property DisplayTime -Average).Average
        
        Write-Host "`n$scenario :" -ForegroundColor Yellow
        Write-Host "  Average TotalTime:   $([math]::Round($avgTotal, 2)) ms" -ForegroundColor White
        Write-Host "  Average DisplayTime: $([math]::Round($avgDisplay, 2)) ms" -ForegroundColor White
    }
}

Write-Host "`n=====================================================================" -ForegroundColor Green
Write-Host "Results saved to: $reportFile" -ForegroundColor Green
Write-Host "=====================================================================" -ForegroundColor Green

Write-Host "`nEXPLANATION:" -ForegroundColor Yellow
Write-Host "- WarmStart: App stopped but caches intact" -ForegroundColor Gray
Write-Host "- ColdStart_NoPageCache: Page cache dropped, simulates first boot" -ForegroundColor Gray
Write-Host "- ColdStart_NoCaches: All caches dropped, truly cold start" -ForegroundColor Gray
Write-Host "`nTotalTime: Time until app is fully loaded" -ForegroundColor Gray
Write-Host "DisplayTime: Time until first frame is displayed" -ForegroundColor Gray
