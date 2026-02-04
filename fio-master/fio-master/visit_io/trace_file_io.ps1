# Bilibili Cold Start File IO Analysis (Enhanced for Cache Optimization)
# This script traces ACTUAL READ operations during app cold start
# Purpose: Collect data for designing SSD secondary cache with sequential layout
# 
# Key data collected:
#   1. File read order (actual read sequence, not just open)
#   2. Read offset and size for each operation
#   3. fd to filename mapping
#   4. Timing information for each read

Write-Host "=== Bilibili File IO Trace (Enhanced for Cache Design) ===" -ForegroundColor Cyan
Write-Host "This script traces ACTUAL READ operations during cold start" -ForegroundColor Yellow
Write-Host "Purpose: Collect data for SSD secondary cache optimization" -ForegroundColor Yellow
Write-Host ""

# Check root (adb shell is already root)
$rootCheck = adb shell "whoami" 2>&1
if ($rootCheck -match "root") {
    Write-Host "✓ Root access confirmed (adb shell as root)" -ForegroundColor Green
} else {
    Write-Host "Current user: $rootCheck" -ForegroundColor Yellow
}

# Create output directory
$outputDir = "io_analysis_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
Write-Host "Output directory: $outputDir" -ForegroundColor Gray

# Stop app and clear caches
Write-Host "`n[1/6] Preparing cold start environment..." -ForegroundColor Magenta
adb shell am force-stop tv.danmaku.bili 2>$null
adb shell "sync; echo 3 > /proc/sys/vm/drop_caches" 2>$null
Start-Sleep -Seconds 3

# Use ftrace to trace file READ operations
# Try android_fs events first (available on most Android devices)
# Fall back to block layer if needed
Write-Host "`n[2/6] Setting up ftrace for READ operation tracing..." -ForegroundColor Magenta

# Setup ftrace
adb shell "echo 0 > /sys/kernel/debug/tracing/tracing_on"
adb shell "echo > /sys/kernel/debug/tracing/trace"
adb shell "echo 131072 > /sys/kernel/debug/tracing/buffer_size_kb"  # Larger buffer for read ops

# Check available tracing methods and enable what's supported
Write-Host "Checking available trace events..." -ForegroundColor Gray

# Method 1: android_fs events (best for Android - includes filename, offset, size)
$androidFsAvailable = adb shell "test -d /sys/kernel/debug/tracing/events/android_fs && echo yes"
if ($androidFsAvailable -match "yes") {
    Write-Host "  ✓ android_fs events available - using this method" -ForegroundColor Green
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/android_fs/android_fs_dataread_start/enable"
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/android_fs/android_fs_dataread_end/enable"
} else {
    Write-Host "  ✗ android_fs events not available" -ForegroundColor Yellow
}

# Method 2: f2fs events (if using f2fs filesystem)
$f2fsAvailable = adb shell "test -d /sys/kernel/debug/tracing/events/f2fs && echo yes"
if ($f2fsAvailable -match "yes") {
    Write-Host "  ✓ f2fs events available - enabling" -ForegroundColor Green
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/f2fs/f2fs_dataread_start/enable" 2>$null
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/f2fs/f2fs_dataread_end/enable" 2>$null
} else {
    Write-Host "  ✗ f2fs events not available" -ForegroundColor Yellow
}

# Method 3: ext4 events (if using ext4 filesystem)
$ext4Available = adb shell "test -d /sys/kernel/debug/tracing/events/ext4 && echo yes"
if ($ext4Available -match "yes") {
    Write-Host "  ✓ ext4 events available - enabling" -ForegroundColor Green
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/ext4/ext4_da_write_begin/enable" 2>$null
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/ext4/ext4_sync_file_enter/enable" 2>$null
}

# Method 4: block layer events (always available - shows actual disk I/O)
Write-Host "  ✓ block layer events - enabling" -ForegroundColor Green
adb shell "echo 1 > /sys/kernel/debug/tracing/events/block/block_rq_issue/enable"
adb shell "echo 1 > /sys/kernel/debug/tracing/events/block/block_rq_complete/enable"

