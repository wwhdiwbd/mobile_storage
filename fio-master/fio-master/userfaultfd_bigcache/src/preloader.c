/*
 * 预加载器实现
 * 
 * 负责在应用启动前：
 * 1. 加载 BigCache 到内存
 * 2. 启动 UFFD 处理器
 * 3. 拦截关键文件的 mmap 调用
 * 4. 将文件映射重定向到 BigCache
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <pthread.h>
#include <time.h>
#include "bigcache.h"
#include "uffd_handler.h"

/* 预加载器全局状态 */
typedef struct {
    BigCacheContext *bigcache;
    UffdHandler *uffd_handler;
    
    /* 原始函数指针（用于 hook）*/
    void* (*original_mmap)(void*, size_t, int, int, int, off_t);
    int (*original_munmap)(void*, size_t);
    void* (*original_dlopen)(const char*, int);
    
    /* 配置 */
    char bigcache_path[512];
    int enabled;
    int verbose;
    
    /* 统计 */
    int intercepted_count;
    int bypassed_count;
    size_t total_intercepted_size;
    
    /* 启动时间 */
    double init_time_ms;
    double preheat_time_ms;
    
    /* 线程安全 */
    pthread_mutex_t lock;
    int initialized;
} PreloaderState;

static PreloaderState g_preloader = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .initialized = 0
};

/* 获取当前时间（毫秒）*/
static double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

/* 检查文件是否应该被拦截 */
static int should_intercept(const char *path) {
    if (!path) return 0;
    
    /* 拦截关键文件类型 */
    if (strstr(path, ".so")) return 1;      /* 共享库 */
    if (strstr(path, ".dex")) return 1;     /* DEX 文件 */
    if (strstr(path, ".odex")) return 1;    /* ODEX 文件 */
    if (strstr(path, ".oat")) return 1;     /* OAT 文件 */
    if (strstr(path, ".vdex")) return 1;    /* VDEX 文件 */
    if (strstr(path, ".art")) return 1;     /* ART 文件 */
    if (strstr(path, ".apk")) return 1;     /* APK 文件 */
    if (strstr(path, ".jar")) return 1;     /* JAR 文件 */
    
    return 0;
}

