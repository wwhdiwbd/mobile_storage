#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
预读(Readahead)机制分析工具
通过分析 IO 模式来推断内核预读的效果
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import os

plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False

def load_data(csv_path):
    """加载数据"""
    df = pd.read_csv(csv_path, header=0)
    df.columns = ['Order', 'Type', 'Filename', 'Empty', 'Offset', 'Size', 'Timestamp', 'Process']
    df = df.drop('Empty', axis=1)
    df['PageBlock'] = df['Offset'] // 4096
    return df

def analyze_readahead_evidence(df):
    """
    分析预读机制的证据
    """
    print("=" * 70)
    print("预读(Readahead)机制分析")
    print("=" * 70)
    print()
    
    # 1. 分析连续读取片段
    print("【1. 连续读取片段分析】")
    print("如果看到大量连续的页块读取，说明应用在顺序访问。")
    print("但如果片段长度经常是固定值（如32、64、128），可能是预读批量触发的。")
    print()
    
    all_segments = []
    for filename in df['Filename'].unique():
        file_df = df[df['Filename'] == filename].sort_values('Order')
        page_blocks = file_df['PageBlock'].values
        
        if len(page_blocks) < 2:
            continue
        
        # 找连续片段
        segment_len = 1
        for i in range(1, len(page_blocks)):
            if page_blocks[i] == page_blocks[i-1] + 1:
                segment_len += 1
            else:
                if segment_len > 1:
                    all_segments.append(segment_len)
                segment_len = 1
        if segment_len > 1:
            all_segments.append(segment_len)
    
    if all_segments:
        print(f"  总连续片段数: {len(all_segments)}")
        print(f"  平均片段长度: {np.mean(all_segments):.1f} 页")
        print(f"  最大片段长度: {max(all_segments)} 页 ({max(all_segments)*4}KB)")
        print()
        
        # 片段长度分布
        print("  片段长度分布 (Top 10):")
        seg_counts = pd.Series(all_segments).value_counts().sort_index()
        for length, count in seg_counts.head(10).items():
            print(f"    {length:>3} 页连续: {count:>5} 次")
    print()
    
    # 2. 分析时间戳间隔 - 预读的证据
    print("【2. 时间戳分析 - 批量读取证据】")
    print("如果多个连续页的时间戳完全相同或极其接近，说明是同一批预读完成的。")
    print()
    
    batch_evidence = []
    for filename in df['Filename'].unique():
        file_df = df[df['Filename'] == filename].sort_values('Order')
        if len(file_df) < 2:
            continue
        
        timestamps = file_df['Timestamp'].values
        page_blocks = file_df['PageBlock'].values
        
        # 找时间戳相同的连续读取
        batch_start = 0
        for i in range(1, len(timestamps)):
            # 时间戳差异小于0.0001秒（0.1ms）认为是同一批
            if timestamps[i] - timestamps[i-1] < 0.0001 and page_blocks[i] == page_blocks[i-1] + 1:
                continue
            else:
                batch_len = i - batch_start
                if batch_len > 1:
                    batch_evidence.append({
                        'filename': filename,
                        'batch_size': batch_len,
                        'pages': batch_len,
                        'timestamp': timestamps[batch_start]
                    })
                batch_start = i
        
        # 最后一批
        batch_len = len(timestamps) - batch_start
        if batch_len > 1:
            batch_evidence.append({
                'filename': filename,
                'batch_size': batch_len,
                'pages': batch_len,
                'timestamp': timestamps[batch_start]
            })
    
    if batch_evidence:
        batch_df = pd.DataFrame(batch_evidence)
        print(f"  检测到 {len(batch_df)} 个批量读取事件")
        print(f"  平均批量大小: {batch_df['batch_size'].mean():.1f} 页")
        print()
        print("  批量大小分布:")
        batch_sizes = batch_df['batch_size'].value_counts().sort_index()
        for size, count in batch_sizes.head(15).items():
            print(f"    {size:>3} 页/批: {count:>5} 次 ({size*4}KB)")
    print()
    
    # 3. 分析"跳跃"现象 - 预读命中的证据
    print("【3. 页块跳跃分析 - 预读命中证据】")
    print("如果某些连续页块被'跳过'（没有IO记录），说明它们可能已被预读到缓存。")
    print()
    
    gaps = []
    for filename in df['Filename'].unique():
        file_df = df[df['Filename'] == filename].sort_values('Order')
        page_blocks = file_df['PageBlock'].values
        
        for i in range(1, len(page_blocks)):
            gap = page_blocks[i] - page_blocks[i-1]
            # 小的正向跳跃（2-128页）可能是预读命中
            if 2 <= gap <= 128:
                gaps.append({
                    'filename': filename,
                    'gap': gap,
                    'from_block': page_blocks[i-1],
                    'to_block': page_blocks[i]
                })
    
    if gaps:
        gap_df = pd.DataFrame(gaps)
        print(f"  检测到 {len(gap_df)} 次小跳跃 (2-128页)")
        print()
        print("  跳跃大小分布 (可能的预读命中):")
        gap_counts = gap_df['gap'].value_counts().sort_index().head(20)
        for gap_size, count in gap_counts.items():
            print(f"    跳过 {gap_size:>3} 页: {count:>5} 次 (预读了 {gap_size*4}KB?)")
    print()
    
    # 4. 分析典型预读窗口大小
    print("【4. 推断预读窗口大小】")
    print("Linux 默认预读窗口最大 128KB (32页)，会动态调整。")
    print()
    
    # 找最常见的批量大小
    if batch_evidence:
        common_batches = batch_df['batch_size'].value_counts().head(5)
        print("  最常见的批量读取大小:")
        for size, count in common_batches.items():
            print(f"    {size} 页 ({size*4}KB): {count} 次")
            if size in [8, 16, 32, 64, 128]:
                print(f"      ^ 这是典型的预读窗口大小!")
    
    return all_segments, batch_evidence, gaps

