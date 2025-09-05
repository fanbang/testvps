#!/bin/bash
# VPS 性能快速检测脚本 v0.1
# by tj 机组(teijiang,远古巨瘦,钻舰队长,鸡贼王，石巨人,牛头人)带领claude、dp3出品

echo -e "\033[1;34m===== 站长 VPS 性能快速检测 v0.1 =====\033[0m"
echo "专注检测：IO性能、CPU稳定性、内存带宽、网络延迟、超售程度"
echo "预计耗时：60秒"
 
# 全局变量
declare -gi DISK_IOPS=0
declare -gi MEMORY_BANDWIDTH=0
declare -gi CPU_SINGLE_SCORE=0
declare -gi CPU_MULTI_SCORE=0
declare -g NETWORK_LATENCY="0"
declare -gi BZIP2_SPEED=0
declare -gi SHA256_SPEED=0
declare -gi MD5SUM_SPEED=0
declare -g actual_efficiency=0
declare -g DISK_IOPS_STR="0"    # 字符串存储综合评分
declare -g read_iops_formatted="0"   # 字符串存储原始IOPS值
declare -g write_bw_formatted="0"    # 字符串存储原始带宽值
declare -gi  cores=1
# 工具安装
install_tools() {
    local tools_needed=""
    command -v fio &>/dev/null || tools_needed="$tools_needed fio"
    command -v sysbench &>/dev/null || tools_needed="$tools_needed sysbench"
    command -v bc &>/dev/null || tools_needed="$tools_needed bc"
    command -v bzip2 &>/dev/null || tools_needed="$tools_needed bzip2"
    command -v jq &>/dev/null || tools_needed="$tools_needed jq"
    
    if [[ -n "$tools_needed" ]]; then
        echo "安装必要工具: $tools_needed"
        if command -v apt-get &>/dev/null; then
            apt-get update >/dev/null 2>&1
            apt-get install -y $tools_needed >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y $tools_needed >/dev/null 2>&1
        fi
    fi
}

# 数值格式化
format_number() {
    local num=$1
    # 移除非数字字符
    num_str=$(echo "$num" | tr -cd '0-9')
    [[ -z "$num_str" ]] && echo "0" && return
    
    # 直接使用字符串处理大数值
    echo "$num_str" | awk '{printf "%'\''d", $1}'
     
}

# 安全的浮点数比较
float_compare() {
    local val1=$1
    local op=$2  
    local val2=$3
    echo "$val1 $op $val2" | bc -l 2>/dev/null || echo 0
} 
 
run_cpu_benchmarks() {
    echo "运行CPU性能基准测试（bzip2/SHA256/MD5）..."
    
    # 创建100MB测试文件
    local test_file="/tmp/cpu_bench_test.dat"
    echo "生成cpu_bench_100mb测试文件..."
    dd if=/dev/zero of="$test_file" bs=512K count=200 >/dev/null 2>&1
    
    # bzip2压缩测试 
    local start_time=$(date +%s%N)
    bzip2 -c "$test_file" > /tmp/test.bz2 2>/dev/null
    local end_time=$(date +%s%N)
    local bzip2_time_ms=$(( (end_time - start_time) / 1000000 ))
    BZIP2_SPEED=$(( 100000 / bzip2_time_ms ))  # 改为纯Bash整数运算
    [[ $BZIP2_SPEED -le 0 ]] && BZIP2_SPEED=1
    echo "  bzip2压缩测试...$BZIP2_SPEED"
    # SHA256哈希测试
    start_time=$(date +%s%N)
    sha256sum "$test_file" >/dev/null 2>&1
    end_time=$(date +%s%N)
    local sha256_time_ms=$(( (end_time - start_time) / 1000000 ))
    SHA256_SPEED=$(( 100000 / sha256_time_ms ))  # 改为纯Bash整数运算
    [[ $SHA256_SPEED -le 0 ]] && SHA256_SPEED=1
    
    echo "  SHA256哈希测试...$SHA256_SPEED"
    # MD5哈希测试
    start_time=$(date +%s%N)
    md5sum "$test_file" >/dev/null 2>&1
    end_time=$(date +%s%N)
    local md5_time_ms=$(( (end_time - start_time) / 1000000 ))
    MD5SUM_SPEED=$(( 100000 / md5_time_ms ))  # 改为纯Bash整数运算
    [[ $MD5SUM_SPEED -le 0 ]] && MD5SUM_SPEED=1
    
    echo "  MD5哈希测试...$MD5SUM_SPEED"
    # 清理临时文件
    rm -f "$test_file" /tmp/test.bz2 2>/dev/null
}