# Method 5: filemap events (page cache activity)
$filemapAvailable = adb shell "test -d /sys/kernel/debug/tracing/events/filemap && echo yes"
if ($filemapAvailable -match "yes") {
    Write-Host "  ✓ filemap events available - enabling" -ForegroundColor Green
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/filemap/mm_filemap_add_to_page_cache/enable" 2>$null
}

# Start tracing
adb shell "echo 1 > /sys/kernel/debug/tracing/tracing_on"

Write-Host "`n[3/6] Launching Bilibili..." -ForegroundColor Magenta
$startTime = Get-Date
$result = adb shell "am start -W -n tv.danmaku.bili/.MainActivityV2"
$endTime = Get-Date
$duration = [math]::Round(($endTime - $startTime).TotalMilliseconds, 0)
Write-Host "App launched in ${duration}ms" -ForegroundColor Green
Write-Host $result -ForegroundColor DarkGray

# Wait for app to fully load
Write-Host "Waiting for app to fully load..." -ForegroundColor Gray
Start-Sleep -Seconds 5

# Stop tracing
adb shell "echo 0 > /sys/kernel/debug/tracing/tracing_on"

# Disable all events
adb shell "echo 0 > /sys/kernel/debug/tracing/events/android_fs/enable" 2>$null
adb shell "echo 0 > /sys/kernel/debug/tracing/events/f2fs/enable" 2>$null
adb shell "echo 0 > /sys/kernel/debug/tracing/events/ext4/enable" 2>$null
adb shell "echo 0 > /sys/kernel/debug/tracing/events/block/enable" 2>$null
adb shell "echo 0 > /sys/kernel/debug/tracing/events/filemap/enable" 2>$null

Write-Host "`n[4/6] Pulling ftrace log..." -ForegroundColor Magenta
adb shell "cat /sys/kernel/debug/tracing/trace" > "$outputDir\ftrace_raw.log"

# Also get the list of open files using /proc
Write-Host "Getting open file descriptors..." -ForegroundColor Gray
$biliPid = adb shell "pidof tv.danmaku.bili" 2>$null
if ($biliPid) {
    $biliPid = $biliPid.Trim()
    Write-Host "Bilibili PID: $biliPid" -ForegroundColor Gray
    adb shell "ls -la /proc/$biliPid/fd/ 2>/dev/null" > "$outputDir\open_fds.txt"
    adb shell "cat /proc/$biliPid/maps 2>/dev/null" > "$outputDir\memory_maps.txt"
    
    # Get detailed fd -> file mapping
    Write-Host "Getting fd to filename mapping..." -ForegroundColor Gray
    adb shell "ls -la /proc/$biliPid/fd/ 2>/dev/null | awk '{print `$NF}'" > "$outputDir\fd_files.txt"
}

# Analyze ftrace output - Focus on READ operations for cache design
Write-Host "`n[5/6] Analyzing READ operations for cache design..." -ForegroundColor Magenta

