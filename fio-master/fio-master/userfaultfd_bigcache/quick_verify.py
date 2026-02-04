#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
快速验证脚本 - 在 Windows 上运行 BigCache 性能模拟
"""

import os
import sys

# 设置路径
script_dir = os.path.dirname(os.path.abspath(__file__))
tools_dir = os.path.join(script_dir, 'tools')
sys.path.insert(0, tools_dir)

# 现有数据路径
layout_path = os.path.join(
    script_dir, '..', 'visit_io', 'io_visualization_output', 'bigcache_layout.csv'
)

def main():
    print("=" * 70)
    print("BigCache + UFFD 冷启动优化方案 - 性能验证")
    print("=" * 70)
    print()
    
    # 检查数据文件
    if not os.path.exists(layout_path):
        print(f"Error: Layout file not found: {layout_path}")
        return 1
    
    # 导入模拟模块
    from simulate_performance import (
        load_io_trace,
        simulate_traditional_access,
        simulate_bigcache_access,
        simulate_uffd_demand_paging,
        STORAGE_PROFILES,
        PAGE_SIZE
    )
    
    # 加载 trace 数据
    print(f"Loading IO trace from: {layout_path}")
    trace = load_io_trace(layout_path)
    print(f"Loaded {len(trace)} IO operations")
    
    # 统计分析
    unique_files = set(io['file'] for io in trace)
    unique_pages = set((io['file'], io['offset'] // PAGE_SIZE * PAGE_SIZE) for io in trace)
    
    # 计算文件切换
    prev_file = None
    file_switches = 0
    for io in trace:
        if prev_file != io['file']:
            file_switches += 1
        prev_file = io['file']
    
    print(f"\n--- IO 模式分析 ---")
    print(f"  唯一文件数: {len(unique_files)}")
    print(f"  唯一页面数: {len(unique_pages)}")
    print(f"  文件切换次数: {file_switches}")
    print(f"  平均连续访问: {len(trace) / file_switches:.1f} 次/切换")
    print(f"  BigCache 大小: {len(unique_pages) * PAGE_SIZE / 1024 / 1024:.2f} MB")
    
    # 性能模拟
    print(f"\n--- 性能模拟结果 ---")
    print(f"\n{'存储类型':<20} {'传统模式(ms)':<15} {'BigCache(ms)':<15} {'加速比':<10}")
    print("-" * 60)
    
    results = {}
    for name, storage in STORAGE_PROFILES.items():
        trad = simulate_traditional_access(trace, storage)
        bc = simulate_bigcache_access(trace, storage)
        speedup = trad['total_time_ms'] / bc['total_time_ms']
        
        results[name] = {
            'traditional': trad['total_time_ms'],
            'bigcache': bc['total_time_ms'],
            'speedup': speedup
        }
        
        print(f"{storage.name:<20} {trad['total_time_ms']:<15.2f} {bc['total_time_ms']:<15.2f} {speedup:.2f}x")
    
    # UFFD 按需分页分析
    print(f"\n--- UFFD 按需分页策略分析 (eMMC) ---")
    storage = STORAGE_PROFILES['emmc']
    print(f"\n{'预热比例':<12} {'总时间(ms)':<15} {'预热时间(ms)':<15} {'访问时间(ms)':<15}")
    print("-" * 60)
    
    for preheat in [0, 25, 50, 75, 100]:
        uffd = simulate_uffd_demand_paging(trace, storage, preheat)
        print(f"{preheat}%{'':<10} {uffd['total_time_ms']:<15.2f} "
              f"{uffd['preheat_time_ms']:<15.2f} {uffd['access_time_ms']:<15.4f}")
    
    # 关键结论
    print(f"\n" + "=" * 70)
    print("关键结论")
    print("=" * 70)
    
    emmc_speedup = results['emmc']['speedup']
    ufs_speedup = results['ufs']['speedup']
    
    print(f"""
1. 【问题根源分析】
   - 冷启动时存在 {file_switches} 次跨文件切换
   - 平均每 {len(trace) / file_switches:.1f} 次 IO 就切换一次文件
   - 这导致 readahead 机制失效，存储无法发挥顺序读性能

2. 【BigCache 方案优势】
   - 将 {len(unique_pages)} 个热点页打包成 {len(unique_pages) * PAGE_SIZE / 1024 / 1024:.2f}MB 的连续文件
   - 消除跨文件切换带来的 seek 开销
   - 充分利用存储的顺序读带宽

3. 【预期性能提升】
   - eMMC 设备: {emmc_speedup:.1f}x 加速
   - UFS 设备: {ufs_speedup:.1f}x 加速
   - HDD 设备: {results['hdd']['speedup']:.1f}x 加速（效果最显著）

4. 【技术创新点】
   - 使用 userfaultfd 实现用户态缺页处理
   - 应用"以为"自己在读多个文件，实际只发生一次顺序读
   - 无需修改应用代码，透明优化

5. 【实施建议】
   - 在应用安装/更新时生成 BigCache
   - 根据设备内存调整预热策略
   - 优先在低端设备（eMMC）上部署
""")
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
