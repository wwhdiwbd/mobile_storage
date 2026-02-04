/*
 * BigCache 核心数据结构定义
 * 
 * BigCache.bin 文件格式：
 * ┌──────────────────────────────────────────┐
 * │ BigCacheHeader (固定大小)                 │
 * ├──────────────────────────────────────────┤
 * │ BigCachePageIndex[num_pages] (索引表)     │
 * ├──────────────────────────────────────────┤
 * │ Page Data (4KB 对齐的页面数据)            │
 * │ [Page 0][Page 1][Page 2]...[Page N-1]    │
 * └──────────────────────────────────────────┘
 */

#ifndef BIGCACHE_H
#define BIGCACHE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

/* 页面大小 */
#define PAGE_SIZE           4096
#define PAGE_SHIFT          12

/* BigCache 魔数 */
#define BIGCACHE_MAGIC      0x42494743  /* "BIGC" */
#define BIGCACHE_VERSION    1

/* 最大路径长度 */
#define MAX_PATH_LEN        512

/* 最大支持的页面数 */
#define MAX_PAGES           (1024 * 1024)  /* 1M pages = 4GB */

/* 最大支持的文件数 */
#define MAX_FILES           4096

/*
 * BigCache 文件头
 */
typedef struct __attribute__((packed)) {
    uint32_t magic;              /* 魔数: BIGCACHE_MAGIC */
    uint32_t version;            /* 版本号 */
    uint32_t num_pages;          /* 总页面数 */
    uint32_t num_files;          /* 源文件数 */
    uint64_t data_offset;        /* 页面数据起始偏移 */
    uint64_t index_offset;       /* 索引表起始偏移 */
    uint64_t file_table_offset;  /* 文件名表起始偏移 */
    uint64_t total_size;         /* BigCache 文件总大小 */
    uint32_t checksum;           /* CRC32 校验和 */
    uint32_t flags;              /* 标志位 */
    uint8_t  reserved[32];       /* 保留字段 */
} BigCacheHeader;

/*
 * 页面索引项
 * 描述 BigCache 中每个页面的来源信息
 */
typedef struct __attribute__((packed)) {
    uint32_t file_id;            /* 源文件 ID（对应文件名表的索引）*/
    uint64_t source_offset;      /* 在源文件中的偏移 */
    uint32_t access_order;       /* 首次访问序号（用于预热排序）*/
    uint16_t flags;              /* 页面标志 */
    uint16_t reserved;           /* 保留 */
} BigCachePageIndex;

/* 页面标志定义 */
#define PAGE_FLAG_EXECUTABLE    (1 << 0)   /* 可执行代码页 */
#define PAGE_FLAG_READONLY      (1 << 1)   /* 只读数据页 */
#define PAGE_FLAG_CRITICAL      (1 << 2)   /* 关键页（优先加载）*/
#define PAGE_FLAG_COMPRESSED    (1 << 3)   /* 已压缩 */

/*
 * 文件名表项
 */
typedef struct __attribute__((packed)) {
    uint32_t file_id;            /* 文件 ID */
    uint32_t path_len;           /* 路径长度 */
    uint32_t total_pages;        /* 该文件在 BigCache 中的总页数 */
    uint64_t original_size;      /* 原始文件大小 */
    char     path[MAX_PATH_LEN]; /* 文件路径 */
} BigCacheFileEntry;

/*
 * 运行时索引结构
 * 用于快速查找：(file_path, offset) -> bigcache_offset
 */
typedef struct {
    char     *file_path;         /* 文件路径（堆分配）*/
    uint64_t source_offset;      /* 源文件内偏移 */
    uint64_t bigcache_offset;    /* BigCache 内偏移 */
    uint32_t access_order;       /* 访问序号 */
} RuntimePageEntry;

/*
 * 哈希表桶
 */
typedef struct HashBucket {
    RuntimePageEntry *entry;
    struct HashBucket *next;
} HashBucket;

/*
 * 页面查找哈希表
 * Key: hash(file_path + offset)
 * Value: bigcache_offset
 */
typedef struct {
    HashBucket **buckets;
    size_t num_buckets;
    size_t num_entries;
} PageLookupTable;

/*
 * BigCache 运行时上下文
 */
typedef struct {
    /* 文件映射 */
    int fd;                      /* BigCache 文件描述符 */
    void *mapped_data;           /* mmap 映射地址 */
    size_t mapped_size;          /* 映射大小 */
    
    /* 头部信息 */
    BigCacheHeader header;       /* 文件头副本 */
    
    /* 索引表 */
    BigCachePageIndex *page_index;   /* 页面索引数组 */
    BigCacheFileEntry *file_table;   /* 文件名表数组 */
    
    /* 运行时查找表 */
    PageLookupTable *lookup_table;
    
    /* 统计信息 */
    uint64_t hit_count;          /* 命中次数 */
    uint64_t miss_count;         /* 未命中次数 */
    uint64_t total_bytes_served; /* 总服务字节数 */
    
    /* 状态 */
    int is_loaded;               /* 是否已加载到内存 */
    int is_preheated;            /* 是否已预热 */
} BigCacheContext;

/*
 * BigCache API 函数声明
 */

/* 初始化与清理 */
BigCacheContext* bigcache_create(void);
void bigcache_destroy(BigCacheContext *ctx);

/* 加载 BigCache 文件 */
int bigcache_load(BigCacheContext *ctx, const char *path);
int bigcache_unload(BigCacheContext *ctx);

/* 页面查找 */
void* bigcache_lookup(BigCacheContext *ctx, 
                      const char *file_path, 
                      uint64_t offset);

int bigcache_lookup_offset(BigCacheContext *ctx,
                           const char *file_path,
                           uint64_t offset,
                           uint64_t *out_bigcache_offset);

/* 预热相关 */
int bigcache_preheat(BigCacheContext *ctx);
int bigcache_preheat_range(BigCacheContext *ctx, 
                           uint32_t start_order, 
                           uint32_t end_order);

/* 统计信息 */
void bigcache_print_stats(BigCacheContext *ctx);
void bigcache_reset_stats(BigCacheContext *ctx);

/* 工具函数 */
uint32_t bigcache_crc32(const void *data, size_t len);
int bigcache_verify(BigCacheContext *ctx);

/*
 * BigCache 打包器 API
 */
typedef struct {
    char file_path[MAX_PATH_LEN];
    uint64_t offset;
    uint32_t size;
    uint32_t access_order;
} PackerPageEntry;

typedef struct {
    PackerPageEntry *entries;
    size_t num_entries;
    size_t capacity;
    
    /* 文件列表 */
    char **file_paths;
    size_t num_files;
    
    /* 输出缓冲 */
    void *output_buffer;
    size_t output_size;
} BigCachePacker;

BigCachePacker* packer_create(void);
void packer_destroy(BigCachePacker *packer);
int packer_add_page(BigCachePacker *packer, 
                    const char *file_path,
                    uint64_t offset,
                    uint32_t access_order);
int packer_build(BigCachePacker *packer, const char *output_path);
int packer_load_from_csv(BigCachePacker *packer, const char *csv_path);

#endif /* BIGCACHE_H */
