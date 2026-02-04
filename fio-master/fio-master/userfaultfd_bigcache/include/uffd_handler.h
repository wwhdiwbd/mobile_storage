/*
 * Userfaultfd 处理器头文件
 * 
 * 实现基于 userfaultfd 的缺页处理机制，
 * 拦截应用的页面故障并从 BigCache 提供数据。
 */

#ifndef UFFD_HANDLER_H
#define UFFD_HANDLER_H

#include <stdint.h>
#include <pthread.h>
#include <linux/userfaultfd.h>
#include "bigcache.h"

/*
 * UFFD 事件类型（使用不同的名称避免与系统宏冲突）
 */
typedef enum {
    BC_UFFD_PAGEFAULT = 0,       /* 缺页事件 */
    BC_UFFD_FORK,                /* fork 事件 */
    BC_UFFD_REMAP,               /* mremap 事件 */
    BC_UFFD_REMOVE,              /* madvise(DONTNEED) 事件 */
    BC_UFFD_UNMAP                /* munmap 事件 */
} UffdEventType;

/*
 * 注册的内存区域
 */
typedef struct MemoryRegion {
    void *base;                  /* 区域基地址 */
    size_t size;                 /* 区域大小 */
    char *file_path;             /* 对应的文件路径 */
    uint64_t file_offset_base;   /* 文件偏移基址 */
    int prot;                    /* 保护标志 (PROT_READ | PROT_WRITE 等) */
    struct MemoryRegion *next;   /* 链表指针 */
} MemoryRegion;

/*
 * UFFD 处理器统计信息
 */
typedef struct {
    uint64_t total_faults;       /* 总缺页次数 */
    uint64_t cache_hits;         /* BigCache 命中次数 */
    uint64_t cache_misses;       /* BigCache 未命中次数 */
    uint64_t zero_fills;         /* 零页填充次数 */
    uint64_t copy_errors;        /* 拷贝错误次数 */
    double total_handle_time_us; /* 总处理时间（微秒）*/
    double avg_handle_time_us;   /* 平均处理时间（微秒）*/
    double max_handle_time_us;   /* 最大处理时间（微秒）*/
} UffdStats;

/*
 * UFFD 处理器配置
 */
typedef struct {
    int enable_zero_fill;        /* 未命中时是否填充零页 */
    int enable_stats;            /* 是否收集统计信息 */
    int enable_logging;          /* 是否启用日志 */
    int handler_priority;        /* 处理器线程优先级 */
    size_t prefetch_ahead;       /* 预取页数 */
} UffdConfig;

/*
 * UFFD 处理器上下文
 */
typedef struct {
    /* Userfaultfd 相关 */
    int uffd;                    /* userfaultfd 文件描述符 */
    pthread_t handler_thread;    /* 处理器线程 */
    volatile int running;        /* 运行标志 */
    
    /* BigCache 引用 */
    BigCacheContext *bigcache;   /* BigCache 上下文 */
    
    /* 注册的内存区域 */
    MemoryRegion *regions;       /* 区域链表 */
    pthread_mutex_t regions_lock;/* 区域锁 */
    int num_regions;             /* 区域数量 */
    
    /* 配置 */
    UffdConfig config;           /* 配置选项 */
    
    /* 统计 */
    UffdStats stats;             /* 统计信息 */
    pthread_mutex_t stats_lock;  /* 统计锁 */
    
    /* 零页缓冲（用于填充未命中的页）*/
    void *zero_page;             /* 预分配的零页 */
    
    /* 事件管道（用于优雅关闭）*/
    int shutdown_pipe[2];        /* 关闭通知管道 */
} UffdHandler;

/*
 * UFFD 处理器 API
 */

/* 创建和销毁 */
UffdHandler* uffd_handler_create(BigCacheContext *bigcache);
void uffd_handler_destroy(UffdHandler *handler);

/* 配置 */
int uffd_handler_set_config(UffdHandler *handler, const UffdConfig *config);
int uffd_handler_get_config(UffdHandler *handler, UffdConfig *config);

/* 启动和停止 */
int uffd_handler_start(UffdHandler *handler);
int uffd_handler_stop(UffdHandler *handler);
int uffd_handler_is_running(UffdHandler *handler);

/* 内存区域管理 */
int uffd_handler_register_region(UffdHandler *handler,
                                  void *addr,
                                  size_t size,
                                  const char *file_path,
                                  uint64_t file_offset_base);
int uffd_handler_unregister_region(UffdHandler *handler, void *addr);

/*
 * 创建受 UFFD 保护的内存映射
 * 这是核心函数：创建匿名映射并注册到 UFFD
 */
void* uffd_handler_create_mapping(UffdHandler *handler,
                                   size_t size,
                                   const char *file_path,
                                   uint64_t file_offset_base,
                                   int prot);
int uffd_handler_destroy_mapping(UffdHandler *handler, void *addr, size_t size);

/* 统计信息 */
void uffd_handler_get_stats(UffdHandler *handler, UffdStats *stats);
void uffd_handler_reset_stats(UffdHandler *handler);
void uffd_handler_print_stats(UffdHandler *handler);

/*
 * 高级 API：文件 mmap 替代
 * 
 * 这些函数可以替代标准的 mmap，自动将文件映射
 * 转换为 UFFD 保护的映射，从 BigCache 提供数据
 */

/* 替代 mmap(file) */
void* uffd_mmap_file(UffdHandler *handler,
                     void *addr,
                     size_t length,
                     int prot,
                     int flags,
                     const char *file_path,
                     off_t offset);

/* 替代 munmap */
int uffd_munmap(UffdHandler *handler, void *addr, size_t length);

/*
 * PLT Hook 支持
 * 用于拦截应用的 mmap 调用
 */
typedef void* (*mmap_func_t)(void*, size_t, int, int, int, off_t);
typedef int (*munmap_func_t)(void*, size_t);

/* 设置 hook 回调 */
void uffd_set_mmap_hook(mmap_func_t original_mmap);
void uffd_set_munmap_hook(munmap_func_t original_munmap);

/* 获取当前活跃的 handler（供 hook 使用）*/
UffdHandler* uffd_get_active_handler(void);
void uffd_set_active_handler(UffdHandler *handler);

/*
 * 调试支持
 */
void uffd_handler_dump_regions(UffdHandler *handler);
void uffd_handler_set_log_level(int level);

/* 日志级别 */
#define UFFD_LOG_NONE    0
#define UFFD_LOG_ERROR   1
#define UFFD_LOG_WARN    2
#define UFFD_LOG_INFO    3
#define UFFD_LOG_DEBUG   4
#define UFFD_LOG_TRACE   5

/*
 * 内部函数（供测试使用）
 */

/* 处理单个缺页 */
int _uffd_handle_pagefault(UffdHandler *handler, 
                           uint64_t fault_addr,
                           uint64_t fault_flags);

/* 查找地址对应的区域 */
MemoryRegion* _uffd_find_region(UffdHandler *handler, void *addr);

/* 计算页对齐地址 */
static inline void* page_align_down(void *addr) {
    return (void*)((uintptr_t)addr & ~(PAGE_SIZE - 1));
}

static inline void* page_align_up(void *addr) {
    return (void*)(((uintptr_t)addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1));
}

#endif /* UFFD_HANDLER_H */
