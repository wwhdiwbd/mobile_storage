# fio-master README

本目录用于在 Android 设备上进行存储性能与冷启动 I/O 行为分析，涵盖缓存分布、I/O 追踪、稳态性能测试、冷启动时延对比，以及基于访问序列的可视化。

## 目录概览

- cache_distribution: 采集应用安装与数据占用、文件分布信息。
- ctrace_io: 通过 atrace 采集冷启动 I/O Trace（含有/无 PageCache）。
- ssd_performance: fio 稳态/顺序读写性能与块大小对比。
- start_time_test: 冷启动时间对比（热启动/仅清 PageCache/全清缓存）。
- visit_io: 基于 ftrace 的真实读序列分析与可视化，评估 Readahead 与 BigCache 方案。

注：脚本部分由AI完成，报错是正常现象，但基本功能均已完成验证，没有问题。

## 运行环境与前置条件

1. Windows + PowerShell。
2. 已安装并配置 ADB（设备连接正常）。具体基础信息可以查看：https://my.feishu.cn/wiki/Y0C4wnTe1idezQkIkXWcZMJanEc?from=from_copylink
3. 设备具备 root 权限（多处脚本需要写 /proc/sys/vm/drop_caches 或读取 ftrace）。——如果没有 root 权限，部分功能将受限，但仍可运行非 root 相关的测试。
4. fio 二进制文件通过push操作放到 /data/local/tmp/fio上。
5. Python 可视化脚本依赖：pandas、numpy、matplotlib。

先通过adb实现简单的测试后，就可以进行下述脚本的测试了。

## cache_distribution

- get_bili_info.ps1
	- 功能：采集 Bilibili 应用安装路径、文件列表、大小分布、缓存与外部存储占用。
	- 输出：bilibili_app_report.txt、bilibili_app_files.csv。
- get_bili_info_1.ps1
	- 功能：与 get_bili_info.ps1 等价的中文注释版本。
- manual_cache_control.ps1（暂未测试）
	- 功能：交互式清理缓存（PageCache、Dentries、App Cache、OAT）并可选择立即启动应用测量耗时。

## ctrace_io

- trace_bili_io.ps1
	- 功能：对 Bilibili 冷启动进行两轮 atrace 采集（无 PageCache 与有 PageCache）。
	- 输出：bili_io_trace_without_pagecache.z、bili_io_trace_with_pagecache.z。
- trace_wz_io.ps1
	- 功能：对王者荣耀进行同样的两轮 atrace 采集。
	- 输出：wz_io_trace_without_pagecache.z、wz_io_trace_with_pagecache.z。

说明：生成的 .z trace 文件可在 Perfetto UI 中分析，直接拖拽放到网站上可以自行进行可视化分析。

## ssd_performance

- test_steady_state.ps1
	- 功能：写入 4GB 预热后，进行随机读/写（fsync=1）稳态测试，覆盖多种块大小。
	- 输出：fio_steady_state_results.csv。
- test_steady_state_seq.ps1
	- 功能：写入 4GB 预热后，进行顺序读/写（fsync=1）测试，覆盖多种块大小。
	- 输出：fio_steady_state_results.csv（与上一个脚本同名，注意避免覆盖）。
- plot_steady_state.py
	- 功能：读取 fio_steady_state_results.csv 生成图表与性能摘要。
	- 输出：steady_state_performance.png。
- test_block_size_comparison.ps1（暂未完成）
	- 功能：比较 “4x4K 并发读” 与 “1x16K 单次读” 的性能差异。
	- 输出：fio_block_comparison_results.csv。
- test_seq_read.ps1（暂未完成）
	- 功能：单条 fio 顺序读示例命令。

## start_time_test

- test_cold_start_bilibili.ps1
	- 功能：Bilibili 冷启动对比测试（热启动 / 仅清 PageCache / 全清缓存），支持多次迭代并统计均值。
	- 输出：bilibili_cold_start_report.csv。
- test_cold_start_wz.ps1
	- 功能：王者荣耀冷启动对比测试，流程与上方一致。
	- 输出：wz_cold_start_report.csv。

注意：全清缓存这段目前没有特别大的用处，主要测试温启动和清理pagecache的启动情况

## visit_io

- trace_file_io.ps1
	- 功能：使用 ftrace 采集真实读序列（含 offset、size、时间戳），用于冷启动 I/O 分析与缓存设计。
	- 输出：io_analysis_YYYYMMDD_HHMMSS 目录，包含 read_sequence.csv、open_fds.txt、memory_maps.txt、file_read_stats.csv 等。
- analyze_io_data.ps1
	- 功能：分析 open_fds.txt 与 memory_maps.txt，统计 APK/DEX、SO、DB、配置文件等类别。
	- 输出：io_analysis_report.txt。
- analyze_io_order.ps1
	- 功能：按 FD 与时间排序展示文件打开顺序。
	- 输出：file_access_order.txt。
- analyze_readahead.py
	- 功能：分析连续读取、批量读取与“跳跃”现象，推断 Readahead 行为并生成可视化。
	- 输出：io_visualization_output 下的 readahead_analysis.png、readahead_evidence.png。
- visualize_io_sequence.py
	- 功能：对 read_sequence.csv 进行类别统计、读取位置分布、时间线等可视化。
	- 输出：io_visualization_output 下的一系列图表。
- analyze_bigcache_feasibility.py（暂未测试）
	- 功能：评估跨文件交织与 seek 开销，估算 BigCache 方案收益，并生成 bigcache_layout.csv。
	- 输出：bigcache_layout.csv、file_interleaving.png、bigcache_comparison.png。

## 使用建议

1. 先完成adb的安装以及部分代码测试
2. 确保手机有root权限以完成全部测试，如果没有root权限，可能只能完成ctrace和部分start_time_test的测试。（测试过程中如果出现permission denied那么就大概率因为需要root权限）