if (Test-Path "$outputDir\ftrace_raw.log") {
    $ftraceContent = Get-Content "$outputDir\ftrace_raw.log" -Raw
    $ftraceLines = Get-Content "$outputDir\ftrace_raw.log"
    
    # Data structures for analysis
    $readSequence = @()       # Ordered list of read operations
    $fileReadStats = @{}      # filename -> {total_bytes, read_count}
    $readOrder = 0            # Global read order counter
    $openFiles = @()          # All unique files accessed
    
    Write-Host "Parsing ftrace log ($($ftraceLines.Count) lines)..." -ForegroundColor Gray
    
    foreach ($line in $ftraceLines) {
        # Skip comments and empty lines
        if ($line -match "^#" -or [string]::IsNullOrWhiteSpace($line)) { continue }
        
        # ============================================================
        # Method 1: Parse android_fs_dataread_start events (BEST)
        # Format: android_fs_dataread_start: entry_name /path, offset 123, bytes 456, cmdline xxx, pid xxx, i_size xxx, ino xxx
        # Note: The line may be split across multiple lines in the log
        # ============================================================
        if ($line -match "android_fs_dataread_start:\s*entry_name\s+(\S+),\s*offset\s+(\d+),\s*bytes\s+(\d+)") {
            $filename = $Matches[1]
            $offset = [int64]$Matches[2]
            $size = [int64]$Matches[3]
            
            # Extract timestamp
            $timestamp = ""
            if ($line -match "\[\d+\]\s+[\.\w]+\s+(\d+\.\d+):") {
                $timestamp = $Matches[1]
            }
            
            # Extract process info
            $procInfo = ""
            if ($line -match "^\s*(\S+)-(\d+)") {
                $procInfo = "$($Matches[1])-$($Matches[2])"
            }
            
            $readOrder++
            $readSequence += [PSCustomObject]@{
                Order = $readOrder
                Type = "android_fs"
                Filename = $filename
                Offset = $offset
                Size = $size
                Timestamp = $timestamp
                Process = $procInfo
            }
            
            # Update file stats
            if (-not $fileReadStats.ContainsKey($filename)) {
                $fileReadStats[$filename] = @{ TotalBytes = 0; ReadCount = 0; Offsets = @() }
            }
            $fileReadStats[$filename].TotalBytes += $size
            $fileReadStats[$filename].ReadCount++
            $fileReadStats[$filename].Offsets += $offset
            
            if ($filename -notin $openFiles) {
                $openFiles += $filename
            }
        }
        
        # ============================================================
        # Method 2: Parse block layer events (fallback)
        # Format: block_rq_issue: ... rwbs=R ... sector=xxx + len
        # ============================================================
        elseif ($line -match "block_rq_issue.*rwbs=R.*\s(\d+)\s*\+\s*(\d+)") {
            $sector = [int64]$Matches[1]
            $sectors = [int64]$Matches[2]
            $size = $sectors * 512  # sectors to bytes
            
            $timestamp = ""
            if ($line -match "\[\s*(\d+\.\d+)\]") {
                $timestamp = $Matches[1]
            }
            
            $procInfo = ""
            if ($line -match "^\s*([^\s]+)-(\d+)") {
                $procInfo = "$($Matches[1])-$($Matches[2])"
            }
            
            $readOrder++
            $readSequence += [PSCustomObject]@{
                Order = $readOrder
                Type = "block_read"
                Filename = "block:$sector"
                Offset = $sector * 512
                Size = $size
                Timestamp = $timestamp
                Process = $procInfo
            }
        }
        
        # ============================================================
        # Method 3: Parse f2fs_dataread events
        # ============================================================
        elseif ($line -match "f2fs_dataread.*ino\s*=\s*(\d+).*pos\s*=\s*(\d+).*len\s*=\s*(\d+)") {
            $ino = $Matches[1]
            $offset = [int64]$Matches[2]
            $size = [int64]$Matches[3]
            
            $timestamp = ""
            if ($line -match "\[\s*(\d+\.\d+)\]") {
                $timestamp = $Matches[1]
            }
            
            $procInfo = ""
            if ($line -match "^\s*([^\s]+)-(\d+)") {
                $procInfo = "$($Matches[1])-$($Matches[2])"
            }
            
            $readOrder++
            $readSequence += [PSCustomObject]@{
                Order = $readOrder
                Type = "f2fs"
                Filename = "inode:$ino"
                Offset = $offset
                Size = $size
                Timestamp = $timestamp
                Process = $procInfo
            }
        }
    }
    
    Write-Host "Found $($readSequence.Count) read operations" -ForegroundColor Green
    
    # If no files from trace, extract from content patterns
    if ($openFiles.Count -eq 0) {
        Write-Host "Extracting filenames from trace content..." -ForegroundColor Yellow
        $openFiles = [regex]::Matches($ftraceContent, '(/[a-zA-Z0-9_\-\./]+\.[a-zA-Z0-9]+)') | 
            ForEach-Object { $_.Groups[1].Value } | 
            Where-Object { $_ -match "\.(apk|dex|odex|vdex|art|so|xml|json|db|jar)$" -or $_ -match "data|system|vendor" } |
            Sort-Object -Unique
    }
    
    # Also add files from memory maps (mmap'd files)
    if (Test-Path "$outputDir\memory_maps.txt") {
        $mapsContent = Get-Content "$outputDir\memory_maps.txt" -Raw
        $mmapFiles = [regex]::Matches($mapsContent, '(/[^\s]+\.(so|apk|dex|odex|vdex|art|jar)[^\s]*)') | 
            ForEach-Object { $_.Groups[1].Value } | 
            Sort-Object -Unique
        $openFiles = ($openFiles + $mmapFiles) | Sort-Object -Unique
    }
    
    # Categorize files
    $apkFiles = $openFiles | Where-Object { $_ -match "\.apk|\.dex|\.odex|\.vdex|\.art" }
    $soFiles = $openFiles | Where-Object { $_ -match "\.so" }
    $dataFiles = $openFiles | Where-Object { $_ -match "/data/data/tv.danmaku.bili|/data/user" }
    $systemFiles = $openFiles | Where-Object { $_ -match "^/system|^/vendor|^/apex" }
    $otherFiles = $openFiles | Where-Object { 
        $_ -notmatch "\.apk|\.dex|\.odex|\.vdex|\.art" -and 
        $_ -notmatch "\.so" -and
        $_ -notmatch "/data/data/tv.danmaku.bili|/data/user" -and
        $_ -notmatch "^/system|^/vendor|^/apex"
    }
    
    # Export read sequence to CSV for cache design analysis
    Write-Host "`n[6/6] Exporting data for cache design..." -ForegroundColor Magenta
    
    $readSequence | Export-Csv -Path "$outputDir\read_sequence.csv" -NoTypeInformation -Encoding UTF8
    Write-Host "Read sequence exported to: read_sequence.csv" -ForegroundColor Green
    
    # Export file read statistics (per-file summary)
    if ($fileReadStats.Count -gt 0) {
        $fileStatsExport = $fileReadStats.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{
                Filename = $_.Key
                TotalBytes = $_.Value.TotalBytes
                ReadCount = $_.Value.ReadCount
                AvgReadSize = [math]::Round($_.Value.TotalBytes / [math]::Max($_.Value.ReadCount, 1), 0)
            }
        } | Sort-Object -Property TotalBytes -Descending
        $fileStatsExport | Export-Csv -Path "$outputDir\file_read_stats.csv" -NoTypeInformation -Encoding UTF8
        Write-Host "Per-file read stats exported to: file_read_stats.csv" -ForegroundColor Green
    }
    
    # Calculate read statistics
    $totalReadBytes = ($readSequence | Measure-Object -Property Size -Sum).Sum
    if ($null -eq $totalReadBytes) { $totalReadBytes = 0 }
    $avgReadSize = if ($readSequence.Count -gt 0) { [math]::Round($totalReadBytes / $readSequence.Count, 0) } else { 0 }
    $smallReads = ($readSequence | Where-Object { $_.Size -lt 4096 }).Count
    $largeReads = ($readSequence | Where-Object { $_.Size -ge 4096 }).Count
    
    # Size distribution analysis
    $sizeDistribution = @{
        "< 512B" = ($readSequence | Where-Object { $_.Size -lt 512 }).Count
        "512B-4KB" = ($readSequence | Where-Object { $_.Size -ge 512 -and $_.Size -lt 4096 }).Count
        "4KB-16KB" = ($readSequence | Where-Object { $_.Size -ge 4096 -and $_.Size -lt 16384 }).Count
        "16KB-64KB" = ($readSequence | Where-Object { $_.Size -ge 16384 -and $_.Size -lt 65536 }).Count
        "64KB-256KB" = ($readSequence | Where-Object { $_.Size -ge 65536 -and $_.Size -lt 262144 }).Count
        ">= 256KB" = ($readSequence | Where-Object { $_.Size -ge 262144 }).Count
    }
    
    # Generate size distribution string before the report
    $sizeDistStr = ($sizeDistribution.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $count = $_.Value
        $pct = [math]::Round($count * 100 / [math]::Max($readSequence.Count, 1), 1)
        "  $($_.Key.PadRight(12)): $($count.ToString().PadLeft(6)) ($pct%)"
    }) -join "`n"
    
    # Generate read sequence string (now with Filename instead of FD)
    $readSeqStr = ($readSequence | Select-Object -First 100 | ForEach-Object {
        $fname = if ($_.Filename.Length -gt 40) { "..." + $_.Filename.Substring($_.Filename.Length - 37) } else { $_.Filename }
        "{0,-5} | {1,-10} | {2,-40} | {3,-11} | {4,-10}" -f $_.Order, $_.Type, $fname, $_.Offset, $_.Size
    }) -join "`n"
    
    # Generate file lists strings
    $apkFilesStr = if ($apkFiles.Count -gt 0) { ($apkFiles | ForEach-Object { "   - $_" }) -join "`n" } else { "   (none)" }
    $soFilesStr = if ($soFiles.Count -gt 0) { ($soFiles | Select-Object -First 30 | ForEach-Object { "   - $_" }) -join "`n" } else { "   (none)" }
    $soFilesMore = if ($soFiles.Count -gt 30) { "`n   ... and $($soFiles.Count - 30) more" } else { "" }
    $dataFilesStr = if ($dataFiles.Count -gt 0) { ($dataFiles | Select-Object -First 20 | ForEach-Object { "   - $_" }) -join "`n" } else { "   (none)" }
    $dataFilesMore = if ($dataFiles.Count -gt 20) { "`n   ... and $($dataFiles.Count - 20) more" } else { "" }
    $systemFilesStr = if ($systemFiles.Count -gt 0) { ($systemFiles | Select-Object -First 30 | ForEach-Object { "   - $_" }) -join "`n" } else { "   (none)" }
    $systemFilesMore = if ($systemFiles.Count -gt 30) { "`n   ... and $($systemFiles.Count - 30) more" } else { "" }
    $allFilesStr = if ($openFiles.Count -gt 0) { ($openFiles | ForEach-Object { $_ }) -join "`n" } else { "(none)" }
    
    # Generate comprehensive report
    $report = @"
