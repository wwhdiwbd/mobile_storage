/**
 * BigCache 生成工具 - Android 设备端
 * 
 * 在 Android 设备上运行，从真实文件读取数据生成 BigCache.bin
 * 这样 BigCache 包含的是真实的文件内容，而不是模拟数据
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <errno.h>
#include <time.h>

/* 常量 */
#define PAGE_SIZE 4096
#define BIGCACHE_MAGIC 0x42494743  /* "BIGC" */
#define BIGCACHE_VERSION 1
#define MAX_PATH_LEN 512
#define MAX_FILES 2000
#define MAX_PAGES 100000

/* BigCache 头部结构 */
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t version;
    uint32_t num_pages;
    uint32_t num_files;
    uint64_t data_offset;
    uint64_t index_offset;
    uint64_t file_table_offset;
    uint64_t total_size;
    uint32_t checksum;
    uint8_t  reserved[32];
} BigCacheHeader;

/* 页面索引结构 */
typedef struct __attribute__((packed)) {
    uint32_t file_id;
    uint64_t source_offset;
    uint32_t access_order;
    uint16_t flags;
    uint16_t reserved;
} BigCachePageIndex;

/* 文件表条目结构 */
typedef struct __attribute__((packed)) {
    uint32_t file_id;
    uint32_t path_len;
    char     path[MAX_PATH_LEN];
    uint32_t total_pages;
    uint64_t original_size;
} BigCacheFileEntry;

/* 内存中的页面条目 */
typedef struct {
    char     file_path[MAX_PATH_LEN];
    uint64_t source_offset;
    uint32_t access_order;
    uint32_t file_id;
    uint64_t bigcache_offset;
} PageEntry;

/* 内存中的文件条目 */
typedef struct {
    char     path[MAX_PATH_LEN];
    uint32_t file_id;
    uint32_t total_pages;
    uint64_t original_size;
} FileEntry;

/* 全局数据 */
static PageEntry g_pages[MAX_PAGES];
static int g_num_pages = 0;

static FileEntry g_files[MAX_FILES];
static int g_num_files = 0;

/* 查找或添加文件 */
static int find_or_add_file(const char *path) {
    /* 查找现有文件 */
    for (int i = 0; i < g_num_files; i++) {
        if (strcmp(g_files[i].path, path) == 0) {
            return g_files[i].file_id;
        }
    }
    
    /* 添加新文件 */
    if (g_num_files >= MAX_FILES) {
        fprintf(stderr, "Error: too many files (max %d)\n", MAX_FILES);
        return -1;
    }
    
    FileEntry *f = &g_files[g_num_files];
    strncpy(f->path, path, MAX_PATH_LEN - 1);
    f->path[MAX_PATH_LEN - 1] = '\0';
    f->file_id = g_num_files;
    f->total_pages = 0;
    f->original_size = 0;
    
    /* 获取文件大小 */
    struct stat st;
    if (stat(path, &st) == 0) {
        f->original_size = st.st_size;
    }
    
    return g_num_files++;
}

/* 检查页面是否已存在（去重） */
static int page_exists(const char *path, uint64_t offset) {
    for (int i = 0; i < g_num_pages; i++) {
        if (g_pages[i].source_offset == offset &&
            strcmp(g_pages[i].file_path, path) == 0) {
            return 1;
        }
    }
    return 0;
}

/* 添加页面 */
static int add_page(const char *file_path, uint64_t offset, uint32_t access_order) {
    /* 页对齐 */
    uint64_t page_offset = (offset / PAGE_SIZE) * PAGE_SIZE;
    
    /* 检查重复 */
    if (page_exists(file_path, page_offset)) {
        return 0;  /* 已存在 */
    }
    
    if (g_num_pages >= MAX_PAGES) {
        fprintf(stderr, "Error: too many pages (max %d)\n", MAX_PAGES);
        return -1;
    }
    
    /* 查找或添加文件 */
    int file_id = find_or_add_file(file_path);
    if (file_id < 0) return -1;
    
    /* 添加页面 */
    PageEntry *p = &g_pages[g_num_pages];
    strncpy(p->file_path, file_path, MAX_PATH_LEN - 1);
    p->file_path[MAX_PATH_LEN - 1] = '\0';
    p->source_offset = page_offset;
    p->access_order = access_order;
    p->file_id = file_id;
    
    g_files[file_id].total_pages++;
    g_num_pages++;
    
    return 1;
}

