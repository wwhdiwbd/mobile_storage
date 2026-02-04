#!/system/bin/sh
# ============================================================
#        Bilibili 启动文件预取脚本 (Android)
# ============================================================
# 这个脚本在系统空闲时预读 Bilibili 启动所需的文件到 page cache
# 需要 root 权限运行

PACKAGE="tv.danmaku.bili"
APK_PATH=$(pm path $PACKAGE | cut -d: -f2)
DATA_PATH="/data/data/$PACKAGE"

echo "=== Bilibili Preload Service ==="
echo "APK Path: $APK_PATH"
echo "Data Path: $DATA_PATH"

# 获取内存状态
MEM_FREE=$(cat /proc/meminfo | grep MemFree | awk '{print $2}')
MEM_FREE_MB=$((MEM_FREE / 1024))
echo "Free Memory: ${MEM_FREE_MB}MB"

# 如果空闲内存小于 500MB，跳过预取
if [ $MEM_FREE_MB -lt 500 ]; then
    echo "Warning: Low memory, skipping preload"
    exit 0
fi

echo ""
echo "--- Phase 1: Preloading APK files ---"

# 预读主 APK（最重要）
if [ -f "$APK_PATH" ]; then
    echo "Preloading: $APK_PATH"
    cat "$APK_PATH" > /dev/null 2>&1
fi

# 预读 Bundle APKs
BUNDLE_PATH="$DATA_PATH/app_tribe/3/bundles"
if [ -d "$BUNDLE_PATH" ]; then
    echo "Preloading bundle APKs..."
    find "$BUNDLE_PATH" -name "*.apk" | while read apk; do
        echo "  - $(basename $apk)"
        cat "$apk" > /dev/null 2>&1
    done
fi

echo ""
echo "--- Phase 2: Preloading config files ---"

# 预读配置文件（按启动顺序）
CONFIG_FILES="
instance.bili_preference.blkv
root.kv
records.kv
foundation.sp
account_exp.blkv
dd-default-config.blkv
dd_core_data.blkv
neuron_config.blkv
fingerprint.raw_kv
localization.blkv
region_store.blkv
biliplayer.blkv
"

for cfg in $CONFIG_FILES; do
    cfg_path=$(find "$DATA_PATH" -name "$cfg" 2>/dev/null | head -1)
    if [ -f "$cfg_path" ]; then
        echo "  - $cfg"
        cat "$cfg_path" > /dev/null 2>&1
    fi
done

echo ""
echo "--- Phase 3: Preloading databases ---"

# 预读数据库文件
find "$DATA_PATH/databases" -name "*.db" 2>/dev/null | while read db; do
    echo "  - $(basename $db)"
    cat "$db" > /dev/null 2>&1
done

echo ""
echo "--- Preload Complete ---"

# 显示 page cache 状态
CACHED=$(cat /proc/meminfo | grep "^Cached:" | awk '{print $2}')
CACHED_MB=$((CACHED / 1024))
echo "Page Cache: ${CACHED_MB}MB"

echo ""
echo "Bilibili files are now in page cache."
echo "Cold start should be faster!"