# 修改后的基于实际数据的GB5预估函数
# 修改后的基于实际数据的GB5预估函数（纯Bash整数运算）
estimate_gb5_from_benchmarks() {
    local bzip2=$BZIP2_SPEED
    local sha256=$SHA256_SPEED
    local md5sum=$MD5SUM_SPEED
    
    # 确保所有参数都是整数
    bzip2=${bzip2%.*}
    sha256=${sha256%.*}
    md5sum=${md5sum%.*}
    
    # 基于两组实际测试数据：
    # 数据1: bzip2=263, sha256=580, md5sum=919 → GB5=2000
    # 数据2: bzip2=152, sha256=262, md5sum=613 → GB5=1200
    
    local gb5_v1=$(( (38 * bzip2 + 12 * sha256 + 8 * md5sum + 2000) / 10 ))
    
    # 方法2: 标准化加权平均（使用整数运算）
    # 2000 * (0.4*bzip2/263 + 0.3*sha256/580 + 0.3*md5sum/919)
    # 转换为整数运算：先乘1000再除1000
    local bzip2_part=$(( 400 * bzip2 / 263 ))
    local sha256_part=$(( 300 * sha256 / 580 ))
    local md5_part=$(( 300 * md5sum / 919 ))
    local gb5_v2=$(( 2000 * (bzip2_part + sha256_part + md5_part) / 1000 ))
    
    # 方法3: 基于第二组数据的比例（使用整数运算）
    # 1200 * ((bzip2/152 + sha256/262 + md5sum/613)/3)
    local bzip2_ratio=$(( 100 * bzip2 / 152 ))
    local sha256_ratio=$(( 100 * sha256 / 262 ))
    local md5_ratio=$(( 100 * md5sum / 613 ))
    local avg_ratio=$(( (bzip2_ratio + sha256_ratio + md5_ratio) / 3 ))
    local gb5_v3=$(( 1200 * avg_ratio / 100 ))
    
    # 综合三种方法（权重：v1=40%, v2=30%, v3=30%）
    local final_gb5=$(( (gb5_v1 * 4 + gb5_v2 * 3 + gb5_v3 * 3) / 10 ))
    
    # 范围限制
    if [[ $final_gb5 -lt 300 ]]; then
        final_gb5=300
    elif [[ $final_gb5 -gt 4000 ]]; then
        final_gb5=4000
    fi
    
    echo "$final_gb5"

} 
# ==================== 虚拟化检测 ====================
detect_virtualization() {
    echo -e "\n\033[1;35m[系统信息] 虚拟化技术检测\033[0m"
    
    local virt_type="未知"
    
    # 检测容器环境
    if [ -f /proc/1/cgroup ]; then
        if grep -qi "docker" /proc/1/cgroup; then
            virt_type="Docker"
        elif grep -qi "kubepods" /proc/1/cgroup; then
            virt_type="Kubernetes"
        elif grep -qi "lxc" /proc/1/cgroup; then
            virt_type="LXC"
        fi
    fi
    
    # 检测虚拟机环境
    if [[ "$virt_type" == "未知" ]]; then
        if [[ -f /proc/cpuinfo ]]; then
            if grep -qi "hypervisor" /proc/cpuinfo; then
                if dmesg | grep -qi "kvm"; then
                    virt_type="KVM"
                elif dmesg | grep -qi "vmware"; then
                    virt_type="VMware"
                elif dmesg | grep -qi "xen"; then
                    virt_type="Xen"
                elif dmesg | grep -qi "microsoft hv"; then
                    virt_type="Hyper-V"
                else
                    virt_type="虚拟化 (类型未知)"
                fi
            else
                virt_type="物理机"
            fi
        fi
    fi

    # 使用systemd检测
    if [[ "$virt_type" == "未知" ]]; then
        if command -v systemd-detect-virt &>/dev/null; then
            local sysd_virt=$(systemd-detect-virt)
            [[ "$sysd_virt" != "none" ]] && virt_type="$sysd_virt"
        fi
    fi
    
    echo "虚拟化技术: $virt_type"
}

