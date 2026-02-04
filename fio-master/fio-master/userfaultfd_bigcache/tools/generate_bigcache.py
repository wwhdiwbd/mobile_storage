#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BigCache 生成工具

从 IO trace CSV 生成 BigCache 二进制文件和索引。
适用于 Windows/Linux 测试环境。
"""

import os
import sys
import csv
import struct
import mmap
from collections import defaultdict
from dataclasses import dataclass
from typing import List, Dict, Optional
import hashlib

# 常量
PAGE_SIZE = 4096
BIGCACHE_MAGIC = 0x42494743  # "BIGC"
BIGCACHE_VERSION = 1
MAX_PATH_LEN = 512

@dataclass
class PageEntry:
    """页面条目"""
    file_path: str
    source_offset: int
    access_order: int
    bigcache_offset: int = 0

@dataclass
class FileEntry:
    """文件条目"""
    file_id: int
    path: str
    total_pages: int = 0
    original_size: int = 0

class BigCacheGenerator:
    """BigCache 生成器"""
    
    def __init__(self):
        self.pages: List[PageEntry] = []
        self.files: Dict[str, FileEntry] = {}
        self.file_id_counter = 0
        self.seen_pages: set = set()  # 用于快速去重
        
    def add_page(self, file_path: str, offset: int, access_order: int):
        """添加一个热点页"""
        # 页对齐
        page_offset = (offset // PAGE_SIZE) * PAGE_SIZE
        
        # 检查重复（O(1) 查找）
        key = (file_path, page_offset)
        if key in self.seen_pages:
            return  # 已存在
        self.seen_pages.add(key)
        
        # 添加文件（如果是新文件）
        if file_path not in self.files:
            self.files[file_path] = FileEntry(
                file_id=self.file_id_counter,
                path=file_path
            )
            self.file_id_counter += 1
        
        # 添加页面
        self.pages.append(PageEntry(
            file_path=file_path,
            source_offset=page_offset,
            access_order=access_order
        ))
        
        self.files[file_path].total_pages += 1
    
    def load_from_csv(self, csv_path: str) -> int:
        """从 CSV 加载页面布局"""
        loaded = 0
        
        with open(csv_path, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    file_path = row['source_file']
                    offset = int(row['source_offset'])
                    order = int(row['first_access_order'])
                    
                    self.add_page(file_path, offset, order)
                    loaded += 1
                except (KeyError, ValueError) as e:
                    print(f"Warning: skipping row: {e}")
                    continue
        
        print(f"Loaded {loaded} pages from {csv_path}")
        return loaded
    
    def calculate_layout(self):
        """计算 BigCache 布局"""
        # 头部大小（固定）
        header_size = 64  # BigCacheHeader
        
        # 索引表大小
        index_entry_size = 24  # BigCachePageIndex
        index_size = len(self.pages) * index_entry_size
        
        # 文件表大小
        file_entry_size = MAX_PATH_LEN + 24  # BigCacheFileEntry
        file_table_size = len(self.files) * file_entry_size
        
        # 数据偏移（页对齐）
        data_offset = ((header_size + index_size + file_table_size + PAGE_SIZE - 1) 
                       // PAGE_SIZE * PAGE_SIZE)
        
        # 总大小
        total_size = data_offset + len(self.pages) * PAGE_SIZE
        
        return {
            'header_size': header_size,
            'index_offset': header_size,
            'index_size': index_size,
            'file_table_offset': header_size + index_size,
            'file_table_size': file_table_size,
            'data_offset': data_offset,
            'data_size': len(self.pages) * PAGE_SIZE,
            'total_size': total_size
        }
    
    def generate(self, output_path: str, source_root: Optional[str] = None):
        """生成 BigCache 文件"""
        layout = self.calculate_layout()
        
        print(f"\nGenerating BigCache:")
        print(f"  Pages: {len(self.pages)}")
        print(f"  Files: {len(self.files)}")
        print(f"  Total size: {layout['total_size'] / 1024 / 1024:.2f} MB")
        
        # 创建输出文件
        with open(output_path, 'wb') as f:
            # 预分配空间
            f.seek(layout['total_size'] - 1)
            f.write(b'\x00')
            f.seek(0)
            
            # 写入头部
            header = struct.pack(
                '<IIIIQQQQI32s',
                BIGCACHE_MAGIC,           # magic
                BIGCACHE_VERSION,         # version
                len(self.pages),          # num_pages
                len(self.files),          # num_files
                layout['data_offset'],    # data_offset
                layout['index_offset'],   # index_offset
                layout['file_table_offset'],  # file_table_offset
                layout['total_size'],     # total_size
                0,                        # checksum (placeholder)
                b'\x00' * 32              # reserved
            )
            f.write(header)
            
            # 写入索引表
            f.seek(layout['index_offset'])
            for i, page in enumerate(self.pages):
                file_entry = self.files[page.file_path]
                page.bigcache_offset = layout['data_offset'] + i * PAGE_SIZE
                
                index_entry = struct.pack(
                    '<IQIHH',
                    file_entry.file_id,    # file_id
                    page.source_offset,    # source_offset
                    page.access_order,     # access_order
                    0,                     # flags
                    0                      # reserved
                )
                f.write(index_entry)
            
            # 写入文件表
            f.seek(layout['file_table_offset'])
            for path, entry in self.files.items():
                path_bytes = path.encode('utf-8')[:MAX_PATH_LEN-1]
                path_bytes = path_bytes.ljust(MAX_PATH_LEN, b'\x00')
                
                file_entry = struct.pack(
                    f'<II{MAX_PATH_LEN}sIQ',
                    entry.file_id,
                    len(path),
                    path_bytes,
                    entry.total_pages,
                    entry.original_size
                )
                f.write(file_entry)
            
            # 写入数据
            f.seek(layout['data_offset'])
            for i, page in enumerate(self.pages):
                # 尝试读取源文件
                page_data = self._read_source_page(page, source_root)
                f.write(page_data)
                
                if (i + 1) % 10000 == 0:
                    print(f"  Progress: {i + 1}/{len(self.pages)} pages")
        
        print(f"\nBigCache generated: {output_path}")
        return output_path
    
    def _read_source_page(self, page: PageEntry, source_root: Optional[str]) -> bytes:
        """读取源文件的页面数据"""
        if source_root:
            # 尝试从源目录读取
            full_path = os.path.join(source_root, page.file_path.lstrip('/'))
            if os.path.exists(full_path):
                try:
                    with open(full_path, 'rb') as f:
                        f.seek(page.source_offset)
                        data = f.read(PAGE_SIZE)
                        if len(data) < PAGE_SIZE:
                            data += b'\x00' * (PAGE_SIZE - len(data))
                        return data
                except:
                    pass
        
        # 生成模拟数据
        simulated = (
            f"SIMULATED PAGE\n"
            f"File: {page.file_path}\n"
            f"Offset: {page.source_offset}\n"
            f"Order: {page.access_order}\n"
        ).encode('utf-8')
        
        return simulated.ljust(PAGE_SIZE, b'\x00')
    
    def generate_index_file(self, output_path: str):
        """生成索引文件（用于快速查找）"""
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write("file_path,source_offset,bigcache_offset,access_order\n")
            for page in self.pages:
                f.write(f"{page.file_path},{page.source_offset},"
                       f"{page.bigcache_offset},{page.access_order}\n")
        
        print(f"Index file generated: {output_path}")

def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Generate BigCache from IO trace layout'
    )
    parser.add_argument('input', help='Input CSV layout file')
    parser.add_argument('-o', '--output', default='bigcache.bin',
                       help='Output BigCache file')
    parser.add_argument('-s', '--source-root', 
                       help='Root directory for source files')
    parser.add_argument('-i', '--index', 
                       help='Generate index file')
    parser.add_argument('--simulate', action='store_true',
                       help='Generate simulated page data (no real files needed)')
    
    args = parser.parse_args()
    
    generator = BigCacheGenerator()
    generator.load_from_csv(args.input)
    # 如果使用 --simulate，不传 source_root，让它生成模拟数据
    source_root = None if args.simulate else args.source_root
    generator.generate(args.output, source_root)
    
    if args.index:
        generator.generate_index_file(args.index)

if __name__ == '__main__':
    main()
