#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BigCache 方案可行性分析
验证 userfaultfd + BigCache.bin 方案是否有价值

核心问题：
1. 当前 IO 是否存在跨文件交织？（readahead 无法优化这个）
2. 如果把热点页打包成 BigCache.bin，能减少多少 seek？
3. 理论上能提升多少性能？
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import os
from collections import defaultdict

plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False

def load_data(csv_path):
    """加载数据"""
    df = pd.read_csv(csv_path, header=0)
    df.columns = ['Order', 'Type', 'Filename', 'Empty', 'Offset', 'Size', 'Timestamp', 'Process']
    df = df.drop('Empty', axis=1)
    df['PageBlock'] = df['Offset'] // 4096
    return df

def analyze_file_interleaving(df):
    """
    分析1: 跨文件交织情况
    这是 readahead 无法优化的关键问题！
    """
    print("=" * 70)
    print("【分析1: 跨文件交织 - Readahead 的盲区】")
    print("=" * 70)
    print()
    print("Readahead 只能在单个文件内预读，当 IO 在多个文件间切换时，")
    print("每次切换都可能导致磁盘 seek，这是你方案的核心优化点！")
    print()
    
    df_sorted = df.sort_values('Order')
    
    # 统计文件切换次数
    prev_file = None
    file_switches = 0
    switch_details = []
    
    for _, row in df_sorted.iterrows():
        if prev_file is not None and row['Filename'] != prev_file:
            file_switches += 1
            switch_details.append({
                'from': prev_file,
                'to': row['Filename'],
                'order': row['Order']
            })
        prev_file = row['Filename']
    
    total_ios = len(df)
    switch_ratio = file_switches / total_ios * 100
    
    print(f"总 IO 次数: {total_ios}")
    print(f"文件切换次数: {file_switches}")
    print(f"切换频率: 每 {total_ios/file_switches:.1f} 次 IO 切换一次文件")
    print(f"切换占比: {switch_ratio:.1f}%")
    print()
    
    # 分析连续访问同一文件的"片段"长度
    segment_lengths = []
    current_len = 1
    prev_file = df_sorted.iloc[0]['Filename']
    
    for _, row in df_sorted.iloc[1:].iterrows():
        if row['Filename'] == prev_file:
            current_len += 1
        else:
            segment_lengths.append(current_len)
            current_len = 1
        prev_file = row['Filename']
    segment_lengths.append(current_len)
    
    print("连续访问同一文件的片段长度分布:")
    print(f"  平均: {np.mean(segment_lengths):.1f} 次 IO")
    print(f"  中位数: {np.median(segment_lengths):.0f} 次 IO")
    print(f"  最大: {max(segment_lengths)} 次 IO")
    print()
    
    # 片段长度分布
    seg_counts = pd.Series(segment_lengths).value_counts().sort_index()
    print("  片段长度分布 (Top 10):")
    for length, count in seg_counts.head(10).items():
        print(f"    连续访问 {length:>3} 次后切换: {count:>5} 次")
    
    return file_switches, segment_lengths

