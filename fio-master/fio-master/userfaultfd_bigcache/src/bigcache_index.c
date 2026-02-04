/*
 * BigCache 索引管理实现
 * 
 * 提供高效的页面查找功能
 * Key: (file_path, offset) -> Value: bigcache_offset
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include "bigcache.h"

/* 哈希函数 - FNV-1a */
static uint64_t hash_fnv1a(const char *str, uint64_t offset) {
    uint64_t hash = 14695981039346656037ULL;  /* FNV offset basis */
    
    /* 哈希文件路径 */
    while (*str) {
        hash ^= (uint8_t)*str++;
        hash *= 1099511628211ULL;  /* FNV prime */
    }
    
    /* 混入偏移值 */
    for (int i = 0; i < 8; i++) {
        hash ^= (offset >> (i * 8)) & 0xFF;
        hash *= 1099511628211ULL;
    }
    
    return hash;
}

/* CRC32 查找表 */
static uint32_t crc32_table[256];
static int crc32_table_init = 0;

static void init_crc32_table(void) {
    if (crc32_table_init) return;
    
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int j = 0; j < 8; j++) {
            c = (c >> 1) ^ ((c & 1) ? 0xEDB88320 : 0);
        }
        crc32_table[i] = c;
    }
    crc32_table_init = 1;
}

uint32_t bigcache_crc32(const void *data, size_t len) {
    init_crc32_table();
    
    const uint8_t *buf = (const uint8_t*)data;
    uint32_t crc = 0xFFFFFFFF;
    
    for (size_t i = 0; i < len; i++) {
        crc = crc32_table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    }
    
    return crc ^ 0xFFFFFFFF;
}

/* 创建页面查找表 */
static PageLookupTable* create_lookup_table(size_t num_entries) {
    PageLookupTable *table = calloc(1, sizeof(PageLookupTable));
    if (!table) return NULL;
    
    /* 哈希表大小为条目数的 1.5 倍，减少冲突 */
    table->num_buckets = num_entries * 3 / 2;
    if (table->num_buckets < 1024) table->num_buckets = 1024;
    
    table->buckets = calloc(table->num_buckets, sizeof(HashBucket*));
    if (!table->buckets) {
        free(table);
        return NULL;
    }
    
    table->num_entries = 0;
    return table;
}

/* 销毁查找表 */
static void destroy_lookup_table(PageLookupTable *table) {
    if (!table) return;
    
    for (size_t i = 0; i < table->num_buckets; i++) {
        HashBucket *bucket = table->buckets[i];
        while (bucket) {
            HashBucket *next = bucket->next;
            if (bucket->entry) {
                free(bucket->entry->file_path);
                free(bucket->entry);
            }
            free(bucket);
            bucket = next;
        }
    }
    
    free(table->buckets);
    free(table);
}

/* 向查找表插入条目 */
static int lookup_table_insert(PageLookupTable *table,
                               const char *file_path,
                               uint64_t source_offset,
                               uint64_t bigcache_offset,
                               uint32_t access_order) {
    uint64_t hash = hash_fnv1a(file_path, source_offset);
    size_t idx = hash % table->num_buckets;
    
    /* 创建条目 */
    RuntimePageEntry *entry = calloc(1, sizeof(RuntimePageEntry));
    if (!entry) return -ENOMEM;
    
    entry->file_path = strdup(file_path);
    if (!entry->file_path) {
        free(entry);
        return -ENOMEM;
    }
    
    entry->source_offset = source_offset;
    entry->bigcache_offset = bigcache_offset;
    entry->access_order = access_order;
    
    /* 创建桶 */
    HashBucket *bucket = calloc(1, sizeof(HashBucket));
    if (!bucket) {
        free(entry->file_path);
        free(entry);
        return -ENOMEM;
    }
    
    bucket->entry = entry;
    bucket->next = table->buckets[idx];
    table->buckets[idx] = bucket;
    table->num_entries++;
    
    return 0;
}

/* 从查找表查找 */
static RuntimePageEntry* lookup_table_find(PageLookupTable *table,
                                           const char *file_path,
                                           uint64_t source_offset) {
    uint64_t hash = hash_fnv1a(file_path, source_offset);
    size_t idx = hash % table->num_buckets;
    
    HashBucket *bucket = table->buckets[idx];
    while (bucket) {
        RuntimePageEntry *entry = bucket->entry;
        if (entry && 
            entry->source_offset == source_offset &&
            strcmp(entry->file_path, file_path) == 0) {
            return entry;
        }
        bucket = bucket->next;
    }
    
    return NULL;
}

/* 创建 BigCache 上下文 */
BigCacheContext* bigcache_create(void) {
    BigCacheContext *ctx = calloc(1, sizeof(BigCacheContext));
    if (!ctx) return NULL;
    
    ctx->fd = -1;
    ctx->mapped_data = MAP_FAILED;
    
    return ctx;
}