# ==================== 1. 磁盘IO性能测试 ====================
test_disk_performance() {
    echo -e "\n\033[1;34m[磁盘测试] 建站IO密集型模式测试\033[0m"
    local test_file="/tmp/wp_io_test.bin"
    local result_file="/tmp/fio_result.json"
    
    # 清理可能的旧文件
    rm -f "$test_file" "$result_file" 2>/dev/null
    
    # 建站典型IO密集型模式：4K随机读写 + 64K顺序写
    echo "测试随机4K读取（数据库查询模式）..."
    fio --name=wp_db_read --filename="$test_file" --rw=randread --bs=4k \
        --size=200M --runtime=8 --direct=1 --numjobs=4 --group_reporting \
        --output-format=json --output="$result_file" >/dev/null 2>&1
    
    # 改进的解析逻辑
    local read_iops=0
    if [[ -f "$result_file" ]]; then
        if command -v jq &>/dev/null; then
            read_iops=$(jq '.jobs[0].read.iops' "$result_file" 2>/dev/null | cut -d. -f1)
        else
            read_iops=$(grep -o '"iops":[0-9.]*' "$result_file" | head -1 | cut -d: -f2 | cut -d. -f1)
        fi
    fi
    [[ -z "$read_iops" ]] || ! [[ "$read_iops" =~ ^[0-9]+$ ]] && read_iops=0
    
    echo "测试64K顺序写入（媒体上传模式）..."
    fio --name=wp_media_write --filename="$test_file" --rw=write --bs=64k \
        --size=200M --runtime=5 --direct=1 --numjobs=2 --group_reporting \
        --output-format=json --output="$result_file" >/dev/null 2>&1
    
    local write_bw=0
    if [[ -f "$result_file" ]]; then
        if command -v jq &>/dev/null; then
            write_bw=$(jq '.jobs[0].write.bw' "$result_file" 2>/dev/null | cut -d. -f1)
        else
            write_bw=$(grep -o '"bw":[0-9.]*' "$result_file" | head -1 | cut -d: -f2 | cut -d. -f1)
        fi
    fi
    [[ -z "$write_bw" ]] || ! [[ "$write_bw" =~ ^[0-9]+$ ]] && write_bw=0
    
    # 计算写入带宽（MB/s）
    local write_mbps=$((write_bw / 1024))
    # 综合IO评分（模拟GB5存储分数）
    DISK_IOPS=$((read_iops + write_bw / 100))
    
    # 使用人类可读的单位输出
    read_iops_formatted=$(format_number "$read_iops")
    write_mbps_formatted=$(format_number "$write_mbps")
    
    # 使用字符串存储综合评分
    DISK_IOPS_STR=$read_iops
    echo "4K 随机读 IOPS: ${read_iops_formatted}"
    echo "64K 写入带宽: ${write_mbps_formatted} MB/s (${write_bw} KB/s)"
    echo "综合 IO 评分: $(format_number "$DISK_IOPS")"

    # 清理临时文件
    rm -f "$test_file" "$result_file" 2>/dev/null
} 	
test_cpu_multicore_efficiency() {
    cores=$(nproc) 
    
    # 1. 单核性能测试
    echo "执行单核测试..."
    local single_output=$(openssl speed -multi 1 rsa2048 2>/dev/null | grep 'rsa 2048')
    # 提取时间值并转换为秒（移除's'后缀）
    local single_time_s=$(echo $single_output | awk '{gsub(/s/, "", $7); print $7}')
    # 转换为纯数字（使用bc处理浮点数）
    local single_time=$(echo $single_time_s | bc -l)
    
    # 2. 多核性能测试
    echo "执行多核测试（使用 $cores 个核心）..."
    local multi_output=$(openssl speed -multi $cores rsa2048 2>/dev/null | grep 'rsa 2048')
    local multi_time_s=$(echo $multi_output | awk '{gsub(/s/, "", $7); print $7}')
    local multi_time=$(echo $multi_time_s | bc -l)
    
    # 3. 计算实际扩展效率
    # 性能值 = 1/时间（签名次数/秒）
    local single_perf=$(echo "scale=10; 1 / $single_time" | bc -l)
    local multi_perf=$(echo "scale=10; 1 / $multi_time" | bc -l)
    
    # 正确公式：效率 = 多核性能 / (单核性能 × 核心数)
    actual_efficiency=$(echo "scale=4; $single_perf  / ($multi_perf )" | bc -l)
    echo "$single_perf"
    echo "$multi_perf"
    # 输出效率（保留两位小数）
    printf "%.2f\n" "$actual_efficiency"
}
# 新增：多核扩展效率测试函数
test_cpu_multicore_effici1ency() {
    cores=$(nproc) 
    
    # 1. 单核性能测试
    local single_start=$(date +%s%N)
    local single_perf=$(openssl speed -multi 1 rsa2048 2>/dev/null | grep 'rsa 2048') # | awk '{print $5}'
    local single_end=$(date +%s%N)
    local single_time_ms=$(( (single_end - single_start) / 1000000 ))
    
    # 2. 多核压力测试
    local multi_start=$(date +%s%N)
    local multi_perf=$(openssl speed -multi $cores rsa2048 2>/dev/null | grep 'rsa 2048' )#| awk '{print $5}'
    local multi_end=$(date +%s%N)
    local multi_time_ms=$(( (multi_end - multi_start) / 1000000 ))
    
    # 3. 计算实际扩展效率
    local theoretical_time=$(( $single_perf * cores ))
    actual_efficiency=$((theoretical_time / multi_perf))
    #echo "$actual_efficiency"
    
}

