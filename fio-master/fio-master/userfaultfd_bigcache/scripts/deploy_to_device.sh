#!/bin/bash
# Android 设备部署脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../build"
DEVICE_DIR="/data/local/tmp/bigcache"

echo "=== BigCache Android Deployment ==="

# 检查 adb
if ! command -v adb &> /dev/null; then
    echo "Error: adb not found. Please install Android SDK platform-tools."
    exit 1
fi

# 检查设备连接
if ! adb devices | grep -q "device$"; then
    echo "Error: No Android device connected."
    exit 1
fi

# 检查 root
echo "Checking root access..."
if ! adb shell "su -c 'id'" 2>/dev/null | grep -q "uid=0"; then
    echo "Warning: Device may not have root access."
    echo "UFFD features may not work without root."
fi

# 创建设备目录
echo "Creating device directory..."
adb shell "mkdir -p ${DEVICE_DIR}"

# 推送二进制文件
echo "Pushing binaries..."

if [ -f "${BUILD_DIR}/android/libs/arm64-v8a/bigcache" ]; then
    adb push "${BUILD_DIR}/android/libs/arm64-v8a/bigcache" "${DEVICE_DIR}/"
    adb shell "chmod 755 ${DEVICE_DIR}/bigcache"
    echo "  Pushed: bigcache"
else
    echo "  Warning: bigcache binary not found"
fi

if [ -f "${BUILD_DIR}/android/libs/arm64-v8a/libpreloader.so" ]; then
    adb push "${BUILD_DIR}/android/libs/arm64-v8a/libpreloader.so" "${DEVICE_DIR}/"
    echo "  Pushed: libpreloader.so"
fi

# 推送测试数据
if [ -f "${BUILD_DIR}/test_bigcache.bin" ]; then
    echo "Pushing test BigCache..."
    adb push "${BUILD_DIR}/test_bigcache.bin" "${DEVICE_DIR}/"
fi

# 推送脚本
echo "Pushing scripts..."
cat > /tmp/run_benchmark.sh << 'EOF'
#!/system/bin/sh
cd /data/local/tmp/bigcache

echo "=== BigCache Benchmark ==="
echo ""

# 检查 UFFD 支持
echo "Checking UFFD support..."
if [ -e /proc/sys/vm/userfaultfd_allowed ]; then
    echo "  UFFD status: $(cat /proc/sys/vm/userfaultfd_allowed)"
else
    echo "  UFFD: checking via syscall"
fi

# 运行基准测试
if [ -f "bigcache" ] && [ -f "test_bigcache.bin" ]; then
    echo ""
    echo "Running info..."
    ./bigcache info test_bigcache.bin
    
    echo ""
    echo "Running benchmark..."
    ./bigcache benchmark test_bigcache.bin 1000
fi

echo ""
echo "=== Benchmark Complete ==="
EOF

adb push /tmp/run_benchmark.sh "${DEVICE_DIR}/"
adb shell "chmod 755 ${DEVICE_DIR}/run_benchmark.sh"

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "To run benchmark on device:"
echo "  adb shell \"su -c '${DEVICE_DIR}/run_benchmark.sh'\""
echo ""
echo "To use preloader with an app (requires root):"
echo "  adb shell \"su -c 'export LD_PRELOAD=${DEVICE_DIR}/libpreloader.so && <your_app>'\""
