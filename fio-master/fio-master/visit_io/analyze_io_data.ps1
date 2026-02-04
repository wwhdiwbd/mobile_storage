# Analyze Bilibili Cold Start IO Data
# This script analyzes open_fds.txt and memory_maps.txt

param(
    [string]$inputDir = "io_analysis_20260126_162551"  # Change this to your directory
)

Write-Host "=== Bilibili Cold Start IO Analysis ===" -ForegroundColor Cyan
Write-Host "Analyzing: $inputDir" -ForegroundColor Gray
Write-Host ""

# Read open_fds.txt
$fdsFile = Join-Path $inputDir "open_fds.txt"
$mapsFile = Join-Path $inputDir "memory_maps.txt"

if (-not (Test-Path $fdsFile)) {
    Write-Host "Error: $fdsFile not found!" -ForegroundColor Red
    exit 1
}

$fdsContent = Get-Content $fdsFile

# Parse file descriptors
$files = @{
    "APK/DEX" = @()
    "JAR (Framework)" = @()
    "Native Libraries (.so)" = @()
    "Databases (.db)" = @()
    "Config/Preferences" = @()
    "Sockets/Pipes" = @()
    "Devices" = @()
    "Other" = @()
}

foreach ($line in $fdsContent) {
    if ($line -match "-> (.+)$") {
        $target = $matches[1]
        
        if ($target -match "\.apk$") {
            $files["APK/DEX"] += $target
        }
        elseif ($target -match "\.jar$") {
            $files["JAR (Framework)"] += $target
        }
        elseif ($target -match "\.so") {
            $files["Native Libraries (.so)"] += $target
        }
        elseif ($target -match "\.db") {
            $files["Databases (.db)"] += $target
        }
        elseif ($target -match "\.(blkv|raw_kv|sp|kv)$") {
            $files["Config/Preferences"] += $target
        }
        elseif ($target -match "socket:|pipe:") {
            $files["Sockets/Pipes"] += $target
        }
        elseif ($target -match "^/dev/") {
            $files["Devices"] += $target
        }
        elseif ($target -notmatch "anon_inode") {
            $files["Other"] += $target
        }
    }
}

# Remove duplicates
foreach ($key in $files.Keys) {
    $files[$key] = $files[$key] | Sort-Object -Unique
}

# Print analysis
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "              FILE DESCRIPTOR ANALYSIS                       " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Summary
Write-Host "SUMMARY:" -ForegroundColor Yellow
Write-Host "--------" -ForegroundColor Yellow
$total = 0
foreach ($key in $files.Keys | Sort-Object) {
    $count = $files[$key].Count
    $total += $count
    Write-Host ("  {0,-25} : {1}" -f $key, $count) -ForegroundColor White
}
Write-Host ("  {0,-25} : {1}" -f "TOTAL", $total) -ForegroundColor Green
Write-Host ""

# Detailed Analysis
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "              DETAILED BREAKDOWN                             " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 1. APK Files - Most important for cold start
Write-Host "`n1. APK/DEX FILES (Critical for cold start IO)" -ForegroundColor Magenta
Write-Host "   These are loaded from disk when page cache is empty:" -ForegroundColor Gray
foreach ($f in $files["APK/DEX"]) {
    Write-Host "   • $f" -ForegroundColor White
}

# 2. Framework JARs
Write-Host "`n2. FRAMEWORK JAR FILES" -ForegroundColor Magenta
Write-Host "   System framework libraries:" -ForegroundColor Gray
foreach ($f in $files["JAR (Framework)"]) {
    Write-Host "   • $f" -ForegroundColor White
}

# 3. Databases
Write-Host "`n3. DATABASE FILES" -ForegroundColor Magenta
Write-Host "   SQLite databases accessed during startup:" -ForegroundColor Gray
$dbFiles = $files["Databases (.db)"] | Where-Object { $_ -notmatch "-wal|-shm" } | Sort-Object -Unique
foreach ($f in $dbFiles) {
    Write-Host "   • $f" -ForegroundColor White
}

# 4. Config files
Write-Host "`n4. CONFIGURATION FILES (blkv, raw_kv, sp)" -ForegroundColor Magenta
Write-Host "   Preferences and settings loaded at startup:" -ForegroundColor Gray
$configFiles = $files["Config/Preferences"] | Select-Object -First 20
foreach ($f in $configFiles) {
    $shortName = $f -replace ".*/", ""
    Write-Host "   • $shortName" -ForegroundColor White
}
if ($files["Config/Preferences"].Count -gt 20) {
    Write-Host "   ... and $($files["Config/Preferences"].Count - 20) more" -ForegroundColor DarkGray
}

