/*
 * 文件预热工具
 * 
 * 原理：按照 IO trace 顺序读取真实文件，将数据预热到系统页缓存。
 * 当应用启动时，这些页面已经在页缓存中，实现"免费"加速。
 * 
 * 这是最简单有效的方案，无需 LD_PRELOAD，无需修改应用。
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <errno.h>

#define PAGE_SIZE 4096
#define MAX_PATH 512
#define MAX_FILES 1024
#define MAX_PAGES 100000

typedef struct {
    char path[MAX_PATH];
    int fd;
    off_t size;
} FileEntry;

typedef struct {
    char path[MAX_PATH];
    off_t offset;
    int order;
} PageEntry;

static FileEntry g_files[MAX_FILES];
static int g_file_count = 0;

static PageEntry g_pages[MAX_PAGES];
static int g_page_count = 0;

/* 获取时间（毫秒）*/
static double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

/* 打开文件（缓存 fd）*/
static int open_file(const char *path) {
    /* 检查是否已打开 */
    for (int i = 0; i < g_file_count; i++) {
        if (strcmp(g_files[i].path, path) == 0) {
            return g_files[i].fd;
        }
    }
    
    /* 打开新文件 */
    if (g_file_count >= MAX_FILES) {
        return -1;
    }
    
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    
    struct stat st;
    if (fstat(fd, &st) < 0) {
        close(fd);
        return -1;
    }
    
    strncpy(g_files[g_file_count].path, path, MAX_PATH - 1);
    g_files[g_file_count].fd = fd;
    g_files[g_file_count].size = st.st_size;
    g_file_count++;
    
    return fd;
}

/* 关闭所有文件 */
static void close_all_files(void) {
    for (int i = 0; i < g_file_count; i++) {
        close(g_files[i].fd);
    }
    g_file_count = 0;
}

/* 解析 CSV 行 */
static int parse_csv_line(const char *line, PageEntry *entry) {
    /* 格式: bigcache_offset,source_file,source_offset,first_access_order */
    char *buf = strdup(line);
    if (!buf) return -1;
    
    char *token;
    int field = 0;
    char *saveptr;
    
    token = strtok_r(buf, ",", &saveptr);
    while (token && field < 4) {
        switch (field) {
            case 0: /* bigcache_offset - 跳过 */
                break;
            case 1: /* source_file */
                strncpy(entry->path, token, MAX_PATH - 1);
                break;
            case 2: /* source_offset */
                entry->offset = atoll(token);
                break;
            case 3: /* first_access_order */
                entry->order = atoi(token);
                break;
        }
        field++;
        token = strtok_r(NULL, ",", &saveptr);
    }
    
    free(buf);
    return (field >= 4) ? 0 : -1;
}

/* 加载 CSV 布局文件 */
static int load_layout(const char *csv_path) {
    FILE *fp = fopen(csv_path, "r");
    if (!fp) {
        fprintf(stderr, "Cannot open layout file: %s\n", csv_path);
        return -1;
    }
    
    char line[1024];
    int line_num = 0;
    
    while (fgets(line, sizeof(line), fp) && g_page_count < MAX_PAGES) {
        line_num++;
        
        /* 跳过标题行 */
        if (line_num == 1) continue;
        
        /* 移除换行符 */
        line[strcspn(line, "\r\n")] = 0;
        
        if (parse_csv_line(line, &g_pages[g_page_count]) == 0) {
            g_page_count++;
        }
    }
    
    fclose(fp);
    printf("Loaded %d pages from layout\n", g_page_count);
    return g_page_count;
}

/* 预热单个页面 */
static int preheat_page(const PageEntry *entry) {
    int fd = open_file(entry->path);
    if (fd < 0) {
        return -1;
    }
    
    /* 使用 posix_fadvise 告诉内核我们即将读取这个区域 */
    posix_fadvise(fd, entry->offset, PAGE_SIZE, POSIX_FADV_WILLNEED);
    
    /* 实际读取一个字节来确保页面被加载 */
    char buf;
    if (pread(fd, &buf, 1, entry->offset) != 1) {
        return -1;
    }
    
    return 0;
}