============================================================
    Bilibili Cold Start IO Analysis for Cache Optimization
============================================================
Analysis Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
App Launch Time: ${duration}ms

============================================================
                READ OPERATION STATISTICS
============================================================

Total read operations: $($readSequence.Count)
Total bytes read: $([math]::Round($totalReadBytes / 1MB, 2)) MB ($totalReadBytes bytes)
Average read size: $avgReadSize bytes
Small reads (< 4KB): $smallReads ($([math]::Round($smallReads * 100 / [math]::Max($readSequence.Count, 1), 1))%)
Large reads (>= 4KB): $largeReads ($([math]::Round($largeReads * 100 / [math]::Max($readSequence.Count, 1), 1))%)

READ SIZE DISTRIBUTION:
$sizeDistStr

READ OPERATION TYPES:
  read:    $(($readSequence | Where-Object { $_.Type -eq "read" }).Count)
  pread64: $(($readSequence | Where-Object { $_.Type -eq "pread64" }).Count)
  mmap:    $(($readSequence | Where-Object { $_.Type -eq "mmap" }).Count)

============================================================
            CACHE DESIGN RECOMMENDATIONS
============================================================

Based on the analysis:

1. SMALL READ PROBLEM:
   - $smallReads small reads (< 4KB) detected
   - These benefit most from cache pre-loading
   - Estimated cache efficiency gain: ~$([math]::Round($smallReads * 4, 0))KB consolidated