# Analyze memory maps for .so files
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "              MEMORY MAPPED FILES (.so)                      " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

if (Test-Path $mapsFile) {
    $mapsContent = Get-Content $mapsFile -Raw
    
    # Extract .so files
    $soFiles = [regex]::Matches($mapsContent, '(/[^\s]+\.so[^\s]*)') | 
        ForEach-Object { $_.Groups[1].Value } | 
        Sort-Object -Unique
    
    # Categorize .so files
    $appSo = $soFiles | Where-Object { $_ -match "tv.danmaku.bili|data/app" }
    $systemSo = $soFiles | Where-Object { $_ -match "^/system|^/apex|^/vendor" }
    
    Write-Host "`nAPP-SPECIFIC NATIVE LIBRARIES ($($appSo.Count) files):" -ForegroundColor Yellow
    Write-Host "These are loaded from the APK and cause IO during cold start:" -ForegroundColor Gray
    foreach ($f in $appSo) {
        $name = $f -replace ".*/", ""
        Write-Host "   • $name" -ForegroundColor White
    }
    
    Write-Host "`nSYSTEM NATIVE LIBRARIES ($($systemSo.Count) files):" -ForegroundColor Yellow
    Write-Host "First 15 system libraries:" -ForegroundColor Gray
    $systemSo | Select-Object -First 15 | ForEach-Object {
        $name = $_ -replace ".*/", ""
        Write-Host "   • $name" -ForegroundColor DarkGray
    }
    if ($systemSo.Count -gt 15) {
        Write-Host "   ... and $($systemSo.Count - 15) more" -ForegroundColor DarkGray
    }
}

# IO Impact Analysis
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "              COLD START IO IMPACT ANALYSIS                  " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green

Write-Host "`nFILES THAT CAUSE IO WHEN PAGE CACHE IS EMPTY:" -ForegroundColor Yellow
Write-Host ""

Write-Host "1. HIGH IMPACT (Large files, loaded early):" -ForegroundColor Red
Write-Host "   • base.apk - Main application package (~100+ MB)" -ForegroundColor White
Write-Host "   • *.odex/*.vdex - Optimized DEX files" -ForegroundColor White
Write-Host "   • Native .so libraries in APK" -ForegroundColor White

Write-Host "`n2. MEDIUM IMPACT (Multiple small reads):" -ForegroundColor Yellow
Write-Host "   • Framework JAR files ($($files["JAR (Framework)"].Count) files)" -ForegroundColor White
Write-Host "   • Configuration files ($($files["Config/Preferences"].Count) files)" -ForegroundColor White

Write-Host "`n3. LOWER IMPACT (After main UI displayed):" -ForegroundColor DarkYellow
Write-Host "   • Database files ($($dbFiles.Count) databases)" -ForegroundColor White
Write-Host "   • Cache files" -ForegroundColor White

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "              RECOMMENDATIONS                                " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host "
To improve cold start performance:

1. PAGE CACHE BENEFIT:
   - When page cache has base.apk, cold start is ~500ms faster
   - Framework JARs are usually cached by system

2. APP OPTIMIZATION OPPORTUNITIES:
   - Reduce number of .blkv/.raw_kv config files read at startup
   - Lazy-load databases not needed for first frame
   - Consider app bundle (split APKs) to reduce initial load

3. SYSTEM LEVEL:
   - PinnerService can pin critical files in memory
   - Check /system/etc/pinnerconfig to see what's pinned
" -ForegroundColor White

# Save detailed report
$reportFile = Join-Path $inputDir "io_analysis_report.txt"
$report = @"
============================================================
         BILIBILI COLD START IO ANALYSIS REPORT
============================================================
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

SUMMARY
-------
APK/DEX Files:           $($files["APK/DEX"].Count)
Framework JARs:          $($files["JAR (Framework)"].Count)  
Native Libraries (.so):  $(if ($soFiles) { $soFiles.Count } else { "N/A" })
Databases:               $($dbFiles.Count)
Config Files:            $($files["Config/Preferences"].Count)

APK FILES
---------
$($files["APK/DEX"] | Out-String)

FRAMEWORK JARS
--------------
$($files["JAR (Framework)"] | Out-String)

DATABASES
---------
$($dbFiles | Out-String)

CONFIG FILES
------------
$($files["Config/Preferences"] | Out-String)

APP NATIVE LIBRARIES
--------------------
$(if ($appSo) { $appSo | Out-String } else { "See memory_maps.txt" })
"@

$report | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host "`nDetailed report saved to: $reportFile" -ForegroundColor Green
