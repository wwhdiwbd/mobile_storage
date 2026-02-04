/*
 * Userfaultfd 处理器实现
 * 
 * 核心功能：
 * 1. 创建和管理 userfaultfd
 * 2. 注册内存区域
 * 3. 处理缺页中断
 * 4. 从 BigCache 复制数据到故障地址
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/userfaultfd.h>
#include <time.h>
#include "uffd_handler.h"
#include "bigcache.h"

/* 日志级别 */
static int g_log_level = UFFD_LOG_INFO;

/* 活跃的 handler（全局，供 hook 使用）*/
static UffdHandler *g_active_handler = NULL;

/* 日志宏 */
#define UFFD_LOG(level, fmt, ...) do { \
    if (g_log_level >= level) { \
        const char *level_str[] = {"", "ERROR", "WARN", "INFO", "DEBUG", "TRACE"}; \
        fprintf(stderr, "[UFFD %s] " fmt "\n", level_str[level], ##__VA_ARGS__); \
    } \
} while(0)

#define LOG_ERROR(fmt, ...) UFFD_LOG(UFFD_LOG_ERROR, fmt, ##__VA_ARGS__)
#define LOG_WARN(fmt, ...)  UFFD_LOG(UFFD_LOG_WARN, fmt, ##__VA_ARGS__)
#define LOG_INFO(fmt, ...)  UFFD_LOG(UFFD_LOG_INFO, fmt, ##__VA_ARGS__)
#define LOG_DEBUG(fmt, ...) UFFD_LOG(UFFD_LOG_DEBUG, fmt, ##__VA_ARGS__)
#define LOG_TRACE(fmt, ...) UFFD_LOG(UFFD_LOG_TRACE, fmt, ##__VA_ARGS__)

/* 获取当前时间（微秒）*/
static double get_time_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000.0 + ts.tv_nsec / 1000.0;
}

/* 设置日志级别 */
void uffd_handler_set_log_level(int level) {
    g_log_level = level;
}

/* 获取/设置活跃的 handler */
UffdHandler* uffd_get_active_handler(void) {
    return g_active_handler;
}

void uffd_set_active_handler(UffdHandler *handler) {
    g_active_handler = handler;
}

/* 创建 userfaultfd */
static int create_userfaultfd(void) {
    /* 使用 syscall 创建 userfaultfd */
    int uffd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK);
    if (uffd < 0) {
        LOG_ERROR("syscall(userfaultfd) failed: %s", strerror(errno));
        return -1;
    }
    
    /* 初始化 UFFD API */
    struct uffdio_api uffdio_api;
    uffdio_api.api = UFFD_API;
    uffdio_api.features = 0;  /* 可以启用 UFFD_FEATURE_* */
    
    if (ioctl(uffd, UFFDIO_API, &uffdio_api) < 0) {
        LOG_ERROR("ioctl(UFFDIO_API) failed: %s", strerror(errno));
        close(uffd);
        return -1;
    }
    
    LOG_INFO("Created userfaultfd: fd=%d, api=0x%llx, features=0x%llx",
             uffd, 
             (unsigned long long)uffdio_api.api,
             (unsigned long long)uffdio_api.features);
    
    return uffd;
}