/* 初始化预加载器 */
int preloader_init(const char *bigcache_path) {
    pthread_mutex_lock(&g_preloader.lock);
    
    if (g_preloader.initialized) {
        pthread_mutex_unlock(&g_preloader.lock);
        return 0;  /* 已初始化 */
    }
    
    double start_time = get_time_ms();
    
    printf("=== BigCache Preloader Initializing ===\n");
    
    /* 保存配置 */
    if (bigcache_path) {
        strncpy(g_preloader.bigcache_path, bigcache_path, 
                sizeof(g_preloader.bigcache_path) - 1);
    } else {
        strcpy(g_preloader.bigcache_path, "/data/local/tmp/bigcache.bin");
    }
    
    /* 读取环境变量配置 */
    const char *verbose = getenv("BIGCACHE_VERBOSE");
    g_preloader.verbose = verbose ? atoi(verbose) : 0;
    
    const char *enabled = getenv("BIGCACHE_ENABLED");
    g_preloader.enabled = enabled ? atoi(enabled) : 1;
    
    if (!g_preloader.enabled) {
        printf("BigCache is disabled by environment\n");
        g_preloader.initialized = 1;
        pthread_mutex_unlock(&g_preloader.lock);
        return 0;
    }
    
    /* 创建 BigCache 上下文 */
    g_preloader.bigcache = bigcache_create();
    if (!g_preloader.bigcache) {
        fprintf(stderr, "Failed to create BigCache context\n");
        pthread_mutex_unlock(&g_preloader.lock);
        return -ENOMEM;
    }
    
    /* 加载 BigCache 文件 */
    int ret = bigcache_load(g_preloader.bigcache, g_preloader.bigcache_path);
    if (ret < 0) {
        fprintf(stderr, "Failed to load BigCache from %s: %d\n",
                g_preloader.bigcache_path, ret);
        bigcache_destroy(g_preloader.bigcache);
        g_preloader.bigcache = NULL;
        g_preloader.enabled = 0;
        g_preloader.initialized = 1;
        pthread_mutex_unlock(&g_preloader.lock);
        return ret;
    }
    
    g_preloader.init_time_ms = get_time_ms() - start_time;
    
    /* 预热 BigCache */
    double preheat_start = get_time_ms();
    ret = bigcache_preheat(g_preloader.bigcache);
    if (ret < 0) {
        fprintf(stderr, "Failed to preheat BigCache: %d\n", ret);
    }
    g_preloader.preheat_time_ms = get_time_ms() - preheat_start;
    
    /* 创建 UFFD 处理器 */
    g_preloader.uffd_handler = uffd_handler_create(g_preloader.bigcache);
    if (!g_preloader.uffd_handler) {
        fprintf(stderr, "Failed to create UFFD handler\n");
        bigcache_destroy(g_preloader.bigcache);
        g_preloader.bigcache = NULL;
        g_preloader.enabled = 0;
        g_preloader.initialized = 1;
        pthread_mutex_unlock(&g_preloader.lock);
        return -ENOMEM;
    }
    
    /* 配置 UFFD 处理器 */
    UffdConfig config = {
        .enable_zero_fill = 1,
        .enable_stats = 1,
        .enable_logging = g_preloader.verbose,
        .handler_priority = -10,  /* 高优先级 */
        .prefetch_ahead = 8
    };
    uffd_handler_set_config(g_preloader.uffd_handler, &config);
    
    /* 启动 UFFD 处理器 */
    ret = uffd_handler_start(g_preloader.uffd_handler);
    if (ret < 0) {
        fprintf(stderr, "Failed to start UFFD handler: %d\n", ret);
        uffd_handler_destroy(g_preloader.uffd_handler);
        bigcache_destroy(g_preloader.bigcache);
        g_preloader.uffd_handler = NULL;
        g_preloader.bigcache = NULL;
        g_preloader.enabled = 0;
        g_preloader.initialized = 1;
        pthread_mutex_unlock(&g_preloader.lock);
        return ret;
    }
    
    /* 保存原始函数指针 */
    g_preloader.original_mmap = dlsym(RTLD_NEXT, "mmap");
    g_preloader.original_munmap = dlsym(RTLD_NEXT, "munmap");
    g_preloader.original_dlopen = dlsym(RTLD_NEXT, "dlopen");
    
    double total_time = get_time_ms() - start_time;
    
    printf("\n=== Preloader Initialized ===\n");
    printf("BigCache: %s\n", g_preloader.bigcache_path);
    printf("Init time: %.2f ms\n", g_preloader.init_time_ms);
    printf("Preheat time: %.2f ms\n", g_preloader.preheat_time_ms);
    printf("Total time: %.2f ms\n", total_time);
    printf("=============================\n\n");
    
    g_preloader.initialized = 1;
    pthread_mutex_unlock(&g_preloader.lock);
    
    return 0;
}

/* 清理预加载器 */
void preloader_cleanup(void) {
    pthread_mutex_lock(&g_preloader.lock);
    
    if (!g_preloader.initialized) {
        pthread_mutex_unlock(&g_preloader.lock);
        return;
    }
    
    printf("\n=== Preloader Cleanup ===\n");
    
    /* 打印统计 */
    printf("Intercepted: %d calls, %.2f MB\n",
           g_preloader.intercepted_count,
           (double)g_preloader.total_intercepted_size / (1024*1024));
    printf("Bypassed: %d calls\n", g_preloader.bypassed_count);
    
    if (g_preloader.uffd_handler) {
        uffd_handler_print_stats(g_preloader.uffd_handler);
        uffd_handler_stop(g_preloader.uffd_handler);
        uffd_handler_destroy(g_preloader.uffd_handler);
        g_preloader.uffd_handler = NULL;
    }
    
    if (g_preloader.bigcache) {
        bigcache_print_stats(g_preloader.bigcache);
        bigcache_destroy(g_preloader.bigcache);
        g_preloader.bigcache = NULL;
    }
    
    g_preloader.initialized = 0;
    pthread_mutex_unlock(&g_preloader.lock);
    
    printf("=========================\n\n");
}

/* 
 * mmap Hook
 * 
 * 拦截文件映射，对于在 BigCache 中的文件，
 * 创建 UFFD 保护的匿名映射替代
 */
