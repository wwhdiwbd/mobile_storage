#!/system/bin/sh
#
# Bilibili 文件预热脚本
# 将关键文件预热到系统页缓存，加速冷启动
#

APP_PATH="/data/app/~~CEsSzuk4LmIJOLfx-hZiqg==/tv.danmaku.bili-tP-kjx4nfMJdM1IxTw81pQ=="

echo "=== Bilibili File Preheat ==="
echo "App path: $APP_PATH"

START=$(date +%s%3N 2>/dev/null || date +%s)

# 预热 APK (最重要，包含 dex 和资源)
echo "Preheating base.apk..."
dd if="$APP_PATH/base.apk" of=/dev/null bs=4M 2>/dev/null

# 预热 native 库
echo "Preheating native libraries..."
for so in "$APP_PATH/lib/arm64/"*.so; do
    if [ -f "$so" ]; then
        dd if="$so" of=/dev/null bs=1M 2>/dev/null
    fi
done

# 预热 OAT/VDEX 文件 (编译后的 dex)
echo "Preheating oat/vdex files..."
OAT_PATH="/data/app/~~CEsSzuk4LmIJOLfx-hZiqg==/tv.danmaku.bili-tP-kjx4nfMJdM1IxTw81pQ==/oat/arm64"
if [ -d "$OAT_PATH" ]; then
    for f in "$OAT_PATH"/*; do
        if [ -f "$f" ]; then
            dd if="$f" of=/dev/null bs=4M 2>/dev/null
        fi
    done
fi

# 预热 data 目录中的关键文件
DATA_PATH="/data/data/tv.danmaku.bili"
if [ -d "$DATA_PATH" ]; then
    echo "Preheating app data..."
    # code_cache
    if [ -d "$DATA_PATH/code_cache" ]; then
        find "$DATA_PATH/code_cache" -type f -exec dd if={} of=/dev/null bs=1M 2>/dev/null \;
    fi
fi

END=$(date +%s%3N 2>/dev/null || date +%s)

# 计算统计
if [ "$END" != "$START" ]; then
    ELAPSED=$((END - START))
    echo ""
    echo "=== Preheat Complete ==="
    echo "Time: ${ELAPSED} ms"
else
    echo ""
    echo "=== Preheat Complete ==="
fi

echo "========================"