/* 处理单个缺页 */
int _uffd_handle_pagefault(UffdHandler *handler, 
                           uint64_t fault_addr,
                           uint64_t fault_flags) {
    double start_time = 0;
    if (handler->config.enable_stats) {
        start_time = get_time_us();
    }
    
    /* 页对齐故障地址 */
    uint64_t page_addr = fault_addr & ~(PAGE_SIZE - 1);
    
    LOG_DEBUG("Page fault at 0x%lx (page 0x%lx), flags=0x%lx",
              (unsigned long)fault_addr, 
              (unsigned long)page_addr,
              (unsigned long)fault_flags);
    
    /* 查找对应的内存区域 */
    pthread_mutex_lock(&handler->regions_lock);
    MemoryRegion *region = _uffd_find_region(handler, (void*)page_addr);
    pthread_mutex_unlock(&handler->regions_lock);
    
    if (!region) {
        LOG_ERROR("No region registered for address 0x%lx", (unsigned long)page_addr);
        return -ENOENT;
    }
    
    /* 计算在源文件中的偏移 */
    uint64_t offset_in_region = page_addr - (uint64_t)region->base;
    uint64_t file_offset = region->file_offset_base + offset_in_region;
    
    LOG_TRACE("Region: base=0x%lx, file=%s, file_offset=%lu",
              (unsigned long)region->base,
              region->file_path,
              (unsigned long)file_offset);
    
    /* 从 BigCache 查找数据 */
    void *source_data = bigcache_lookup(handler->bigcache, 
                                        region->file_path,
                                        file_offset);
    
    int cache_hit = (source_data != NULL);
    
    /* 准备复制数据 */
    struct uffdio_copy uffdio_copy;
    uffdio_copy.dst = page_addr;
    uffdio_copy.len = PAGE_SIZE;
    uffdio_copy.mode = 0;
    
    if (source_data) {
        /* 命中：从 BigCache 复制 */
        uffdio_copy.src = (uint64_t)source_data;
        LOG_TRACE("Cache HIT: copying from BigCache");
    } else {
        /* 未命中：填充零页或报错 */
        if (handler->config.enable_zero_fill) {
            uffdio_copy.src = (uint64_t)handler->zero_page;
            LOG_DEBUG("Cache MISS: zero-filling page at 0x%lx", (unsigned long)page_addr);
        } else {
            LOG_ERROR("Cache MISS and zero-fill disabled for 0x%lx", 
                      (unsigned long)page_addr);
            return -ENODATA;
        }
    }
    
    /* 执行复制 */
    if (ioctl(handler->uffd, UFFDIO_COPY, &uffdio_copy) < 0) {
        if (errno != EEXIST) {  /* EEXIST 表示页面已存在，不是错误 */
            LOG_ERROR("ioctl(UFFDIO_COPY) failed: %s", strerror(errno));
            if (handler->config.enable_stats) {
                pthread_mutex_lock(&handler->stats_lock);
                handler->stats.copy_errors++;
                pthread_mutex_unlock(&handler->stats_lock);
            }
            return -errno;
        }
    }
    
    /* 更新统计 */
    if (handler->config.enable_stats) {
        double elapsed = get_time_us() - start_time;
        
        pthread_mutex_lock(&handler->stats_lock);
        handler->stats.total_faults++;
        
        if (cache_hit) {
            handler->stats.cache_hits++;
        } else {
            if (handler->config.enable_zero_fill) {
                handler->stats.zero_fills++;
            } else {
                handler->stats.cache_misses++;
            }
        }
        
        handler->stats.total_handle_time_us += elapsed;
        if (elapsed > handler->stats.max_handle_time_us) {
            handler->stats.max_handle_time_us = elapsed;
        }
        handler->stats.avg_handle_time_us = 
            handler->stats.total_handle_time_us / handler->stats.total_faults;
        
        pthread_mutex_unlock(&handler->stats_lock);
    }
    
    return 0;
}

/* 查找地址对应的区域 */
MemoryRegion* _uffd_find_region(UffdHandler *handler, void *addr) {
    MemoryRegion *region = handler->regions;
    uint64_t target = (uint64_t)addr;
    
    while (region) {
        uint64_t start = (uint64_t)region->base;
        uint64_t end = start + region->size;
        
        if (target >= start && target < end) {
            return region;
        }
        
        region = region->next;
    }
    
    return NULL;
}

/* 处理器线程主函数 */
static void* handler_thread_func(void *arg) {
    UffdHandler *handler = (UffdHandler*)arg;
    
    LOG_INFO("Handler thread started");
    
    struct pollfd pollfds[2];
    pollfds[0].fd = handler->uffd;
    pollfds[0].events = POLLIN;
    pollfds[1].fd = handler->shutdown_pipe[0];
    pollfds[1].events = POLLIN;
    
    while (handler->running) {
        int ret = poll(pollfds, 2, 1000);  /* 1秒超时 */
        
        if (ret < 0) {
            if (errno == EINTR) continue;
            LOG_ERROR("poll failed: %s", strerror(errno));
            break;
        }
        
        if (ret == 0) {
            /* 超时，继续循环 */
            continue;
        }
        
        /* 检查关闭信号 */
        if (pollfds[1].revents & POLLIN) {
            LOG_INFO("Shutdown signal received");
            break;
        }
        
        /* 处理 UFFD 事件 */
        if (pollfds[0].revents & POLLIN) {
            struct uffd_msg msg;
            
            ssize_t n = read(handler->uffd, &msg, sizeof(msg));
            if (n < 0) {
                if (errno == EAGAIN) continue;
                LOG_ERROR("read(uffd) failed: %s", strerror(errno));
                break;
            }
            
            if (n != sizeof(msg)) {
                LOG_ERROR("read(uffd) returned %zd, expected %zu", n, sizeof(msg));
                continue;
            }
            
            /* 处理消息 */
            switch (msg.event) {
                case UFFD_EVENT_PAGEFAULT:
                    _uffd_handle_pagefault(handler,
                                           msg.arg.pagefault.address,
                                           msg.arg.pagefault.flags);
                    break;
                    
                case UFFD_EVENT_FORK:
                    LOG_DEBUG("UFFD_EVENT_FORK received");
                    break;
                    
                case UFFD_EVENT_REMAP:
                    LOG_DEBUG("UFFD_EVENT_REMAP received");
                    break;
                    
                case UFFD_EVENT_REMOVE:
                    LOG_DEBUG("UFFD_EVENT_REMOVE received");
                    break;
                    
                case UFFD_EVENT_UNMAP:
                    LOG_DEBUG("UFFD_EVENT_UNMAP received");
                    break;
                    
                default:
                    LOG_WARN("Unknown UFFD event: %u", msg.event);
                    break;
            }
        }
    }
    
    LOG_INFO("Handler thread exiting");
    return NULL;
}

