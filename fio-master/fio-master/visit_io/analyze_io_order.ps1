# Analyze Bilibili Cold Start IO Data - Time Ordered
# This script analyzes open_fds.txt and shows files in access time order

param(
    [string]$inputDir = "io_analysis_20260126_162551"
)

Write-Host "=== Bilibili Cold Start IO Analysis (Time Ordered) ===" -ForegroundColor Cyan
Write-Host "Analyzing: $inputDir" -ForegroundColor Gray
Write-Host ""

$fdsFile = Join-Path $inputDir "open_fds.txt"

if (-not (Test-Path $fdsFile)) {
    Write-Host "Error: $fdsFile not found!" -ForegroundColor Red
    exit 1
}

$fdsContent = Get-Content $fdsFile

# Parse with timestamp
$fileAccess = @()

foreach ($line in $fdsContent) {
    # Format: lrwx------ 1 u0_a215 u0_a215 64 2026-01-26 16:25 107 -> /data/...
    if ($line -match "(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(\d+)\s+->\s+(.+)$") {
        $date = $matches[1]
        $time = $matches[2]
        $fd = [int]$matches[3]
        $target = $matches[4].Trim()
        
        # Skip anon_inode, socket, pipe (not real files)
        if ($target -notmatch "anon_inode|socket:|pipe:") {
            $fileAccess += [PSCustomObject]@{
                DateTime = "$date $time"
                FD = $fd
                File = $target
                Category = ""
            }
        }
    }
}

# Categorize files
foreach ($item in $fileAccess) {
    $f = $item.File
    if ($f -match "\.apk$") { $item.Category = "APK" }
    elseif ($f -match "\.jar$") { $item.Category = "JAR" }
    elseif ($f -match "\.so") { $item.Category = "SO" }
    elseif ($f -match "\.db") { $item.Category = "DB" }
    elseif ($f -match "\.(blkv|raw_kv|sp|kv)$") { $item.Category = "CONFIG" }
    elseif ($f -match "^/dev/") { $item.Category = "DEVICE" }
    else { $item.Category = "OTHER" }
}

# Sort by FD number (approximates open order since FDs are assigned sequentially)
$sortedByFD = $fileAccess | Sort-Object FD

# Sort by timestamp then FD
$sortedByTime = $fileAccess | Sort-Object DateTime, FD

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "         FILE ACCESS ORDER (by File Descriptor)             " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "FDs are assigned sequentially, so lower FD = opened earlier" -ForegroundColor Gray
Write-Host ""

Write-Host "TIME       FD    CATEGORY   FILE" -ForegroundColor Yellow
Write-Host "-------    ---   --------   ----" -ForegroundColor Yellow

$count = 0
foreach ($item in $sortedByFD) {
    $count++
    $shortFile = $item.File
    # Shorten long paths
    if ($shortFile.Length -gt 70) {
        $shortFile = "..." + $shortFile.Substring($shortFile.Length - 67)
    }
    
    $categoryColor = switch ($item.Category) {
        "APK" { "Magenta" }
        "JAR" { "Blue" }
        "SO" { "Yellow" }
        "DB" { "Green" }
        "CONFIG" { "Cyan" }
        "DEVICE" { "DarkGray" }
        default { "White" }
    }
    
    $timeStr = $item.DateTime.Substring(11)  # Just the time part
    Write-Host ("{0,-10} {1,4}  {2,-8}   " -f $timeStr, $item.FD, $item.Category) -NoNewline
    Write-Host $shortFile -ForegroundColor $categoryColor
}

Write-Host ""
Write-Host "Total files: $count" -ForegroundColor Green

# Show startup sequence phases
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "              STARTUP SEQUENCE ANALYSIS                      " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Phase 1: Very early (FD < 30)
$phase1 = $sortedByFD | Where-Object { $_.FD -lt 30 }
Write-Host "`nPHASE 1: Process Initialization (FD 0-29)" -ForegroundColor Magenta
Write-Host "These are opened by the system when the process starts:" -ForegroundColor Gray
foreach ($item in $phase1) {
    Write-Host ("  [{0,3}] {1}" -f $item.FD, $item.File) -ForegroundColor White
}

# Phase 2: Framework loading (FD 30-100)
$phase2 = $sortedByFD | Where-Object { $_.FD -ge 30 -and $_.FD -lt 100 }
Write-Host "`nPHASE 2: Framework & App Loading (FD 30-99)" -ForegroundColor Magenta
Write-Host "Framework JARs, app APK, and early initialization:" -ForegroundColor Gray
foreach ($item in $phase2) {
    $color = if ($item.Category -eq "APK") { "Yellow" } else { "White" }
    Write-Host ("  [{0,3}] [{1,-6}] {2}" -f $item.FD, $item.Category, ($item.File -replace ".*/", "")) -ForegroundColor $color
}

# Phase 3: App startup (FD 100-200)
$phase3 = $sortedByFD | Where-Object { $_.FD -ge 100 -and $_.FD -lt 200 }
Write-Host "`nPHASE 3: App Startup (FD 100-199)" -ForegroundColor Magenta
Write-Host "App configs, databases, and resources:" -ForegroundColor Gray
$phase3 | ForEach-Object {
    $shortName = $_.File -replace ".*/", ""
    Write-Host ("  [{0,3}] [{1,-6}] {2}" -f $_.FD, $_.Category, $shortName) -ForegroundColor White
}

# Phase 4: Main activity (FD 200+)
$phase4 = $sortedByFD | Where-Object { $_.FD -ge 200 }
Write-Host "`nPHASE 4: Main Activity & Features (FD 200+)" -ForegroundColor Magenta
Write-Host "Feature modules, WebView, and UI resources:" -ForegroundColor Gray
$phase4 | Select-Object -First 30 | ForEach-Object {
    $shortName = $_.File -replace ".*/", ""
    Write-Host ("  [{0,3}] [{1,-6}] {2}" -f $_.FD, $_.Category, $shortName) -ForegroundColor White
}
if ($phase4.Count -gt 30) {
    Write-Host "  ... and $($phase4.Count - 30) more files" -ForegroundColor DarkGray
}

# IO Timeline summary
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                    IO TIMELINE SUMMARY                      " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$times = $fileAccess | Group-Object { $_.DateTime.Substring(11, 5) } | Sort-Object Name
Write-Host "`nFile opens by time (minute:second):" -ForegroundColor Yellow
foreach ($t in $times) {
    $barLen = [math]::Min($t.Count, 50)
    $bar = "#" * $barLen
    Write-Host ("{0}  {1,3} files  {2}" -f $t.Name, $t.Count, $bar) -ForegroundColor Green
}

# Save ordered list
$reportFile = Join-Path $inputDir "file_access_order.txt"
$report = @"
============================================================
     BILIBILI FILE ACCESS ORDER (by File Descriptor)
============================================================
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Lower FD number = opened earlier in startup sequence

FD     TIME        CATEGORY   FILE
----   ----------  --------   ----
"@

foreach ($item in $sortedByFD) {
    $report += "`n{0,-6} {1}  {2,-8}   {3}" -f $item.FD, $item.DateTime, $item.Category, $item.File
}

$report | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host "`nOrdered list saved to: $reportFile" -ForegroundColor Green
