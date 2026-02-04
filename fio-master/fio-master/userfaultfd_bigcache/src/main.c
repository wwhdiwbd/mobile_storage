/*
 * BigCache + UFFD 主程序
 * 
 * 提供命令行接口用于：
 * 1. 打包生成 BigCache.bin
 * 2. 验证 BigCache
 * 3. 运行性能测试
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#include "bigcache.h"
#include "uffd_handler.h"

/* 外部声明 */
extern int preloader_init(const char *bigcache_path);
extern void preloader_cleanup(void);

/* 获取时间（毫秒）*/
static double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

/* 命令：打包 */
static int cmd_pack(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: bigcache pack <layout.csv> <output.bin>\n");
        return 1;
    }
    
    const char *csv_path = argv[0];
    const char *output_path = argv[1];
    
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
    printf("\nBigCache created successfully: %s\n", output_path);
    return 0;
}

/* 命令：验证 */
static int cmd_verify(int argc, char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: bigcache verify <bigcache.bin>\n");
        return 1;
    }
    
    const char *path = argv[0];
    
    BigCacheContext *ctx = bigcache_create();
    if (!ctx) {
        fprintf(stderr, "Failed to create context\n");
        return 1;
    }
    
    int ret = bigcache_load(ctx, path);
    if (ret < 0) {
        fprintf(stderr, "Failed to load BigCache: %d\n", ret);
        bigcache_destroy(ctx);
        return 1;
    }
    
    ret = bigcache_verify(ctx);
    
    bigcache_print_stats(ctx);
    bigcache_destroy(ctx);
    
    return ret < 0 ? 1 : 0;
}

/* 命令：信息 */
static int cmd_info(int argc, char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: bigcache info <bigcache.bin>\n");
        return 1;
    }
    
    const char *path = argv[0];
    
    BigCacheContext *ctx = bigcache_create();
    if (!ctx) return 1;
    
    int ret = bigcache_load(ctx, path);
    if (ret < 0) {
        bigcache_destroy(ctx);
        return 1;
    }
    
    printf("\n=== BigCache Information ===\n");
    printf("File: %s\n", path);
    printf("Magic: 0x%08X\n", ctx->header.magic);
    printf("Version: %u\n", ctx->header.version);
    printf("Pages: %u\n", ctx->header.num_pages);
    printf("Files: %u\n", ctx->header.num_files);
    printf("Total size: %.2f MB\n", (double)ctx->header.total_size / (1024*1024));
    printf("Data offset: 0x%lx\n", (unsigned long)ctx->header.data_offset);
    printf("Index offset: 0x%lx\n", (unsigned long)ctx->header.index_offset);
    printf("File table offset: 0x%lx\n", (unsigned long)ctx->header.file_table_offset);
    printf("============================\n\n");
    
    bigcache_destroy(ctx);
    return 0;
}

