#!/bin/bash
# 手机存储碎片+低容量模拟脚本
# 作者：编程助手
# 适配：安卓/sdcard（无需ROOT）
# 功能：生成碎片+控剩余容量5%-10%+验证+清理

# ====================== 配置项（可根据需求修改） ======================
FRAG_DIR="/sdcard/fragment_test"  # 碎片文件存储目录
TARGET_FREE_PERCENT=10             # 目标剩余容量百分比（5-10之间，推荐8）
FRAG_FILE_NUM=100000              # 碎片文件数量（10万，可改5万/20万）
FRAG_SIZE_MIN=1                   # 碎片文件最小大小（KB）
FRAG_SIZE_MAX=100                 # 碎片文件最大大小（KB）
FILL_FILE_SIZE=10                 # 填充大文件大小（GB/个）
# =====================================================================

# 颜色输出（方便看结果）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 重置颜色

# 函数1：检查存储信息
check_storage() {
    echo -e "${YELLOW}===== 第一步：检查当前存储状态 =====${NC}"
    # 获取sdcard总容量、已用、剩余（单位：KB）
    STORAGE_INFO=$(df -k /sdcard | grep /sdcard | awk '{print $2,$3,$4}')
    TOTAL_SIZE_KB=$(echo $STORAGE_INFO | awk '{print $1}')
    USED_SIZE_KB=$(echo $STORAGE_INFO | awk '{print $2}')
    FREE_SIZE_KB=$(echo $STORAGE_INFO | awk '{print $3}')
    
    # 转换为GB（保留1位小数）
    TOTAL_SIZE_GB=$(echo "scale=1; $TOTAL_SIZE_KB/1024/1024" | bc)
    USED_SIZE_GB=$(echo "scale=1; $USED_SIZE_KB/1024/1024" | bc)
    FREE_SIZE_GB=$(echo "scale=1; $FREE_SIZE_KB/1024/1024" | bc)
    CURRENT_FREE_PERCENT=$(echo "scale=1; $FREE_SIZE_KB/$TOTAL_SIZE_KB*100" | bc)
    
    echo "📱 手机/sdcard存储信息："
    echo "   总容量：$TOTAL_SIZE_GB GB"
    echo "   已使用：$USED_SIZE_GB GB"
    echo "   剩余容量：$FREE_SIZE_GB GB（$CURRENT_FREE_PERCENT%）"
    echo "   目标剩余容量：$TARGET_FREE_PERCENT%（约$(echo "scale=1; $TOTAL_SIZE_GB*$TARGET_FREE_PERCENT/100" | bc) GB）"
    
    # 计算需要填充的容量（KB）
    TARGET_FREE_KB=$(echo "scale=0; $TOTAL_SIZE_KB*$TARGET_FREE_PERCENT/100" | bc)
    NEED_FILL_KB=$(echo "scale=0; $FREE_SIZE_KB - $TARGET_FREE_KB" | bc)
    
    # 转换为GB
    NEED_FILL_GB=$(echo "scale=1; $NEED_FILL_KB/1024/1024" | bc)
    echo "   需要额外填充容量：$NEED_FILL_GB GB"
    echo ""
    
    # 检查是否需要填充（剩余已小于目标）
    if [ $NEED_FILL_KB -lt 0 ]; then
        echo -e "${RED}⚠️ 当前剩余容量已小于目标（$TARGET_FREE_PERCENT%），无需填充！${NC}"
        NEED_FILL_GB=0
        return 1
    fi
    return 0
}