def analyze_seek_overhead(df):
    """
    分析2: Seek 开销估算
    假设文件在磁盘上随机分布，计算潜在的 seek 开销
    """
    print()
    print("=" * 70)
    print("【分析2: 磁盘 Seek 开销估算】")
    print("=" * 70)
    print()
    
    df_sorted = df.sort_values('Order')
    
    # 为每个文件分配一个虚拟的磁盘起始位置（模拟文件在磁盘上的分布）
    files = df['Filename'].unique()
    np.random.seed(42)
    # 假设磁盘大小 128GB，文件随机分布
    disk_size = 128 * 1024 * 1024 * 1024  # 128GB
    file_disk_positions = {f: np.random.randint(0, disk_size // 1024) * 1024 for f in files}
    
    # 计算当前模式的 seek 距离
    total_seek_distance = 0
    seek_count = 0
    prev_pos = 0
    prev_file = None
    
    for _, row in df_sorted.iterrows():
        file_base = file_disk_positions[row['Filename']]
        current_pos = file_base + row['Offset']
        
        if prev_file is not None:
            seek_dist = abs(current_pos - prev_pos)
            # 只统计跨文件的大 seek（> 1MB）
            if row['Filename'] != prev_file and seek_dist > 1024 * 1024:
                total_seek_distance += seek_dist
                seek_count += 1
        
        prev_pos = current_pos
        prev_file = row['Filename']
    
    print(f"跨文件大 Seek (>1MB) 次数: {seek_count}")
    print(f"总 Seek 距离: {total_seek_distance / 1024 / 1024 / 1024:.2f} GB")
    print(f"平均每次 Seek: {total_seek_distance / seek_count / 1024 / 1024:.1f} MB" if seek_count > 0 else "")
    print()
    
    # HDD vs SSD 的影响
    print("对不同存储介质的影响:")
    print(f"  HDD (假设 seek time 8ms): {seek_count * 8 / 1000:.2f} 秒 纯 seek 开销")
    print(f"  SSD (假设 seek time 0.1ms): {seek_count * 0.1 / 1000:.3f} 秒 纯 seek 开销")
    print(f"  eMMC (假设 seek time 0.3ms): {seek_count * 0.3 / 1000:.3f} 秒 纯 seek 开销")
    
    return seek_count, total_seek_distance

def analyze_bigcache_benefit(df):
    """
    分析3: BigCache.bin 方案的理论收益
    """
    print()
    print("=" * 70)
    print("【分析3: BigCache.bin 方案收益估算】")
    print("=" * 70)
    print()
    
    df_sorted = df.sort_values('Order')
    
    # 统计热点页
    unique_pages = df_sorted.groupby('Filename').apply(
        lambda x: x['PageBlock'].nunique()
    ).to_dict()
    
    total_hot_pages = sum(unique_pages.values())
    total_hot_size = total_hot_pages * 4096
    
    print("热点页统计:")
    print(f"  涉及文件数: {len(unique_pages)}")
    print(f"  总热点页数: {total_hot_pages} 页")
    print(f"  BigCache.bin 大小: {total_hot_size / 1024 / 1024:.2f} MB")
    print()
    
    # 当前模式 vs BigCache 模式对比
    print("IO 模式对比:")
    print()
    print("【当前模式】")
    print(f"  - {len(unique_pages)} 个文件的随机 mmap 访问")
    print(f"  - 每个文件内有 readahead，但文件间有 seek")
    print(f"  - 实际 IO: 多次小块读取 + 文件切换 seek")
    print()
    print("【BigCache.bin 模式】")
    print(f"  - 1 个文件的纯顺序读取")
    print(f"  - 文件大小: {total_hot_size / 1024 / 1024:.2f} MB")
    print(f"  - 实际 IO: 1 次大块顺序读取")
    print()
    
    # 理论性能估算
    print("理论性能对比 (假设 eMMC 顺序读 300MB/s, 随机读 30MB/s):")
    
    # 当前模式：考虑随机性
    current_time_random = total_hot_size / (30 * 1024 * 1024)
    current_time_seq = total_hot_size / (300 * 1024 * 1024)
    
    # BigCache 模式：纯顺序
    bigcache_time = total_hot_size / (300 * 1024 * 1024)
    
    print(f"  当前模式 (偏随机): ~{current_time_random:.2f} 秒")
    print(f"  当前模式 (偏顺序): ~{current_time_seq:.3f} 秒")
    print(f"  BigCache 模式: ~{bigcache_time:.3f} 秒")
    print(f"  潜在提升: {current_time_random / bigcache_time:.1f}x (最大)")
    
    return total_hot_pages, total_hot_size

def analyze_io_pattern_detail(df):
    """
    分析4: 详细的 IO 模式分析 - 证明 readahead 不够用
    """
    print()
    print("=" * 70)
    print("【分析4: Readahead 为什么不够用】")
    print("=" * 70)
    print()
    
    df_sorted = df.sort_values('Order')
    
    # 分析：每次文件切换时，readahead 的预读数据是否被浪费
    print("Readahead 的问题:")
    print()
    print("1. 【预读浪费】当切换到另一个文件时，之前文件的预读缓存可能没用完")
    
    # 计算每个文件最后一次访问时，距离文件末尾还有多少预读空间被浪费
    file_last_access = {}
    file_max_offset = df.groupby('Filename')['Offset'].max().to_dict()
    
    prev_file = None
    wasted_readahead = 0
    for _, row in df_sorted.iterrows():
        if prev_file is not None and row['Filename'] != prev_file:
            # 切换了文件，计算之前文件的预读浪费
            # 假设预读窗口 128KB
            readahead_window = 128 * 1024
            last_offset = file_last_access.get(prev_file, 0)
            max_offset = file_max_offset.get(prev_file, 0)
            potential_waste = min(readahead_window, max_offset - last_offset)
            if potential_waste > 0:
                wasted_readahead += potential_waste
        
        file_last_access[row['Filename']] = row['Offset']
        prev_file = row['Filename']
    
    print(f"   预读缓存潜在浪费: {wasted_readahead / 1024 / 1024:.2f} MB")
    print()
    
    print("2. 【冷启动延迟】第一次访问每个文件时，必须等待磁盘 IO")
    first_access_count = df['Filename'].nunique()
    print(f"   首次访问的文件数: {first_access_count}")
    print(f"   每个文件首次访问都有 IO 延迟 (无法预读)")
    print()
    
    print("3. 【随机 vs 顺序的本质区别】")
    print("   - 当前: 访问文件A → 切换到文件B → 切换到文件C → 回到文件A")
    print("   - BigCache: A的热点页 + B的热点页 + C的热点页 → 一次顺序读完")
    print()
    
    # 可视化文件访问的交织情况
    return wasted_readahead

def visualize_interleaving(df, output_dir):
    """
    可视化文件访问交织情况
    """
    os.makedirs(output_dir, exist_ok=True)
    
    df_sorted = df.sort_values('Order')
    
    # 只取前 2000 个 IO 来可视化
    n = min(2000, len(df_sorted))
    df_vis = df_sorted.head(n)
    
    # 为每个文件分配一个 Y 值
    files = df_vis['Filename'].unique()
    file_to_y = {f: i for i, f in enumerate(files)}
    
    fig, axes = plt.subplots(2, 1, figsize=(18, 12))
    
    # 图1: 文件访问交织图
    ax1 = axes[0]
    colors = plt.cm.tab20(np.linspace(0, 1, len(files)))
    file_colors = {f: colors[i] for i, f in enumerate(files)}
    
    for _, row in df_vis.iterrows():
        y = file_to_y[row['Filename']]
        ax1.scatter(row['Order'], y, c=[file_colors[row['Filename']]], s=10, alpha=0.7)
    
    # 画连接线显示切换
    orders = df_vis['Order'].values
    ys = [file_to_y[f] for f in df_vis['Filename'].values]
    ax1.plot(orders, ys, 'k-', alpha=0.2, linewidth=0.5)
    
    ax1.set_xlabel('IO 序号', fontsize=12)
    ax1.set_ylabel('文件 (每行一个文件)', fontsize=12)
    ax1.set_title(f'文件访问交织图 (前 {n} 次 IO)\n'
                  f'横向跳跃 = 磁盘 seek，这是 BigCache 能优化的！', fontsize=14)
    ax1.set_yticks([])
    
    # 图2: 文件切换频率
    ax2 = axes[1]
    window_size = 50
    switch_rates = []
    
    filenames = df_vis['Filename'].values
    for i in range(0, len(filenames) - window_size, 10):
        window = filenames[i:i+window_size]
        switches = sum(1 for j in range(1, len(window)) if window[j] != window[j-1])
        switch_rates.append(switches / window_size * 100)
    
    ax2.plot(range(len(switch_rates)), switch_rates, 'b-', linewidth=1)
    ax2.fill_between(range(len(switch_rates)), switch_rates, alpha=0.3)
    ax2.axhline(y=50, color='red', linestyle='--', label='50% 切换率')
    ax2.set_xlabel('IO 位置 (窗口)', fontsize=12)
    ax2.set_ylabel('文件切换率 (%)', fontsize=12)
    ax2.set_title('文件切换频率 (滑动窗口)\n高切换率 = readahead 效果差', fontsize=14)
    ax2.legend()
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, 'file_interleaving.png')
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"\n已保存: {output_path}")
    
    # 图3: BigCache vs 当前模式对比图
    fig2, axes2 = plt.subplots(1, 2, figsize=(16, 6))
    
    # 当前模式
    ax_current = axes2[0]
    for i, (_, row) in enumerate(df_vis.head(200).iterrows()):
        y = file_to_y[row['Filename']]
        ax_current.scatter(i, y, c=[file_colors[row['Filename']]], s=30, alpha=0.7)
    
    orders_200 = list(range(200))
    ys_200 = [file_to_y[f] for f in df_vis.head(200)['Filename'].values]
    ax_current.plot(orders_200, ys_200, 'k-', alpha=0.3, linewidth=1)
    ax_current.set_title('当前模式: 跨文件随机跳跃\n(每次跳跃 = 磁盘 seek)', fontsize=12)
    ax_current.set_xlabel('IO 序号')
    ax_current.set_ylabel('文件')
    ax_current.set_yticks([])
    
    # BigCache 模式
    ax_bigcache = axes2[1]
    # 模拟 BigCache：按文件分组后顺序读取
    bigcache_order = df_vis.head(200).sort_values(['Filename', 'Offset'])
    for i, (_, row) in enumerate(bigcache_order.iterrows()):
        y = file_to_y[row['Filename']]
        ax_bigcache.scatter(i, y, c=[file_colors[row['Filename']]], s=30, alpha=0.7)
    
    ys_bigcache = [file_to_y[f] for f in bigcache_order['Filename'].values]
    ax_bigcache.plot(range(len(ys_bigcache)), ys_bigcache, 'k-', alpha=0.3, linewidth=1)
    ax_bigcache.set_title('BigCache 模式: 顺序读取\n(按文件聚合，消除 seek)', fontsize=12)
    ax_bigcache.set_xlabel('IO 序号')
    ax_bigcache.set_ylabel('文件')
    ax_bigcache.set_yticks([])
    
    plt.tight_layout()
    output_path2 = os.path.join(output_dir, 'bigcache_comparison.png')
    plt.savefig(output_path2, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"已保存: {output_path2}")