2. SUGGESTED CACHE BLOCK SIZE:
   - Recommended: 256KB - 1MB blocks
   - This consolidates multiple small reads into single large reads

3. TOTAL CACHE SIZE NEEDED:
   - Minimum: $([math]::Round($totalReadBytes / 1MB, 2)) MB
   - Recommended with padding: $([math]::Round($totalReadBytes * 1.2 / 1MB, 2)) MB

============================================================
                    FILE CATEGORIES
============================================================

1. APK/DEX Files ($($apkFiles.Count) files) - CRITICAL FOR CACHE:
$apkFilesStr

2. Native Libraries (.so) ($($soFiles.Count) files) - HIGH PRIORITY:
$soFilesStr$soFilesMore

3. App Data Files ($($dataFiles.Count) files):
$dataFilesStr$dataFilesMore

4. System Files ($($systemFiles.Count) files):
$systemFilesStr$systemFilesMore

============================================================
               READ SEQUENCE (First 100 ops)
============================================================
Order | Type       | Filename (truncated)                     | Offset      | Size
------|------------|------------------------------------------|-------------|----------
$readSeqStr

============================================================
                    ALL FILES ACCESSED
============================================================
$allFilesStr
"@

    $report | Out-File -FilePath "$outputDir\io_analysis_report.txt" -Encoding UTF8
    Write-Host "Full report saved to: io_analysis_report.txt" -ForegroundColor Green
    
    # Also export file list for cache pre-population
    $openFiles | Out-File -FilePath "$outputDir\cache_file_list.txt" -Encoding UTF8
    Write-Host "File list for cache: cache_file_list.txt" -ForegroundColor Green
    
    # Export prioritized file list (APK/DEX first, then .so, then data)
    $prioritizedFiles = @()
    $prioritizedFiles += $apkFiles
    $prioritizedFiles += $soFiles
    $prioritizedFiles += $dataFiles
    $prioritizedFiles | Out-File -FilePath "$outputDir\cache_priority_files.txt" -Encoding UTF8
    Write-Host "Prioritized cache list: cache_priority_files.txt" -ForegroundColor Green
    
    # Print summary
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "              ANALYSIS SUMMARY FOR CACHE DESIGN" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "App launch time: ${duration}ms" -ForegroundColor White
    Write-Host ""
    Write-Host "READ STATISTICS:" -ForegroundColor Yellow
    Write-Host "  Total read ops:    $($readSequence.Count)" -ForegroundColor White
    Write-Host "  Total bytes:       $([math]::Round($totalReadBytes / 1MB, 2)) MB" -ForegroundColor White
    Write-Host "  Avg read size:     $avgReadSize bytes" -ForegroundColor White
    Write-Host "  Small reads (<4KB): $smallReads ($([math]::Round($smallReads * 100 / [math]::Max($readSequence.Count, 1), 1))%)" -ForegroundColor $(if ($smallReads -gt $largeReads) { "Red" } else { "White" })
    Write-Host ""
    Write-Host "SIZE DISTRIBUTION:" -ForegroundColor Yellow
    foreach ($key in $sizeDistribution.Keys | Sort-Object) {
        $count = $sizeDistribution[$key]
        $pct = [math]::Round($count * 100 / [math]::Max($readSequence.Count, 1), 1)
        Write-Host "  $($key.PadRight(12)): $($count.ToString().PadLeft(6)) ($pct%)" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "FILES BY CATEGORY:" -ForegroundColor Yellow
    Write-Host "  APK/DEX files:     $($apkFiles.Count)" -ForegroundColor White
    Write-Host "  Native libs (.so): $($soFiles.Count)" -ForegroundColor White
    Write-Host "  App data files:    $($dataFiles.Count)" -ForegroundColor White
    Write-Host "  System files:      $($systemFiles.Count)" -ForegroundColor White
    Write-Host "  Other files:       $($otherFiles.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "CACHE RECOMMENDATION:" -ForegroundColor Yellow
    Write-Host "  Min cache size: $([math]::Round($totalReadBytes / 1MB, 2)) MB" -ForegroundColor Green
    Write-Host "  Priority files: $($apkFiles.Count + $soFiles.Count) (APK + .so)" -ForegroundColor Green

} else {
    Write-Host "Warning: ftrace log not found or empty" -ForegroundColor Yellow
}

