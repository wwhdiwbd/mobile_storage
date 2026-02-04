#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
转换 bigcache_layout.csv 中的路径为实际 Android 路径
"""

import csv
import sys
import re

def convert_path(path, app_base):
    """转换路径"""
    # /app/~~xxx/tv.danmaku.bili-yyy/base.apk -> /data/app/~~real/tv.danmaku.bili-real/base.apk
    if path.startswith('/app/~~'):
        # 提取相对路径部分 (base.apk, lib/arm64/xxx.so 等)
        match = re.match(r'/app/~~[^/]+/tv\.danmaku\.bili-[^/]+/(.+)', path)
        if match:
            rel_path = match.group(1)
            return f"{app_base}/{rel_path}"
    
    # /data/ 开头的路径保持不变
    if path.startswith('/data/'):
        return path
    
    # 其他路径加 /data 前缀
    if not path.startswith('/'):
        return f"/data/{path}"
    
    return f"/data{path}"

def main():
    if len(sys.argv) < 4:
        print("Usage: python convert_layout.py <input.csv> <output.csv> <app_base_path>")
        return 1
    
    input_csv = sys.argv[1]
    output_csv = sys.argv[2]
    app_base = sys.argv[3].rstrip('/')
    
    rows = []
    with open(input_csv, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        for row in reader:
            row['source_file'] = convert_path(row['source_file'], app_base)
            rows.append(row)
    
    with open(output_csv, 'w', encoding='utf-8', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    
    print(f"Converted {len(rows)} entries")
    print(f"Output: {output_csv}")
    
    # 显示前几个路径
    print("\nSample paths:")
    for row in rows[:5]:
        print(f"  {row['source_file']}")
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
