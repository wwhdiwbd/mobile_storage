adb shell "echo > /sys/kernel/tracing/trace"
adb shell "echo 1 > /sys/kernel/tracing/events/syscalls/sys_enter_openat/enable"
adb shell "echo 1 > /sys/kernel/tracing/events/syscalls/sys_exit_openat/enable"
adb shell "echo 1 > /sys/kernel/tracing/events/syscalls/sys_enter_read/enable"
adb shell "echo 1 > /sys/kernel/tracing/events/syscalls/sys_enter_pread64/enable"
# 关键：开启文件映射监控
adb shell "echo 1 > /sys/kernel/tracing/events/filemap/mm_filemap_add_to_page_cache/enable"

# ... 执行你的启动 ...

adb shell "cat /sys/kernel/tracing/trace" > /sdcard/io_order.txt