# Also analyze memory maps if available
if (Test-Path "$outputDir\memory_maps.txt") {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "              MEMORY MAPPED FILES (.so libraries)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    
    $mapsContent = Get-Content "$outputDir\memory_maps.txt" -Raw
    $mappedFiles = [regex]::Matches($mapsContent, '(/[^\s]+\.so[^\s]*)') | 
        ForEach-Object { $_.Groups[1].Value } | 
        Sort-Object -Unique
    
    Write-Host "Total .so files loaded: $($mappedFiles.Count)" -ForegroundColor White
    $mappedFiles | Select-Object -First 20 | ForEach-Object { 
        Write-Host "  $_" -ForegroundColor Gray 
    }
    if ($mappedFiles.Count -gt 20) {
        Write-Host "  ... and $($mappedFiles.Count - 20) more" -ForegroundColor DarkGray
    }
    
    # Export mmap files for cache
    $mappedFiles | Out-File -FilePath "$outputDir\mmap_files.txt" -Encoding UTF8
    Write-Host "Memory mapped files exported to: mmap_files.txt" -ForegroundColor Green
}

# Generate cache layout suggestion file
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "           GENERATING CACHE LAYOUT SUGGESTION" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Prepare file lists for cache layout
$apkCacheStr = if ($apkFiles -and $apkFiles.Count -gt 0) { ($apkFiles | ForEach-Object { "CRITICAL: $_" }) -join "`n" } else { "# No APK files detected" }
$soCacheStr = if ($soFiles -and $soFiles.Count -gt 0) { ($soFiles | ForEach-Object { "HIGH: $_" }) -join "`n" } else { "# No .so files detected" }
$dataCacheStr = if ($dataFiles -and $dataFiles.Count -gt 0) { ($dataFiles | ForEach-Object { "MEDIUM: $_" }) -join "`n" } else { "# No data files detected" }

