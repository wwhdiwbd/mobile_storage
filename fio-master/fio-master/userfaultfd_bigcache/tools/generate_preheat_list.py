#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成预热用的文件列表
从 bigcache_layout.csv 提取唯一文件，转换为实际 Android 路径
"""

import csv
import sys
import os

def main():
    if len(sys.argv) < 3:
        print("Usage: python generate_preheat_list.py <layout.csv> <app_base_path>")
        print("Example: python generate_preheat_list.py layout.csv /data/app/~~xxx==/tv.danmaku.bili-yyy==/")
        return 1
    
    layout_csv = sys.argv[1]
    app_base = sys.argv[2].rstrip('/')
    
    # 提取唯一文件
    files = set()
    with open(layout_csv, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            path = row['source_file']
            files.add(path)
    
    print(f"Found {len(files)} unique files")
    
    # 生成转换后的文件列表
    output_lines = []
    
    for path in sorted(files):
        # 转换路径
        if path.startswith('/app/~~'):
            # 替换 /app/~~xxx/tv.danmaku.bili-yyy/ 为实际路径
            parts = path.split('/')
            # /app/~~xxx/tv.danmaku.bili-yyy/base.apk -> 取最后部分
            if len(parts) >= 4:
                rel_path = '/'.join(parts[4:])  # base.apk, lib/...
                new_path = f"{app_base}/{rel_path}"
            else:
                new_path = path
        elif path.startswith('/data/'):
            new_path = path
        else:
            # 其他路径保持不变或加 /data 前缀
            new_path = f"/data{path}" if not path.startswith('/') else path
        
        output_lines.append(new_path)
    
    # 输出到 stdout
    for line in output_lines:
        print(line)
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
