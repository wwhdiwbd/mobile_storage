# === Bilibili APP 信息获取脚本 ===
Write-Host "=== Bilibili APP File Information ===" -ForegroundColor Cyan
Write-Host "Collecting data..." -ForegroundColor Yellow

# 定义输出文件的名称
$reportFile = "bilibili_app_report.txt"
$csvFile = "bilibili_app_files.csv"

# 1. 获取应用安装路径
# 使用 adb pm path 命令查找包名对应的安装路径
$packagePath = adb shell pm path tv.danmaku.bili 2>$null

if ($packagePath) {
    # 处理路径字符串：去掉 "package:" 前缀，并去掉末尾的 "/base.apk" 以获取目录
    $appPath = ($packagePath -replace "package:", "").Trim()
    $appDir = $appPath -replace "/base\.apk$", ""
    
    Write-Host "`nApplication Path: $appDir" -ForegroundColor Green
    
    # 2. 构建 Shell 命令块
    # 这里创建了一个将在 Android 手机内部执行的脚本字符串
    # 这种写法是为了只建立一次 ADB 连接就获取所有信息，提高速度
    $shellCommands = @"
echo '---APP_DIR---'
# 列出安装目录下的所有文件详细信息 (ls -lh)
find '$appDir' -type f -exec ls -lh {} \;
echo '---APP_SIZE---'
# 计算安装目录总大小 (APK + so库等)
du -sh '$appDir'
echo '---DATA_DIR---'
# 计算私有数据目录大小 (/data/data)，尝试两种常见路径以兼容不同安卓版本
du -sh /data/data/tv.danmaku.bili 2>/dev/null || du -sh /data/user/0/tv.danmaku.bili 2>/dev/null
echo '---DATA_FILES---'
# 统计私有数据目录下的文件数量
find /data/data/tv.danmaku.bili -type f 2>/dev/null | wc -l || find /data/user/0/tv.danmaku.bili -type f 2>/dev/null | wc -l
echo '---CACHE_DIR---'
# 单独计算缓存目录大小
du -sh /data/data/tv.danmaku.bili/cache 2>/dev/null || echo '0'
echo '---EXTERNAL_DATA---'
# 计算外部存储 (SD卡) 中的数据大小
du -sh /sdcard/Android/data/tv.danmaku.bili 2>/dev/null || echo '0'
echo '---FILE_COUNT---'
# 统计安装目录下的文件数量
find '$appDir' -type f | wc -l
echo '---DUMPSYS---'
# 获取 Android 系统层面的包信息 (grep 过滤关键字段)
dumpsys package tv.danmaku.bili | grep -A 5 'dataDir\|codeSize\|dataSize\|cacheSize'
echo '---END---'
"@
    
    # 3. 执行命令并获取结果
    $result = $shellCommands | adb shell
    
    # 4. 解析结果
    $lines = $result -split "`n"
    $fileList = @()
    # 初始化状态标记和变量
    $inFileSection = $false        # 标记是否正在读取文件列表部分
    $inDumpsysSection = $false     # 标记是否正在读取 dumpsys 部分
    $totalFiles = "0"
    $appSize = "Unknown"
    $dataSize = "Unknown"
    $cacheSize = "0"
    $externalSize = "0"
    $dataFileCount = "0"
    $dumpsysInfo = @()
    
    foreach ($line in $lines) {
        # --- 状态机切换逻辑：根据分隔符判断当前读取的是哪部分数据 ---
        if ($line -match "---APP_DIR---") {
            $inFileSection = $true
            continue
        }
        if ($line -match "---APP_SIZE---") {
            $inFileSection = $false
            continue
        }
        if ($line -match "---DATA_DIR---") { continue }
        if ($line -match "---DATA_FILES---") { continue }
        if ($line -match "---CACHE_DIR---") { continue }
        if ($line -match "---EXTERNAL_DATA---") { continue }
        if ($line -match "---FILE_COUNT---") { continue }
        if ($line -match "---DUMPSYS---") {
            $inDumpsysSection = $true
            continue
        }
        if ($line -match "---END---") {
            $inDumpsysSection = $false
            break
        }
        
        # 收集 Dumpsys 信息
        if ($inDumpsysSection) {
            $dumpsysInfo += $line
        }
        
        # --- 解析 ls -lh 文件列表 ---
        if ($inFileSection -and $line -match "^-") {
            # 正则匹配 ls -lh 的输出格式：权限 用户 组 大小 日期 时间 路径
            # 这里的正则主要为了提取 $matches[1](大小) 和 $matches[2](路径)
            if ($line -match "^\S+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+\S+\s+\S+\s+(.+)$") {
                $size = $matches[1]
                $fullPath = $matches[2].Trim()
                $fileName = Split-Path $fullPath -Leaf
                # 计算相对路径，让显示更简洁
                $relativePath = $fullPath -replace [regex]::Escape($appDir), "" -replace "^/", ""
                
                # 创建对象并存入列表
                $fileList += [PSCustomObject]@{
                    FileName = $fileName
                    RelativePath = $relativePath
                    Size = $size
                    FullPath = $fullPath
                }
            }
        }
        
        # --- 解析 du -sh (大小) 输出 ---
        # 匹配以数字开头或 K/M/G 结尾的行
        if ($line -match "^(\S+)\s+" -and -not $inFileSection) {
            $possibleSize = $matches[1].Trim()
            if ($possibleSize -match "^\d+(\.\d+)?[KMG]?$") {
                # 根据当前解析到的变量状态，依次填充大小信息
                # 这种逻辑依赖于 Shell 命令执行的顺序：App -> Data -> Cache -> External
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
        
        # --- 解析文件数量 (纯数字行) ---
        if ($line -match "^\s*(\d+)\s*$") {
            $num = $line.Trim()
            if ($totalFiles -eq "0") {
                $totalFiles = $num
            } elseif ($dataFileCount -eq "0") {
                $dataFileCount = $num
            }
        }
    }
    
    # 5. 构建文本报告内容
    $reportContent = @()
    $reportContent += "====================================================================="
    $reportContent += "                  BILIBILI APP STORAGE ANALYSIS                      "
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
        # 添加表头
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
        
        # 6. 导出 CSV 文件
        # 这是非常关键的一步，生成的 CSV 可以用 Excel 打开进行筛选排序
        $fileList | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
        Write-Host "`nCSV file saved: $csvFile" -ForegroundColor Green
        
        # 在控制台显示简略表格
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
    
    # 7. 保存文本报告
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
    # 错误处理：如果没找到 Bilibili 包
    Write-Host "Bilibili APP not found, try other package names" -ForegroundColor Red
    Write-Host "Searching packages containing bili:" -ForegroundColor Yellow
    # 帮助用户搜索类似的包名
    adb shell pm list packages | Select-String bili
}