#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Plot Steady State Performance with Comparison
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path

# Set Chinese font support
plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei', 'Arial Unicode MS']
plt.rcParams['axes.unicode_minus'] = False

# Read steady state test results
csv_file = 'fio_steady_state_results.csv'
if not Path(csv_file).exists():
    print(f"Error: Cannot find {csv_file}")
    exit(1)

df = pd.read_csv(csv_file)

# Parse block size for sorting
def parse_block_size(bs):
    bs = bs.lower()
    if 'k' in bs:
        return int(bs.replace('k', ''))
    elif 'm' in bs:
        return int(bs.replace('m', '')) * 1024
    return 0

df['BlockSize_KB'] = df['BlockSize'].apply(parse_block_size)
df = df.sort_values('BlockSize_KB')

print("=" * 70)
print("Steady State Performance Results")
print("=" * 70)
print(df[['BlockSize', 'Read_BW_MBps', 'Read_IOPS', 'Write_BW_MBps_fsync', 'Write_IOPS_fsync']].to_string(index=False))
print("=" * 70)

# Create figure with dual y-axis
fig, ax1 = plt.subplots(figsize=(14, 8))

x = np.arange(len(df))
width = 0.35
block_sizes = df['BlockSize'].values

# Plot IOPS as bars on left y-axis
ax1.set_xlabel('Block Size', fontsize=13, fontweight='bold')
ax1.set_ylabel('IOPS', fontsize=13, fontweight='bold', color='#2E86AB')
ax1.set_xticks(x)
ax1.set_xticklabels(block_sizes, rotation=45, ha='right')

bars1 = ax1.bar(x - width/2, df['Read_IOPS'], width, 
                label='Read IOPS', color='#2E86AB', alpha=0.7)
bars2 = ax1.bar(x + width/2, df['Write_IOPS_fsync'], width,
                label='Write IOPS (fsync)', color='#A23B72', alpha=0.7)

ax1.tick_params(axis='y', labelcolor='#2E86AB')
ax1.grid(axis='y', alpha=0.3, linestyle='--', linewidth=0.5)

# Add value labels on bars
for bars in [bars1, bars2]:
    for bar in bars:
        height = bar.get_height()
        if height > 0:
            ax1.text(bar.get_x() + bar.get_width()/2., height,
                    f'{int(height)}',
                    ha='center', va='bottom', fontsize=8, rotation=0)

# Create second y-axis for throughput
ax2 = ax1.twinx()
ax2.set_ylabel('Throughput (MB/s)', fontsize=13, fontweight='bold', color='#06A77D')

# Plot throughput as lines on right y-axis
line1 = ax2.plot(x, df['Read_BW_MBps'], 
                 marker='o', linewidth=2.5, markersize=8,
                 label='Read Throughput', color='#06A77D', linestyle='-')
line2 = ax2.plot(x, df['Write_BW_MBps_fsync'],
                 marker='s', linewidth=2.5, markersize=8,
                 label='Write Throughput (fsync)', color='#F18F01', linestyle='-')

ax2.tick_params(axis='y', labelcolor='#06A77D')

# Add value labels on line points
for i, (read_bw, write_bw) in enumerate(zip(df['Read_BW_MBps'], df['Write_BW_MBps_fsync'])):
    ax2.text(i, read_bw, f'{read_bw:.1f}', 
            ha='center', va='bottom', fontsize=8, color='#06A77D', fontweight='bold')
    ax2.text(i, write_bw, f'{write_bw:.1f}', 
            ha='center', va='top', fontsize=8, color='#F18F01', fontweight='bold')

# Combine legends
lines1, labels1 = ax1.get_legend_handles_labels()
lines2, labels2 = ax2.get_legend_handles_labels()
ax1.legend(lines1 + lines2, labels1 + labels2, 
          loc='upper left', fontsize=11, framealpha=0.9)

# Title
plt.title('Steady State Storage Performance - IOPS & Throughput (with fsync=1)',
         fontsize=15, fontweight='bold', pad=20)

# Layout adjustment
fig.tight_layout()

# Save figure
output_file = 'steady_state_performance.png'
plt.savefig(output_file, dpi=300, bbox_inches='tight')
print(f"\nChart saved to: {output_file}")

# Show summary
print("\n" + "=" * 70)
print("Performance Summary")
print("=" * 70)
print("\nBest Performance:")
print(f"  Read IOPS:  {df['Read_IOPS'].max():.0f} IOPS @ {df.loc[df['Read_IOPS'].idxmax(), 'BlockSize']}")
print(f"  Write IOPS: {df['Write_IOPS_fsync'].max():.0f} IOPS @ {df.loc[df['Write_IOPS_fsync'].idxmax(), 'BlockSize']} (fsync)")
print(f"  Read BW:    {df['Read_BW_MBps'].max():.2f} MB/s @ {df.loc[df['Read_BW_MBps'].idxmax(), 'BlockSize']}")
print(f"  Write BW:   {df['Write_BW_MBps_fsync'].max():.2f} MB/s @ {df.loc[df['Write_BW_MBps_fsync'].idxmax(), 'BlockSize']} (fsync)")
print("=" * 70)