/* 创建 UFFD 处理器 */
UffdHandler* uffd_handler_create(BigCacheContext *bigcache) {
    if (!bigcache) {
        LOG_ERROR("BigCache context is required");
        return NULL;
    }
    
    UffdHandler *handler = calloc(1, sizeof(UffdHandler));
    if (!handler) return NULL;
    
    handler->bigcache = bigcache;
    handler->uffd = -1;
    
    /* 初始化锁 */
    pthread_mutex_init(&handler->regions_lock, NULL);
    pthread_mutex_init(&handler->stats_lock, NULL);
    
    /* 创建 userfaultfd */
    handler->uffd = create_userfaultfd();
    if (handler->uffd < 0) {
        uffd_handler_destroy(handler);
        return NULL;
    }
    
    /* 创建关闭管道 */
    if (pipe(handler->shutdown_pipe) < 0) {
        LOG_ERROR("pipe failed: %s", strerror(errno));
        uffd_handler_destroy(handler);
        return NULL;
    }
    
    /* 分配零页 */
    handler->zero_page = mmap(NULL, PAGE_SIZE, 
                              PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS,
                              -1, 0);
    if (handler->zero_page == MAP_FAILED) {
        LOG_ERROR("mmap(zero_page) failed: %s", strerror(errno));
        uffd_handler_destroy(handler);
        return NULL;
    }
    memset(handler->zero_page, 0, PAGE_SIZE);
    
    /* 默认配置 */
    handler->config.enable_zero_fill = 1;
    handler->config.enable_stats = 1;
    handler->config.enable_logging = 1;
    handler->config.handler_priority = 0;
    handler->config.prefetch_ahead = 4;
    
    LOG_INFO("UFFD handler created");
    return handler;
}

/* 销毁 UFFD 处理器 */
void uffd_handler_destroy(UffdHandler *handler) {
    if (!handler) return;
    
    /* 停止处理器线程 */
    uffd_handler_stop(handler);
    
    /* 释放内存区域 */
    MemoryRegion *region = handler->regions;
    while (region) {
        MemoryRegion *next = region->next;
        free(region->file_path);
        free(region);
        region = next;
    }
    
    /* 关闭文件描述符 */
    if (handler->uffd >= 0) {
        close(handler->uffd);
    }
    
    if (handler->shutdown_pipe[0] >= 0) {
        close(handler->shutdown_pipe[0]);
    }
    if (handler->shutdown_pipe[1] >= 0) {
        close(handler->shutdown_pipe[1]);
    }
    
    /* 释放零页 */
    if (handler->zero_page && handler->zero_page != MAP_FAILED) {
        munmap(handler->zero_page, PAGE_SIZE);
    }
    
    /* 销毁锁 */
    pthread_mutex_destroy(&handler->regions_lock);
    pthread_mutex_destroy(&handler->stats_lock);
    
    /* 清理全局引用 */
    if (g_active_handler == handler) {
        g_active_handler = NULL;
    }
    
    free(handler);
    LOG_INFO("UFFD handler destroyed");
}

/* 配置 */
int uffd_handler_set_config(UffdHandler *handler, const UffdConfig *config) {
    if (!handler || !config) return -EINVAL;
    memcpy(&handler->config, config, sizeof(UffdConfig));
    return 0;
}