# ==================== 2. CPU性能测试 ====================
test_cpu_performance() {
    echo -e "\n\033[1;34m[CPU测试] 单核/多核计算能力\033[0m"
    
    # 获取CPU信息用于校准
    local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
    cores=$(nproc)
    local cpu_mhz=$(grep "cpu MHz" /proc/cpuinfo | head -1 | awk '{print $4}' | cut -d. -f1)
    [[ -z "$cpu_mhz" ]] && cpu_mhz=2000
    
    echo "CPU型号: $cpu_model"
    echo "核心数: $cores, 频率: ${cpu_mhz}MHz"
    
    # 运行基准测试
    run_cpu_benchmarks
    # 基于基准测试预估GB5分数
    CPU_SINGLE_SCORE=$(estimate_gb5_from_benchmarks)
    echo "base score：$CPU_SINGLE_SCORE"
    local cpu_single=$CPU_SINGLE_SCORE
     # ---- 型号特定系数（单核） ------------------------------------
    # 注意：EPYC 的判断必须放在所有 Ryzen 之后！
    if [[ "$cpu_model" =~ "Ryzen" ]]; then
       # 先尝试匹配带P型号
        if [[ "$cpu_model" =~ [[:space:]]+[0-9]{4}X ]]; then
            CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 110 / 100))  # 9700x等带x型号
        else
            CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 98 / 100))  
        fi 
    elif [[ "$cpu_model" =~ "EPYC" ]]; then
          # 先尝试匹配带P型号
        if [[ "$cpu_model" =~ EPYC[[:space:]]+7[0-9]{3}P ]]; then
            CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 130 / 100))  # 7502P等带P型号
        else
            CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 180 / 100))  # 标准EPYC型号
        fi
    elif [[ "$cpu_model" =~ "Xeon.*Gold" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 98 / 100))
    elif [[ "$cpu_model" =~ "Xeon.*Silver" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 97 / 100))
    elif [[ "$cpu_model" =~ "Xeon" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 95 / 100))
    fi
    echo "单核评分: $(format_number "$CPU_SINGLE_SCORE") (预估GB5)"
    # 新增：测试多核扩展效率
    echo "测试多核"
    test_cpu_multicore_efficiency 
    echo "扩展多核系数：$actual_efficiency"
    # 计算多核分数
    if (( $(echo "$actual_efficiency / $cores < 0.85" | bc -l) )); then
        # 扩展效率较低时使用方案a
        CPU_MULTI_SCORE=$(echo "scale=0; $CPU_SINGLE_SCORE * $actual_efficiency *$actual_efficiency / $cores * 0.92 / 1" | bc)
        echo "检测到扩展效率较低，使用核心数优化算法"
    else
        # 扩展效率较高时使用方案b
        CPU_MULTI_SCORE=$(echo "scale=0; $cpu_single * $actual_efficiency * 0.92 / 1" | bc)
        echo "检测到良好扩展效率，使用效率优先算法"
    fi 
    echo "多核评分: $(format_number "$CPU_MULTI_SCORE") (预估GB5)" 
}

