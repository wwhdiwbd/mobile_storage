/*
 * BigCache Tracer - 使用 ptrace 拦截应用的 IO 系统调用
 * 
 * 原理：
 * 1. 以 tracer 身份启动目标应用
 * 2. 拦截 pread64/read/mmap 等系统调用
 * 3. 如果读取的是热点文件的热点页，直接从 BigCache 返回数据
 * 4. 应用感知不到任何变化，但实际上读的是连续的 BigCache
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/user.h>
#include <sys/uio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <linux/ptrace.h>
#include <linux/elf.h>
#include <time.h>
#include <dirent.h>

/* ARM64 系统调用号 */
#define SYS_READ        63
#define SYS_PREAD64     67
#define SYS_OPENAT      56
#define SYS_MMAP        222

#define PAGE_SIZE 4096
#define MAX_PATH 512
#define MAX_FDS 1024
#define MAX_PAGES 100000

/* BigCache 文件头 */
#define BIGCACHE_MAGIC 0x42494743

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

typedef struct __attribute__((packed)) {
    uint32_t file_id;
    uint64_t source_offset;
    uint32_t access_order;
    uint16_t flags;
    uint16_t reserved;
} BigCachePageIndex;

/* 运行时状态 */
typedef struct {
    char path[MAX_PATH];
    int is_tracked;  /* 这个 fd 是否需要被拦截 */
    uint32_t file_id;
} FdInfo;

typedef struct {
    /* BigCache 映射 */
    void *bigcache_data;
    size_t bigcache_size;
    BigCacheHeader *header;
    BigCachePageIndex *index;
    char **file_names;
    
    /* fd 跟踪 */
    FdInfo fds[MAX_FDS];
    
    /* 统计 */
    uint64_t intercepted_reads;
    uint64_t bypassed_reads;
    uint64_t bytes_served;
    double total_time_us;
} TracerState;

static TracerState g_state = {0};

/* 时间函数 */
static double get_time_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000.0 + ts.tv_nsec / 1000.0;
}

/* FNV-1a 哈希 */
static uint64_t fnv1a_hash(const char *str) {
    uint64_t hash = 14695981039346656037ULL;
    while (*str) {
        hash ^= (uint8_t)*str++;
        hash *= 1099511628211ULL;
    }
    return hash;
}

/* 加载 BigCache */
static int load_bigcache(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror("open bigcache");
        return -1;
    }
    
    struct stat st;
    if (fstat(fd, &st) < 0) {
        perror("fstat");
        close(fd);
        return -1;
    }
    
    g_state.bigcache_size = st.st_size;
    g_state.bigcache_data = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    
    if (g_state.bigcache_data == MAP_FAILED) {
        perror("mmap bigcache");
        return -1;
    }
    
    g_state.header = (BigCacheHeader *)g_state.bigcache_data;
    
    if (g_state.header->magic != BIGCACHE_MAGIC) {
        fprintf(stderr, "Invalid BigCache magic\n");
        munmap(g_state.bigcache_data, g_state.bigcache_size);
        return -1;
    }
    
    g_state.index = (BigCachePageIndex *)((char *)g_state.bigcache_data + 
                                          g_state.header->index_offset);
    
    /* 解析文件名表 - 使用 BigCacheFileEntry 结构 */
    typedef struct __attribute__((packed)) {
        uint32_t file_id;
        uint32_t path_len;
        char     path[MAX_PATH];
        uint32_t total_pages;
        uint64_t original_size;
    } BigCacheFileEntry;
    
    g_state.file_names = calloc(g_state.header->num_files, sizeof(char *));
    BigCacheFileEntry *file_table = (BigCacheFileEntry *)((char *)g_state.bigcache_data + 
                                                          g_state.header->file_table_offset);
    
    for (uint32_t i = 0; i < g_state.header->num_files; i++) {
        g_state.file_names[i] = strndup(file_table[i].path, file_table[i].path_len);
    }
    
    printf("BigCache loaded: %u pages, %u files, %.2f MB\n",
           g_state.header->num_pages,
           g_state.header->num_files,
           (double)g_state.bigcache_size / (1024 * 1024));
    
    return 0;
}

/* 查找页面在 BigCache 中的位置 */
static void *find_page_in_bigcache(uint32_t file_id, uint64_t offset) {
    /* 简单线性搜索（可优化为哈希表）*/
    uint64_t page_offset = (offset / PAGE_SIZE) * PAGE_SIZE;
    
    for (uint32_t i = 0; i < g_state.header->num_pages; i++) {
        if (g_state.index[i].file_id == file_id &&
            g_state.index[i].source_offset == page_offset) {
            /* 计算 bigcache_offset: data_offset + i * PAGE_SIZE */
            uint64_t bigcache_offset = g_state.header->data_offset + (uint64_t)i * PAGE_SIZE;
            return (char *)g_state.bigcache_data + bigcache_offset;
        }
    }
    
    return NULL;
}