/* 从 CSV 加载布局 */
static int load_layout_csv(const char *csv_path) {
    FILE *fp = fopen(csv_path, "r");
    if (!fp) {
        fprintf(stderr, "Error: cannot open CSV file %s: %s\n", 
                csv_path, strerror(errno));
        return -1;
    }
    
    char line[2048];  /* 增大缓冲区以容纳长路径 */
    int line_num = 0;
    int loaded = 0;
    
    /* 跳过头部 */
    if (fgets(line, sizeof(line), fp) == NULL) {
        fclose(fp);
        return 0;
    }
    
    while (fgets(line, sizeof(line), fp)) {
        line_num++;
        
        /* 解析 CSV: bigcache_offset,source_file,source_offset,size,first_access_order */
        char *bigcache_offset_str = strtok(line, ",");
        char *source_file = strtok(NULL, ",");
        char *offset_str = strtok(NULL, ",");
        char *size_str = strtok(NULL, ",");
        char *order_str = strtok(NULL, ",\n");
        
        (void)bigcache_offset_str;  /* 不使用 */
        (void)size_str;  /* 不使用 */
        
        if (!source_file || !offset_str || !order_str) {
            fprintf(stderr, "Warning: skipping malformed line %d\n", line_num);
            continue;
        }
        
        uint64_t offset = strtoull(offset_str, NULL, 10);
        uint32_t order = (uint32_t)strtoul(order_str, NULL, 10);
        
        /* 检查文件是否存在 */
        if (access(source_file, R_OK) != 0) {
            fprintf(stderr, "Warning: file not readable: %s\n", source_file);
            continue;
        }
        
        int ret = add_page(source_file, offset, order);
        if (ret > 0) loaded++;
    }
    
    fclose(fp);
    
    printf("Loaded %d pages from %s\n", loaded, csv_path);
    printf("Total files: %d\n", g_num_files);
    
    return loaded;
}

/* 从文件列表加载（每行一个文件路径）- 读取整个文件 */
static int load_file_list(const char *list_path) {
    FILE *fp = fopen(list_path, "r");
    if (!fp) {
        fprintf(stderr, "Error: cannot open file list %s: %s\n", 
                list_path, strerror(errno));
        return -1;
    }
    
    char line[1024];
    int loaded = 0;
    uint32_t order = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        /* 去除换行符 */
        line[strcspn(line, "\r\n")] = '\0';
        
        if (strlen(line) == 0) continue;
        
        /* 检查文件是否存在 */
        struct stat st;
        if (stat(line, &st) != 0) {
            fprintf(stderr, "Warning: cannot stat %s: %s\n", line, strerror(errno));
            continue;
        }
        
        /* 添加文件的所有页面 */
        uint64_t file_size = st.st_size;
        uint64_t offset = 0;
        
        while (offset < file_size) {
            int ret = add_page(line, offset, order++);
            if (ret > 0) loaded++;
            offset += PAGE_SIZE;
        }
    }
    
    fclose(fp);
    
    printf("Loaded %d pages from file list %s\n", loaded, list_path);
    printf("Total files: %d\n", g_num_files);
    
    return loaded;
}

/* 计算布局 */
static void calculate_layout(uint64_t *header_size, uint64_t *index_offset,
                             uint64_t *file_table_offset, uint64_t *data_offset,
                             uint64_t *total_size) {
    *header_size = sizeof(BigCacheHeader);
    *index_offset = *header_size;
    
    uint64_t index_size = g_num_pages * sizeof(BigCachePageIndex);
    *file_table_offset = *index_offset + index_size;
    
    uint64_t file_table_size = g_num_files * sizeof(BigCacheFileEntry);
    
    /* 数据偏移页对齐 */
    uint64_t meta_size = *file_table_offset + file_table_size;
    *data_offset = ((meta_size + PAGE_SIZE - 1) / PAGE_SIZE) * PAGE_SIZE;
    
    *total_size = *data_offset + (uint64_t)g_num_pages * PAGE_SIZE;
}