# ==================== 3. 内存带宽测试 ====================
test_memory_bandwidth() {
    echo -e "\n\033[1;34m[内存测试] 内存带宽检测\033[0m"
    
    MEMORY_BANDWIDTH=0
    
    echo "内存读写速度测试..."
    if command -v sysbench &>/dev/null; then
        # 使用sysbench测试内存
        sysbench memory --memory-block-size=1K --memory-total-size=2G \
            --memory-oper=write --threads=4 --time=5 run > /tmp/mem_test.log 2>&1
        
        local mem_result=$(grep "MiB transferred" /tmp/mem_test.log | awk '{print $(NF-2)}' | sed 's/(//')
        if [[ "$mem_result" =~ ^[0-9.]+$ ]]; then
            MEMORY_BANDWIDTH=$(echo "$mem_result * 1024 / 5" | bc | cut -d. -f1)  # 转换为MB/s
        fi
        rm -f /tmp/mem_test.log 2>/dev/null
    fi
    
    # 备用方法：使用dd测试
    if [[ $MEMORY_BANDWIDTH -eq 0 ]]; then
        echo "使用dd测试内存速度..."
        local temp_file="/dev/shm/memtest.tmp"
        if [[ -d "/dev/shm" ]]; then
            sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
            local dd_result=$(dd if=/dev/zero of="$temp_file" bs=1M count=500 conv=fdatasync 2>&1 | \
                grep -o '[0-9.]* [MG]B/s' | head -1)
            
            if [[ "$dd_result" =~ ^[0-9.]+\ GB/s ]]; then
                local gb_speed=$(echo "$dd_result" | awk '{print $1}')
                MEMORY_BANDWIDTH=$(echo "$gb_speed * 1024" | bc | cut -d. -f1)
            elif [[ "$dd_result" =~ ^[0-9.]+\ MB/s ]]; then
                MEMORY_BANDWIDTH=$(echo "$dd_result" | awk '{print $1}' | cut -d. -f1)
            fi
            
            rm -f "$temp_file" 2>/dev/null
        fi
    fi
    
    if [[ $MEMORY_BANDWIDTH -gt 0 ]]; then
        # 转换为GB/s
        local mem_gbs=$(echo "scale=2; $MEMORY_BANDWIDTH / 1024" | bc)
        echo "内存带宽: $(format_number "$MEMORY_BANDWIDTH") MB/s (${mem_gbs} GB/s)"
    else
        echo "内存带宽: 无法检测"
        MEMORY_BANDWIDTH=3000  # 设置默认值
    fi
}

# ==================== 4. 中断风暴检测 ====================
test_interrupt_stability() {
    echo -e "\n\033[1;34m[稳定性测试] 中断和系统负载检测\033[0m"
    
    local before_file="/tmp/interrupts_before"
    local after_file="/tmp/interrupts_after"
    
    cat /proc/interrupts > "$before_file" 2>/dev/null
    local before_total=$(awk 'NR>1 && NF>2 {for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i} END{print sum+0}' "$before_file")
    
    echo "运行系统负载测试（5 秒）..."
    {
        for i in $(seq 1 $(nproc)); do
            timeout 5 bash -c 'x=0; while [ $((x++)) -lt 10000000 ]; do :; done' & 
        done
        timeout 5 dd if=/dev/zero of=/tmp/loadtest bs=1M count=100 conv=fdatasync >/dev/null 2>&1 & 
        wait
    } >/dev/null 2>&1
    
    sleep 1
    cat /proc/interrupts > "$after_file" 2>/dev/null
    local after_total=$(awk 'NR>1 && NF>2 {for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i} END{print sum+0}' "$after_file")
    
    local interrupt_rate=$(( (after_total - before_total) / 5 ))
    echo "中断频率: $(format_number "$interrupt_rate") 次/秒"
    
    # 分析异常中断
    local critical_irqs=0
    if [[ -f "$before_file" && -f "$after_file" ]]; then
        while read -r line; do
            local irq=$(echo "$line" | awk '{print $1}' | tr -d ':')
            [[ ! "$irq" =~ ^[0-9]+$ ]] && continue
            
            local before_count=$(grep "^ *$irq:" "$before_file" 2>/dev/null | \
                awk 'NF>2 {sum=0; for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i; print sum}')
            local after_count=$(grep "^ *$irq:" "$after_file" 2>/dev/null | \
                awk 'NF>2 {sum=0; for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i; print sum}')
            
            if [[ -n "$before_count" && -n "$after_count" && "$after_count" -gt "$before_count" ]]; then
                local diff=$((after_count - before_count))
                if [[ $diff -gt 2000 ]]; then
                    echo "⚠️ IRQ $irq 异常活跃: $diff 次中断"
                    critical_irqs=$((critical_irqs + 1))
                fi
            fi
        done < <(tail -n +2 "$after_file")
    fi
    
    rm -f "$before_file" "$after_file" "/tmp/loadtest" 2>/dev/null
    
    # 稳定性评级
    if [[ $critical_irqs -gt 3 ]]; then
        echo "🔴 系统不稳定：检测到 $critical_irqs 个异常中断源"
        return 2
    elif [[ $interrupt_rate -gt 100000 ]]; then
        echo "🟠 系统负载偏高：中断频率 > 10万/秒"
        return 1
    else
        echo "🟢 系统稳定：中断处理正常"
        return 0
    fi
}