$cacheLayout = @"
# SSD Secondary Cache Layout Suggestion
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Purpose: Pre-load these files into cache for fast cold start
#
# Layout Strategy:
#   1. Files are ordered by access priority (APK/DEX first)
#   2. Suggested block size: 256KB for consolidation
#   3. Files should be stored CONTIGUOUSLY in cache

# === PHASE 1: Critical boot files (APK/DEX) ===
# These files are accessed first during cold start
# Priority: HIGHEST
$apkCacheStr

# === PHASE 2: Native libraries (.so) ===
# Loaded via dlopen/mmap during initialization
# Priority: HIGH
$soCacheStr

# === PHASE 3: App data files ===
# Configuration, databases, preferences
# Priority: MEDIUM
$dataCacheStr

# === IMPLEMENTATION NOTES ===
# 
# 1. Cache Block Design:
#    - Use 256KB - 1MB cache blocks
#    - Store multiple small files in single block
#    - Align to SSD page size (typically 4KB)
#
# 2. Pre-loading Strategy:
#    - On system boot: pre-load Phase 1 files
#    - On user activity prediction: pre-load Phase 2
#    - Lazy load Phase 3 on first app launch
#
# 3. Cache Eviction:
#    - LRU with priority weighting
#    - Never evict Phase 1 files during app lifecycle
#
# 4. Warm Start Simulation:
#    - When pagecache miss detected
#    - Read entire cache block (not individual files)
#    - Populate pagecache from cache block
"@

$cacheLayout | Out-File -FilePath "$outputDir\cache_layout_suggestion.txt" -Encoding UTF8
Write-Host "Cache layout suggestion saved to: cache_layout_suggestion.txt" -ForegroundColor Green

adb shell am force-stop tv.danmaku.bili 2>$null

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "                    ANALYSIS COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Output files in: $outputDir\" -ForegroundColor White
Write-Host "  - ftrace_raw.log           : Raw ftrace output" -ForegroundColor Gray
Write-Host "  - open_fds.txt             : Open file descriptors" -ForegroundColor Gray
Write-Host "  - memory_maps.txt          : Memory mapped files" -ForegroundColor Gray
Write-Host "  - read_sequence.csv        : Ordered read operations (for analysis)" -ForegroundColor Cyan
Write-Host "  - io_analysis_report.txt   : Full analysis report" -ForegroundColor Cyan
Write-Host "  - cache_file_list.txt      : All files for cache" -ForegroundColor Cyan
Write-Host "  - cache_priority_files.txt : Priority-ordered file list" -ForegroundColor Cyan
Write-Host "  - cache_layout_suggestion.txt : Cache design recommendations" -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT STEPS FOR CACHE IMPLEMENTATION:" -ForegroundColor Yellow
Write-Host "  1. Review read_sequence.csv to understand IO patterns" -ForegroundColor White
Write-Host "  2. Use cache_priority_files.txt as input for cache population" -ForegroundColor White
Write-Host "  3. Implement cache with 256KB+ block size" -ForegroundColor White
Write-Host "  4. Pre-read cache blocks on cold start detection" -ForegroundColor White
