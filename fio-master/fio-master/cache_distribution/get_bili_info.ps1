# Get Bilibili App Information Script
Write-Host "=== Bilibili APP File Information ===" -ForegroundColor Cyan
Write-Host "Collecting data..." -ForegroundColor Yellow

# Define output files
$reportFile = "bilibili_app_report.txt"
$csvFile = "bilibili_app_files.csv"

# Get package path
$packagePath = adb shell pm path tv.danmaku.bili 2>$null
if ($packagePath) {
    $appPath = ($packagePath -replace "package:", "").Trim()
    $appDir = $appPath -replace "/base\.apk$", ""
    
    Write-Host "`nApplication Path: $appDir" -ForegroundColor Green
    
    # Create a shell script to execute in adb shell - Include all storage locations
    $shellCommands = @"
echo '---APP_DIR---'
find '$appDir' -type f -exec ls -lh {} \;
echo '---APP_SIZE---'
du -sh '$appDir'
echo '---DATA_DIR---'
du -sh /data/data/tv.danmaku.bili 2>/dev/null || du -sh /data/user/0/tv.danmaku.bili 2>/dev/null
echo '---DATA_FILES---'
find /data/data/tv.danmaku.bili -type f 2>/dev/null | wc -l || find /data/user/0/tv.danmaku.bili -type f 2>/dev/null | wc -l
echo '---CACHE_DIR---'
du -sh /data/data/tv.danmaku.bili/cache 2>/dev/null || echo '0'
echo '---EXTERNAL_DATA---'
du -sh /sdcard/Android/data/tv.danmaku.bili 2>/dev/null || echo '0'
echo '---FILE_COUNT---'
find '$appDir' -type f | wc -l
echo '---DUMPSYS---'
dumpsys package tv.danmaku.bili | grep -A 5 'dataDir\|codeSize\|dataSize\|cacheSize'
echo '---END---'
"@
    
    $result = $shellCommands | adb shell
    
    # Parse the results
    $lines = $result -split "`n"
    $fileList = @()
    $inFileSection = $false
    $inDumpsysSection = $false
    $totalFiles = "0"
    $appSize = "Unknown"
    $dataSize = "Unknown"
    $cacheSize = "0"
    $externalSize = "0"
    $dataFileCount = "0"
    $dumpsysInfo = @()
    
    foreach ($line in $lines) {
        if ($line -match "---APP_DIR---") {
            $inFileSection = $true
            continue
        }
        if ($line -match "---APP_SIZE---") {
            $inFileSection = $false
            continue
        }
        if ($line -match "---DATA_DIR---") {
            continue
        }
        if ($line -match "---DATA_FILES---") {
            continue
        }
        if ($line -match "---CACHE_DIR---") {
            continue
        }
        if ($line -match "---EXTERNAL_DATA---") {
            continue
        }
        if ($line -match "---FILE_COUNT---") {
            continue
        }
        if ($line -match "---DUMPSYS---") {
            $inDumpsysSection = $true
            continue
        }
        if ($line -match "---END---") {
            $inDumpsysSection = $false
            break
        }
        
        if ($inDumpsysSection) {
            $dumpsysInfo += $line
        }
        
        if ($inFileSection -and $line -match "^-") {
            # Parse ls -lh output: -rw-r--r-- 1 system system 185M 2026-01-22 14:47 /path/to/file
            if ($line -match "^\S+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+\S+\s+\S+\s+(.+)$") {
                $size = $matches[1]
                $fullPath = $matches[2].Trim()
                $fileName = Split-Path $fullPath -Leaf
                $relativePath = $fullPath -replace [regex]::Escape($appDir), "" -replace "^/", ""
                
                $fileList += [PSCustomObject]@{
                    FileName = $fileName
                    RelativePath = $relativePath
                    Size = $size
                    FullPath = $fullPath
                }
            }
        }
        
        # Parse sizes
        if ($line -match "^(\S+)\s+" -and -not $inFileSection) {
            $possibleSize = $matches[1].Trim()
            if ($possibleSize -match "^\d+(\.\d+)?[KMG]?$") {
                # Determine which size this is based on context
                if ($appSize -eq "Unknown") {
                    $appSize = $possibleSize
                } elseif ($dataSize -eq "Unknown") {
                    $dataSize = $possibleSize
                } elseif ($cacheSize -eq "0" -and $possibleSize -ne "0") {
                    $cacheSize = $possibleSize
                } elseif ($externalSize -eq "0" -and $possibleSize -ne "0") {
                    $externalSize = $possibleSize
                }
            }
        }
        
        if ($line -match "^\s*(\d+)\s*$") {
            $num = $line.Trim()
            if ($totalFiles -eq "0") {
                $totalFiles = $num
            } elseif ($dataFileCount -eq "0") {
                $dataFileCount = $num
            }
        }
    }
    
    # Create report content
    $reportContent = @()
    $reportContent += "====================================================================="
    $reportContent += "                   BILIBILI APP STORAGE ANALYSIS                     "
    $reportContent += "====================================================================="
    $reportContent += ""
    $reportContent += "Application Path: $appDir"
    $reportContent += ""
    $reportContent += "STORAGE BREAKDOWN:"
    $reportContent += "-" * 69
    $reportContent += "App Installation Size:    $appSize"
    $reportContent += "App Data Directory Size:  $dataSize"
    $reportContent += "Cache Size:               $cacheSize"
    $reportContent += "External Storage:         $externalSize"
    $reportContent += ""
    $reportContent += "FILES:"
    $reportContent += "-" * 69
    $reportContent += "App Files Count:          $totalFiles"
    $reportContent += "Data Files Count:         $dataFileCount"
    $reportContent += ""
    
    if ($dumpsysInfo.Count -gt 0) {
        $reportContent += "DUMPSYS PACKAGE INFO:"
        $reportContent += "-" * 69
        $dumpsysInfo | ForEach-Object { $reportContent += $_ }
        $reportContent += ""
    }
    
    $reportContent += "====================================================================="
    $reportContent += "                         FILE LIST TABLE                             "
    $reportContent += "====================================================================="
    $reportContent += ""
    
    if ($fileList.Count -gt 0) {
        # Add table header
        $reportContent += "{0,-30} {1,-10} {2,-50}" -f "File Name", "Size", "Path"
        $reportContent += "-" * 90
        
        # Add each file
        foreach ($file in $fileList) {
            $reportContent += "{0,-30} {1,-10} {2,-50}" -f $file.FileName, $file.Size, $file.RelativePath
        }
        
        # Highlight base.apk
        $reportContent += ""
        $reportContent += "====================================================================="
        $reportContent += "                         BASE.APK INFO                               "
        $reportContent += "====================================================================="
        $baseApk = $fileList | Where-Object { $_.FileName -eq "base.apk" }
        if ($baseApk) {
            $reportContent += ""
            $reportContent += "File: base.apk"
            $reportContent += "Size: $($baseApk.Size)"
            $reportContent += "Path: $($baseApk.FullPath)"
        }
        
        # Export to CSV
        $fileList | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
        Write-Host "`nCSV file saved: $csvFile" -ForegroundColor Green
        
        # Display in console
        Write-Host ""
        $fileList | Format-Table -Property @{
            Label = "File Name"
            Expression = { $_.FileName }
            Width = 25
        }, @{
            Label = "Size"
            Expression = { $_.Size }
            Width = 10
        }, @{
            Label = "Path"
            Expression = { $_.RelativePath }
            Width = 50
        } -AutoSize
        
    } else {
        $reportContent += "No files found or unable to access"
        Write-Host "`nNo files found or unable to access" -ForegroundColor Red
    }
    
    # Save report to file
    $reportContent | Out-File -FilePath $reportFile -Encoding UTF8
    
    # Display summary
    Write-Host "`n=====================================================================" -ForegroundColor Cyan
    Write-Host "                   BILIBILI APP STORAGE ANALYSIS                     " -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host "`nSTORAGE BREAKDOWN:" -ForegroundColor Yellow
    Write-Host "App Installation Size:    $appSize" -ForegroundColor White
    Write-Host "App Data Directory Size:  $dataSize" -ForegroundColor White
    Write-Host "Cache Size:               $cacheSize" -ForegroundColor White
    Write-Host "External Storage:         $externalSize" -ForegroundColor White
    Write-Host "`nFILES:" -ForegroundColor Yellow
    Write-Host "App Files Count:          $totalFiles" -ForegroundColor White
    Write-Host "Data Files Count:         $dataFileCount" -ForegroundColor White
    Write-Host "`n=====================================================================" -ForegroundColor Green
    Write-Host "Report saved to: $reportFile" -ForegroundColor Green
    Write-Host "CSV data saved to: $csvFile" -ForegroundColor Green
    Write-Host "=====================================================================" -ForegroundColor Green
    Write-Host "`nNOTE: System settings show total storage including:" -ForegroundColor Yellow
    Write-Host "- App (APK): ~600MB - shown in 'App Installation Size'" -ForegroundColor Gray
    Write-Host "- Data: ~617MB - shown in 'App Data Directory Size'" -ForegroundColor Gray
    Write-Host "- The difference may include caches, external storage, and dalvik cache" -ForegroundColor Gray
    
} else {
    Write-Host "Bilibili APP not found, try other package names" -ForegroundColor Red
    Write-Host "Searching packages containing bili:" -ForegroundColor Yellow
    adb shell pm list packages | Select-String bili
}