def generate_bigcache_layout(df, output_dir):
    """
    生成 BigCache.bin 的布局文件
    这个可以直接用于实现！
    """
    print()
    print("=" * 70)
    print("【生成 BigCache.bin 布局】")
    print("=" * 70)
    print()
    
    df_sorted = df.sort_values('Order')
    
    # 按访问顺序提取每个文件的热点页
    hot_pages = []  # (filename, page_block, access_order)
    seen_pages = set()
    
    for _, row in df_sorted.iterrows():
        key = (row['Filename'], row['PageBlock'])
        if key not in seen_pages:
            seen_pages.add(key)
            hot_pages.append({
                'filename': row['Filename'],
                'page_block': row['PageBlock'],
                'offset_in_file': row['PageBlock'] * 4096,
                'first_access_order': row['Order']
            })
    
    # 生成布局
    layout = []
    bigcache_offset = 0
    
    for page in hot_pages:
        layout.append({
            'bigcache_offset': bigcache_offset,
            'source_file': page['filename'],
            'source_offset': page['offset_in_file'],
            'size': 4096,
            'first_access_order': page['first_access_order']
        })
        bigcache_offset += 4096
    
    # 保存布局文件
    layout_df = pd.DataFrame(layout)
    layout_path = os.path.join(output_dir, 'bigcache_layout.csv')
    layout_df.to_csv(layout_path, index=False)
    print(f"BigCache 布局已保存: {layout_path}")
    print(f"  总页数: {len(layout)}")
    print(f"  BigCache.bin 大小: {bigcache_offset / 1024 / 1024:.2f} MB")
    print()
    
    # 按文件统计
    print("各文件热点页统计 (Top 20):")
    file_stats = layout_df.groupby('source_file').size().sort_values(ascending=False)
    for fname, count in file_stats.head(20).items():
        print(f"  {os.path.basename(fname)}: {count} 页 ({count*4}KB)")
    
    return layout_df

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(script_dir, 'io_analysis_20260128_152506', 'read_sequence.csv')
    output_dir = os.path.join(script_dir, 'io_visualization_output')
    
    print("正在加载数据...")
    df = load_data(csv_path)
    print(f"加载完成: {len(df)} 条记录, {df['Filename'].nunique()} 个文件\n")
    
    # 分析1: 跨文件交织
    file_switches, segment_lengths = analyze_file_interleaving(df)
    
    # 分析2: Seek 开销
    seek_count, total_seek = analyze_seek_overhead(df)
    
    # 分析3: BigCache 收益
    hot_pages, hot_size = analyze_bigcache_benefit(df)
    
    # 分析4: Readahead 的问题
    wasted = analyze_io_pattern_detail(df)
    
    # 可视化
    print("\n正在生成可视化...")
    visualize_interleaving(df, output_dir)
    
    # 生成 BigCache 布局
    layout = generate_bigcache_layout(df, output_dir)
    
    # 最终结论
    print()
    print("=" * 70)
    print("【最终结论: BigCache 方案是否有价值？】")
    print("=" * 70)
    print()
    
    if file_switches > 1000 and np.mean(segment_lengths) < 20:
        print("✅ 你的方案非常有价值！")
        print()
        print("原因:")
        print(f"  1. 文件切换频繁: {file_switches} 次切换")
        print(f"  2. 每次连续访问同一文件仅 {np.mean(segment_lengths):.1f} 次就切换")
        print(f"  3. Readahead 无法跨文件优化")
        print()
        print("BigCache 方案可以:")
        print(f"  - 把 {df['Filename'].nunique()} 个文件的 {hot_pages} 热点页打包")
        print(f"  - 用 1 次 {hot_size/1024/1024:.1f}MB 顺序读取替代大量随机 IO")
        print(f"  - 消除约 {file_switches} 次磁盘 seek")
    else:
        print("⚠️ 方案价值有限")
        print("当前 IO 模式已经比较顺序，readahead 工作良好")
    
    print()
    print("=" * 70)
    print("【实验建议】")
    print("=" * 70)
    print("""
要真正验证效果，建议做以下实验:

1. 【基准测试】清空 Page Cache 后测量冷启动时间
   adb shell "echo 3 > /proc/sys/vm/drop_caches"
   adb shell am start -W <package>

2. 【实现 BigCache】
   - 用生成的 bigcache_layout.csv 打包热点页
   - 实现 userfaultfd handler
   - 对比冷启动时间

3. 【更精确的分析】
   - 用 blktrace 获取实际的块设备 IO
   - 分析真实的 seek pattern
   
4. 【关注 eMMC/UFS 特性】
   - 现代闪存随机读性能已经很好
   - 但顺序读仍有 2-5x 优势
   - BigCache 的主要收益是减少元数据查找和文件系统开销
""")

if __name__ == '__main__':
    main()
