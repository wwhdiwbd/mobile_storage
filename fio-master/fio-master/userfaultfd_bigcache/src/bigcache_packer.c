/*
 * BigCache 打包工具
 * 
 * 从 IO trace 数据（CSV 格式）生成 BigCache.bin 文件
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include "bigcache.h"

#define INITIAL_CAPACITY 10000

/* 创建打包器 */
BigCachePacker* packer_create(void) {
    BigCachePacker *packer = calloc(1, sizeof(BigCachePacker));
    if (!packer) return NULL;
    
    packer->capacity = INITIAL_CAPACITY;
    packer->entries = calloc(packer->capacity, sizeof(PackerPageEntry));
    if (!packer->entries) {
        free(packer);
        return NULL;
    }
    
    packer->file_paths = calloc(MAX_FILES, sizeof(char*));
    if (!packer->file_paths) {
        free(packer->entries);
        free(packer);
        return NULL;
    }
    
    return packer;
}

/* 销毁打包器 */
void packer_destroy(BigCachePacker *packer) {
    if (!packer) return;
    
    free(packer->entries);
    
    for (size_t i = 0; i < packer->num_files; i++) {
        free(packer->file_paths[i]);
    }
    free(packer->file_paths);
    
    free(packer->output_buffer);
    free(packer);
}

/* 查找或添加文件路径 */
static int find_or_add_file(BigCachePacker *packer, const char *path) {
    /* 查找现有的 */
    for (size_t i = 0; i < packer->num_files; i++) {
        if (strcmp(packer->file_paths[i], path) == 0) {
            return (int)i;
        }
    }
    
    /* 添加新的 */
    if (packer->num_files >= MAX_FILES) {
        return -1;
    }
    
    packer->file_paths[packer->num_files] = strdup(path);
    if (!packer->file_paths[packer->num_files]) {
        return -1;
    }
    
    return (int)packer->num_files++;
}

/* 检查页面是否已存在 */
static int page_exists(BigCachePacker *packer, const char *path, uint64_t offset) {
    uint64_t page_offset = offset & ~(PAGE_SIZE - 1);
    
    for (size_t i = 0; i < packer->num_entries; i++) {
        if (packer->entries[i].offset == page_offset &&
            strcmp(packer->entries[i].file_path, path) == 0) {
            return 1;
        }
    }
    
    return 0;
}

/* 添加页面 */
int packer_add_page(BigCachePacker *packer, 
                    const char *file_path,
                    uint64_t offset,
                    uint32_t access_order) {
    if (!packer || !file_path) return -EINVAL;
    
    /* 页对齐 */
    uint64_t page_offset = offset & ~(PAGE_SIZE - 1);
    
    /* 检查重复 */
    if (page_exists(packer, file_path, page_offset)) {
        return 0;  /* 已存在，跳过 */
    }
    
    /* 扩容 */
    if (packer->num_entries >= packer->capacity) {
        size_t new_capacity = packer->capacity * 2;
        PackerPageEntry *new_entries = realloc(packer->entries,
                                               new_capacity * sizeof(PackerPageEntry));
        if (!new_entries) return -ENOMEM;
        
        packer->entries = new_entries;
        packer->capacity = new_capacity;
    }
    
    /* 添加条目 */
    PackerPageEntry *entry = &packer->entries[packer->num_entries];
    strncpy(entry->file_path, file_path, MAX_PATH_LEN - 1);
    entry->file_path[MAX_PATH_LEN - 1] = '\0';
    entry->offset = page_offset;
    entry->size = PAGE_SIZE;
    entry->access_order = access_order;
    
    packer->num_entries++;
    
    /* 确保文件在列表中 */
    if (find_or_add_file(packer, file_path) < 0) {
        return -ENOMEM;
    }
    
    return 0;
}