/* 检查文件是否需要跟踪 */
static int check_file_tracked(const char *path, uint32_t *file_id) {
    for (uint32_t i = 0; i < g_state.header->num_files; i++) {
        if (strstr(path, g_state.file_names[i]) != NULL ||
            strcmp(path, g_state.file_names[i]) == 0) {
            *file_id = i;
            return 1;
        }
    }
    return 0;
}

/* 读取 tracee 的寄存器 */
static int get_regs(pid_t pid, struct user_regs_struct *regs) {
    struct iovec iov = {
        .iov_base = regs,
        .iov_len = sizeof(*regs)
    };
    return ptrace(PTRACE_GETREGSET, pid, NT_PRSTATUS, &iov);
}

/* 设置 tracee 的寄存器 */
static int set_regs(pid_t pid, struct user_regs_struct *regs) {
    struct iovec iov = {
        .iov_base = regs,
        .iov_len = sizeof(*regs)
    };
    return ptrace(PTRACE_SETREGSET, pid, NT_PRSTATUS, &iov);
}

/* 读取 tracee 内存 */
static ssize_t read_mem(pid_t pid, void *local, void *remote, size_t len) {
    struct iovec local_iov = { local, len };
    struct iovec remote_iov = { remote, len };
    return process_vm_readv(pid, &local_iov, 1, &remote_iov, 1, 0);
}

/* 写入 tracee 内存 */
static ssize_t write_mem(pid_t pid, void *local, void *remote, size_t len) {
    struct iovec local_iov = { local, len };
    struct iovec remote_iov = { remote, len };
    return process_vm_writev(pid, &local_iov, 1, &remote_iov, 1, 0);
}

/* 获取 fd 对应的文件路径 */
static int get_fd_path(pid_t pid, int fd, char *path, size_t path_len) {
    char proc_path[64];
    snprintf(proc_path, sizeof(proc_path), "/proc/%d/fd/%d", pid, fd);
    
    ssize_t len = readlink(proc_path, path, path_len - 1);
    if (len < 0) return -1;
    
    path[len] = '\0';
    return 0;
}

/* 处理 openat 系统调用 */
static void handle_openat(pid_t pid, struct user_regs_struct *regs, int is_exit) {
    if (!is_exit) return;
    
    /* x0 是返回值（fd）*/
    int fd = (int)regs->regs[0];
    if (fd < 0 || fd >= MAX_FDS) return;
    
    char path[MAX_PATH];
    if (get_fd_path(pid, fd, path, sizeof(path)) < 0) return;
    
    uint32_t file_id;
    if (check_file_tracked(path, &file_id)) {
        g_state.fds[fd].is_tracked = 1;
        g_state.fds[fd].file_id = file_id;
        strncpy(g_state.fds[fd].path, path, MAX_PATH - 1);
        /* printf("  TRACK fd=%d path=%s\n", fd, path); */
    }
}

/* 处理 pread64 系统调用 */
static void handle_pread64(pid_t pid, struct user_regs_struct *regs, int is_exit) {
    /* ARM64: x0=fd, x1=buf, x2=count, x3=offset */
    int fd = (int)regs->regs[0];
    void *buf = (void *)regs->regs[1];
    size_t count = (size_t)regs->regs[2];
    off_t offset = (off_t)regs->regs[3];
    
    if (fd < 0 || fd >= MAX_FDS || !g_state.fds[fd].is_tracked) {
        g_state.bypassed_reads++;
        return;
    }
    
    if (is_exit) {
        /* 检查原始调用是否成功 */
        ssize_t result = (ssize_t)regs->regs[0];
        if (result <= 0) return;
        
        /* 查找 BigCache 中的数据 */
        double start = get_time_us();
        
        void *cached_data = find_page_in_bigcache(g_state.fds[fd].file_id, offset);
        if (cached_data) {
            /* 计算页内偏移 */
            size_t page_offset = offset % PAGE_SIZE;
            size_t to_copy = PAGE_SIZE - page_offset;
            if (to_copy > count) to_copy = count;
            if (to_copy > (size_t)result) to_copy = result;
            
            /* 将 BigCache 数据写入 tracee 的缓冲区 */
            write_mem(pid, (char *)cached_data + page_offset, buf, to_copy);
            
            g_state.intercepted_reads++;
            g_state.bytes_served += to_copy;
            g_state.total_time_us += get_time_us() - start;
        } else {
            g_state.bypassed_reads++;
        }
    }
}

/* 处理 read 系统调用（类似 pread64）*/
static void handle_read(pid_t pid, struct user_regs_struct *regs, int is_exit) {
    /* 简化：read 不处理，因为我们主要关心 pread64 */
    g_state.bypassed_reads++;
}

