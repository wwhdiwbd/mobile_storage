#!/bin/bash
# Android NDK 编译脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
BUILD_DIR="${PROJECT_DIR}/build"

echo "=== BigCache Android Build ==="

# 检查 NDK
if [ -z "${ANDROID_NDK}" ]; then
    # 尝试常见位置
    for ndk_path in \
        "${HOME}/Android/Sdk/ndk-bundle" \
        "${HOME}/Android/Sdk/ndk/"*/ \
        "/opt/android-ndk" \
        "C:/Android/Sdk/ndk-bundle"; do
        if [ -d "${ndk_path}" ]; then
            export ANDROID_NDK="${ndk_path}"
            break
        fi
    done
fi

if [ -z "${ANDROID_NDK}" ] || [ ! -d "${ANDROID_NDK}" ]; then
    echo "Error: Android NDK not found."
    echo "Please set ANDROID_NDK environment variable."
    exit 1
fi

echo "Using NDK: ${ANDROID_NDK}"

# 默认参数
PLATFORM=${ANDROID_PLATFORM:-android-26}
ABI=${ANDROID_ABI:-arm64-v8a}

echo "Platform: ${PLATFORM}"
echo "ABI: ${ABI}"

# 创建构建目录
mkdir -p "${BUILD_DIR}/android"

# 运行 ndk-build
cd "${PROJECT_DIR}"

"${ANDROID_NDK}/ndk-build" \
    APP_BUILD_SCRIPT=./Android.mk \
    APP_PLATFORM=${PLATFORM} \
    APP_ABI=${ABI} \
    NDK_PROJECT_PATH=. \
    NDK_OUT="${BUILD_DIR}/android/obj" \
    NDK_LIBS_OUT="${BUILD_DIR}/android/libs" \
    V=1

echo ""
echo "=== Build Complete ==="
echo ""
echo "Output:"
ls -la "${BUILD_DIR}/android/libs/${ABI}/"