/* 从 CSV 加载 */
int packer_load_from_csv(BigCachePacker *packer, const char *csv_path) {
    if (!packer || !csv_path) return -EINVAL;
    
    FILE *fp = fopen(csv_path, "r");
    if (!fp) {
        perror("packer_load_from_csv: fopen");
        return -errno;
    }
    
    char line[2048];
    int line_num = 0;
    int loaded = 0;
    
    /* 跳过 header */
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return -EIO;
    }
    
    /* 读取数据行 */
    /* 格式: bigcache_offset,source_file,source_offset,size,first_access_order */
    while (fgets(line, sizeof(line), fp)) {
        line_num++;
        
        /* 移除换行符 */
        size_t len = strlen(line);
        if (len > 0 && line[len-1] == '\n') line[len-1] = '\0';
        if (len > 1 && line[len-2] == '\r') line[len-2] = '\0';
        
        /* 解析 CSV */
        char *bigcache_offset_str = strtok(line, ",");
        char *source_file = strtok(NULL, ",");
        char *source_offset_str = strtok(NULL, ",");
        char *size_str = strtok(NULL, ",");
        char *access_order_str = strtok(NULL, ",");
        
        if (!bigcache_offset_str || !source_file || 
            !source_offset_str || !access_order_str) {
            fprintf(stderr, "Warning: skipping malformed line %d\n", line_num);
            continue;
        }
        
        uint64_t source_offset = strtoull(source_offset_str, NULL, 10);
        uint32_t access_order = strtoul(access_order_str, NULL, 10);
        
        int ret = packer_add_page(packer, source_file, source_offset, access_order);
        if (ret < 0) {
            fprintf(stderr, "Error adding page at line %d: %d\n", line_num, ret);
        } else {
            loaded++;
        }
    }
    
    fclose(fp);
    
    printf("Loaded %d pages from %s\n", loaded, csv_path);
    return loaded;
}

