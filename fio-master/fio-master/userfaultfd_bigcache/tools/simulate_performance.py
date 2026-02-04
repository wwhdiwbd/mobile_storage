#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BigCache 性能模拟和分析

模拟 BigCache 方案与传统方案的性能对比，
用于评估优化效果。
"""

import os
import sys
import csv
import time
import random
import numpy as np
import matplotlib.pyplot as plt
from dataclasses import dataclass
from typing import List, Dict, Tuple
from collections import defaultdict

plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False

# 存储参数（模拟）
@dataclass
class StorageParams:
    """存储性能参数"""
    name: str
    sequential_read_mbps: float  # 顺序读速度 MB/s
    random_read_iops: float      # 随机读 IOPS
    seek_time_ms: float          # 寻道时间 ms
    page_read_us: float          # 单页读取时间 us

# 典型存储设备参数
STORAGE_PROFILES = {
    'hdd': StorageParams(
        name='HDD',
        sequential_read_mbps=150,
        random_read_iops=100,
        seek_time_ms=8,
        page_read_us=10000  # 10ms
    ),
    'ssd': StorageParams(
        name='SSD (SATA)',
        sequential_read_mbps=500,
        random_read_iops=50000,
        seek_time_ms=0.1,
        page_read_us=80
    ),
    'nvme': StorageParams(
        name='NVMe SSD',
        sequential_read_mbps=3000,
        random_read_iops=500000,
        seek_time_ms=0.02,
        page_read_us=20
    ),
    'emmc': StorageParams(
        name='eMMC (Mobile)',
        sequential_read_mbps=300,
        random_read_iops=10000,
        seek_time_ms=0.3,
        page_read_us=200
    ),
    'ufs': StorageParams(
        name='UFS 3.1 (Mobile)',
        sequential_read_mbps=2000,
        random_read_iops=70000,
        seek_time_ms=0.1,
        page_read_us=50
    )
}

PAGE_SIZE = 4096

def load_io_trace(csv_path: str) -> List[Dict]:
    """加载 IO trace"""
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

def simulate_traditional_access(trace: List[Dict], storage: StorageParams) -> Dict:
    """模拟传统访问模式"""
    total_time_ms = 0
    file_switches = 0
    seeks = 0
    
    prev_file = None
    prev_offset = 0
    
    for io in trace:
        file = io['file']
        offset = io['offset']
        
        # 文件切换检测
        if prev_file != file:
            file_switches += 1
            # 跨文件 seek
            total_time_ms += storage.seek_time_ms
            seeks += 1
        else:
            # 同文件内检查是否顺序
            if abs(offset - prev_offset) > 128 * 1024:  # >128KB 认为非顺序
                total_time_ms += storage.seek_time_ms * 0.5  # 较小的 seek
                seeks += 1
        
        # 读取时间
        total_time_ms += storage.page_read_us / 1000
        
        prev_file = file
        prev_offset = offset
    
    return {
        'total_time_ms': total_time_ms,
        'file_switches': file_switches,
        'seeks': seeks,
        'io_count': len(trace)
    }

def simulate_bigcache_access(trace: List[Dict], storage: StorageParams) -> Dict:
    """模拟 BigCache 访问模式"""
    # BigCache 大小
    unique_pages = set((io['file'], io['offset'] // PAGE_SIZE * PAGE_SIZE) for io in trace)
    bigcache_size = len(unique_pages) * PAGE_SIZE
    
    # 顺序预读时间
    preheat_time_ms = (bigcache_size / (1024 * 1024)) / storage.sequential_read_mbps * 1000
    
    # 内存访问时间（几乎可以忽略）
    memory_access_time_us = 0.1  # 假设 100ns 内存访问
    access_time_ms = len(trace) * memory_access_time_us / 1000
    
    return {
        'total_time_ms': preheat_time_ms + access_time_ms,
        'preheat_time_ms': preheat_time_ms,
        'memory_access_time_ms': access_time_ms,
        'bigcache_size_mb': bigcache_size / (1024 * 1024),
        'unique_pages': len(unique_pages),
        'io_count': len(trace)
    }

def simulate_uffd_demand_paging(trace: List[Dict], storage: StorageParams,
                                  preheat_percent: float = 100) -> Dict:
    """模拟 UFFD 按需分页模式"""
    unique_pages = set((io['file'], io['offset'] // PAGE_SIZE * PAGE_SIZE) for io in trace)
    bigcache_size = len(unique_pages) * PAGE_SIZE
    
    # 预热部分数据
    preheat_pages = int(len(unique_pages) * preheat_percent / 100)
    preheat_size = preheat_pages * PAGE_SIZE
    preheat_time_ms = (preheat_size / (1024 * 1024)) / storage.sequential_read_mbps * 1000
    
    # UFFD 处理开销（假设每次缺页处理 5us）
    uffd_overhead_us = 5
    
    # 缺页处理时间
    pages_hit = 0
    pages_miss = 0
    
    # 模拟访问
    access_time_ms = 0
    for i, io in enumerate(trace):
        page_key = (io['file'], io['offset'] // PAGE_SIZE * PAGE_SIZE)
        
        if i < preheat_pages:
            # 预热的页面：内存访问
            access_time_ms += 0.0001  # ~100ns
            pages_hit += 1
        else:
            # 未预热页面：UFFD 处理 + BigCache 查找 + 内存拷贝
            access_time_ms += uffd_overhead_us / 1000
            # 假设已经预读到内存
            access_time_ms += 0.001  # 1us 内存操作
            pages_miss += 1
    
    return {
        'total_time_ms': preheat_time_ms + access_time_ms,
        'preheat_time_ms': preheat_time_ms,
        'access_time_ms': access_time_ms,
        'pages_hit': pages_hit,
        'pages_miss': pages_miss,
        'preheat_percent': preheat_percent
    }

def analyze_and_visualize(trace_path: str, output_dir: str):
    """分析并可视化结果"""
    os.makedirs(output_dir, exist_ok=True)
    
    print("Loading trace data...")
    trace = load_io_trace(trace_path)
    print(f"Loaded {len(trace)} IO operations")
    
    results = {}
    
    # 对每种存储类型进行模拟
    print("\nSimulating different storage types...")
    for storage_name, storage in STORAGE_PROFILES.items():
        print(f"\n=== {storage.name} ===")
        
        # 传统模式
        trad = simulate_traditional_access(trace, storage)
        print(f"Traditional: {trad['total_time_ms']:.2f} ms, "
              f"{trad['file_switches']} file switches, {trad['seeks']} seeks")
        
        # BigCache 模式
        bc = simulate_bigcache_access(trace, storage)
        print(f"BigCache: {bc['total_time_ms']:.2f} ms "
              f"(preheat: {bc['preheat_time_ms']:.2f} ms, "
              f"size: {bc['bigcache_size_mb']:.2f} MB)")
        
        # UFFD 模式（不同预热比例）
        uffd_100 = simulate_uffd_demand_paging(trace, storage, 100)
        uffd_50 = simulate_uffd_demand_paging(trace, storage, 50)
        uffd_0 = simulate_uffd_demand_paging(trace, storage, 0)
        
        speedup = trad['total_time_ms'] / bc['total_time_ms']
        print(f"Speedup: {speedup:.2f}x")
        
        results[storage_name] = {
            'traditional': trad,
            'bigcache': bc,
            'uffd_100': uffd_100,
            'uffd_50': uffd_50,
            'uffd_0': uffd_0,
            'speedup': speedup
        }
    
    # 生成可视化
    print("\nGenerating visualizations...")
    
    # 图1：各存储类型的性能对比
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    
    storage_names = list(results.keys())
    x = np.arange(len(storage_names))
    width = 0.35
    
    trad_times = [results[s]['traditional']['total_time_ms'] for s in storage_names]
    bc_times = [results[s]['bigcache']['total_time_ms'] for s in storage_names]
    
    ax1 = axes[0]
    bars1 = ax1.bar(x - width/2, trad_times, width, label='传统模式', color='#FF6B6B')
    bars2 = ax1.bar(x + width/2, bc_times, width, label='BigCache 模式', color='#4ECDC4')
    
    ax1.set_xlabel('存储类型')
    ax1.set_ylabel('冷启动时间 (ms)')
    ax1.set_title('传统模式 vs BigCache 模式')
    ax1.set_xticks(x)
    ax1.set_xticklabels([STORAGE_PROFILES[s].name for s in storage_names], rotation=15)
    ax1.legend()
    ax1.set_yscale('log')
    ax1.grid(True, alpha=0.3)
    
    # 图2：加速比
    ax2 = axes[1]
    speedups = [results[s]['speedup'] for s in storage_names]
    colors = plt.cm.RdYlGn(np.array(speedups) / max(speedups))
    bars = ax2.bar(x, speedups, color=colors)
    
    ax2.set_xlabel('存储类型')
    ax2.set_ylabel('加速比 (倍)')
    ax2.set_title('BigCache 加速比')
    ax2.set_xticks(x)
    ax2.set_xticklabels([STORAGE_PROFILES[s].name for s in storage_names], rotation=15)
    ax2.axhline(y=1, color='red', linestyle='--', label='基准线')
    
    for bar, speedup in zip(bars, speedups):
        ax2.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5,
                f'{speedup:.1f}x', ha='center', va='bottom', fontsize=10)
    
    ax2.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'storage_comparison.png'), dpi=150)
    plt.close()
    
    # 图3：移动设备详细分析（eMMC/UFS）
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    
    mobile_storages = ['emmc', 'ufs']
    
    for idx, storage_name in enumerate(mobile_storages):
        storage = STORAGE_PROFILES[storage_name]
        result = results[storage_name]
        
        # 时间分解
        ax = axes[0, idx]
        
        trad_time = result['traditional']['total_time_ms']
        bc_preheat = result['bigcache']['preheat_time_ms']
        bc_access = result['bigcache']['memory_access_time_ms']
        
        categories = ['传统模式', 'BigCache']
        times = [
            [trad_time],
            [bc_preheat, bc_access]
        ]
        labels = [
            ['随机IO时间'],
            ['预热时间', '内存访问']
        ]
        colors_list = [
            ['#FF6B6B'],
            ['#4ECDC4', '#45B7D1']
        ]
        
        bottom = 0
        for i, (cat, t_list, l_list, c_list) in enumerate(zip(categories, times, labels, colors_list)):
            for t, l, c in zip(t_list, l_list, c_list):
                ax.bar(cat, t, bottom=bottom if i > 0 else 0, label=l, color=c)
                bottom += t if i > 0 else 0
            bottom = 0
        
        ax.set_ylabel('时间 (ms)')
        ax.set_title(f'{storage.name} 时间分解')
        ax.legend(loc='upper right')
        ax.grid(True, alpha=0.3)
        
        # UFFD 不同预热比例
        ax = axes[1, idx]
        
        preheat_levels = [0, 25, 50, 75, 100]
        uffd_times = []
        for preheat in preheat_levels:
            uffd = simulate_uffd_demand_paging(trace, storage, preheat)
            uffd_times.append(uffd['total_time_ms'])
        
        ax.plot(preheat_levels, uffd_times, 'o-', color='#9B59B6', linewidth=2, markersize=8)
        ax.axhline(y=trad_time, color='#FF6B6B', linestyle='--', label='传统模式')
        ax.axhline(y=bc_preheat + bc_access, color='#4ECDC4', linestyle='--', label='BigCache 完全预热')
        
        ax.set_xlabel('预热百分比 (%)')
        ax.set_ylabel('总时间 (ms)')
        ax.set_title(f'{storage.name} UFFD 预热策略分析')
        ax.legend()
        ax.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'mobile_analysis.png'), dpi=150)
    plt.close()
    
    # 生成报告
    report_path = os.path.join(output_dir, 'simulation_report.txt')
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write("=" * 70 + "\n")
        f.write("BigCache + UFFD 性能模拟报告\n")
        f.write("=" * 70 + "\n\n")
        
        f.write(f"IO Trace: {trace_path}\n")
        f.write(f"总 IO 操作数: {len(trace)}\n")
        f.write(f"唯一页面数: {results['emmc']['bigcache']['unique_pages']}\n")
        f.write(f"BigCache 大小: {results['emmc']['bigcache']['bigcache_size_mb']:.2f} MB\n\n")
        
        f.write("=" * 70 + "\n")
        f.write("各存储类型性能对比\n")
        f.write("=" * 70 + "\n\n")
        
        for storage_name, storage in STORAGE_PROFILES.items():
            result = results[storage_name]
            f.write(f"【{storage.name}】\n")
            f.write(f"  传统模式: {result['traditional']['total_time_ms']:.2f} ms\n")
            f.write(f"  BigCache: {result['bigcache']['total_time_ms']:.2f} ms\n")
            f.write(f"  加速比: {result['speedup']:.2f}x\n\n")
        
        f.write("=" * 70 + "\n")
        f.write("结论与建议\n")
        f.write("=" * 70 + "\n\n")
        
        emmc_speedup = results['emmc']['speedup']
        ufs_speedup = results['ufs']['speedup']
        
        f.write(f"1. 在典型移动设备存储上：\n")
        f.write(f"   - eMMC: BigCache 可实现 {emmc_speedup:.1f}x 加速\n")
        f.write(f"   - UFS: BigCache 可实现 {ufs_speedup:.1f}x 加速\n\n")
        
        f.write(f"2. 主要优化来源：\n")
        f.write(f"   - 消除跨文件 seek 开销\n")
        f.write(f"   - 将随机 IO 转换为顺序 IO\n")
        f.write(f"   - 利用存储的高顺序读带宽\n\n")
        
        f.write(f"3. 适用场景：\n")
        f.write(f"   - 冷启动优化\n")
        f.write(f"   - IO 密集型应用\n")
        f.write(f"   - 存在大量跨文件访问的场景\n")
    
    print(f"\nReport saved: {report_path}")
    print(f"Visualizations saved to: {output_dir}")
    
    return results

def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='BigCache performance simulation and analysis'
    )
    parser.add_argument('trace', help='IO trace CSV file (bigcache_layout.csv)')
    parser.add_argument('-o', '--output', default='simulation_output',
                       help='Output directory for results')
    
    args = parser.parse_args()
    
    results = analyze_and_visualize(args.trace, args.output)
    
    # 打印摘要
    print("\n" + "=" * 50)
    print("性能模拟摘要")
    print("=" * 50)
    for storage_name in ['emmc', 'ufs']:
        result = results[storage_name]
        print(f"\n{STORAGE_PROFILES[storage_name].name}:")
        print(f"  传统模式: {result['traditional']['total_time_ms']:.2f} ms")
        print(f"  BigCache: {result['bigcache']['total_time_ms']:.2f} ms")
        print(f"  加速比: {result['speedup']:.2f}x")

if __name__ == '__main__':
    main()