/* 销毁 BigCache 上下文 */
void bigcache_destroy(BigCacheContext *ctx) {
    if (!ctx) return;
    
    bigcache_unload(ctx);
    
    if (ctx->lookup_table) {
        destroy_lookup_table(ctx->lookup_table);
    }
    
    free(ctx);
}

/* 加载 BigCache 文件 */
int bigcache_load(BigCacheContext *ctx, const char *path) {
    if (!ctx || !path) return -EINVAL;
    
    /* 打开文件 */
    ctx->fd = open(path, O_RDONLY);
    if (ctx->fd < 0) {
        perror("bigcache_load: open");
        return -errno;
    }
    
    /* 获取文件大小 */
    struct stat st;
    if (fstat(ctx->fd, &st) < 0) {
        perror("bigcache_load: fstat");
        close(ctx->fd);
        ctx->fd = -1;
        return -errno;
    }
    
    ctx->mapped_size = st.st_size;
    
    /* mmap 整个文件 */
    ctx->mapped_data = mmap(NULL, ctx->mapped_size, 
                            PROT_READ, MAP_PRIVATE, 
                            ctx->fd, 0);
    if (ctx->mapped_data == MAP_FAILED) {
        perror("bigcache_load: mmap");
        close(ctx->fd);
        ctx->fd = -1;
        return -errno;
    }
    
    /* 读取并验证头部 */
    memcpy(&ctx->header, ctx->mapped_data, sizeof(BigCacheHeader));
    
    if (ctx->header.magic != BIGCACHE_MAGIC) {
        fprintf(stderr, "bigcache_load: invalid magic: 0x%08X\n", 
                ctx->header.magic);
        bigcache_unload(ctx);
        return -EINVAL;
    }
    
    if (ctx->header.version != BIGCACHE_VERSION) {
        fprintf(stderr, "bigcache_load: unsupported version: %u\n",
                ctx->header.version);
        bigcache_unload(ctx);
        return -EINVAL;
    }
    
    /* 设置指针 */
    ctx->page_index = (BigCachePageIndex*)
        ((uint8_t*)ctx->mapped_data + ctx->header.index_offset);
    ctx->file_table = (BigCacheFileEntry*)
        ((uint8_t*)ctx->mapped_data + ctx->header.file_table_offset);
    
    /* 构建运行时查找表 */
    ctx->lookup_table = create_lookup_table(ctx->header.num_pages);
    if (!ctx->lookup_table) {
        bigcache_unload(ctx);
        return -ENOMEM;
    }
    
    /* 填充查找表 */
    for (uint32_t i = 0; i < ctx->header.num_pages; i++) {
        BigCachePageIndex *pi = &ctx->page_index[i];
        BigCacheFileEntry *fe = &ctx->file_table[pi->file_id];
        
        uint64_t bigcache_offset = ctx->header.data_offset + (uint64_t)i * PAGE_SIZE;
        
        int ret = lookup_table_insert(ctx->lookup_table,
                                      fe->path,
                                      pi->source_offset,
                                      bigcache_offset,
                                      pi->access_order);
        if (ret < 0) {
            fprintf(stderr, "bigcache_load: failed to build lookup table\n");
            bigcache_unload(ctx);
            return ret;
        }
    }
    
    ctx->is_loaded = 1;
    
    printf("BigCache loaded: %u pages, %u files, %.2f MB\n",
           ctx->header.num_pages,
           ctx->header.num_files,
           (double)ctx->header.total_size / (1024 * 1024));
    
    return 0;
}

/* 卸载 BigCache */
int bigcache_unload(BigCacheContext *ctx) {
    if (!ctx) return -EINVAL;
    
    if (ctx->mapped_data != MAP_FAILED) {
        munmap(ctx->mapped_data, ctx->mapped_size);
        ctx->mapped_data = MAP_FAILED;
    }
    
    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
    
    ctx->is_loaded = 0;
    ctx->is_preheated = 0;
    
    return 0;
}

/* 查找页面数据 */
void* bigcache_lookup(BigCacheContext *ctx, 
                      const char *file_path, 
                      uint64_t offset) {
    if (!ctx || !ctx->is_loaded || !file_path) return NULL;
    
    /* 页对齐 */
    uint64_t page_offset = offset & ~(PAGE_SIZE - 1);
    
    RuntimePageEntry *entry = lookup_table_find(ctx->lookup_table,
                                                file_path,
                                                page_offset);
    if (!entry) {
        ctx->miss_count++;
        return NULL;
    }
    
    ctx->hit_count++;
    ctx->total_bytes_served += PAGE_SIZE;
    
    return (uint8_t*)ctx->mapped_data + entry->bigcache_offset;
}

/* 查找偏移（不返回数据）*/
int bigcache_lookup_offset(BigCacheContext *ctx,
                           const char *file_path,
                           uint64_t offset,
                           uint64_t *out_bigcache_offset) {
    if (!ctx || !ctx->is_loaded || !file_path || !out_bigcache_offset) {
        return -EINVAL;
    }
    
    uint64_t page_offset = offset & ~(PAGE_SIZE - 1);
    
    RuntimePageEntry *entry = lookup_table_find(ctx->lookup_table,
                                                file_path,
                                                page_offset);
    if (!entry) {
        ctx->miss_count++;
        return -ENOENT;
    }
    
    *out_bigcache_offset = entry->bigcache_offset;
    ctx->hit_count++;
    
    return 0;
}