/* 构建 BigCache 文件 */
int packer_build(BigCachePacker *packer, const char *output_path) {
    if (!packer || !output_path || packer->num_entries == 0) {
        return -EINVAL;
    }
    
    printf("Building BigCache with %zu pages from %zu files...\n",
           packer->num_entries, packer->num_files);
    
    /* 计算各部分大小 */
    size_t header_size = sizeof(BigCacheHeader);
    size_t index_size = packer->num_entries * sizeof(BigCachePageIndex);
    size_t file_table_size = packer->num_files * sizeof(BigCacheFileEntry);
    size_t data_size = packer->num_entries * PAGE_SIZE;
    
    /* 对齐 */
    size_t index_offset = header_size;
    size_t file_table_offset = index_offset + index_size;
    size_t data_offset = (file_table_offset + file_table_size + PAGE_SIZE - 1) 
                         & ~(PAGE_SIZE - 1);  /* 页对齐 */
    size_t total_size = data_offset + data_size;
    
    printf("  Header: %zu bytes\n", header_size);
    printf("  Index: %zu bytes (%zu entries)\n", index_size, packer->num_entries);
    printf("  File table: %zu bytes (%zu files)\n", file_table_size, packer->num_files);
    printf("  Data: %zu bytes (%.2f MB)\n", data_size, (double)data_size / (1024*1024));
    printf("  Total: %zu bytes (%.2f MB)\n", total_size, (double)total_size / (1024*1024));
    
    /* 创建输出文件 */
    int fd = open(output_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("packer_build: open output");
        return -errno;
    }
    
    /* 扩展文件大小 */
    if (ftruncate(fd, total_size) < 0) {
        perror("packer_build: ftruncate");
        close(fd);
        return -errno;
    }
    
    /* mmap 输出文件 */
    void *output = mmap(NULL, total_size, PROT_READ | PROT_WRITE, 
                        MAP_SHARED, fd, 0);
    if (output == MAP_FAILED) {
        perror("packer_build: mmap output");
        close(fd);
        return -errno;
    }
    
    /* 填充头部 */
    BigCacheHeader *header = (BigCacheHeader*)output;
    memset(header, 0, sizeof(BigCacheHeader));
    header->magic = BIGCACHE_MAGIC;
    header->version = BIGCACHE_VERSION;
    header->num_pages = packer->num_entries;
    header->num_files = packer->num_files;
    header->index_offset = index_offset;
    header->file_table_offset = file_table_offset;
    header->data_offset = data_offset;
    header->total_size = total_size;
    
    /* 填充文件表 */
    BigCacheFileEntry *file_table = (BigCacheFileEntry*)
        ((uint8_t*)output + file_table_offset);
    
    for (size_t i = 0; i < packer->num_files; i++) {
        BigCacheFileEntry *fe = &file_table[i];
        fe->file_id = i;
        strncpy(fe->path, packer->file_paths[i], MAX_PATH_LEN - 1);
        fe->path_len = strlen(fe->path);
        fe->total_pages = 0;
        fe->original_size = 0;
        
        /* 统计该文件的页数 */
        for (size_t j = 0; j < packer->num_entries; j++) {
            if (strcmp(packer->entries[j].file_path, packer->file_paths[i]) == 0) {
                fe->total_pages++;
            }
        }
    }
    
    /* 填充索引和数据 */
    BigCachePageIndex *page_index = (BigCachePageIndex*)
        ((uint8_t*)output + index_offset);
    uint8_t *data_area = (uint8_t*)output + data_offset;
    
    int successful_pages = 0;
    int failed_pages = 0;
    
    for (size_t i = 0; i < packer->num_entries; i++) {
        PackerPageEntry *pe = &packer->entries[i];
        BigCachePageIndex *pi = &page_index[i];
        
        /* 填充索引 */
        pi->file_id = find_or_add_file(packer, pe->file_path);
        pi->source_offset = pe->offset;
        pi->access_order = pe->access_order;
        pi->flags = 0;
        
        /* 判断页面类型 */
        if (strstr(pe->file_path, ".so") || 
            strstr(pe->file_path, ".odex") ||
            strstr(pe->file_path, ".oat")) {
            pi->flags |= PAGE_FLAG_EXECUTABLE;
        }
        
        /* 读取源文件数据 */
        uint8_t *page_data = data_area + i * PAGE_SIZE;
        
        /* 注意：这里需要实际的文件系统访问 */
        /* 在模拟环境中，我们填充测试数据 */
        int src_fd = open(pe->file_path, O_RDONLY);
        if (src_fd >= 0) {
            /* 可以访问源文件 */
            if (pread(src_fd, page_data, PAGE_SIZE, pe->offset) == PAGE_SIZE) {
                successful_pages++;
            } else {
                /* 读取失败，填充零 */
                memset(page_data, 0, PAGE_SIZE);
                failed_pages++;
            }
            close(src_fd);
        } else {
            /* 无法访问源文件，填充模拟数据 */
            /* 用于测试目的 */
            memset(page_data, 0, PAGE_SIZE);
            
            /* 写入标识信息（用于验证）*/
            snprintf((char*)page_data, 256,
                     "SIMULATED PAGE\n"
                     "File: %s\n"
                     "Offset: %lu\n"
                     "Order: %u\n",
                     pe->file_path,
                     (unsigned long)pe->offset,
                     pe->access_order);
            
            failed_pages++;
        }
        
        if ((i + 1) % 10000 == 0) {
            printf("  Progress: %zu / %zu pages\n", i + 1, packer->num_entries);
        }
    }
    
    /* 计算校验和 */
    header->checksum = bigcache_crc32((uint8_t*)output + sizeof(uint32_t) * 2,
                                      total_size - sizeof(uint32_t) * 2);
    
    /* 同步并取消映射 */
    if (msync(output, total_size, MS_SYNC) < 0) {
        perror("packer_build: msync");
    }
    
    munmap(output, total_size);
    close(fd);
    
    printf("\nBigCache built successfully:\n");
    printf("  Output: %s\n", output_path);
    printf("  Size: %.2f MB\n", (double)total_size / (1024*1024));
    printf("  Successful pages: %d\n", successful_pages);
    printf("  Simulated pages: %d\n", failed_pages);
    
    return 0;
}

/* 命令行工具入口 */
#ifdef BUILD_PACKER_TOOL
int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <layout.csv> <output.bin>\n", argv[0]);
        fprintf(stderr, "\nBuilds a BigCache binary from a layout CSV file.\n");
        fprintf(stderr, "\nCSV format:\n");
        fprintf(stderr, "  bigcache_offset,source_file,source_offset,size,first_access_order\n");
        return 1;
    }
    
    const char *csv_path = argv[1];
    const char *output_path = argv[2];
    
    BigCachePacker *packer = packer_create();
    if (!packer) {
        fprintf(stderr, "Failed to create packer\n");
        return 1;
    }
    
    int ret = packer_load_from_csv(packer, csv_path);
    if (ret < 0) {
        fprintf(stderr, "Failed to load CSV: %d\n", ret);
        packer_destroy(packer);
        return 1;
    }
    
    ret = packer_build(packer, output_path);
    if (ret < 0) {
        fprintf(stderr, "Failed to build BigCache: %d\n", ret);
        packer_destroy(packer);
        return 1;
    }
    
    packer_destroy(packer);
    return 0;
}
#endif