/* 读取源文件的一个页面 */
static int read_source_page(const char *path, uint64_t offset, uint8_t *buffer) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        /* 文件无法打开，填充零 */
        memset(buffer, 0, PAGE_SIZE);
        return -1;
    }
    
    /* 定位并读取 */
    if (lseek(fd, offset, SEEK_SET) < 0) {
        close(fd);
        memset(buffer, 0, PAGE_SIZE);
        return -1;
    }
    
    ssize_t n = read(fd, buffer, PAGE_SIZE);
    close(fd);
    
    if (n < 0) {
        memset(buffer, 0, PAGE_SIZE);
        return -1;
    }
    
    /* 如果读取不足一页，填充零 */
    if (n < PAGE_SIZE) {
        memset(buffer + n, 0, PAGE_SIZE - n);
    }
    
    return 0;
}

/* 生成 BigCache 文件 */
static int generate_bigcache(const char *output_path) {
    uint64_t header_size, index_offset, file_table_offset, data_offset, total_size;
    calculate_layout(&header_size, &index_offset, &file_table_offset, 
                     &data_offset, &total_size);
    
    printf("\n=== Generating BigCache ===\n");
    printf("Pages: %d\n", g_num_pages);
    printf("Files: %d\n", g_num_files);
    printf("Header size: %lu bytes\n", (unsigned long)header_size);
    printf("Index offset: %lu\n", (unsigned long)index_offset);
    printf("File table offset: %lu\n", (unsigned long)file_table_offset);
    printf("Data offset: %lu\n", (unsigned long)data_offset);
    printf("Total size: %.2f MB\n", total_size / 1024.0 / 1024.0);
    
    /* 创建输出文件 */
    int fd = open(output_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "Error: cannot create output file %s: %s\n",
                output_path, strerror(errno));
        return -1;
    }
    
    /* 预分配空间 */
    if (ftruncate(fd, total_size) < 0) {
        fprintf(stderr, "Error: cannot allocate space: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    
    /* 写入头部 */
    BigCacheHeader header = {
        .magic = BIGCACHE_MAGIC,
        .version = BIGCACHE_VERSION,
        .num_pages = g_num_pages,
        .num_files = g_num_files,
        .data_offset = data_offset,
        .index_offset = index_offset,
        .file_table_offset = file_table_offset,
        .total_size = total_size,
        .checksum = 0
    };
    memset(header.reserved, 0, sizeof(header.reserved));
    
    if (write(fd, &header, sizeof(header)) != sizeof(header)) {
        fprintf(stderr, "Error: failed to write header\n");
        close(fd);
        return -1;
    }
    
    /* 写入索引表 */
    lseek(fd, index_offset, SEEK_SET);
    for (int i = 0; i < g_num_pages; i++) {
        g_pages[i].bigcache_offset = data_offset + (uint64_t)i * PAGE_SIZE;
        
        BigCachePageIndex idx = {
            .file_id = g_pages[i].file_id,
            .source_offset = g_pages[i].source_offset,
            .access_order = g_pages[i].access_order,
            .flags = 0,
            .reserved = 0
        };
        
        if (write(fd, &idx, sizeof(idx)) != sizeof(idx)) {
            fprintf(stderr, "Error: failed to write index entry %d\n", i);
            close(fd);
            return -1;
        }
    }
    
    /* 写入文件表 */
    lseek(fd, file_table_offset, SEEK_SET);
    for (int i = 0; i < g_num_files; i++) {
        BigCacheFileEntry entry = {
            .file_id = g_files[i].file_id,
            .path_len = strlen(g_files[i].path),
            .total_pages = g_files[i].total_pages,
            .original_size = g_files[i].original_size
        };
        memset(entry.path, 0, MAX_PATH_LEN);
        strncpy(entry.path, g_files[i].path, MAX_PATH_LEN - 1);
        
        if (write(fd, &entry, sizeof(entry)) != sizeof(entry)) {
            fprintf(stderr, "Error: failed to write file entry %d\n", i);
            close(fd);
            return -1;
        }
    }
    
    /* 写入数据 - 从真实文件读取 */
    printf("\nReading file contents...\n");
    
    uint8_t *page_buffer = malloc(PAGE_SIZE);
    if (!page_buffer) {
        fprintf(stderr, "Error: cannot allocate page buffer\n");
        close(fd);
        return -1;
    }
    
    lseek(fd, data_offset, SEEK_SET);
    
    int read_errors = 0;
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    
    for (int i = 0; i < g_num_pages; i++) {
        /* 从源文件读取真实数据 */
        if (read_source_page(g_pages[i].file_path, 
                             g_pages[i].source_offset, 
                             page_buffer) < 0) {
            read_errors++;
        }
        
        /* 写入 BigCache */
        if (write(fd, page_buffer, PAGE_SIZE) != PAGE_SIZE) {
            fprintf(stderr, "Error: failed to write page data %d\n", i);
            free(page_buffer);
            close(fd);
            return -1;
        }
        
        /* 进度报告 */
        if ((i + 1) % 5000 == 0 || i == g_num_pages - 1) {
            printf("  Progress: %d/%d pages (%.1f%%)\n", 
                   i + 1, g_num_pages, (i + 1) * 100.0 / g_num_pages);
        }
    }
    
    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) + 
                     (end.tv_nsec - start.tv_nsec) / 1e9;
    
    free(page_buffer);
    close(fd);
    
    printf("\n=== BigCache Generated ===\n");
    printf("Output: %s\n", output_path);
    printf("Size: %.2f MB\n", total_size / 1024.0 / 1024.0);
    printf("Time: %.2f seconds\n", elapsed);
    printf("Speed: %.2f MB/s\n", (total_size / 1024.0 / 1024.0) / elapsed);
    if (read_errors > 0) {
        printf("Warning: %d pages could not be read (filled with zeros)\n", read_errors);
    }
    
    /* 同步到磁盘 */
    sync();
    
    return 0;
}

