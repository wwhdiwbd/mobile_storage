#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BigCache 完整分析和可视化
生成所有分析图表和报告
"""

import os
import sys
import csv
import numpy as np
import matplotlib.pyplot as plt
from collections import defaultdict
from dataclasses import dataclass

# 设置中文字体
plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False

PAGE_SIZE = 4096

@dataclass
class StorageParams:
    name: str
    sequential_read_mbps: float
    random_read_iops: float
    seek_time_ms: float
    page_read_us: float

STORAGE_PROFILES = {
    'hdd': StorageParams('HDD', 150, 100, 8, 10000),
    'ssd': StorageParams('SSD (SATA)', 500, 50000, 0.1, 80),
    'nvme': StorageParams('NVMe SSD', 3000, 500000, 0.02, 20),
    'emmc': StorageParams('eMMC (Mobile)', 300, 10000, 0.3, 200),
    'ufs': StorageParams('UFS 3.1 (Mobile)', 2000, 70000, 0.1, 50)
}

def load_trace(csv_path):
    """加载 trace 数据"""
    trace = []
    with open(csv_path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            trace.append({
                'file': row.get('source_file', row.get('Filename', '')),
                'offset': int(row.get('source_offset', row.get('Offset', 0))),
                'order': int(row.get('first_access_order', row.get('Order', 0)))
            })
    return trace

def analyze_io_pattern(trace):
    """分析 IO 模式"""
    unique_files = set(io['file'] for io in trace)
    unique_pages = set((io['file'], io['offset'] // PAGE_SIZE * PAGE_SIZE) for io in trace)
    
    # 文件切换分析
    prev_file = None
    file_switches = 0
    segment_lengths = []
    current_segment = 0
    
    for io in trace:
        if prev_file != io['file']:
            if current_segment > 0:
                segment_lengths.append(current_segment)
            current_segment = 1
            file_switches += 1
        else:
            current_segment += 1
        prev_file = io['file']
    
    if current_segment > 0:
        segment_lengths.append(current_segment)
    
    # 文件访问统计
    file_access_count = defaultdict(int)
    for io in trace:
        file_access_count[io['file']] += 1
    
    return {
        'total_ios': len(trace),
        'unique_files': len(unique_files),
        'unique_pages': len(unique_pages),
        'file_switches': file_switches,
        'segment_lengths': segment_lengths,
        'file_access_count': dict(file_access_count),
        'bigcache_size_mb': len(unique_pages) * PAGE_SIZE / 1024 / 1024
    }

def simulate_traditional(trace, storage):
    """模拟传统访问"""
    total_time_ms = 0
    prev_file = None
    prev_offset = 0
    seeks = 0
    
    for io in trace:
        if prev_file != io['file']:
            total_time_ms += storage.seek_time_ms
            seeks += 1
        elif abs(io['offset'] - prev_offset) > 128 * 1024:
            total_time_ms += storage.seek_time_ms * 0.5
            seeks += 1
        
        total_time_ms += storage.page_read_us / 1000
        prev_file = io['file']
        prev_offset = io['offset']
    
    return {'total_time_ms': total_time_ms, 'seeks': seeks}

def simulate_bigcache(trace, storage):
    """模拟 BigCache"""
    unique_pages = set((io['file'], io['offset'] // PAGE_SIZE * PAGE_SIZE) for io in trace)
    bigcache_size = len(unique_pages) * PAGE_SIZE
    
    preheat_time_ms = (bigcache_size / (1024 * 1024)) / storage.sequential_read_mbps * 1000
    access_time_ms = len(trace) * 0.0001  # 内存访问
    
    return {
        'total_time_ms': preheat_time_ms + access_time_ms,
        'preheat_time_ms': preheat_time_ms,
        'bigcache_size_mb': bigcache_size / (1024 * 1024)
    }

def create_visualizations(trace, analysis, output_dir):
    """创建可视化图表"""
    os.makedirs(output_dir, exist_ok=True)
    
    # 图1：各存储类型性能对比
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    
    storage_names = list(STORAGE_PROFILES.keys())
    trad_times = []
    bc_times = []
    speedups = []
    
    for name in storage_names:
        storage = STORAGE_PROFILES[name]
        trad = simulate_traditional(trace, storage)
        bc = simulate_bigcache(trace, storage)
        trad_times.append(trad['total_time_ms'])
        bc_times.append(bc['total_time_ms'])
        speedups.append(trad['total_time_ms'] / bc['total_time_ms'])
    
    x = np.arange(len(storage_names))
    width = 0.35
    
    ax1 = axes[0]
    ax1.bar(x - width/2, trad_times, width, label='传统模式', color='#FF6B6B', alpha=0.8)
    ax1.bar(x + width/2, bc_times, width, label='BigCache 模式', color='#4ECDC4', alpha=0.8)
    ax1.set_xlabel('存储类型')
    ax1.set_ylabel('冷启动 IO 时间 (ms)')
    ax1.set_title('传统模式 vs BigCache 模式')
    ax1.set_xticks(x)
    ax1.set_xticklabels([STORAGE_PROFILES[s].name for s in storage_names], rotation=15)
    ax1.legend()
    ax1.set_yscale('log')
    ax1.grid(True, alpha=0.3, axis='y')
    
    ax2 = axes[1]
    colors = plt.cm.RdYlGn(np.array(speedups) / max(speedups))
    bars = ax2.bar(x, speedups, color=colors, alpha=0.8)
    ax2.set_xlabel('存储类型')
    ax2.set_ylabel('加速比 (倍)')
    ax2.set_title('BigCache 加速效果')
    ax2.set_xticks(x)
    ax2.set_xticklabels([STORAGE_PROFILES[s].name for s in storage_names], rotation=15)
    ax2.axhline(y=1, color='red', linestyle='--', alpha=0.5)
    
    for bar, speedup in zip(bars, speedups):
        ax2.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.3,
                f'{speedup:.1f}x', ha='center', fontsize=9)
    
    ax2.grid(True, alpha=0.3, axis='y')
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'storage_comparison.png'), dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  Created: storage_comparison.png")
    
    # 图2：文件访问交织分析
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    
    # 文件切换热力图
    ax = axes[0, 0]
    n = min(500, len(trace))
    files = list(set(io['file'] for io in trace[:n]))
    file_to_idx = {f: i for i, f in enumerate(files)}
    
    data = [file_to_idx.get(trace[i]['file'], 0) for i in range(n)]
    ax.plot(range(n), data, 'b-', alpha=0.5, linewidth=0.5)
    ax.scatter(range(n), data, c=data, cmap='tab20', s=5, alpha=0.7)
    ax.set_xlabel('IO 序号')
    ax.set_ylabel('文件索引')
    ax.set_title(f'文件访问交织模式 (前 {n} 次 IO)')
    ax.grid(True, alpha=0.3)
    
    # 片段长度分布
    ax = axes[0, 1]
    segment_lengths = analysis['segment_lengths']
    if segment_lengths:
        ax.hist(segment_lengths, bins=50, color='#9B59B6', alpha=0.7, edgecolor='black')
        ax.axvline(x=np.mean(segment_lengths), color='red', linestyle='--', 
                   label=f'平均: {np.mean(segment_lengths):.1f}')
        ax.set_xlabel('连续访问同一文件的次数')
        ax.set_ylabel('频率')
        ax.set_title('文件连续访问片段长度分布')
        ax.legend()
        ax.grid(True, alpha=0.3)
    
    # Top 10 热点文件
    ax = axes[1, 0]
    file_counts = analysis['file_access_count']
    top_files = sorted(file_counts.items(), key=lambda x: x[1], reverse=True)[:10]
    files_short = [os.path.basename(f[0])[:20] for f in top_files]
    counts = [f[1] for f in top_files]
    
    y_pos = np.arange(len(files_short))
    ax.barh(y_pos, counts, color='#3498DB', alpha=0.8)
    ax.set_yticks(y_pos)
    ax.set_yticklabels(files_short, fontsize=8)
    ax.set_xlabel('访问次数')
    ax.set_title('Top 10 热点文件')
    ax.invert_yaxis()
    ax.grid(True, alpha=0.3, axis='x')
    
    # 移动设备详细分析
    ax = axes[1, 1]
    mobile_storages = ['emmc', 'ufs']
    preheat_levels = np.arange(0, 101, 10)
    
    for storage_name in mobile_storages:
        storage = STORAGE_PROFILES[storage_name]
        unique_pages = set((io['file'], io['offset'] // PAGE_SIZE * PAGE_SIZE) for io in trace)
        bigcache_size = len(unique_pages) * PAGE_SIZE
        
        times = []
        for preheat in preheat_levels:
            preheat_size = bigcache_size * preheat / 100
            preheat_time = (preheat_size / (1024 * 1024)) / storage.sequential_read_mbps * 1000
            # 简化的按需加载时间估算
            demand_pages = int(len(unique_pages) * (100 - preheat) / 100)
            demand_time = demand_pages * storage.page_read_us / 1000
            times.append(preheat_time + demand_time * 0.1)  # 假设大部分页面已经在缓存
        
        ax.plot(preheat_levels, times, 'o-', label=storage.name, linewidth=2, markersize=6)
    
    ax.set_xlabel('预热百分比 (%)')
    ax.set_ylabel('总时间 (ms)')
    ax.set_title('UFFD 预热策略分析')
    ax.legend()
    ax.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'io_pattern_analysis.png'), dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  Created: io_pattern_analysis.png")
    
    # 图3：优化效果总结
    fig, ax = plt.subplots(figsize=(10, 6))
    
    metrics = ['IO 操作数', '文件切换', '有效 Seek', 'BigCache 大小\n(MB)']
    
    trad = simulate_traditional(trace, STORAGE_PROFILES['emmc'])
    bc = simulate_bigcache(trace, STORAGE_PROFILES['emmc'])
    
    trad_values = [len(trace), analysis['file_switches'], trad['seeks'], 0]
    bc_values = [len(trace), 0, 1, bc['bigcache_size_mb']]  # BigCache 只有一次顺序读
    
    x = np.arange(len(metrics))
    width = 0.35
    
    bars1 = ax.bar(x - width/2, trad_values, width, label='传统模式', color='#FF6B6B', alpha=0.8)
    bars2 = ax.bar(x + width/2, bc_values, width, label='BigCache 模式', color='#4ECDC4', alpha=0.8)
    
    ax.set_ylabel('数值')
    ax.set_title('传统模式 vs BigCache 模式 - 关键指标对比')
    ax.set_xticks(x)
    ax.set_xticklabels(metrics)
    ax.legend()
    ax.grid(True, alpha=0.3, axis='y')
    
    # 添加数值标签
    for bar in bars1:
        height = bar.get_height()
        if height > 0:
            ax.text(bar.get_x() + bar.get_width()/2., height,
                   f'{int(height):,}' if height > 1 else f'{height:.1f}',
                   ha='center', va='bottom', fontsize=8)
    
    for bar in bars2:
        height = bar.get_height()
        if height > 0:
            ax.text(bar.get_x() + bar.get_width()/2., height,
                   f'{int(height):,}' if height > 1 else f'{height:.1f}',
                   ha='center', va='bottom', fontsize=8)
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'optimization_summary.png'), dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  Created: optimization_summary.png")

def generate_report(trace, analysis, output_dir):
    """生成分析报告"""
    report_path = os.path.join(output_dir, 'analysis_report.md')
    
    # 计算各存储类型的性能
    results = {}
    for name, storage in STORAGE_PROFILES.items():
        trad = simulate_traditional(trace, storage)
        bc = simulate_bigcache(trace, storage)
        results[name] = {
            'traditional': trad['total_time_ms'],
            'bigcache': bc['total_time_ms'],
            'speedup': trad['total_time_ms'] / bc['total_time_ms']
        }
    
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write("# BigCache + UFFD 冷启动优化方案分析报告\n\n")
        
        f.write("## 1. 数据概览\n\n")
        f.write(f"| 指标 | 数值 |\n")
        f.write(f"|------|------|\n")
        f.write(f"| 总 IO 操作数 | {analysis['total_ios']:,} |\n")
        f.write(f"| 唯一文件数 | {analysis['unique_files']} |\n")
        f.write(f"| 唯一页面数 | {analysis['unique_pages']:,} |\n")
        f.write(f"| 文件切换次数 | {analysis['file_switches']:,} |\n")
        f.write(f"| BigCache 大小 | {analysis['bigcache_size_mb']:.2f} MB |\n")
        f.write(f"| 平均连续访问 | {np.mean(analysis['segment_lengths']):.1f} 次/切换 |\n\n")
        
        f.write("## 2. 性能对比\n\n")
        f.write("| 存储类型 | 传统模式 (ms) | BigCache (ms) | 加速比 |\n")
        f.write("|----------|--------------|--------------|--------|\n")
        for name in ['hdd', 'ssd', 'nvme', 'emmc', 'ufs']:
            r = results[name]
            f.write(f"| {STORAGE_PROFILES[name].name} | {r['traditional']:.2f} | {r['bigcache']:.2f} | {r['speedup']:.2f}x |\n")
        
        f.write("\n## 3. 核心发现\n\n")
        f.write(f"### 3.1 IO 模式问题\n")
        f.write(f"- 文件切换过于频繁（{analysis['file_switches']:,} 次），平均每 {analysis['total_ios']/analysis['file_switches']:.1f} 次 IO 就切换文件\n")
        f.write(f"- 这导致 readahead 机制无法有效工作\n")
        f.write(f"- 存储设备的顺序读性能无法发挥\n\n")
        
        f.write(f"### 3.2 BigCache 解决方案\n")
        f.write(f"- 将 {analysis['unique_pages']:,} 个热点页打包成 {analysis['bigcache_size_mb']:.2f} MB 的连续文件\n")
        f.write(f"- 启动时一次顺序读取完成\n")
        f.write(f"- 使用 userfaultfd 将数据\"偷梁换柱\"到应用期望的地址\n\n")
        
        f.write("## 4. 技术优势\n\n")
        f.write("1. **消除跨文件 Seek**：将随机 IO 转换为顺序 IO\n")
        f.write("2. **利用高顺序带宽**：充分发挥存储的顺序读性能\n")
        f.write("3. **用户态实现**：无需修改内核，部署灵活\n")
        f.write("4. **透明优化**：应用无感知，无需修改应用代码\n\n")
        
        f.write("## 5. 建议\n\n")
        f.write("1. 在低端设备（eMMC）上效果最显著\n")
        f.write("2. 首次安装后生成 BigCache\n")
        f.write("3. 根据设备内存调整预热策略\n")
        f.write("4. 定期更新 BigCache 以适应应用行为变化\n")
    
    print(f"  Created: analysis_report.md")
    return report_path

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    layout_path = os.path.join(
        script_dir, '..', 'visit_io', 'io_visualization_output', 'bigcache_layout.csv'
    )
    output_dir = os.path.join(script_dir, 'analysis_output')
    
    print("=" * 70)
    print("BigCache + UFFD 冷启动优化方案 - 完整分析")
    print("=" * 70)
    print()
    
    # 检查文件
    if not os.path.exists(layout_path):
        print(f"Error: Layout file not found: {layout_path}")
        return 1
    
    print(f"Loading trace from: {layout_path}")
    trace = load_trace(layout_path)
    print(f"Loaded {len(trace)} IO operations")
    
    print("\nAnalyzing IO pattern...")
    analysis = analyze_io_pattern(trace)
    
    print("\n--- 分析结果 ---")
    print(f"  总 IO 数: {analysis['total_ios']:,}")
    print(f"  唯一文件: {analysis['unique_files']}")
    print(f"  唯一页面: {analysis['unique_pages']:,}")
    print(f"  文件切换: {analysis['file_switches']:,}")
    print(f"  BigCache 大小: {analysis['bigcache_size_mb']:.2f} MB")
    
    print("\nGenerating visualizations...")
    create_visualizations(trace, analysis, output_dir)
    
    print("\nGenerating report...")
    generate_report(trace, analysis, output_dir)
    
    print("\n--- 性能模拟结果 ---")
    print(f"\n{'存储类型':<20} {'传统模式':<15} {'BigCache':<15} {'加速比':<10}")
    print("-" * 60)
    
    for name, storage in STORAGE_PROFILES.items():
        trad = simulate_traditional(trace, storage)
        bc = simulate_bigcache(trace, storage)
        speedup = trad['total_time_ms'] / bc['total_time_ms']
        print(f"{storage.name:<20} {trad['total_time_ms']:<15.2f} {bc['total_time_ms']:<15.2f} {speedup:.2f}x")
    
    print(f"\n输出目录: {output_dir}")
    print("\n" + "=" * 70)
    print("分析完成!")
    print("=" * 70)
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