/* 命令：基准测试 */
static int cmd_benchmark(int argc, char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: bigcache benchmark <bigcache.bin> [iterations]\n");
        return 1;
    }
    
    const char *path = argv[0];
    int iterations = argc > 1 ? atoi(argv[1]) : 1000;
    
    printf("\n=== BigCache Benchmark ===\n");
    printf("File: %s\n", path);
    printf("Iterations: %d\n\n", iterations);
    
    /* 加载 BigCache */
    double load_start = get_time_ms();
    
    BigCacheContext *ctx = bigcache_create();
    if (!ctx) return 1;
    
    int ret = bigcache_load(ctx, path);
    if (ret < 0) {
        bigcache_destroy(ctx);
        return 1;
    }
    
    double load_time = get_time_ms() - load_start;
    printf("Load time: %.2f ms\n", load_time);
    
    /* 预热测试 */
    double preheat_start = get_time_ms();
    ret = bigcache_preheat(ctx);
    double preheat_time = get_time_ms() - preheat_start;
    printf("Preheat time: %.2f ms\n", preheat_time);
    
    /* 创建 UFFD 处理器 */
    UffdHandler *handler = uffd_handler_create(ctx);
    if (!handler) {
        bigcache_destroy(ctx);
        return 1;
    }
    
    ret = uffd_handler_start(handler);
    if (ret < 0) {
        uffd_handler_destroy(handler);
        bigcache_destroy(ctx);
        return 1;
    }
    
    /* 创建测试映射 */
    size_t test_size = 4 * 1024 * 1024;  /* 4MB */
    void *test_region = uffd_handler_create_mapping(handler, test_size,
                                                    "/test/simulated.so", 0,
                                                    PROT_READ);
    
    if (test_region == MAP_FAILED) {
        printf("Warning: Could not create UFFD mapping, using mmap test\n");
        test_region = mmap(NULL, test_size, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    }
    
    /* 访问测试 */
    printf("\nRunning access benchmark...\n");
    
    volatile uint8_t sum = 0;
    double access_start = get_time_ms();
    
    uint8_t *data = (uint8_t*)test_region;
    for (int i = 0; i < iterations; i++) {
        /* 随机访问模式 */
        size_t offset = (rand() % (test_size / PAGE_SIZE)) * PAGE_SIZE;
        sum += data[offset];
    }
    
    double access_time = get_time_ms() - access_start;
    
    printf("Access test:\n");
    printf("  Total time: %.2f ms\n", access_time);
    printf("  Avg per access: %.2f us\n", access_time * 1000 / iterations);
    printf("  Throughput: %.2f accesses/sec\n", iterations * 1000 / access_time);
    
    /* 顺序访问测试 */
    printf("\nRunning sequential access benchmark...\n");
    
    double seq_start = get_time_ms();
    for (size_t i = 0; i < test_size; i += PAGE_SIZE) {
        sum += data[i];
    }
    double seq_time = get_time_ms() - seq_start;
    
    int num_pages = test_size / PAGE_SIZE;
    printf("Sequential test:\n");
    printf("  Total time: %.2f ms\n", seq_time);
    printf("  Avg per page: %.2f us\n", seq_time * 1000 / num_pages);
    printf("  Bandwidth: %.2f MB/s\n", test_size / seq_time / 1000);
    
    /* 打印统计 */
    uffd_handler_print_stats(handler);
    bigcache_print_stats(ctx);
    
    /* 清理 */
    munmap(test_region, test_size);
    uffd_handler_stop(handler);
    uffd_handler_destroy(handler);
    bigcache_destroy(ctx);
    
    (void)sum;
    
    printf("\n=== Benchmark Complete ===\n\n");
    return 0;
}

/* 命令：模拟冷启动 */
static int cmd_simulate(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: bigcache simulate <bigcache.bin> <layout.csv>\n");
        fprintf(stderr, "\nSimulates cold start by replaying the IO sequence from layout.csv\n");
        return 1;
    }
    
    const char *bigcache_path = argv[0];
    const char *layout_path = argv[1];
    
    printf("\n=== Cold Start Simulation ===\n");
    printf("BigCache: %s\n", bigcache_path);
    printf("Layout: %s\n\n", layout_path);
    
    /* 方案一：传统方式（直接访问 BigCache 数据）*/
    printf("--- Method 1: Traditional Sequential Read ---\n");
    
    double trad_start = get_time_ms();
    
    BigCacheContext *ctx = bigcache_create();
    bigcache_load(ctx, bigcache_path);
    
    double load_time = get_time_ms() - trad_start;
    printf("BigCache load: %.2f ms\n", load_time);
    
    double preheat_start = get_time_ms();
    bigcache_preheat(ctx);
    double preheat_time = get_time_ms() - preheat_start;
    printf("Preheat: %.2f ms\n", preheat_time);
    
    double trad_total = get_time_ms() - trad_start;
    printf("Total (sequential read): %.2f ms\n\n", trad_total);
    
    /* 方案二：模拟随机访问 */
    printf("--- Method 2: Simulated Random Access (baseline) ---\n");
    
    /* 读取 layout 模拟随机访问 */
    FILE *fp = fopen(layout_path, "r");
    if (!fp) {
        perror("fopen layout");
        bigcache_destroy(ctx);
        return 1;
    }
    
    /* 跳过 header */
    char line[2048];
    fgets(line, sizeof(line), fp);
    
    /* 统计要访问的页数 */
    int page_count = 0;
    while (fgets(line, sizeof(line), fp)) {
        page_count++;
    }
    rewind(fp);
    fgets(line, sizeof(line), fp);  /* 跳过 header */
    
    printf("Pages to access: %d\n", page_count);
    
    /* 模拟随机访问（用 BigCache 的 lookup）*/
    double random_start = get_time_ms();
    
    int hits = 0;
    int misses = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        /* 解析行 */
        char *bc_offset_str = strtok(line, ",");
        char *source_file = strtok(NULL, ",");
        char *source_offset_str = strtok(NULL, ",");
        
        if (!bc_offset_str || !source_file || !source_offset_str) continue;
        
        uint64_t source_offset = strtoull(source_offset_str, NULL, 10);
        
        /* 查找 */
        void *data = bigcache_lookup(ctx, source_file, source_offset);
        if (data) {
            hits++;
            /* 模拟实际使用数据 */
            volatile uint8_t x = *(uint8_t*)data;
            (void)x;
        } else {
            misses++;
        }
    }
    
    double random_time = get_time_ms() - random_start;
    printf("Lookup time: %.2f ms\n", random_time);
    printf("Hits: %d, Misses: %d\n", hits, misses);
    printf("Hit rate: %.2f%%\n", (double)hits * 100 / (hits + misses));
    
    fclose(fp);
    
    /* 方案三：使用 UFFD 的方式 */
    printf("\n--- Method 3: UFFD Demand Paging ---\n");
    
    UffdHandler *handler = uffd_handler_create(ctx);
    uffd_handler_start(handler);
    
    /* 创建模拟映射区域 */
    size_t region_size = (size_t)page_count * PAGE_SIZE;
    void *region = uffd_handler_create_mapping(handler, region_size,
                                               "/simulated/app.so", 0,
                                               PROT_READ);
    
    if (region != MAP_FAILED) {
        double uffd_start = get_time_ms();
        
        /* 顺序触发缺页（模拟代码执行）*/
        volatile uint8_t sum = 0;
        uint8_t *ptr = (uint8_t*)region;
        for (int i = 0; i < page_count && i < 10000; i++) {  /* 限制数量 */
            sum += ptr[i * PAGE_SIZE];
        }
        
        double uffd_time = get_time_ms() - uffd_start;
        printf("UFFD demand paging time: %.2f ms\n", uffd_time);
        
        uffd_handler_print_stats(handler);
        
        munmap(region, region_size);
        (void)sum;
    } else {
        printf("Could not create UFFD mapping\n");
    }
    
    uffd_handler_stop(handler);
    uffd_handler_destroy(handler);
    
    /* 总结 */
    printf("\n=== Summary ===\n");
    printf("Traditional (sequential BigCache read): %.2f ms\n", trad_total);
    printf("Random lookup simulation: %.2f ms\n", random_time + load_time);
    printf("Speedup potential: %.1fx\n", 
           (random_time + load_time) / trad_total);
    printf("================\n\n");
    
    bigcache_destroy(ctx);
    return 0;
}