# ==================== 5. 修复的网络延迟测试 ====================
test_network_latency() {
    echo -e "\n\033[1;34m[网络测试] CDN和数据库连接延迟\033[0m"
    
    local targets=("8.8.8.8" "1.1.1.1")
    local total_latency="0"
    local successful_pings=0
    
    for target in "${targets[@]}"; do
        echo "测试到 $target 的延迟..."
        local ping_result=$(timeout 3 ping -c 3 -W 1 "$target" 2>/dev/null | \
            grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}' | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')
        
        if [[ "$ping_result" =~ ^[0-9.]+$ ]] && [[ $(echo "$ping_result > 0" | bc 2>/dev/null || echo 0) -eq 1 ]]; then
            total_latency=$(echo "$total_latency + $ping_result" | bc)
            successful_pings=$((successful_pings + 1))
            echo "延迟: ${ping_result}ms"
        else
            echo "延迟: 超时"
        fi
    done
    
    if [[ $successful_pings -gt 0 ]]; then
        NETWORK_LATENCY=$(echo "scale=2; $total_latency / $successful_pings" | bc)
        echo "平均网络延迟: ${NETWORK_LATENCY}ms"
    else
        echo "网络连接异常"
        NETWORK_LATENCY="999"
    fi
}

# ==================== 6. 超售程度评估 ====================
assess_overselling() {
    echo -e "\n\033[1;35m[超售检测] 系统资源分配评估\033[0m"
    
    local cpu_score=0
    local memory_score=0
    local io_score=0
    local total_score=0
    
    # 1. CPU超售检测
    if [[ "$actual_efficiency" != "0" ]]; then
        # 多核扩展效率评估
        local efficiency_percent=$(echo "$actual_efficiency / $cores * 100" | bc -l | cut -d. -f1)
        
        if [[ $efficiency_percent -ge 85 ]]; then
            echo "CPU扩展效率: 优秀 ($efficiency_percent%) - 无超售迹象"
            cpu_score=3
        elif [[ $efficiency_percent -ge 70 ]]; then
            echo "CPU扩展效率: 良好 ($efficiency_percent%) - 轻度超售"
            cpu_score=2
        elif [[ $efficiency_percent -ge 50 ]]; then
            echo "CPU扩展效率: 一般 ($efficiency_percent%) - 中度超售"
            cpu_score=1
        else
            echo "CPU扩展效率: 差 ($efficiency_percent%) - 严重超售"
            cpu_score=0
        fi
    else
        # 基于CPU型号和性能比对的备选方案
        local expected_score=0
        case "$cpu_model" in
            *Xeon*Gold*)
                expected_score=2500
                ;;
            *Xeon*Silver*)
                expected_score=1800
                ;;
            *Ryzen*9*)
                expected_score=2200
                ;;
            *EPYC*)
                expected_score=2000
                ;;
            *)
                expected_score=1500
                ;;
        esac
        
        local performance_ratio=$(( CPU_SINGLE_SCORE * 100 / expected_score ))
        
        if [[ $performance_ratio -ge 90 ]]; then
            echo "CPU性能: 符合预期 ($performance_ratio% 达到同类CPU水平) - 无超售迹象"
            cpu_score=3
        elif [[ $performance_ratio -ge 70 ]]; then
            echo "CPU性能: 略低于预期 ($performance_ratio% 达到同类CPU水平) - 可能超售"
            cpu_score=2
        else
            echo "CPU性能: 显著低于预期 ($performance_ratio% 达到同类CPU水平) - 可能严重超售"
            cpu_score=1
        fi
    fi
    
    # 2. 内存超售检测
    local mem_used=$(free -m | awk '/Mem:/ {printf "%.1f", $3/$2*100}')
    local swap_used=$(free -m | awk '/Swap:/ {if ($2 == 0) print "0"; else printf "%.1f", $3/$2*100}')
    
    # 内存带宽评估
    local mem_bandwidth_gbs=$(echo "scale=2; $MEMORY_BANDWIDTH / 1024" | bc)
    local mem_bandwidth_score=0
    
    if [ $(echo "$mem_bandwidth_gbs > 15" | bc -l) -eq 1 ]; then
        echo "内存带宽: 优秀 (${mem_bandwidth_gbs} GB/s) - 无超售迹象"
        mem_bandwidth_score=3
    elif [ $(echo "$mem_bandwidth_gbs > 8" | bc -l) -eq 1 ]; then
        echo "内存带宽: 良好 (${mem_bandwidth_gbs} GB/s) - 轻度超售可能"
        mem_bandwidth_score=2 
    elif [ $(echo "$mem_bandwidth_gbs > 3" | bc -l) -eq 1 ]; then
        echo "内存带宽: 普通 (${mem_bandwidth_gbs} GB/s) - 重度超售可能"
        mem_bandwidth_score=1 
    else
        echo "内存带宽: 较差 (${mem_bandwidth_gbs} GB/s) - 可能严重超售"
        mem_bandwidth_score=0
    fi 
    
    memory_score=$(( mem_bandwidth_score + mem_usage_score + swap_score ))
    
    # 3. IO超售检测
    # 数据库查询性能评估 (4K随机读)
    if [[ $DISK_IOPS_STR -gt 10000 ]]; then
        echo "数据库查询性能: 优秀 ($(format_number $read_iops_formatted) IOPS) - 无超售迹象"
        io_score=3
    elif [[ $DISK_IOPS_STR -gt 3000 ]]; then
        echo "数据库查询性能: 良好 ($(format_number $read_iops_formatted) IOPS) - 轻度超售可能"
        io_score=2
    elif [[ $DISK_IOPS_STR -gt 1000 ]]; then
        echo "数据库查询性能: 一般 ($(format_number $read_iops_formatted) IOPS) - 可能超售"
        io_score=1
    else
        echo "数据库查询性能: 差 ($(format_number $read_iops_formatted) IOPS) - 可能严重超售"
        io_score=0
    fi
    
    # 媒体上传性能评估 (64K顺序写)
    if [[ $write_mbps_formatted -gt 500 ]]; then  # >500 MB/s
        echo "媒体上传性能: 优秀 ($(format_number $((write_mbps_formatted))) MB/s) - 无超售迹象"
        io_score=$((io_score + 1))
    elif [[ $write_mbps_formatted -gt 200 ]]; then  # >200 MB/s
        echo "媒体上传性能: 良好 ($(format_number $((write_mbps_formatted))) MB/s) - 轻度超售可能"
        io_score=$((io_score + 1))
    else
        echo "媒体上传性能: 差 ($(format_number $((write_mbps_formatted))) MB/s) - 可能超售"
    fi
    
    # 综合评分
    total_score=$((cpu_score + memory_score + io_score))
    local oversell_level=""
    if [[ $total_score -ge 9 ]]; then
        oversell_level="非常好"
    elif [[ $total_score -ge 8 ]]; then
        oversell_level="无超售迹象"
    elif [[ $total_score -ge 6 ]]; then
        oversell_level="轻度超售可能"
    elif [[ $total_score -ge 3 ]]; then
        oversell_level="中度超售"
    else
        oversell_level="发现远古巨瘦 您已严重超售"
    fi
    
    echo -e "\n\033[1;35m超售综合评估: ${total_score}/10 - ${oversell_level}\033[0m"
}
testc() {
     
    cache_mb=$(echo "$l3_cache" | sed 's/.*\\([0-9]\\+\\) MB.*/\\1/')
    [ -n "$cache_mb" ] || cache_mb=0
    cache_bonus=$(($cache_mb * 20))
    echo "L3 cache $cache_mb"   
    #estimate_gb5_from_benchmarks 118 216 531
    #test_cpu_performance
    #test_cpu_multicore_efficiency
}
# ==================== 主函数 ====================
main() {
    install_tools
    detect_virtualization
    test_disk_performance
    test_cpu_performance
    test_memory_bandwidth
    test_interrupt_stability
    #test_network_latency
    assess_overselling
    
    echo -e "\n\033[1;32m检测完成！\033[0m"
}

# 执行主程序
main "$@"