def visualize_readahead(df, output_dir):
    """可视化预读分析结果"""
    
    os.makedirs(output_dir, exist_ok=True)
    
    # 选择一个有代表性的大文件
    file_counts = df['Filename'].value_counts()
    top_file = file_counts.index[0]
    file_df = df[df['Filename'] == top_file].sort_values('Order').copy()
    
    fig, axes = plt.subplots(3, 1, figsize=(16, 14))
    
    # 1. 页块号随IO序号变化 - 显示批量读取
    ax1 = axes[0]
    orders = file_df['Order'].values
    page_blocks = file_df['PageBlock'].values
    timestamps = file_df['Timestamp'].values
    
    # 根据时间戳间隔着色
    colors = ['red']
    for i in range(1, len(timestamps)):
        if timestamps[i] - timestamps[i-1] < 0.0001:  # 同一批
            colors.append(colors[-1])
        else:
            # 换一个颜色
            colors.append('blue' if colors[-1] == 'red' else 'red')
    
    ax1.scatter(orders, page_blocks, c=colors, s=20, alpha=0.7)
    ax1.set_xlabel('IO 序号', fontsize=10)
    ax1.set_ylabel('页块号', fontsize=10)
    ax1.set_title(f'批量读取可视化: {os.path.basename(top_file)}\n(颜色交替表示不同的读取批次，同色点是同一批预读)', fontsize=12)
    
    # 2. 时间戳间隔分布
    ax2 = axes[1]
    time_diffs = np.diff(timestamps) * 1000  # 转换为毫秒
    time_diffs = time_diffs[time_diffs < 10]  # 只看小于10ms的
    
    ax2.hist(time_diffs, bins=100, color='steelblue', edgecolor='black', alpha=0.7)
    ax2.axvline(x=0.1, color='red', linestyle='--', label='0.1ms (同批阈值)')
    ax2.set_xlabel('相邻IO时间间隔 (毫秒)', fontsize=10)
    ax2.set_ylabel('频次', fontsize=10)
    ax2.set_title('IO时间间隔分布\n(接近0的峰值表示批量预读)', fontsize=12)
    ax2.legend()
    
    # 3. 连续读取片段长度与时间的关系
    ax3 = axes[2]
    
    # 找出每个批次的信息
    batch_starts = [0]
    batch_lens = []
    current_len = 1
    
    for i in range(1, len(timestamps)):
        if timestamps[i] - timestamps[i-1] < 0.0001 and page_blocks[i] == page_blocks[i-1] + 1:
            current_len += 1
        else:
            batch_lens.append(current_len)
            batch_starts.append(i)
            current_len = 1
    batch_lens.append(current_len)
    
    # 绘制批次大小随时间变化
    batch_times = [timestamps[i] for i in batch_starts]
    ax3.bar(range(len(batch_lens[:100])), batch_lens[:100], color='green', alpha=0.7)
    ax3.axhline(y=32, color='red', linestyle='--', label='32页 (128KB 预读窗口)')
    ax3.axhline(y=16, color='orange', linestyle='--', label='16页 (64KB)')
    ax3.set_xlabel('批次序号', fontsize=10)
    ax3.set_ylabel('批次大小 (页数)', fontsize=10)
    ax3.set_title('连续读取批次大小 (前100个批次)\n(接近32/16/8的值可能是预读窗口大小)', fontsize=12)
    ax3.legend()
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, 'readahead_analysis.png')
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"\n已保存: {output_path}")
    
    # 4. 单独画一个预读证据图
    fig2, ax = plt.subplots(figsize=(16, 8))
    
    # 只取前500个IO
    n = min(500, len(file_df))
    orders = file_df['Order'].values[:n]
    page_blocks = file_df['PageBlock'].values[:n]
    timestamps = file_df['Timestamp'].values[:n]
    
    # 画点
    ax.scatter(orders, page_blocks, c='red', s=30, alpha=0.6, zorder=3, label='实际IO记录')
    
    # 画连续读取的线（同批次的用绿线）
    for i in range(1, len(page_blocks)):
        if page_blocks[i] == page_blocks[i-1] + 1:
            if timestamps[i] - timestamps[i-1] < 0.0001:
                # 同批次，用粗绿线
                ax.plot([orders[i-1], orders[i]], [page_blocks[i-1], page_blocks[i]], 
                       'g-', linewidth=3, alpha=0.8, zorder=2)
            else:
                # 不同批次但连续，用细蓝线
                ax.plot([orders[i-1], orders[i]], [page_blocks[i-1], page_blocks[i]], 
                       'b-', linewidth=1, alpha=0.5, zorder=1)
    
    # 标注可能的预读命中（跳跃的地方）
    for i in range(1, len(page_blocks)):
        gap = page_blocks[i] - page_blocks[i-1]
        if 2 <= gap <= 32:  # 小跳跃，可能是预读命中
            ax.annotate('', xy=(orders[i], page_blocks[i]), 
                       xytext=(orders[i-1], page_blocks[i-1]),
                       arrowprops=dict(arrowstyle='->', color='orange', lw=1.5, alpha=0.7))
    
    ax.set_xlabel('IO 序号', fontsize=12)
    ax.set_ylabel('页块号 (Offset / 4096)', fontsize=12)
    ax.set_title(f'预读机制可视化: {os.path.basename(top_file)} (前{n}次IO)\n'
                f'粗绿线=同批次预读, 细蓝线=连续但分批, 橙色箭头=可能的预读命中(跳过的页)', fontsize=12)
    
    # 添加图例
    from matplotlib.lines import Line2D
    legend_elements = [
        Line2D([0], [0], marker='o', color='w', markerfacecolor='red', markersize=10, label='实际IO记录'),
        Line2D([0], [0], color='green', linewidth=3, label='同批次预读 (时间戳相同)'),
        Line2D([0], [0], color='blue', linewidth=1, label='连续读取 (分批完成)'),
        Line2D([0], [0], color='orange', linewidth=2, label='可能的预读命中 (跳过的页)'),
    ]
    ax.legend(handles=legend_elements, loc='upper left', fontsize=10)
    
    plt.tight_layout()
    output_path2 = os.path.join(output_dir, 'readahead_evidence.png')
    plt.savefig(output_path2, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"已保存: {output_path2}")

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(script_dir, 'io_analysis_20260128_152506', 'read_sequence.csv')
    output_dir = os.path.join(script_dir, 'io_visualization_output')
    
    print("正在加载数据...")
    df = load_data(csv_path)
    print(f"加载完成: {len(df)} 条记录\n")
    
    # 分析预读证据
    segments, batches, gaps = analyze_readahead_evidence(df)
    
    # 可视化
    print("\n正在生成可视化...")
    visualize_readahead(df, output_dir)
    
    print("\n" + "=" * 70)
    print("总结：预读机制的工作原理")
    print("=" * 70)
    print("""
1. 当内核检测到顺序读取模式时，会启动预读机制
2. 预读会一次性读取多个连续页面（通常8-128KB）
3. 这些页面在同一时间戳完成（批量读取）
4. 后续访问如果命中预读缓存，就不会产生新的IO记录
5. 所以你看到的"跳跃"可能就是预读命中的证据！

典型预读窗口大小：
  - 初始: 16KB-32KB
  - 最大: 128KB (可通过 /sys/block/xxx/queue/read_ahead_kb 调整)
  - 动态调整: 根据应用的读取模式自动增减
""")

if __name__ == '__main__':
    main()