/* 打印使用帮助 */
static void print_usage(const char *prog) {
    printf("BigCache Generator for Android\n");
    printf("\nUsage:\n");
    printf("  %s -c <layout.csv> -o <output.bin>   Generate from CSV layout\n", prog);
    printf("  %s -l <file_list.txt> -o <output.bin> Generate from file list\n", prog);
    printf("\nOptions:\n");
    printf("  -c <csv>    CSV layout file (source_file,source_offset,first_access_order)\n");
    printf("  -l <list>   File list (one file path per line, reads entire files)\n");
    printf("  -o <file>   Output BigCache file (default: bigcache.bin)\n");
    printf("  -h          Show this help\n");
    printf("\nExamples:\n");
    printf("  # Generate from CSV layout (recommended for cold start optimization):\n");
    printf("  %s -c /data/local/tmp/layout.csv -o /data/local/tmp/bigcache.bin\n", prog);
    printf("\n  # Generate from file list (reads entire files):\n");
    printf("  %s -l /data/local/tmp/files.txt -o /data/local/tmp/bigcache.bin\n", prog);
}

int main(int argc, char *argv[]) {
    const char *csv_path = NULL;
    const char *list_path = NULL;
    const char *output_path = "bigcache.bin";
    
    int opt;
    while ((opt = getopt(argc, argv, "c:l:o:h")) != -1) {
        switch (opt) {
            case 'c':
                csv_path = optarg;
                break;
            case 'l':
                list_path = optarg;
                break;
            case 'o':
                output_path = optarg;
                break;
            case 'h':
            default:
                print_usage(argv[0]);
                return opt == 'h' ? 0 : 1;
        }
    }
    
    if (!csv_path && !list_path) {
        fprintf(stderr, "Error: must specify -c (CSV) or -l (file list)\n");
        print_usage(argv[0]);
        return 1;
    }
    
    printf("=== BigCache Generator ===\n");
    printf("Output: %s\n\n", output_path);
    
    /* 加载布局 */
    int loaded = 0;
    if (csv_path) {
        loaded = load_layout_csv(csv_path);
    } else if (list_path) {
        loaded = load_file_list(list_path);
    }
    
    if (loaded <= 0) {
        fprintf(stderr, "Error: no pages loaded\n");
        return 1;
    }
    
    /* 生成 BigCache */
    if (generate_bigcache(output_path) < 0) {
        fprintf(stderr, "Error: failed to generate BigCache\n");
        return 1;
    }
    
    return 0;
}