int uffd_handler_get_config(UffdHandler *handler, UffdConfig *config) {
    if (!handler || !config) return -EINVAL;
    memcpy(config, &handler->config, sizeof(UffdConfig));
    return 0;
}

/* 启动处理器 */
int uffd_handler_start(UffdHandler *handler) {
    if (!handler) return -EINVAL;
    
    if (handler->running) {
        LOG_WARN("Handler already running");
        return 0;
    }
    
    handler->running = 1;
    
    int ret = pthread_create(&handler->handler_thread, NULL,
                             handler_thread_func, handler);
    if (ret != 0) {
        LOG_ERROR("pthread_create failed: %s", strerror(ret));
        handler->running = 0;
        return -ret;
    }
    
    /* 设置为活跃处理器 */
    g_active_handler = handler;
    
    LOG_INFO("UFFD handler started");
    return 0;
}

/* 停止处理器 */
int uffd_handler_stop(UffdHandler *handler) {
    if (!handler) return -EINVAL;
    
    if (!handler->running) {
        return 0;
    }
    
    handler->running = 0;
    
    /* 发送关闭信号 */
    char c = 1;
    if (write(handler->shutdown_pipe[1], &c, 1) < 0) {
        LOG_WARN("write(shutdown_pipe) failed: %s", strerror(errno));
    }
    
    /* 等待线程结束 */
    pthread_join(handler->handler_thread, NULL);
    
    LOG_INFO("UFFD handler stopped");
    return 0;
}

int uffd_handler_is_running(UffdHandler *handler) {
    return handler ? handler->running : 0;
}