/* 主跟踪循环 */
static int trace_process(pid_t pid) {
    int status;
    int in_syscall = 0;
    struct user_regs_struct regs;
    
    /* 等待初始停止 */
    waitpid(pid, &status, 0);
    
    /* 设置 ptrace 选项 */
    ptrace(PTRACE_SETOPTIONS, pid, 0, 
           PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACEFORK | 
           PTRACE_O_TRACEVFORK | PTRACE_O_TRACECLONE);
    
    printf("Tracing PID %d...\n", pid);
    
    while (1) {
        /* 继续执行到下一个系统调用 */
        if (ptrace(PTRACE_SYSCALL, pid, 0, 0) < 0) {
            if (errno == ESRCH) break;  /* 进程已退出 */
            perror("ptrace syscall");
            break;
        }
        
        if (waitpid(pid, &status, 0) < 0) {
            perror("waitpid");
            break;
        }
        
        if (WIFEXITED(status) || WIFSIGNALED(status)) {
            printf("Process exited\n");
            break;
        }
        
        if (!WIFSTOPPED(status)) continue;
        
        int sig = WSTOPSIG(status);
        if (sig != (SIGTRAP | 0x80)) {
            /* 不是系统调用停止，转发信号 */
            ptrace(PTRACE_SYSCALL, pid, 0, sig);
            continue;
        }
        
        /* 获取寄存器 */
        if (get_regs(pid, &regs) < 0) continue;
        
        /* ARM64: x8 是系统调用号 */
        int syscall_nr = regs.regs[8];
        
        switch (syscall_nr) {
            case SYS_OPENAT:
                handle_openat(pid, &regs, in_syscall);
                break;
            case SYS_PREAD64:
                handle_pread64(pid, &regs, in_syscall);
                break;
            case SYS_READ:
                handle_read(pid, &regs, in_syscall);
                break;
        }
        
        in_syscall = !in_syscall;
    }
    
    return 0;
}

/* 打印统计信息 */
static void print_stats(void) {
    printf("\n=== Tracer Statistics ===\n");
    printf("Intercepted reads: %lu\n", g_state.intercepted_reads);
    printf("Bypassed reads: %lu\n", g_state.bypassed_reads);
    printf("Bytes served from BigCache: %.2f MB\n", 
           (double)g_state.bytes_served / (1024 * 1024));
    printf("Total intercept time: %.2f ms\n", g_state.total_time_us / 1000);
    if (g_state.intercepted_reads > 0) {
        printf("Avg intercept time: %.2f us\n", 
               g_state.total_time_us / g_state.intercepted_reads);
    }
    printf("=========================\n");
}

static void print_usage(const char *prog) {
    printf("Usage: %s <bigcache.bin> -- <command> [args...]\n", prog);
    printf("       %s <bigcache.bin> -p <pid>\n", prog);
    printf("\nExample:\n");
    printf("  %s /data/local/tmp/bigcache.bin -- am start tv.danmaku.bili\n", prog);
    printf("  %s /data/local/tmp/bigcache.bin -p 12345\n", prog);
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        print_usage(argv[0]);
        return 1;
    }
    
    const char *bigcache_path = argv[1];
    
    /* 加载 BigCache */
    printf("Loading BigCache: %s\n", bigcache_path);
    if (load_bigcache(bigcache_path) < 0) {
        return 1;
    }
    
    pid_t target_pid = 0;
    
    if (strcmp(argv[2], "-p") == 0 && argc >= 4) {
        /* Attach 到已有进程 */
        target_pid = atoi(argv[3]);
        
        if (ptrace(PTRACE_ATTACH, target_pid, 0, 0) < 0) {
            perror("ptrace attach");
            return 1;
        }
        
        printf("Attached to PID %d\n", target_pid);
    } else if (strcmp(argv[2], "--") == 0 && argc >= 4) {
        /* Fork 并执行命令 */
        target_pid = fork();
        
        if (target_pid == 0) {
            /* 子进程 */
            ptrace(PTRACE_TRACEME, 0, 0, 0);
            raise(SIGSTOP);
            execvp(argv[3], &argv[3]);
            perror("execvp");
            exit(1);
        } else if (target_pid < 0) {
            perror("fork");
            return 1;
        }
        
        printf("Started process PID %d\n", target_pid);
    } else {
        print_usage(argv[0]);
        return 1;
    }
    
    /* 开始跟踪 */
    trace_process(target_pid);
    
    /* 打印统计 */
    print_stats();
    
    /* 清理 */
    if (g_state.bigcache_data) {
        munmap(g_state.bigcache_data, g_state.bigcache_size);
    }
    
    return 0;
}
