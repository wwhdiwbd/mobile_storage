#!/system/bin/sh
#
# 文件预热脚本
# 原理：按顺序读取真实文件，将数据预热到系统页缓存
#
# 用法: sh preheat.sh <layout.csv>
#

LAYOUT="$1"

if [ -z "$LAYOUT" ]; then
    echo "Usage: $0 <layout.csv>"
    exit 1
fi

if [ ! -f "$LAYOUT" ]; then
    echo "Error: Layout file not found: $LAYOUT"
    exit 1
fi

echo "=== File Preheat Tool ==="
echo "Layout: $LAYOUT"

# 统计
TOTAL=0
SUCCESS=0
FAILED=0
START=$(date +%s%3N)

# 获取唯一文件列表
echo "Extracting unique files..."
FILES=$(tail -n +2 "$LAYOUT" | cut -d',' -f2 | sort -u)
FILE_COUNT=$(echo "$FILES" | wc -l)
echo "Found $FILE_COUNT unique files"

# 预热每个文件
echo ""
echo "Preheating files to page cache..."

for FILE in $FILES; do
    if [ -f "$FILE" ]; then
        # 使用 dd 读取文件（会进入页缓存）
        dd if="$FILE" of=/dev/null bs=1M 2>/dev/null
        if [ $? -eq 0 ]; then
            SUCCESS=$((SUCCESS + 1))
            SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
            TOTAL=$((TOTAL + SIZE))
        else
            FAILED=$((FAILED + 1))
        fi
    else
        FAILED=$((FAILED + 1))
    fi
    
    # 进度
    DONE=$((SUCCESS + FAILED))
    printf "\r  Progress: %d/%d files" $DONE $FILE_COUNT
done

END=$(date +%s%3N)
ELAPSED=$((END - START))

echo ""
echo ""
echo "=== Preheat Complete ==="
echo "Files preheated: $SUCCESS"
echo "Files failed: $FAILED"
echo "Total data: $((TOTAL / 1024 / 1024)) MB"
echo "Time: ${ELAPSED} ms"
if [ $ELAPSED -gt 0 ]; then
    SPEED=$((TOTAL / 1024 * 1000 / ELAPSED))
    echo "Speed: ${SPEED} KB/s"
fi
echo "========================"