/* 预热所有页面（按访问顺序）*/
static int preheat_all(int verbose) {
    int success = 0;
    int failed = 0;
    
    double start = get_time_ms();
    double last_report = start;
    
    for (int i = 0; i < g_page_count; i++) {
        if (preheat_page(&g_pages[i]) == 0) {
            success++;
        } else {
            failed++;
            if (verbose && failed <= 10) {
                fprintf(stderr, "  Failed: %s @ %ld\n", 
                       g_pages[i].path, (long)g_pages[i].offset);
            }
        }
        
        /* 进度报告 */
        double now = get_time_ms();
        if (now - last_report > 500 || i == g_page_count - 1) {
            double elapsed = now - start;
            double mb_done = (double)success * PAGE_SIZE / (1024 * 1024);
            double speed = mb_done / (elapsed / 1000);
            printf("\r  Progress: %d/%d pages (%.1f MB), %.1f MB/s    ", 
                   i + 1, g_page_count, mb_done, speed);
            fflush(stdout);
            last_report = now;
        }
    }
    
    double elapsed = get_time_ms() - start;
    printf("\n");
    printf("Preheated: %d pages (%.2f MB) in %.2f ms\n", 
           success, (double)success * PAGE_SIZE / (1024 * 1024), elapsed);
    printf("Failed: %d pages\n", failed);
    printf("Speed: %.2f MB/s\n", 
           (double)success * PAGE_SIZE / (1024 * 1024) / (elapsed / 1000));
    
    return success;
}

/* 使用 mmap + madvise 方式预热（更高效）*/
static int preheat_all_mmap(int verbose) {
    int success = 0;
    int failed = 0;
    
    double start = get_time_ms();
    
    printf("Preheating using mmap + madvise...\n");
    
    /* 按文件分组预热，减少系统调用 */
    for (int i = 0; i < g_file_count; i++) {
        FileEntry *fe = &g_files[i];
        
        /* mmap 整个文件 */
        void *addr = mmap(NULL, fe->size, PROT_READ, MAP_PRIVATE, fe->fd, 0);
        if (addr == MAP_FAILED) {
            fprintf(stderr, "mmap failed for %s: %s\n", fe->path, strerror(errno));
            failed++;
            continue;
        }
        
        /* 告诉内核我们会顺序访问 */
        madvise(addr, fe->size, MADV_SEQUENTIAL);
        madvise(addr, fe->size, MADV_WILLNEED);
        
        /* 触摸每个页面 */
        volatile char sum = 0;
        for (off_t off = 0; off < fe->size; off += PAGE_SIZE) {
            sum += ((char*)addr)[off];
            success++;
        }
        
        munmap(addr, fe->size);
        
        if (verbose) {
            printf("  %s: %.2f MB\n", fe->path, (double)fe->size / (1024 * 1024));
        }
    }
    
    double elapsed = get_time_ms() - start;
    printf("Preheated: %d pages in %.2f ms\n", success, elapsed);
    printf("Speed: %.2f MB/s\n", 
           (double)success * PAGE_SIZE / (1024 * 1024) / (elapsed / 1000));
    
    return success;
}

static void print_usage(const char *prog) {
    printf("Usage: %s <layout.csv> [options]\n", prog);
    printf("\nOptions:\n");
    printf("  -v          Verbose output\n");
    printf("  -m          Use mmap mode (faster)\n");
    printf("  -n <count>  Only preheat first N pages\n");
    printf("\nExample:\n");
    printf("  %s /data/local/tmp/layout.csv\n", prog);
    printf("  %s /data/local/tmp/layout.csv -m -v\n", prog);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }
    
    const char *layout_path = argv[1];
    int verbose = 0;
    int use_mmap = 0;
    int max_pages = MAX_PAGES;
    
    /* 解析参数 */
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0) {
            verbose = 1;
        } else if (strcmp(argv[i], "-m") == 0) {
            use_mmap = 1;
        } else if (strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
            max_pages = atoi(argv[++i]);
        }
    }
    
    printf("=== File Preheat Tool ===\n");
    printf("Layout: %s\n", layout_path);
    
    /* 加载布局 */
    if (load_layout(layout_path) < 0) {
        return 1;
    }
    
    if (g_page_count > max_pages) {
        g_page_count = max_pages;
        printf("Limited to first %d pages\n", max_pages);
    }
    
    /* 先打开所有需要的文件 */
    printf("Opening files...\n");
    for (int i = 0; i < g_page_count; i++) {
        open_file(g_pages[i].path);
    }
    printf("Opened %d unique files\n", g_file_count);
    
    /* 预热 */
    printf("\nPreheating pages to page cache...\n");
    
    double start = get_time_ms();
    int count;
    
    if (use_mmap) {
        count = preheat_all_mmap(verbose);
    } else {
        count = preheat_all(verbose);
    }
    
    double total_time = get_time_ms() - start;
    
    printf("\n=== Preheat Complete ===\n");
    printf("Total time: %.2f ms\n", total_time);
    printf("Pages in cache: %d (%.2f MB)\n", 
           count, (double)count * PAGE_SIZE / (1024 * 1024));
    printf("========================\n");
    
    /* 清理 */
    close_all_files();
    
    return 0;
}