/* 注册内存区域 */
int uffd_handler_register_region(UffdHandler *handler,
                                  void *addr,
                                  size_t size,
                                  const char *file_path,
                                  uint64_t file_offset_base) {
    if (!handler || !addr || size == 0 || !file_path) {
        return -EINVAL;
    }
    
    /* 检查对齐 */
    if ((uint64_t)addr % PAGE_SIZE != 0) {
        LOG_ERROR("Address 0x%lx is not page-aligned", (unsigned long)addr);
        return -EINVAL;
    }
    
    if (size % PAGE_SIZE != 0) {
        LOG_WARN("Size %zu is not page-aligned, rounding up", size);
        size = (size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    }
    
    /* 创建区域结构 */
    MemoryRegion *region = calloc(1, sizeof(MemoryRegion));
    if (!region) return -ENOMEM;
    
    region->base = addr;
    region->size = size;
    region->file_path = strdup(file_path);
    region->file_offset_base = file_offset_base;
    
    if (!region->file_path) {
        free(region);
        return -ENOMEM;
    }
    
    /* 向 UFFD 注册区域 */
    struct uffdio_register uffdio_register;
    uffdio_register.range.start = (uint64_t)addr;
    uffdio_register.range.len = size;
    uffdio_register.mode = UFFDIO_REGISTER_MODE_MISSING;
    
    if (ioctl(handler->uffd, UFFDIO_REGISTER, &uffdio_register) < 0) {
        LOG_ERROR("ioctl(UFFDIO_REGISTER) failed: %s", strerror(errno));
        free(region->file_path);
        free(region);
        return -errno;
    }
    
    /* 添加到链表 */
    pthread_mutex_lock(&handler->regions_lock);
    region->next = handler->regions;
    handler->regions = region;
    handler->num_regions++;
    pthread_mutex_unlock(&handler->regions_lock);
    
    LOG_INFO("Registered region: base=0x%lx, size=%zu, file=%s, offset=%lu",
             (unsigned long)addr, size, file_path, (unsigned long)file_offset_base);
    
    return 0;
}

/* 取消注册内存区域 */
int uffd_handler_unregister_region(UffdHandler *handler, void *addr) {
    if (!handler || !addr) return -EINVAL;
    
    pthread_mutex_lock(&handler->regions_lock);
    
    MemoryRegion **prev = &handler->regions;
    MemoryRegion *region = handler->regions;
    
    while (region) {
        if (region->base == addr) {
            /* 从 UFFD 取消注册 */
            struct uffdio_range range;
            range.start = (uint64_t)addr;
            range.len = region->size;
            
            if (ioctl(handler->uffd, UFFDIO_UNREGISTER, &range) < 0) {
                LOG_WARN("ioctl(UFFDIO_UNREGISTER) failed: %s", strerror(errno));
            }
            
            /* 从链表移除 */
            *prev = region->next;
            handler->num_regions--;
            
            pthread_mutex_unlock(&handler->regions_lock);
            
            free(region->file_path);
            free(region);
            
            LOG_INFO("Unregistered region: base=0x%lx", (unsigned long)addr);
            return 0;
        }
        
        prev = &region->next;
        region = region->next;
    }
    
    pthread_mutex_unlock(&handler->regions_lock);
    return -ENOENT;
}

/* 创建受 UFFD 保护的映射 */
void* uffd_handler_create_mapping(UffdHandler *handler,
                                   size_t size,
                                   const char *file_path,
                                   uint64_t file_offset_base,
                                   int prot) {
    if (!handler || size == 0 || !file_path) {
        return MAP_FAILED;
    }
    
    /* 对齐大小 */
    size = (size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    
    /* 创建匿名映射 */
    void *addr = mmap(NULL, size,
                      prot | PROT_WRITE,  /* 需要写权限来填充数据 */
                      MAP_PRIVATE | MAP_ANONYMOUS,
                      -1, 0);
    
    if (addr == MAP_FAILED) {
        LOG_ERROR("mmap failed: %s", strerror(errno));
        return MAP_FAILED;
    }
    
    /* 注册到 UFFD */
    int ret = uffd_handler_register_region(handler, addr, size,
                                           file_path, file_offset_base);
    if (ret < 0) {
        munmap(addr, size);
        return MAP_FAILED;
    }
    
    return addr;
}

/* 销毁映射 */
int uffd_handler_destroy_mapping(UffdHandler *handler, void *addr, size_t size) {
    if (!handler || !addr) return -EINVAL;
    
    uffd_handler_unregister_region(handler, addr);
    return munmap(addr, size);
}

/* 统计信息 */
void uffd_handler_get_stats(UffdHandler *handler, UffdStats *stats) {
    if (!handler || !stats) return;
    
    pthread_mutex_lock(&handler->stats_lock);
    memcpy(stats, &handler->stats, sizeof(UffdStats));
    pthread_mutex_unlock(&handler->stats_lock);
}

void uffd_handler_reset_stats(UffdHandler *handler) {
    if (!handler) return;
    
    pthread_mutex_lock(&handler->stats_lock);
    memset(&handler->stats, 0, sizeof(UffdStats));
    pthread_mutex_unlock(&handler->stats_lock);
}

void uffd_handler_print_stats(UffdHandler *handler) {
    if (!handler) return;
    
    UffdStats stats;
    uffd_handler_get_stats(handler, &stats);
    
    printf("\n=== UFFD Handler Statistics ===\n");
    printf("Total page faults: %lu\n", (unsigned long)stats.total_faults);
    printf("Cache hits: %lu\n", (unsigned long)stats.cache_hits);
    printf("Cache misses: %lu\n", (unsigned long)stats.cache_misses);
    printf("Zero fills: %lu\n", (unsigned long)stats.zero_fills);
    printf("Copy errors: %lu\n", (unsigned long)stats.copy_errors);
    
    if (stats.total_faults > 0) {
        printf("Hit rate: %.2f%%\n", 
               (double)stats.cache_hits * 100 / stats.total_faults);
    }
    
    printf("Avg handle time: %.2f us\n", stats.avg_handle_time_us);
    printf("Max handle time: %.2f us\n", stats.max_handle_time_us);
    printf("Total handle time: %.2f ms\n", stats.total_handle_time_us / 1000);
    printf("===============================\n\n");
}

/* 调试：打印所有注册的区域 */
void uffd_handler_dump_regions(UffdHandler *handler) {
    if (!handler) return;
    
    pthread_mutex_lock(&handler->regions_lock);
    
    printf("\n=== Registered Memory Regions ===\n");
    printf("Total regions: %d\n\n", handler->num_regions);
    
    MemoryRegion *region = handler->regions;
    int i = 0;
    
    while (region) {
        printf("Region %d:\n", i++);
        printf("  Base: 0x%lx\n", (unsigned long)region->base);
        printf("  Size: %zu bytes (%.2f MB)\n", 
               region->size, (double)region->size / (1024*1024));
        printf("  File: %s\n", region->file_path);
        printf("  File offset base: %lu\n", (unsigned long)region->file_offset_base);
        printf("\n");
        
        region = region->next;
    }
    
    printf("=================================\n\n");
    
    pthread_mutex_unlock(&handler->regions_lock);
}