/* 使用说明 */
static void usage(const char *prog) {
    printf("BigCache - Userspace Demand Paging for Cold Start Optimization\n\n");
    printf("Usage: %s <command> [options]\n\n", prog);
    printf("Commands:\n");
    printf("  pack <layout.csv> <output.bin>    Pack pages into BigCache\n");
    printf("  verify <bigcache.bin>             Verify BigCache integrity\n");
    printf("  info <bigcache.bin>               Show BigCache information\n");
    printf("  benchmark <bigcache.bin> [iter]   Run performance benchmark\n");
    printf("  simulate <bigcache.bin> <layout>  Simulate cold start\n");
    printf("  help                              Show this help\n");
    printf("\nEnvironment variables:\n");
    printf("  BIGCACHE_PATH     Path to BigCache file (for preloader)\n");
    printf("  BIGCACHE_ENABLED  Enable/disable preloader (0/1)\n");
    printf("  BIGCACHE_VERBOSE  Verbose logging level (0-5)\n");
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }
    
    const char *cmd = argv[1];
    int cmd_argc = argc - 2;
    char **cmd_argv = argv + 2;
    
    if (strcmp(cmd, "pack") == 0) {
        return cmd_pack(cmd_argc, cmd_argv);
    } else if (strcmp(cmd, "verify") == 0) {
        return cmd_verify(cmd_argc, cmd_argv);
    } else if (strcmp(cmd, "info") == 0) {
        return cmd_info(cmd_argc, cmd_argv);
    } else if (strcmp(cmd, "benchmark") == 0) {
        return cmd_benchmark(cmd_argc, cmd_argv);
    } else if (strcmp(cmd, "simulate") == 0) {
        return cmd_simulate(cmd_argc, cmd_argv);
    } else if (strcmp(cmd, "help") == 0 || strcmp(cmd, "-h") == 0 ||
               strcmp(cmd, "--help") == 0) {
        usage(argv[0]);
        return 0;
    } else {
        fprintf(stderr, "Unknown command: %s\n\n", cmd);
        usage(argv[0]);
        return 1;
    }
}