# 函数2：生成磁盘碎片（随机小文件）
generate_fragment() {
    echo -e "${YELLOW}===== 第二步：生成磁盘碎片（$FRAG_FILE_NUM 个小文件）=====${NC}"
    # 创建碎片目录
    mkdir -p $FRAG_DIR
    cd $FRAG_DIR
    
    # 生成随机小文件
    start_time=$(date +%s)
    echo "🚀 开始生成碎片文件（1KB~$FRAG_SIZE_MAX KB），请耐心等待..."
    for i in $(seq 1 $FRAG_FILE_NUM); do
        # 生成随机大小（KB→字节）
        size_kb=$(( (RANDOM % ($FRAG_SIZE_MAX - $FRAG_SIZE_MIN + 1)) + $FRAG_SIZE_MIN ))
        size_byte=$((size_kb * 1024))
        # 生成随机文件，写入随机数据（屏蔽输出）
        dd if=/dev/urandom of=file_frag_$i bs=$size_byte count=1 > /dev/null 2>&1
        # 每1000个文件输出进度
        if [ $((i % 1000)) -eq 0 ]; then
            echo "   已生成 $i/$FRAG_FILE_NUM 个碎片文件"
        fi
    done
    end_time=$(date +%s)
    cost_time=$((end_time - start_time))
    echo -e "${GREEN}✅ 碎片生成完成！耗时 $cost_time 秒${NC}"
    echo ""
}

# 函数3：填充大文件，控制剩余容量
fill_storage() {
    if [ $NEED_FILL_GB -eq 0 ]; then
        return
    fi
    echo -e "${YELLOW}===== 第三步：填充大文件，控制剩余容量 =====${NC}"
    cd $FRAG_DIR
    
    # 计算需要生成的大文件数量
    fill_file_num=$(echo "scale=0; $NEED_FILL_GB / $FILL_FILE_SIZE + 1" | bc)
    echo "📦 需要生成 $fill_file_num 个 $FILL_FILE_SIZE GB 的大文件..."
    
    # 生成大文件
    for i in $(seq 1 $fill_file_num); do
        echo "   正在生成 fill_${FILL_FILE_SIZE}g_$i ..."
        dd if=/dev/zero of=fill_${FILL_FILE_SIZE}g_$i bs=1G count=$FILL_FILE_SIZE > /dev/null 2>&1
        
        # 检查剩余容量是否达标
        CURRENT_FREE=$(df -k /sdcard | grep /sdcard | awk '{print $4}')
        CURRENT_FREE_PERCENT=$(echo "scale=1; $CURRENT_FREE/$TOTAL_SIZE_KB*100" | bc)
        echo "   当前剩余容量百分比：$CURRENT_FREE_PERCENT%"
        
        # 剩余≤目标则停止
        if (( $(echo "$CURRENT_FREE_PERCENT <= $TARGET_FREE_PERCENT" | bc -l) )); then
            echo -e "${GREEN}✅ 剩余容量已达标（≤$TARGET_FREE_PERCENT%），停止填充！${NC}"
            break
        fi
    done
    echo ""
}

# 函数4：验证碎片+低容量效果（测4KB随机读性能）
verify_fragment() {
    echo -e "${YELLOW}===== 第四步：验证碎片+低容量效果（测4KB随机读）=====${NC}"
    # 检查是否安装fio
    if ! command -v fio &> /dev/null; then
        echo -e "${YELLOW}⚠️ 未安装fio，先安装...${NC}"
        pkg install -y fio > /dev/null 2>&1
    fi
    
    # 运行4KB随机读测试
    fio --name=frag_verify \
    --ioengine=psync \
    --direct=1 \
    --rw=randread \
    --bs=4k \
    --size=1G \
    --filename=$FRAG_DIR/test_verify \
    --numjobs=1 \
    --runtime=10 \
    --ramp_time=2 \
    --group_reporting
    
    echo -e "${GREEN}✅ 性能验证完成！碎片场景下4KB随机读性能会明显下降${NC}"
    echo ""
}

# 函数5：清理所有测试文件（重要！）
cleanup() {
    echo -e "${YELLOW}===== 第五步：清理测试文件（释放空间）=====${NC}"
    read -p "❓ 是否删除所有碎片/填充文件？(y/n) " choice
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        rm -rf $FRAG_DIR
        echo -e "${GREEN}✅ 清理完成！/sdcard剩余容量已恢复${NC}"
        # 显示最终存储状态
        df -h /sdcard | grep /sdcard
    else
        echo -e "${YELLOW}⚠️ 已取消清理，测试文件仍保留在 $FRAG_DIR${NC}"
    fi
}

# 主流程执行
check_storage
if [ $? -eq 0 ]; then
    generate_fragment
    fill_storage
fi
verify_fragment
cleanup

echo -e "\n${GREEN}🎉 整个模拟流程完成！${NC}"