#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IO 读取序列可视化工具
用于可视化 read_sequence.csv 文件中的 IO 读取位置
"""

import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
import os
from collections import defaultdict
import re

# 设置中文字体支持
plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False

def categorize_file(filename):
    """
    根据文件路径对文件进行分类
    """
    if not filename or pd.isna(filename):
        return 'Unknown'
    
    filename = str(filename)
    
    # APK 相关文件
    if '.apk' in filename:
        return 'APK'
    if '.odex' in filename or '.vdex' in filename or '.art' in filename:
        return 'DEX/ART'
    
    # JAR 文件
    if '.jar' in filename:
        return 'JAR'
    
    # 配置文件
    if 'properties' in filename or 'config' in filename or '.xml' in filename:
        return 'Config'
    
    # 日志文件
    if '/log/' in filename or '.log' in filename:
        return 'Log'
    
    # 库文件
    if '.so' in filename:
        return 'Shared Library'
    
    # 字体文件
    if '.ttf' in filename or '.otf' in filename or 'fonts' in filename:
        return 'Font'
    
    # 数据库文件
    if '.db' in filename or '.sqlite' in filename:
        return 'Database'
    
    # 缓存文件
    if 'cache' in filename.lower():
        return 'Cache'
    
    # 图片资源
    if any(ext in filename for ext in ['.png', '.jpg', '.jpeg', '.webp', '.gif']):
        return 'Image'
    
    return 'Other'

def simplify_filename(filename):
    """
    简化文件名以便显示
    """
    if not filename or pd.isna(filename):
        return 'Unknown'
    
    filename = str(filename)
    
    # 提取基本文件名
    basename = os.path.basename(filename)
    
    # 如果路径太长，截取关键部分
    if len(basename) > 40:
        basename = '...' + basename[-37:]
    
    return basename

def load_and_process_data(csv_path):
    """
    加载并处理 CSV 数据
    """
    # 读取 CSV，注意列名中有空列
    df = pd.read_csv(csv_path, header=0)
    
    # 重命名列（处理空列名）
    columns = ['Order', 'Type', 'Filename', 'Empty', 'Offset', 'Size', 'Timestamp', 'Process']
    if len(df.columns) >= 8:
        df.columns = columns[:len(df.columns)]
    
    # 删除空列
    if 'Empty' in df.columns:
        df = df.drop('Empty', axis=1)
    
    # 添加分类列
    df['Category'] = df['Filename'].apply(categorize_file)
    df['SimpleName'] = df['Filename'].apply(simplify_filename)
    
    return df

def get_file_max_offset(df):
    """
    获取每个文件的最大偏移量（估算文件大小）
    """
    file_max = df.groupby('Filename').agg({
        'Offset': 'max',
        'Size': 'max'
    }).reset_index()
    file_max['EstimatedSize'] = file_max['Offset'] + file_max['Size']
    return dict(zip(file_max['Filename'], file_max['EstimatedSize']))

def plot_io_positions_by_category(df, output_dir):
    """
    按类别绘制 IO 读取位置图
    偏移量除以 4096 转换为页块号，连续的页块用绿线连接
    """
    categories = df['Category'].unique()
    
    # 为每个类别创建一个图
    for category in categories:
        cat_df = df[df['Category'] == category].copy()
        files = cat_df['Filename'].unique()
        
        if len(files) == 0:
            continue
        
        # 限制每个图最多显示 20 个文件
        if len(files) > 20:
            # 选择 IO 次数最多的 20 个文件
            file_counts = cat_df['Filename'].value_counts().head(20)
            files = file_counts.index.tolist()
            cat_df = cat_df[cat_df['Filename'].isin(files)]
        
        # 计算页块号
        cat_df['PageBlock'] = cat_df['Offset'] // 4096
        
        fig, ax = plt.subplots(figsize=(16, max(8, len(files) * 0.5)))
        
        # 获取每个文件的最大页块号
        file_max_block = cat_df.groupby('Filename')['PageBlock'].max().to_dict()
        
        # 为每个文件创建一行
        y_positions = {}
        for i, filename in enumerate(files):
            y_positions[filename] = i
        
        # 统计顺序读取信息
        sequential_stats = {}
        
        # 绘制每个文件的 IO 位置
        for filename in files:
            file_df = cat_df[cat_df['Filename'] == filename].sort_values('Order')
            y = y_positions[filename]
            max_block = file_max_block.get(filename, 1)
            
            # 归一化页块号到 0-1 范围
            page_blocks = file_df['PageBlock'].values
            normalized_blocks = page_blocks / max_block if max_block > 0 else page_blocks
            
            # 绘制文件的基线
            ax.hlines(y, 0, 1, colors='lightgray', linestyles='-', linewidth=1)
            
            # 统计并绘制连续读取
            sequential_count = 0
            for i in range(1, len(page_blocks)):
                if page_blocks[i] == page_blocks[i-1] + 1:
                    # 连续读取，画绿线
                    x1 = normalized_blocks[i-1]
                    x2 = normalized_blocks[i]
                    ax.plot([x1, x2], [y - 0.15, y + 0.15], 'g-', alpha=0.7, linewidth=2)
                    sequential_count += 1
            
            sequential_stats[filename] = (sequential_count, len(page_blocks) - 1 if len(page_blocks) > 1 else 0)
            
            # 绘制红点表示读取位置
            ax.scatter(normalized_blocks, [y] * len(file_df), 
                      c='red', s=20, alpha=0.6, marker='o', zorder=3)
        
        # 设置 Y 轴标签（添加顺序读取比例）
        ylabels = []
        for f in files:
            seq, total = sequential_stats.get(f, (0, 0))
            ratio = seq / total * 100 if total > 0 else 0
            ylabels.append(f"{simplify_filename(f)} ({ratio:.0f}%顺序)")
        
        ax.set_yticks(range(len(files)))
        ax.set_yticklabels(ylabels, fontsize=8)
        
        ax.set_xlabel('文件内相对位置 (0=文件开头, 1=文件末尾) [页块号/4096]', fontsize=12)
        ax.set_ylabel('文件', fontsize=12)
        ax.set_title(f'IO 读取位置分布 - {category} 类文件\n(红点=读取位置, 绿线=顺序读取)', fontsize=14)
        ax.set_xlim(-0.05, 1.05)
        ax.set_ylim(-0.5, len(files) - 0.5)
        
        plt.tight_layout()
        
        # 保存图片
        safe_category = re.sub(r'[^\w\-_]', '_', category)
        output_path = os.path.join(output_dir, f'io_positions_{safe_category}.png')
        plt.savefig(output_path, dpi=150, bbox_inches='tight')
        plt.close()
        print(f'已保存: {output_path}')

def plot_io_timeline(df, output_dir):
    """
    绘制 IO 时间线图
    偏移量除以 4096 转换为页块号
    """
    df_copy = df.copy()
    df_copy['PageBlock'] = df_copy['Offset'] // 4096
    
    fig, ax = plt.subplots(figsize=(16, 10))
    
    # 获取唯一的类别和颜色
    categories = df_copy['Category'].unique()
    colors = plt.cm.tab10(np.linspace(0, 1, len(categories)))
    color_map = dict(zip(categories, colors))
    
    # 按时间戳排序
    df_sorted = df_copy.sort_values('Timestamp')
    
    # 为每个类别绘制散点
    for category in categories:
        cat_df = df_sorted[df_sorted['Category'] == category]
        ax.scatter(cat_df['Order'], cat_df['PageBlock'], 
                  c=[color_map[category]], label=category, 
                  s=10, alpha=0.6)
    
    ax.set_xlabel('IO 序号', fontsize=12)
    ax.set_ylabel('页块号 (Offset / 4096)', fontsize=12)
    ax.set_title('IO 读取时间线 - 按类别着色 (页块号)', fontsize=14)
    ax.legend(loc='upper right', fontsize=10)
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, 'io_timeline.png')
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f'已保存: {output_path}')

def plot_category_statistics(df, output_dir):
    """
    绘制类别统计图
    """
    fig, axes = plt.subplots(2, 2, figsize=(14, 12))
    
    # 1. 各类别 IO 次数饼图
    ax1 = axes[0, 0]
    category_counts = df['Category'].value_counts()
    colors = plt.cm.Set3(np.linspace(0, 1, len(category_counts)))
    wedges, texts, autotexts = ax1.pie(category_counts.values, labels=category_counts.index, 
                                        autopct='%1.1f%%', colors=colors, startangle=90)
    ax1.set_title('各类别 IO 次数分布', fontsize=12)
    
    # 2. 各类别数据量柱状图
    ax2 = axes[0, 1]
    category_sizes = df.groupby('Category')['Size'].sum() / (1024 * 1024)  # 转换为 MB
    bars = ax2.bar(range(len(category_sizes)), category_sizes.values, color=colors[:len(category_sizes)])
    ax2.set_xticks(range(len(category_sizes)))
    ax2.set_xticklabels(category_sizes.index, rotation=45, ha='right', fontsize=9)
    ax2.set_ylabel('数据量 (MB)', fontsize=10)
    ax2.set_title('各类别读取数据量', fontsize=12)
    
    # 3. Top 10 文件 IO 次数
    ax3 = axes[1, 0]
    file_counts = df['Filename'].value_counts().head(10)
    y_pos = range(len(file_counts))
    ax3.barh(y_pos, file_counts.values, color='steelblue')
    ax3.set_yticks(y_pos)
    ax3.set_yticklabels([simplify_filename(f) for f in file_counts.index], fontsize=8)
    ax3.set_xlabel('IO 次数', fontsize=10)
    ax3.set_title('Top 10 高频访问文件', fontsize=12)
    ax3.invert_yaxis()
    
    # 4. 读取大小分布直方图
    ax4 = axes[1, 1]
    sizes = df['Size'] / 1024  # 转换为 KB
    ax4.hist(sizes, bins=50, color='coral', edgecolor='black', alpha=0.7)
    ax4.set_xlabel('读取大小 (KB)', fontsize=10)
    ax4.set_ylabel('频次', fontsize=10)
    ax4.set_title('单次读取大小分布', fontsize=12)
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, 'io_statistics.png')
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f'已保存: {output_path}')

def plot_single_file_detail(df, filename, output_dir):
    """
    绘制单个文件的详细 IO 位置图
    偏移量除以 4096 转换为页块号，连续的页块用线连接
    """
    file_df = df[df['Filename'] == filename].copy()
    if len(file_df) == 0:
        return
    
    # 计算页块号 (偏移量 / 4096)
    file_df['PageBlock'] = file_df['Offset'] // 4096
    
    fig, axes = plt.subplots(2, 1, figsize=(14, 10))
    
    # 1. IO 位置随时间变化（使用页块号）
    ax1 = axes[0]
    orders = file_df['Order'].values
    page_blocks = file_df['PageBlock'].values
    
    # 绘制红点
    ax1.scatter(orders, page_blocks, c='red', s=30, alpha=0.6, zorder=3)
    
    # 只在连续的页块之间连线
    for i in range(1, len(page_blocks)):
        # 检查是否连续（当前页块 = 上一个页块 + 1）
        if page_blocks[i] == page_blocks[i-1] + 1:
            ax1.plot([orders[i-1], orders[i]], [page_blocks[i-1], page_blocks[i]], 
                    'g-', alpha=0.8, linewidth=1.5, zorder=2)
    
    # 统计顺序读取
    sequential_count = sum(1 for i in range(1, len(page_blocks)) if page_blocks[i] == page_blocks[i-1] + 1)
    total_transitions = len(page_blocks) - 1 if len(page_blocks) > 1 else 0
    seq_ratio = sequential_count / total_transitions * 100 if total_transitions > 0 else 0
    
    ax1.set_xlabel('IO 序号', fontsize=10)
    ax1.set_ylabel('页块号 (Offset / 4096)', fontsize=10)
    ax1.set_title(f'文件 IO 访问模式: {simplify_filename(filename)}\n(绿线=顺序读取, 红点=读取位置, 顺序读取率: {seq_ratio:.1f}%)', fontsize=12)
    
    # 2. 顺序读取片段可视化
    ax2 = axes[1]
    
    # 识别连续读取的片段
    segments = []
    current_segment = [0]
    for i in range(1, len(page_blocks)):
        if page_blocks[i] == page_blocks[i-1] + 1:
            current_segment.append(i)
        else:
            if len(current_segment) > 0:
                segments.append(current_segment)
            current_segment = [i]
    if len(current_segment) > 0:
        segments.append(current_segment)
    
    # 绘制每个片段
    y = 0
    colors_seq = plt.cm.Set2(np.linspace(0, 1, len(segments)))
    for idx, segment in enumerate(segments):
        seg_blocks = page_blocks[segment]
        seg_orders = orders[segment]
        
        if len(segment) > 1:
            # 连续读取片段，用绿色
            ax2.barh(y, len(segment), left=min(seg_blocks), height=0.8, 
                    color='green', alpha=0.7, edgecolor='darkgreen')
            ax2.text(min(seg_blocks) + len(segment)/2, y, f'{len(segment)}块', 
                    ha='center', va='center', fontsize=8, color='white', fontweight='bold')
        else:
            # 单独的随机读取，用红色
            ax2.barh(y, 1, left=seg_blocks[0], height=0.8, 
                    color='red', alpha=0.6, edgecolor='darkred')
        y += 1
        
        # 每20个片段换一行显示
        if y > 30:
            break
    
    ax2.set_xlabel('页块号 (Offset / 4096)', fontsize=10)
    ax2.set_ylabel('读取片段序号', fontsize=10)
    ax2.set_title(f'读取片段分析 (共 {len(segments)} 个片段, 绿色=顺序读取, 红色=随机读取)', fontsize=12)
    
    plt.tight_layout()
    safe_name = re.sub(r'[^\w\-_]', '_', simplify_filename(filename))
    output_path = os.path.join(output_dir, f'file_detail_{safe_name}.png')
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f'已保存: {output_path}')

def plot_all_files_overview(df, output_dir):
    """
    绘制所有文件的 IO 位置概览图
    偏移量除以 4096 转换为页块号，连续的页块用绿线连接
    """
    # 获取 IO 次数最多的前 50 个文件
    top_files = df['Filename'].value_counts().head(50).index.tolist()
    top_df = df[df['Filename'].isin(top_files)].copy()
    
    # 计算页块号
    top_df['PageBlock'] = top_df['Offset'] // 4096
    
    fig, ax = plt.subplots(figsize=(18, 14))
    
    # 获取每个文件的最大页块号
    file_max_block = top_df.groupby('Filename')['PageBlock'].max().to_dict()
    
    # 为每个文件分配 Y 位置
    y_positions = {f: i for i, f in enumerate(top_files)}
    
    # 类别颜色
    categories = top_df['Category'].unique()
    colors = plt.cm.tab10(np.linspace(0, 1, len(categories)))
    color_map = dict(zip(categories, colors))
    
    # 统计顺序读取信息
    sequential_stats = {}
    
    # 绘制每个文件的 IO 位置
    for filename in top_files:
        file_df = top_df[top_df['Filename'] == filename].sort_values('Order')
        y = y_positions[filename]
        max_block = file_max_block.get(filename, 1)
        
        # 归一化页块号到 0-1 范围
        page_blocks = file_df['PageBlock'].values
        normalized_blocks = page_blocks / max_block if max_block > 0 else page_blocks
        
        # 获取文件类别颜色
        category = file_df['Category'].iloc[0]
        color = color_map[category]
        
        # 绘制基线（用类别颜色）
        ax.hlines(y, 0, 1, colors=color, linestyles='-', linewidth=3, alpha=0.3)
        
        # 统计连续读取次数
        sequential_count = 0
        
        # 在连续的页块之间画绿线
        for i in range(1, len(page_blocks)):
            if page_blocks[i] == page_blocks[i-1] + 1:
                # 连续读取，画绿线
                x1 = normalized_blocks[i-1]
                x2 = normalized_blocks[i]
                ax.plot([x1, x2], [y - 0.1, y + 0.1], 'g-', alpha=0.7, linewidth=1.5)
                sequential_count += 1
        
        sequential_stats[filename] = (sequential_count, len(page_blocks) - 1 if len(page_blocks) > 1 else 0)
        
        # 绘制红点
        ax.scatter(normalized_blocks, [y] * len(file_df), 
                  c='red', s=15, alpha=0.6, marker='o', zorder=3)
    
    # 设置 Y 轴标签（添加顺序读取比例）
    ylabels = []
    for f in top_files:
        seq, total = sequential_stats.get(f, (0, 0))
        ratio = seq / total * 100 if total > 0 else 0
        ylabels.append(f"{simplify_filename(f)} ({ratio:.0f}%顺序)")
    
    ax.set_yticks(range(len(top_files)))
    ax.set_yticklabels(ylabels, fontsize=7)
    
    ax.set_xlabel('文件内相对位置 (0=文件开头, 1=文件末尾) [页块号/4096]', fontsize=12)
    ax.set_ylabel('文件 (按 IO 次数排序)', fontsize=12)
    ax.set_title('Top 50 高频访问文件 - IO 读取位置分布\n(红点=读取位置, 绿线=顺序读取, 背景色=文件类别)', fontsize=14)
    ax.set_xlim(-0.05, 1.05)
    ax.set_ylim(-0.5, len(top_files) - 0.5)
    
    # 添加图例
    legend_patches = [mpatches.Patch(color=color_map[cat], label=cat, alpha=0.3) 
                     for cat in categories]
    legend_patches.append(mpatches.Patch(color='green', label='顺序读取', alpha=0.7))
    ax.legend(handles=legend_patches, loc='upper right', fontsize=9)
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, 'io_positions_overview.png')
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f'已保存: {output_path}')

def generate_summary_report(df, output_dir):
    """
    生成文本摘要报告
    """
    report_lines = []
    report_lines.append("=" * 60)
    report_lines.append("IO 读取序列分析报告")
    report_lines.append("=" * 60)
    report_lines.append("")
    
    # 基本统计
    report_lines.append("【基本统计】")
    report_lines.append(f"  总 IO 次数: {len(df)}")
    report_lines.append(f"  涉及文件数: {df['Filename'].nunique()}")
    report_lines.append(f"  总读取数据量: {df['Size'].sum() / (1024*1024):.2f} MB")
    report_lines.append(f"  平均单次读取: {df['Size'].mean() / 1024:.2f} KB")
    report_lines.append("")
    
    # 类别统计
    report_lines.append("【按类别统计】")
    category_stats = df.groupby('Category').agg({
        'Order': 'count',
        'Size': 'sum',
        'Filename': 'nunique'
    }).rename(columns={'Order': 'IO次数', 'Size': '数据量(字节)', 'Filename': '文件数'})
    category_stats['数据量(MB)'] = category_stats['数据量(字节)'] / (1024*1024)
    category_stats = category_stats.sort_values('IO次数', ascending=False)
    
    for cat, row in category_stats.iterrows():
        report_lines.append(f"  {cat}:")
        report_lines.append(f"    - IO 次数: {row['IO次数']}")
        report_lines.append(f"    - 文件数: {row['文件数']}")
        report_lines.append(f"    - 数据量: {row['数据量(MB)']:.2f} MB")
    report_lines.append("")
    
    # Top 10 文件
    report_lines.append("【Top 10 高频访问文件】")
    file_counts = df['Filename'].value_counts().head(10)
    for i, (filename, count) in enumerate(file_counts.items(), 1):
        report_lines.append(f"  {i}. {simplify_filename(filename)}: {count} 次")
    report_lines.append("")
    
    # 保存报告
    report_path = os.path.join(output_dir, 'io_analysis_summary.txt')
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(report_lines))
    print(f'已保存: {report_path}')

def main():
    """
    主函数
    """
    # 设置路径
    script_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(script_dir, 'io_analysis_20260128_152506', 'read_sequence.csv')
    output_dir = os.path.join(script_dir, 'io_visualization_output')
    
    # 检查文件是否存在
    if not os.path.exists(csv_path):
        print(f"错误: 找不到文件 {csv_path}")
        # 尝试相对路径
        csv_path = 'read_sequence.csv'
        if not os.path.exists(csv_path):
            print("请确保 read_sequence.csv 文件存在")
            return
    
    # 创建输出目录
    os.makedirs(output_dir, exist_ok=True)
    print(f"输出目录: {output_dir}")
    print("")
    
    # 加载数据
    print("正在加载数据...")
    df = load_and_process_data(csv_path)
    print(f"加载完成: {len(df)} 条 IO 记录, {df['Filename'].nunique()} 个文件")
    print("")
    
    # 显示类别分布
    print("文件类别分布:")
    for cat, count in df['Category'].value_counts().items():
        print(f"  {cat}: {count} 次 IO")
    print("")
    
    # 生成可视化
    print("正在生成可视化图表...")
    print("-" * 40)
    
    # 1. 所有文件概览
    print("1. 生成文件 IO 位置概览图...")
    plot_all_files_overview(df, output_dir)
    
    # 2. 按类别绘制
    print("2. 生成按类别分组的 IO 位置图...")
    plot_io_positions_by_category(df, output_dir)
    
    # 3. 时间线图
    print("3. 生成 IO 时间线图...")
    plot_io_timeline(df, output_dir)
    
    # 4. 统计图表
    print("4. 生成统计图表...")
    plot_category_statistics(df, output_dir)
    
    # 5. Top 5 文件详细图
    print("5. 生成高频文件详细分析图...")
    top_files = df['Filename'].value_counts().head(5).index.tolist()
    for filename in top_files:
        plot_single_file_detail(df, filename, output_dir)
    
    # 6. 生成文本报告
    print("6. 生成分析报告...")
    generate_summary_report(df, output_dir)
    
    print("-" * 40)
    print(f"\n可视化完成! 所有图表已保存到: {output_dir}")
    print("\n生成的文件列表:")
    for f in os.listdir(output_dir):
        print(f"  - {f}")

if __name__ == '__main__':
    main()