void* preloader_mmap(void *addr, size_t length, int prot, int flags,
                     int fd, off_t offset, const char *pathname) {
    /* 检查是否应该拦截 */
    if (!g_preloader.enabled || 
        !g_preloader.uffd_handler ||
        !(flags & MAP_PRIVATE) ||
        !pathname ||
        !should_intercept(pathname)) {
        
        /* 使用原始 mmap */
        if (g_preloader.verbose) {
            printf("[Preloader] Bypass mmap: %s\n", pathname ? pathname : "(null)");
        }
        g_preloader.bypassed_count++;
        return g_preloader.original_mmap(addr, length, prot, flags, fd, offset);
    }
    
    /* 检查页面是否在 BigCache 中 */
    uint64_t bc_offset;
    int found = bigcache_lookup_offset(g_preloader.bigcache, 
                                       pathname, offset, &bc_offset);
    if (found < 0) {
        /* BigCache 中没有这个页面，使用原始 mmap */
        if (g_preloader.verbose > 1) {
            printf("[Preloader] Miss BigCache: %s offset=%ld\n", 
                   pathname, (long)offset);
        }
        g_preloader.bypassed_count++;
        return g_preloader.original_mmap(addr, length, prot, flags, fd, offset);
    }
    
    /* 创建 UFFD 保护的映射 */
    void *result = uffd_handler_create_mapping(g_preloader.uffd_handler,
                                               length, pathname, offset, prot);
    
    if (result == MAP_FAILED) {
        /* 失败，回退到原始 mmap */
        if (g_preloader.verbose) {
            printf("[Preloader] UFFD mapping failed, fallback: %s\n", pathname);
        }
        g_preloader.bypassed_count++;
        return g_preloader.original_mmap(addr, length, prot, flags, fd, offset);
    }
    
    /* 成功 */
    if (g_preloader.verbose) {
        printf("[Preloader] Intercepted: %s, len=%zu, offset=%ld -> 0x%lx\n",
               pathname, length, (long)offset, (unsigned long)result);
    }
    
    g_preloader.intercepted_count++;
    g_preloader.total_intercepted_size += length;
    
    return result;
}

/*
 * 获取预加载器状态
 */
void preloader_get_stats(int *intercepted, int *bypassed, 
                         size_t *total_size, double *init_time) {
    if (intercepted) *intercepted = g_preloader.intercepted_count;
    if (bypassed) *bypassed = g_preloader.bypassed_count;
    if (total_size) *total_size = g_preloader.total_intercepted_size;
    if (init_time) *init_time = g_preloader.init_time_ms + g_preloader.preheat_time_ms;
}

/*
 * 检查预加载器是否启用
 */
int preloader_is_enabled(void) {
    return g_preloader.enabled && g_preloader.initialized;
}

/*
 * 获取 BigCache 上下文
 */
BigCacheContext* preloader_get_bigcache(void) {
    return g_preloader.bigcache;
}

/*
 * 获取 UFFD 处理器
 */
UffdHandler* preloader_get_uffd_handler(void) {
    return g_preloader.uffd_handler;
}

/*
 * LD_PRELOAD 入口点
 * 
 * 当库被 LD_PRELOAD 加载时自动初始化
 */
__attribute__((constructor))
static void preloader_constructor(void) {
    const char *path = getenv("BIGCACHE_PATH");
    preloader_init(path);
}

__attribute__((destructor))
static void preloader_destructor(void) {
    preloader_cleanup();
}

/*
 * 导出的 mmap/munmap hook（需要配合 LD_PRELOAD 使用）
 * 
 * 注意：这些 hook 只在特定条件下才会真正替代系统调用，
 * 需要根据实际部署环境调整
 */

#ifdef ENABLE_MMAP_HOOK
/* 这个版本用于 LD_PRELOAD */
void* mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    /* 获取文件路径 */
    char path[512] = "";
    if (fd >= 0) {
        char proc_path[64];
        snprintf(proc_path, sizeof(proc_path), "/proc/self/fd/%d", fd);
        ssize_t len = readlink(proc_path, path, sizeof(path) - 1);
        if (len > 0) path[len] = '\0';
    }
    
    return preloader_mmap(addr, length, prot, flags, fd, offset, 
                          path[0] ? path : NULL);
}

int munmap(void *addr, size_t length) {
    if (g_preloader.uffd_handler) {
        /* 尝试从 UFFD 处理器移除 */
        uffd_handler_unregister_region(g_preloader.uffd_handler, addr);
    }
    return g_preloader.original_munmap(addr, length);
}
#endif
