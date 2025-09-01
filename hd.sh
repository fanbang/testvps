#!/bin/bash
# 保存为 system_health_check_final.sh
# 描述：修复所有数值显示问题的终极版本

echo -e "\033[1;34m===== 系统健康全面检测 (最终版) =====\033[0m"
echo "测试包括：硬盘性能、中断风暴、上下文切换、内存稳定性、CPU节流、内存速度"
echo "总耗时：约35秒"

# 全局变量声明
declare -gi GLOBAL_IOPS_RESULT

# 安装必要工具
install_tools() {
    if ! command -v fio &>/dev/null || ! command -v stress-ng &>/dev/null; then
        echo "安装诊断工具..."
        apt-get update >/dev/null 2>&1
        apt-get install -y fio stress-ng sysstat dstat bc hdparm jq sysbench >/dev/null 2>&1
    fi
}

# 安全数值格式化函数
safe_format_number() {
    local num=$1
    # 处理空值或非数字
    if [[ -z "$num" ]] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
        echo "0"
        return
    fi
    
    # 处理小数值
    if [[ "$num" -lt 1000 ]]; then
        echo "$num"
        return
    fi
    
    # 格式化大数值
    echo "$num" | awk '{printf "%'\''d", $1}'
}

# 改进的硬盘性能测试函数
disk_perf_test() {
    echo -e "\n\033[1;34m[硬盘测试] $1 ($2秒)\033[0m"
    TEST_FILE="$3"
    iops=""
    
    # 使用直接IO测试
    fio --name=disk_test --filename="$TEST_FILE" --rw=randread --bs=4k --size=100M \
        --runtime="$2" --direct=1 --output-format=json > "$4" 2>/dev/null
    
    # 方法1: 使用jq解析JSON
    if command -v jq &>/dev/null; then
        iops=$(jq '.jobs[0].read.iops' "$4" 2>/dev/null | cut -d. -f1)
    fi
    
    # 备用解析方法
    if [[ -z "$iops" ]] || [[ "$iops" == "null" ]]; then
        iops=$(grep '"iops"' "$4" | grep -Eo '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
    fi
    
    # 方法3: 数值计算
    if [[ -z "$iops" ]] || [[ "$iops" -lt 100 ]]; then
        # 从fio输出中提取带宽数据计算
        bandwidth_kb=$(grep 'bw=' "$4" | grep -Eo 'bw=[0-9.]+KiB/s' | head -1 | grep -Eo '[0-9.]+')
        
        if [[ -n "$bandwidth_kb" ]]; then
            # 转换为IOPS (4KB块)
            iops=$(echo "$bandwidth_kb / 4" | bc | cut -d. -f1)
            [[ -z "$iops" ]] && iops=0
        fi
    fi
    
    # 方法4: dd测试作为最后手段
    if [[ -z "$iops" ]] || [[ "$iops" -lt 100 ]]; then
        echo "使用dd进行硬盘性能测试..."
        temp_file="$TEST_DIR/dd_test.tmp"
        sync
        echo 3 > /proc/sys/vm/drop_caches
        
        # 测试写入性能
        dd_output=$(dd if=/dev/zero of="$temp_file" bs=1M count=100 conv=fdatasync 2>&1)
        
        if [[ "$dd_output" =~ ([0-9.]+)\ MB/s ]]; then
            mb_speed=${BASH_REMATCH[1]}
            # 将MB/s转换为IOPS (4KB块)
            iops=$(echo "$mb_speed * 1024 / 4" | bc | cut -d. -f1)
        fi
        
        sync
        rm -f "$temp_file"
    fi
    
    # 确保IOPS合理
    [[ -z "$iops" ]] && iops=0
    ! [[ "$iops" =~ ^[0-9]+$ ]] && iops=0
    [[ "$iops" -lt 0 ]] && iops=0
    
    # 安全格式化输出
    formatted_iops=$(safe_format_number "$iops") 
    echo "IOPS: $formatted_iops"
      # 将结果存储在全局变量中
    GLOBAL_IOPS_RESULT=$iops
    return 0
}

# CPU节流检测
cpu_throttle_test() {
    echo -e "\n\033[1;34m[CPU测试] 节流检测 (10秒)\033[0m"
    
    # 获取CPU信息
    cores=$(nproc)
    echo "CPU核心数: $cores"
    
    # 空闲频率
    idle_freq=$(grep "cpu MHz" /proc/cpuinfo | head -1 | awk '{print $4}')
    [[ -z "$idle_freq" ]] && idle_freq=0
    echo "空闲频率: $idle_freq MHz"
    
    # 负载频率
    echo "运行压力测试..."
    stress-ng --cpu "$cores" --timeout 10 >/dev/null &
    
    # 采样最高频率
    max_freq=0
    for _ in {1..10}; do
        current_freq=$(grep "cpu MHz" /proc/cpuinfo | head -1 | awk '{print $4}')
        [[ -z "$current_freq" ]] && current_freq=0
        
        # 使用bc进行浮点数比较
        if (( $(echo "$current_freq > $max_freq" | bc -l 2>/dev/null || echo 0) )); then
            max_freq=$current_freq
        fi
        sleep 1
    done
    
    # 等待压力测试结束
    wait
    
    echo "负载频率: $max_freq MHz"
    
    # 计算节流比例
    if (( $(echo "$idle_freq > 0" | bc -l 2>/dev/null || echo 0) )) && (( $(echo "$max_freq > 0" | bc -l 2>/dev/null || echo 0) )); then
        throttle_pct=$(echo "scale=2; (1 - $max_freq/$idle_freq)*100" | bc -l 2>/dev/null)
        [[ -z "$throttle_pct" ]] && throttle_pct=0 
        echo "节流比例: ${throttle_pct}%"
        
        if (( $(echo "$throttle_pct > 20" | bc -l 2>/dev/null || echo 0) )); then
            echo -e "\033[31m严重节流：CPU频率下降超过20%\033[0m"
            return 3
        elif (( $(echo "$throttle_pct > 10" | bc -l 2>/dev/null || echo 0) )); then
            echo -e "\033[33m中度节流：CPU频率下降10-20%\033[0m"
            return 2
        elif (( $(echo "$throttle_pct > 5" | bc -l 2>/dev/null || echo 0) )); then
            echo -e "\033[93m轻度节流：CPU频率下降5-10%\033[0m"
            return 1
        else
            echo -e "\033[32m未检测到明显节流\033[0m"
            return 0
        fi
    else
        echo "无法获取有效频率数据"
        return 0
    fi
}

# 内存速度测试
memory_speed_test() {
    echo -e "\n\033[1;34m[内存测试] 速度检测 (5秒)\033[0m"
    speed=""
    
    # 方法1: 使用sysbench（优先）
    if command -v sysbench &>/dev/null; then
        echo "使用sysbench检测内存速度..."
        sysbench memory --memory-block-size=1K --memory-total-size=10G --memory-oper=write run > mem_test.txt 2>/dev/null
        speed=$(grep "transferred" mem_test.txt | grep -Eo '[0-9]+\.[0-9]+ MiB/sec' | awk '{print $1}')
    fi
    
    # 方法2: 使用stress-ng备用
    if [[ -z "$speed" ]] && command -v stress-ng &>/dev/null; then
        echo "使用stress-ng检测内存速度..."
        stress-ng --vm 1 --vm-bytes 5G --vm-method all --metrics-brief --timeout 5 > mem_test.txt 2>/dev/null
        speed=$(grep "MEM" mem_test.txt | awk '{print $9}')
    fi
    
    # 方法3: 使用dd作为最后备用
    if [[ -z "$speed" ]]; then
        echo "使用dd检测内存速度..."
        temp_file="/dev/shm/memtest.tmp"
        sync
        echo 3 > /proc/sys/vm/drop_caches
        dd_output=$(dd if=/dev/zero of=$temp_file bs=1M count=500 conv=fdatasync 2>&1)
        sync
        
        if [[ "$dd_output" =~ ([0-9.]+)\ MB/s ]]; then
            speed=${BASH_REMATCH}
        fi
        
        rm -f $temp_file 2>/dev/null
    fi
    
    # 确保速度值有效
    if [[ -n "$speed" ]] && [[ "$speed" =~ ^[0-9.]+$ ]]; then
        echo "内存速度: $speed MiB/秒"
    else
        echo "无法获取内存速度"
        speed=0
    fi
    
    # 评估内存速度
    if (( $(echo "$speed < 1000" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "\033[31m极慢内存：低于1GB/s\033[0m"
        return 3
    elif (( $(echo "$speed < 3000" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "\033[33m较慢内存：1-3GB/s\033[0m"
        return 2
    elif (( $(echo "$speed < 6000" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "\033[93m标准内存：3-6GB/s\033[0m"
        return 1
    else
        echo -e "\033[32m高速内存：超过6GB/s\033[0m"
        return 0
    fi
}

# 中断风暴检测
interrupt_storm_test() {
    echo -e "\n\033[1;34m[中断测试] 中断压力测试 (5秒)\033[0m"
    BEFORE_LOG=$(mktemp)
    AFTER_LOG=$(mktemp)
    
    cat /proc/interrupts > "$BEFORE_LOG" 2>/dev/null
    
    # 检查stress-ng是否支持--irq选项
    if stress-ng --help 2>&1 | grep -q -- --irq; then
        stress-ng --irq $(( $(nproc) * 2 )) --timeout 5 >/dev/null
    else
        # 使用替代方法生成中断
        echo "使用替代中断测试方法..."
        for i in $(seq 1 $(( $(nproc) * 2 ))); do
            timeout 5 dd if=/dev/urandom of=/dev/null bs=1M status=none &
        done
        wait
    fi
    
    cat /proc/interrupts > "$AFTER_LOG" 2>/dev/null
    
    echo -e "\n\033[1;35m中断变化报告:\033[0m"
    critical_count=0
    warning_count=0
    
    # 处理中断分析
    grep -v IPI "$BEFORE_LOG" 2>/dev/null | awk '{print $1}' | sort | uniq | while read -r irq; do
        before=$(grep "^ *$irq:" "$BEFORE_LOG" 2>/dev/null | awk '{sum=0; for(i=2;i<=NF-3;i++) if($i ~ /^[0-9]+$/) sum+=$i; print sum}')
        after=$(grep "^ *$irq:" "$AFTER_LOG" 2>/dev/null | awk '{sum=0; for(i=2;i<=NF-3;i++) if($i ~ /^[0-9]+$/) sum+=$i; print sum}')
        
        if [[ -n "$before" ]] && [[ -n "$after" ]] && [[ "$before" -ne 0 ]] && [[ "$after" -ge "$before" ]]; then
            diff=$((after - before))
            if [[ "$diff" -gt 1000 ]]; then
                echo -e "\033[31mIRQ $irq: 激增 $diff 次中断 (可能硬件故障)\033[0m"
                critical_count=$((critical_count+1))
            elif [[ "$diff" -gt 100 ]]; then
                echo -e "\033[33mIRQ $irq: 增加 $diff 次中断 (需关注)\033[0m"
                warning_count=$((warning_count+1))
            fi
        fi
    done
    
    rm -f "$BEFORE_LOG" "$AFTER_LOG"
    return $critical_count
}

# 上下文切换分析
context_switch_test() {
    echo -e "\n\033[1;34m[切换测试] 上下文切换压力 (5秒)\033[0m"
    BEFORE_LOG=$(mktemp)
    AFTER_LOG=$(mktemp)
    
    cat /proc/stat | grep ctxt > "$BEFORE_LOG" 2>/dev/null
    
    # 检查stress-ng是否支持--switch选项
    if stress-ng --help 2>&1 | grep -q -- --switch; then
        stress-ng --switch $(( $(nproc) * 4 )) --timeout 5 >/dev/null
    else
        # 使用替代方法生成上下文切换
        echo "使用替代上下文切换测试方法..."
        for i in $(seq 1 $(( $(nproc) * 4 ))); do
            timeout 5 bash -c 'while true; do /bin/true; done' &
        done
        sleep 5
        killall -9 bash &>/dev/null
    fi
    
    cat /proc/stat | grep ctxt > "$AFTER_LOG" 2>/dev/null
    
    before_ctx=$(awk '{print $2}' "$BEFORE_LOG")
    after_ctx=$(awk '{print $2}' "$AFTER_LOG")
    ctx_diff=$((after_ctx - before_ctx))
    ctx_rate=$((ctx_diff / 5))
    
    echo -e "\n\033[1;35m上下文切换报告:\033[0m"
    echo "总切换次数: $(safe_format_number "$ctx_diff")"
    echo "平均速率: $(safe_format_number "$ctx_rate") 次/秒"
    
    level=0
    if [[ "$ctx_rate" -gt 500000 ]]; then
        echo -e "\033[31m警告：上下文切换速率过高 (可能调度器故障)\033[0m"
        level=2
    elif [[ "$ctx_rate" -gt 100000 ]]; then
        echo -e "\033[33m注意：上下文切换速率偏高 (可能配置不当)\033[0m"
        level=1
    else
        echo -e "\033[32m上下文切换速率正常\033[0m"
    fi
    
    rm -f "$BEFORE_LOG" "$AFTER_LOG"
    return $level
}

# 内存稳定性检测
# 内存稳定性检测
memory_stability_test() {
    echo -e "\n\033[1;34m[内存测试] 错误检测 (5秒)\033[0m"
    BEFORE_LOG=$(mktemp)
    AFTER_LOG=$(mktemp)
    
    # 检查日志文件
    log_files=()
    [[ -f "/var/log/kern.log" ]] && log_files+=("/var/log/kern.log")
    [[ -f "/var/log/syslog" ]] && log_files+=("/var/log/syslog")
    [[ -f "/var/log/messages" ]] && log_files+=("/var/log/messages")
    
    if [[ ${#log_files[@]} -gt 0 ]]; then
        grep -i -e "ECC" -e "memory" -e "corrected" -e "error" "${log_files[@]}" > "$BEFORE_LOG" 2>/dev/null
    else
        touch "$BEFORE_LOG"
    fi
    
    # 运行内存压力测试
    mem_size=$(free -m | awk '/Mem/{print int($2*0.85)}') # 使用85%内存
    [[ "$mem_size" -lt 100 ]] && mem_size=100 # 最少100MB
    stress-ng --vm $(( $(nproc) * 2 )) --vm-bytes ${mem_size}M --vm-keep --timeout 5 >/dev/null
    
    # 检查日志变化
    if [[ ${#log_files[@]} -gt 0 ]]; then
        grep -i -e "ECC" -e "memory" -e "corrected" -e "error" "${log_files[@]}" > "$AFTER_LOG" 2>/dev/null
    else
        touch "$AFTER_LOG"
    fi
    
    echo -e "\n\033[1;35m内存错误报告:\033[0m"
    error_count=0
    
    # 计算新错误 - 修复语法错误
    if [[ -f "$BEFORE_LOG" && -f "$AFTER_LOG" ]]; then
        new_errors=$(diff "$BEFORE_LOG" "$AFTER_LOG" 2>/dev/null | grep -c '^>') || new_errors=0
        
        if [[ $new_errors -gt 0 ]]; then  # 修复这里的语法
            echo -e "\033[31m发现 $new_errors 个新内存错误\033[0m"
            error_count=$new_errors
        else
            echo -e "\033[32m未检测到新内存错误\033[0m"
        fi
    else
        echo -e "\033[33m无法获取日志文件进行对比\033[0m"
    fi
    
    rm -f "$BEFORE_LOG" "$AFTER_LOG"
    return $error_count
}

# 主测试流程
main() {
    # 安装必要工具
    install_tools
    
    # 创建专用测试环境
    TEST_DIR=$(mktemp -d -p /tmp)
    TEST_FILE="$TEST_DIR/io_test.bin"
    INIT_LOG="$TEST_DIR/init.json"
    FINAL_LOG="$TEST_DIR/final.json"
    
    # 硬盘性能测试（初始状态）
    disk_perf_test "初始IOPS测试" 3 "$TEST_FILE" "$INIT_LOG"
    initial_iops=$GLOBAL_IOPS_RESULT
    
    # CPU节流测试
    cpu_throttle_test
    cpu_throttle_level=$?
    
    # 内存速度测试
    memory_speed_test
    mem_speed_level=$?
    
    # 系统稳定性测试
    interrupt_storm_test
    critical_interrupts=$?
    
    context_switch_test
    switch_level=$?
    
    memory_stability_test
    memory_errors=$?
    
    # 硬盘性能测试（压力后）
    disk_perf_test "最终IOPS测试" 3 "$TEST_FILE" "$FINAL_LOG"
    final_iops=$GLOBAL_IOPS_RESULT
    
    # 清理测试文件
    rm -rf "$TEST_DIR"
    rm -f mem_test.txt 2>/dev/null
    
    # 性能评估
    echo -e "\n\033[1;31m===== 综合健康报告 =====\033[0m"
    
    # 硬盘性能评级
    echo -e "\n\033[1;35m存储性能评级:\033[0m"
    echo "初始IOPS: $(safe_format_number "$initial_iops")"
    echo "最终IOPS: $(safe_format_number "$final_iops")"
    
    if [[ "$initial_iops" -gt 0 ]] && [[ "$final_iops" -gt 0 ]]; then
        if [[ "$initial_iops" -gt "$final_iops" ]]; then
            drop_percent=$((100 - (final_iops * 100 / initial_iops)))
            echo "性能下降: $drop_percent%"
        else
            increase_percent=$(((final_iops * 100 / initial_iops) - 100))
            echo "性能提升: $increase_percent%"
        fi
    else
        drop_percent=0
    fi
    
    if [[ "$initial_iops" -lt 1000 ]]; then
        echo "💩 垃圾级 (≤1k IOPS) - 严重超售磁盘"
    elif [[ "$initial_iops" -lt 5000 ]]; then
        echo "⚠️ 劣质级 (1k-5k IOPS) - 明显超售磁盘"
    elif [[ "$initial_iops" -lt 10000 ]]; then
        echo "🟡 普通级 (5k-10k IOPS) - 轻度超售磁盘"
    elif [[ "$initial_iops" -lt 30000 ]]; then
        echo "🟢 良好级 (10k-30k IOPS) - 标准云磁盘"
    else
        echo "🚀 优秀级 (>30k IOPS) - 优质存储"
    fi
    
    # CPU节流评级
    echo -e "\n\033[1;35mCPU性能评级:\033[0m"
    case $cpu_throttle_level in
        3) echo "🔴 严重节流：CPU频率下降超过20%" ;;
        2) echo "🟠 中度节流：CPU频率下降10-20%" ;;
        1) echo "🟡 轻度节流：CPU频率下降5-10%" ;;
        *) echo "🟢 未检测到明显节流" ;;
    esac
    
    # 系统稳定性评级
    echo -e "\n\033[1;35m系统稳定性评级:\033[0m"
    issues=0
    
    if [[ "$critical_interrupts" -gt 0 ]]; then
        echo "🔴 中断问题: $critical_interrupts 个中断源异常"
        issues=$((issues+2))
    fi
    
    if [[ "$switch_level" -gt 1 ]]; then
        echo "🔴 切换问题: 上下文切换速率过高"
        issues=$((issues+2))
    elif [[ "$switch_level" -gt 0 ]]; then
        echo "🟠 切换问题: 上下文切换速率偏高"
        issues=$((issues+1))
    fi
    
    if [[ "$memory_errors" -gt 0 ]]; then
        echo "🔴 内存问题: $memory_errors 个内存错误"
        issues=$((issues+2))
    fi
    
    # 内存速度评级
    case $mem_speed_level in
        3) echo "🔴 内存问题: 极慢内存 (<1GB/s)"; issues=$((issues+2)) ;;
        2) echo "🟠 内存问题: 较慢内存 (1-3GB/s)"; issues=$((issues+1)) ;;
        1) echo "🟡 内存问题: 标准内存 (3-6GB/s)" ;;
    esac
    
    # 总体评级
    if [[ "$issues" -ge 4 ]]; then
        echo -e "\n\033[1;31m✗ 系统不稳定：检测到严重硬件问题\033[0m"
    elif [[ "$issues" -ge 2 ]]; then
        echo -e "\n\033[1;33m⚠ 系统亚稳定：存在多个潜在风险\033[0m"
    elif [[ "$issues" -ge 1 ]]; then
        echo -e "\n\033[1;33m⚠ 系统基本稳定：存在轻度问题\033[0m"
    else
        echo -e "\n\033[1;32m✓ 系统稳定：未检测到重大问题\033[0m"
    fi
    
    # 硬件摘要
    echo -e "\n\033[1;34m===== 硬件配置摘要 =====\033[0m"
    echo "CPU: $(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')"
    echo "核心: $(nproc)"
    echo "内存: $(free -h | awk '/Mem/{print $2}' | sed 's/Gi/GB/')"
    echo "虚拟化: $(dmidecode -s system-product-name 2>/dev/null || echo "未知")"
    
    echo -e "\n\033[1;32m检测完成！耗时约35秒\033[0m"
}

# 执行主函数
main