/* 预热 BigCache */
int bigcache_preheat(BigCacheContext *ctx) {
    if (!ctx || !ctx->is_loaded) return -EINVAL;
    
    printf("Preheating BigCache (%.2f MB)...\n",
           (double)ctx->mapped_size / (1024 * 1024));
    
    /* 使用 madvise 通知内核我们将顺序访问 */
    if (madvise(ctx->mapped_data, ctx->mapped_size, MADV_SEQUENTIAL) < 0) {
        perror("bigcache_preheat: madvise SEQUENTIAL");
    }
    
    /* 触发实际的读取（遍历每个页面）*/
    volatile uint8_t sum = 0;
    uint8_t *data = (uint8_t*)ctx->mapped_data;
    
    for (size_t i = 0; i < ctx->mapped_size; i += PAGE_SIZE) {
        sum += data[i];  /* 触发缺页，加载到内存 */
    }
    
    /* 设置随机访问提示（预热后访问模式是随机的）*/
    if (madvise(ctx->mapped_data, ctx->mapped_size, MADV_RANDOM) < 0) {
        perror("bigcache_preheat: madvise RANDOM");
    }
    
    /* 锁定在内存中（如果有权限）*/
    if (mlock(ctx->mapped_data, ctx->mapped_size) < 0) {
        /* mlock 失败不是致命错误 */
        perror("bigcache_preheat: mlock (optional)");
    }
    
    ctx->is_preheated = 1;
    printf("BigCache preheated successfully\n");
    
    (void)sum;  /* 防止编译器优化掉 */
    return 0;
}

/* 预热指定范围的页面 */
int bigcache_preheat_range(BigCacheContext *ctx, 
                           uint32_t start_order, 
                           uint32_t end_order) {
    if (!ctx || !ctx->is_loaded) return -EINVAL;
    
    if (start_order >= ctx->header.num_pages || 
        end_order > ctx->header.num_pages ||
        start_order >= end_order) {
        return -EINVAL;
    }
    
    size_t start_offset = ctx->header.data_offset + (size_t)start_order * PAGE_SIZE;
    size_t end_offset = ctx->header.data_offset + (size_t)end_order * PAGE_SIZE;
    size_t length = end_offset - start_offset;
    
    volatile uint8_t sum = 0;
    uint8_t *data = (uint8_t*)ctx->mapped_data + start_offset;
    
    for (size_t i = 0; i < length; i += PAGE_SIZE) {
        sum += data[i];
    }
    
    (void)sum;
    return 0;
}

/* 验证 BigCache 完整性 */
int bigcache_verify(BigCacheContext *ctx) {
    if (!ctx || !ctx->is_loaded) return -EINVAL;
    
    printf("Verifying BigCache...\n");
    
    /* 验证头部 */
    if (ctx->header.magic != BIGCACHE_MAGIC) {
        fprintf(stderr, "Verification failed: invalid magic\n");
        return -1;
    }
    
    /* 验证大小 */
    if (ctx->header.total_size != ctx->mapped_size) {
        fprintf(stderr, "Verification failed: size mismatch "
                "(header: %lu, actual: %lu)\n",
                (unsigned long)ctx->header.total_size,
                (unsigned long)ctx->mapped_size);
        return -1;
    }
    
    /* TODO: 验证 CRC32 */
    
    printf("BigCache verification passed\n");
    return 0;
}

/* 打印统计信息 */
void bigcache_print_stats(BigCacheContext *ctx) {
    if (!ctx) return;
    
    printf("\n=== BigCache Statistics ===\n");
    printf("Loaded: %s\n", ctx->is_loaded ? "Yes" : "No");
    printf("Preheated: %s\n", ctx->is_preheated ? "Yes" : "No");
    
    if (ctx->is_loaded) {
        printf("Pages: %u\n", ctx->header.num_pages);
        printf("Files: %u\n", ctx->header.num_files);
        printf("Size: %.2f MB\n", (double)ctx->header.total_size / (1024 * 1024));
    }
    
    printf("Cache Hits: %lu\n", (unsigned long)ctx->hit_count);
    printf("Cache Misses: %lu\n", (unsigned long)ctx->miss_count);
    
    uint64_t total = ctx->hit_count + ctx->miss_count;
    if (total > 0) {
        printf("Hit Rate: %.2f%%\n", 
               (double)ctx->hit_count * 100 / total);
    }
    
    printf("Total Bytes Served: %.2f MB\n", 
           (double)ctx->total_bytes_served / (1024 * 1024));
    printf("===========================\n\n");
}

/* 重置统计信息 */
void bigcache_reset_stats(BigCacheContext *ctx) {
    if (!ctx) return;
    
    ctx->hit_count = 0;
    ctx->miss_count = 0;
    ctx->total_bytes_served = 0;
}
