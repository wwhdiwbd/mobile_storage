#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BigCache 完整测试套件

包含：
1. BigCache 生成测试
2. 性能模拟
3. 结果分析和可视化
"""

import os
import sys
import subprocess
import time

# 添加工具目录到路径
script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(script_dir, 'tools'))

from generate_bigcache import BigCacheGenerator
from simulate_performance import (
    load_io_trace, 
    simulate_traditional_access,
    simulate_bigcache_access,
    simulate_uffd_demand_paging,
    STORAGE_PROFILES,
    analyze_and_visualize
)

def test_bigcache_generation():
    """测试 BigCache 生成"""
    print("\n" + "=" * 60)
    print("测试 1: BigCache 生成")
    print("=" * 60)
    
    # 使用现有的布局文件
    layout_path = os.path.join(
        script_dir, '..', 'visit_io', 'io_visualization_output', 'bigcache_layout.csv'
    )
    
    if not os.path.exists(layout_path):
        print(f"Warning: Layout file not found: {layout_path}")
        print("Creating sample layout for testing...")
        
        # 创建测试数据
        os.makedirs(os.path.join(script_dir, 'test_data'), exist_ok=True)
        layout_path = os.path.join(script_dir, 'test_data', 'sample_layout.csv')
        
        with open(layout_path, 'w') as f:
            f.write("bigcache_offset,source_file,source_offset,size,first_access_order\n")
            for i in range(1000):
                file_path = f"/app/test/lib{i % 10}.so"
                offset = (i * 4096) % (100 * 4096)
                f.write(f"{i * 4096},{file_path},{offset},4096,{i+1}\n")
        
        print(f"Created sample layout: {layout_path}")
    
    # 生成 BigCache
    output_path = os.path.join(script_dir, 'test_data', 'test_bigcache.bin')
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    generator = BigCacheGenerator()
    loaded = generator.load_from_csv(layout_path)
    
    print(f"Loaded {loaded} pages from layout")
    print(f"Files: {len(generator.files)}")
    
    generator.generate(output_path)
    
    # 验证文件
    if os.path.exists(output_path):
        size_mb = os.path.getsize(output_path) / (1024 * 1024)
        print(f"✓ BigCache generated: {output_path}")
        print(f"  Size: {size_mb:.2f} MB")
        return True, output_path, layout_path
    else:
        print("✗ BigCache generation failed")
        return False, None, layout_path

def test_performance_simulation(layout_path):
    """测试性能模拟"""
    print("\n" + "=" * 60)
    print("测试 2: 性能模拟")
    print("=" * 60)
    
    output_dir = os.path.join(script_dir, 'test_data', 'simulation_results')
    
    try:
        results = analyze_and_visualize(layout_path, output_dir)
        
        print("\n性能模拟结果:")
        for storage_name in ['emmc', 'ufs']:
            if storage_name in results:
                result = results[storage_name]
                print(f"\n  {STORAGE_PROFILES[storage_name].name}:")
                print(f"    传统模式: {result['traditional']['total_time_ms']:.2f} ms")
                print(f"    BigCache: {result['bigcache']['total_time_ms']:.2f} ms")
                print(f"    加速比: {result['speedup']:.2f}x")
        
        return True, results
    except Exception as e:
        print(f"✗ Simulation failed: {e}")
        import traceback
        traceback.print_exc()
        return False, None

def test_trace_analysis(layout_path):
    """测试 IO trace 分析"""
    print("\n" + "=" * 60)
    print("测试 3: IO Trace 分析")
    print("=" * 60)
    
    trace = load_io_trace(layout_path)
    print(f"Loaded {len(trace)} IO operations")
    
    # 分析文件切换
    prev_file = None
    file_switches = 0
    unique_files = set()
    unique_pages = set()
    
    for io in trace:
        file = io['file']
        offset = io['offset']
        
        if prev_file != file:
            file_switches += 1
        
        unique_files.add(file)
        unique_pages.add((file, offset // 4096 * 4096))
        
        prev_file = file
    
    print(f"\n分析结果:")
    print(f"  唯一文件数: {len(unique_files)}")
    print(f"  唯一页面数: {len(unique_pages)}")
    print(f"  文件切换次数: {file_switches}")
    print(f"  平均连续访问: {len(trace) / file_switches:.1f} 次/切换")
    print(f"  BigCache 大小: {len(unique_pages) * 4096 / 1024 / 1024:.2f} MB")
    
    return True

def test_uffd_simulation(layout_path):
    """测试 UFFD 模拟"""
    print("\n" + "=" * 60)
    print("测试 4: UFFD 按需分页模拟")
    print("=" * 60)
    
    trace = load_io_trace(layout_path)
    storage = STORAGE_PROFILES['emmc']
    
    print(f"\n在 {storage.name} 上测试不同预热策略:")
    
    preheat_levels = [0, 25, 50, 75, 100]
    for preheat in preheat_levels:
        result = simulate_uffd_demand_paging(trace, storage, preheat)
        print(f"  预热 {preheat:3d}%: "
              f"总时间 = {result['total_time_ms']:8.2f} ms, "
              f"预热时间 = {result['preheat_time_ms']:8.2f} ms, "
              f"访问时间 = {result['access_time_ms']:6.2f} ms")
    
    # 对比传统模式
    trad = simulate_traditional_access(trace, storage)
    print(f"\n  传统模式: 总时间 = {trad['total_time_ms']:.2f} ms")
    
    best_preheat = min(preheat_levels, 
                       key=lambda p: simulate_uffd_demand_paging(trace, storage, p)['total_time_ms'])
    best_result = simulate_uffd_demand_paging(trace, storage, best_preheat)
    speedup = trad['total_time_ms'] / best_result['total_time_ms']
    
    print(f"\n最佳策略: 预热 {best_preheat}%, 加速比 {speedup:.2f}x")
    
    return True

def generate_final_report(bigcache_path, layout_path, results):
    """生成最终报告"""
    print("\n" + "=" * 60)
    print("生成最终报告")
    print("=" * 60)
    
    report_path = os.path.join(script_dir, 'test_data', 'final_report.md')
    
    trace = load_io_trace(layout_path)
    unique_pages = set((io['file'], io['offset'] // 4096 * 4096) for io in trace)
    
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write("# BigCache + UFFD 冷启动优化方案测试报告\n\n")
        f.write(f"生成时间: {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        
        f.write("## 1. 方案概述\n\n")
        f.write("本方案通过以下技术手段优化 Android 应用冷启动：\n\n")
        f.write("1. **热点页打包**：将启动过程中访问的所有热点页打包到 BigCache.bin\n")
        f.write("2. **顺序预读**：启动时顺序读取 BigCache，利用存储的高顺序读带宽\n")
        f.write("3. **UFFD 拦截**：使用 userfaultfd 拦截缺页，从预读的 BigCache 提供数据\n\n")
        
        f.write("## 2. 数据分析\n\n")
        f.write(f"- IO 操作总数: {len(trace)}\n")
        f.write(f"- 唯一文件数: {len(set(io['file'] for io in trace))}\n")
        f.write(f"- 唯一页面数: {len(unique_pages)}\n")
        f.write(f"- BigCache 大小: {len(unique_pages) * 4096 / 1024 / 1024:.2f} MB\n\n")
        
        f.write("## 3. 性能测试结果\n\n")
        f.write("| 存储类型 | 传统模式 (ms) | BigCache (ms) | 加速比 |\n")
        f.write("|---------|--------------|--------------|--------|\n")
        
        if results:
            for storage_name in ['emmc', 'ufs', 'ssd', 'nvme']:
                if storage_name in results:
                    r = results[storage_name]
                    f.write(f"| {STORAGE_PROFILES[storage_name].name} | "
                           f"{r['traditional']['total_time_ms']:.2f} | "
                           f"{r['bigcache']['total_time_ms']:.2f} | "
                           f"{r['speedup']:.2f}x |\n")
        
        f.write("\n## 4. 关键发现\n\n")
        
        if results and 'emmc' in results:
            emmc_speedup = results['emmc']['speedup']
            f.write(f"- 在典型 eMMC 存储上，BigCache 方案可实现 **{emmc_speedup:.1f}x** 加速\n")
        if results and 'ufs' in results:
            ufs_speedup = results['ufs']['speedup']
            f.write(f"- 在 UFS 3.1 存储上，BigCache 方案可实现 **{ufs_speedup:.1f}x** 加速\n")
        
        f.write("\n## 5. 技术优势\n\n")
        f.write("1. **消除文件切换开销**：传统模式频繁在不同文件间切换导致大量 seek\n")
        f.write("2. **顺序读带宽利用**：BigCache 将随机访问转换为一次顺序读\n")
        f.write("3. **用户态实现**：userfaultfd 无需修改内核，部署灵活\n")
        f.write("4. **按需分页支持**：支持部分预热，平衡启动时间和内存占用\n\n")
        
        f.write("## 6. 使用建议\n\n")
        f.write("1. 在首次安装或更新后生成 BigCache\n")
        f.write("2. 根据可用内存调整预热策略\n")
        f.write("3. 定期更新 BigCache 以适应应用行为变化\n")
        f.write("4. 在低端设备上效果更明显（存储性能较差）\n\n")
        
        f.write("## 7. 文件列表\n\n")
        f.write(f"- BigCache 文件: `{bigcache_path}`\n")
        f.write(f"- 布局文件: `{layout_path}`\n")
        f.write(f"- 可视化结果: `test_data/simulation_results/`\n")
    
    print(f"报告已生成: {report_path}")
    return report_path

def main():
    print("=" * 60)
    print("BigCache + UFFD 冷启动优化方案测试")
    print("=" * 60)
    
    # 测试 1: BigCache 生成
    success, bigcache_path, layout_path = test_bigcache_generation()
    if not success:
        print("\n测试失败: BigCache 生成")
        return 1
    
    # 测试 2: 性能模拟
    success, results = test_performance_simulation(layout_path)
    if not success:
        print("\n测试部分失败: 性能模拟")
        results = None
    
    # 测试 3: IO Trace 分析
    test_trace_analysis(layout_path)
    
    # 测试 4: UFFD 模拟
    test_uffd_simulation(layout_path)
    
    # 生成最终报告
    generate_final_report(bigcache_path, layout_path, results)
    
    print("\n" + "=" * 60)
    print("所有测试完成!")
    print("=" * 60)
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
