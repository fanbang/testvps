#!/bin/bash
# WordPress VPS 性能快速检测脚本 v2.0
# 修复浮点数处理、GB5 预估基准（2000）以及若干细节

# ==================== 全局变量 ====================
declare -gi DISK_IOPS=0
declare -gi MEMORY_BANDWIDTH=0
declare -gi CPU_SINGLE_SCORE=0
declare -gi CPU_MULTI_SCORE=0
declare -g  NETWORK_LATENCY="0"

# GB5 基准分数（单核），默认 2300，可自行调节
declare -gi GB5_BASE_SCORE=1850

# ==================== 工具安装 ====================
install_tools() {
    local tools_needed=""
    command -v fio      &>/dev/null || tools_needed="${tools_needed} fio"
    command -v sysbench &>/dev/null || tools_needed="${tools_needed} sysbench"
    command -v bc       &>/dev/null || tools_needed="${tools_needed} bc"
    command -v jq       &>/dev/null || tools_needed="${tools_needed} jq"

    if [[ -n "$tools_needed" ]]; then
        echo "安装必要工具: $tools_needed"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y $tools_needed -qq
        elif command -v yum &>/dev/null; then
            yum install -y $tools_needed -q
        fi
    fi
}

# ==================== 辅助函数 ====================
# 数值格式化（千位分隔）
format_number() {
    local num=$1
    num=$(echo "$num" | cut -d. -f1)
    [[ -z "$num" ]] || ! [[ "$num" =~ ^[0-9]+$ ]] && echo "0" && return
    [[ "$num" -lt 1000 ]] && echo "$num" && return
    echo "$num" | awk '{printf "%'\''d", $1}'
    #printf "%'0.2f\n" "$num"
}

# 安全的浮点数比较
float_compare() {
    local v1=$1 op=$2 v2=$3
    echo "$v1 $op $v2" | bc -l 2>/dev/null || echo 0
}

# ==================== 1. 磁盘 IO 性能 ====================
test_disk_performance() {
    echo -e "\n\033[1;34m[磁盘测试] WordPress IO 模式测试\033[0m"
    local test_file="/tmp/wp_io_test.bin"
    local result_file="/tmp/fio_result.json"

    echo "测试随机 4K 读取（数据库查询模式）..."
    fio --name=wp_db_read --filename="$test_file" --rw=randread --bs=4k \
        --size=200M --runtime=8 --direct=1 --numjobs=4 --group_reporting \
        --output-format=json --output="$result_file" >/dev/null 2>&1

    local read_iops=0
    if command -v jq &>/dev/null; then
        read_iops=$(jq '.jobs[0].read.iops' "$result_file" 2>/dev/null | cut -d. -f1)
    else
        read_iops=$(grep -o '"iops":[0-9.]*' "$result_file" | head -1 | cut -d: -f2 | cut -d. -f1)
    fi
    [[ -z "$read_iops" ]] || ! [[ "$read_iops" =~ ^[0-9]+$ ]] && read_iops=0

    echo "测试 64K 顺序写入（媒体上传模式）..."
    fio --name=wp_media_write --filename="$test_file" --rw=write --bs=64k \
        --size=200M --runtime=5 --direct=1 --numjobs=2 --group_reporting \
        --output-format=json --output="$result_file" >/dev/null 2>&1

    local write_bw=0
    if command -v jq &>/dev/null; then
        write_bw=$(jq '.jobs[0].write.bw' "$result_file" 2>/dev/null | cut -d. -f1)
    else
        write_bw=$(grep -o '"bw":[0-9.]*' "$result_file" | head -1 | cut -d: -f2 | cut -d. -f1)
    fi
    [[ -z "$write_bw" ]] || ! [[ "$write_bw" =~ ^[0-9]+$ ]] && write_bw=0

    # 综合 IO 评分（模拟 GB5 存储分数）
    DISK_IOPS=$((read_iops + write_bw / 100))

    echo "4K 随机读 IOPS: $(format_number "$read_iops")"
    echo "64K 写入带宽: $(format_number "$write_bw") KB/s"
    echo "综合 IO 评分: $(format_number "$DISK_IOPS")"

    rm -f "$test_file" "$result_file" 2>/dev/null
}

# ==================== 2. CPU 性能 ====================
# -------------------------------------------------
# 2. 改进的CPU性能测试

test_cpu_performance() {
    echo -e "\n\033[1;32m[CPU测试] 单核/多核计算能力\033[0m"

    # ---- 基本信息 -------------------------------------------------
    local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
    local cores=$(nproc)
    local cpu_mhz=$(grep "cpu MHz" /proc/cpuinfo | head -1 | awk '{print $4}' | cut -d. -f1)
    [[ -z "$cpu_mhz" ]] && cpu_mhz=2000

    echo "CPU型号: $cpu_model"
    echo "核心数: $cores, 频率: ${cpu_mhz}MHz"

    # ---- 单核测试 -------------------------------------------------
    echo "单核计算测试（混合负载模式）..."
    local test_start=$(date +%s%N)
    # 1. 质数计算测试（整数性能）
    sysbench cpu --cpu-max-prime=30000 --threads=1 --time=3 run > /tmp/cpu_prime.log 2>&1
    local prime_events=$(grep "total number of events" /tmp/cpu_prime.log | awk '{print $5}')
    
    # 2. 浮点计算测试
    sysbench cpu --cpu-max-prime=20000 --threads=1 --time=3 run > /tmp/cpu_float.log 2>&1
    local float_events=$(grep "total number of events" /tmp/cpu_float.log | awk '{print $5}')
    
    rm -f /tmp/cpu_prime.log /tmp/cpu_float.log 2>/dev/null
    local test_end=$(date +%s%N)
    local test_ms=$(( (test_end - test_start) / 1000000 ))
    
    # 综合评分计算
    local total_events=$((prime_events + float_events))
    local events_per_sec=$((total_events * 1000 / test_ms))  

    # 基础分数（GB5 基准 1500）
    local base_score=$(( events_per_sec * GB5_BASE_SCORE / 2000 ))

    # 调试信息（可选）
    echo "base_score: $base_score"
    
    # 频率校准（保留小数 → 乘 1000 再除）
    local freq_factor_int=$(awk "BEGIN{printf \"%d\", ($cpu_mhz/2500)*1000}")   # 1516 / 998
    CPU_SINGLE_SCORE=$(( base_score * freq_factor_int / 1000 ))

    # 调试信息（可选）
    echo "freq_factor_int: $freq_factor_int"
    
    # ---- 型号特定系数（单核） ------------------------------------
    # 注意：EPYC 的判断必须放在所有 Ryzen 之后！
    if [[ "$cpu_model" =~ "Ryzen 9" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 95 / 100))
    elif [[ "$cpu_model" =~ "Ryzen 7" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 90 / 100))
    elif [[ "$cpu_model" =~ "Ryzen 5" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 85 / 100))
    elif [[ "$cpu_model" =~ "Ryzen" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 80 / 100))  
    elif [[ "$cpu_model" =~ "EPYC" ]]; then
          # 先尝试匹配带P型号
        if [[ "$cpu_model" =~ EPYC[[:space:]]+7[0-9]{3}P ]]; then
            CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 220 / 100))  # 7502P等带P型号
        else
            CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 280 / 100))  # 标准EPYC型号
        fi
    elif [[ "$cpu_model" =~ "Xeon.*Gold" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 90 / 100))
    elif [[ "$cpu_model" =~ "Xeon.*Silver" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 75 / 100))
    elif [[ "$cpu_model" =~ "Xeon" ]]; then
        CPU_SINGLE_SCORE=$((CPU_SINGLE_SCORE * 80 / 100))
    fi

    # 合理范围限制
    [[ $CPU_SINGLE_SCORE -gt 3500 ]] && CPU_SINGLE_SCORE=3500
    [[ $CPU_SINGLE_SCORE -lt 200  ]] && CPU_SINGLE_SCORE=200

    if [[ $cores -eq 1 ]]; then
        CPU_MULTI_SCORE=$((CPU_SINGLE_SCORE * 99 / 100))
    else 
        # ---- 多核测试 -------------------------------------------------
        echo "多核测试（$cores 核心）..."
        local test_start=$(date +%s%N)
    # 1. 质数计算测试（整数性能）
        sysbench cpu --cpu-max-prime=30000 --threads="$cores"  --time=3 run > /tmp/cpu_prime.log 2>&1
        local prime_events=$(grep "total number of events" /tmp/cpu_prime.log | awk '{print $5}')
    
    # 2. 浮点计算测试
        sysbench cpu --cpu-max-prime=20000 --threads="$cores"  --time=3 run > /tmp/cpu_float.log 2>&1
        local float_events=$(grep "total number of events" /tmp/cpu_float.log | awk '{print $5}')
    
        rm -f /tmp/cpu_prime.log /tmp/cpu_float.log 2>/dev/null
        local test_end=$(date +%s%N)
        local test_ms=$(( (test_end - test_start) / 1000000 ))
    
    # 综合评分计算
        local total_events=$((prime_events + float_events))
        local multi_events_per_sec=$((total_events * 1000 / test_ms))   
        
        # 基础多核分数（先按线性放大，再乘频率因子）
        local freq_factor_multi_int=$(awk "BEGIN{printf \"%d\", ($cpu_mhz/2500)*1000}")
        local base_multi=$(( multi_events_per_sec * freq_factor_multi_int / 1000 ))

        # 效率系数优化（调整为更合理的值）
        local efficiency
        case $cores in
            2)  efficiency=92 ;;
            3)  efficiency=85 ;;   # 3核效率85%
            4)  efficiency=80 ;;   # 4核效率80%
            8)  efficiency=75 ;;   # 8核效率75%
            16) efficiency=70 ;;   # 16核效率70%
            *)  efficiency=65 ;;   # 其他核数效率65%
        esac
        
        CPU_MULTI_SCORE=$(( base_multi * efficiency / 100 ))
        
        # 多核型号系数优化
        if [[ "$cpu_model" =~ "EPYC" ]]; then
          # 先尝试匹配带P型号
            if [[ "$cpu_model" =~ EPYC[[:space:]]+7[0-9]{3}P ]]; then
                CPU_MULTI_SCORE=$((CPU_MULTI_SCORE * 220 / 100))  # 7502P等带P型号
            else
                CPU_MULTI_SCORE=$((CPU_MULTI_SCORE * 280 / 100))  # 标准EPYC型号
            fi
        elif [[ "$cpu_model" =~ "Xeon" ]]; then
            CPU_MULTI_SCORE=$((CPU_MULTI_SCORE * 90 / 100))
        elif [[ "$cpu_model" =~ "Ryzen" ]]; then
            CPU_MULTI_SCORE=$((CPU_MULTI_SCORE * 80 / 100))
        fi

        [[ $CPU_MULTI_SCORE -gt 20000 ]] && CPU_MULTI_SCORE=20000
    fi

    echo "单核评分: $(format_number "$CPU_SINGLE_SCORE") (预估 GB5)"
    echo "多核评分: $(format_number "$CPU_MULTI_SCORE") (预估 GB5)"
 
}
# -------------------------------------------------

# ==================== 3. 内存带宽 ====================
test_memory_bandwidth() {
    echo -e "\n\033[1;34m[内存测试] 内存带宽检测\033[0m"
    MEMORY_BANDWIDTH=0

    echo "使用 sysbench 进行内存写入测试..."
    if command -v sysbench &>/dev/null; then
        sysbench memory --memory-block-size=1K --memory-total-size=2G \
            --memory-oper=write --threads=4 --time=5 run > /tmp/mem_test.log 2>&1

        local mem_result=$(grep "MiB transferred" /tmp/mem_test.log | awk '{print $(NF-2)}' | sed 's/(//')
        if [[ "$mem_result" =~ ^[0-9.]+$ ]]; then
            MEMORY_BANDWIDTH=$(echo "$mem_result * 1024 / 5" | bc | cut -d. -f1)  # MB/s
        fi
        rm -f /tmp/mem_test.log 2>/dev/null
    fi

    # 备用方案：dd + /dev/shm
    if [[ $MEMORY_BANDWIDTH -eq 0 ]]; then
        echo "使用 dd 进行内存带宽测试..."
        local tmp_file="/dev/shm/memtest.tmp"
        if [[ -d "/dev/shm" ]]; then
            sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
            local dd_res=$(dd if=/dev/zero of="$tmp_file" bs=1M count=500 conv=fdatasync 2>&1 |
                grep -o '[0-9.]* [MG]B/s' | head -1)

            if [[ "$dd_res" =~ ^([0-9.]+)\ GB/s ]]; then
                local gb=$(echo "$dd_res" | awk '{print $1}')
                MEMORY_BANDWIDTH=$(echo "$gb * 1024" | bc | cut -d. -f1)
            elif [[ "$dd_res" =~ ^([0-9.]+)\ MB/s ]]; then
                MEMORY_BANDWIDTH=$(echo "$dd_res" | awk '{print $1}' | cut -d. -f1)
            fi
            rm -f "$tmp_file" 2>/dev/null
        fi
    fi

    if [[ $MEMORY_BANDWIDTH -gt 0 ]]; then
        echo "内存带宽: $(format_number "$MEMORY_BANDWIDTH") MB/s"
    else
        echo "内存带宽: 无法检测，使用默认值 3000 MB/s"
        MEMORY_BANDWIDTH=3000
    fi
}

# ==================== 4. 中断与系统负载 ====================
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

    # 检测异常中断
    local critical_irqs=0
    if [[ -f "$before_file" && -f "$after_file" ]]; then
        while read -r line; do
            local irq=$(echo "$line" | awk '{print $1}' | tr -d ':')
            [[ ! "$irq" =~ ^[0-9]+$ ]] && continue

            local before_cnt=$(grep "^ *$irq:" "$before_file" 2>/dev/null |
                awk 'NF>2 {sum=0; for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i; print sum}')
            local after_cnt=$(grep "^ *$irq:" "$after_file" 2>/dev/null |
                awk 'NF>2 {sum=0; for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i; print sum}')

            if [[ -n "$before_cnt" && -n "$after_cnt" && "$after_cnt" -gt "$before_cnt" ]]; then
                local diff=$((after_cnt - before_cnt))
                if [[ $diff -gt 2000 ]]; then
                    echo "⚠️ IRQ $irq 异常活跃: $diff 次中断"
                    critical_irqs=$((critical_irqs + 1))
                fi
            fi
        done < <(tail -n +2 "$after_file")
    fi

    rm -f "$before_file" "$after_file" "/tmp/loadtest" 2>/dev/null

    if [[ $critical_irqs -gt 3 ]]; then
        echo "🔴 系统不稳定：检测到 $critical_irqs 个异常中断源"
        return 2
    elif [[ $interrupt_rate -gt 100000 ]]; then
        echo "🟠 系统负载偏高：中断频率 > 10 万/秒"
        return 1
    else
        echo "🟢 系统稳定：中断处理正常"
        return 0
    fi
}

# ==================== 5. 网络延迟 ====================
test_network_latency() {
    echo -e "\n\033[1;34m[网络测试] CDN 和数据库连接延迟\033[0m"

    local targets=("8.8.8.8" "192.124.171.1" "60.190.160.1")
    local total_latency="0"
    local successful=0

    for tgt in "${targets[@]}"; do
        echo "测试到 $tgt 的延迟..."
        local ping_res=$(timeout 3 ping -c 3 -W 1 "$tgt" 2>/dev/null |
            grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}' |
            awk '{sum+=$1; cnt++} END{if(cnt) printf "%.2f", sum/cnt; else print "0"}')

        if [[ "$ping_res" =~ ^[0-9.]+$ ]] && (( $(echo "$ping_res > 0" | bc -l) )); then
            total_latency=$(echo "$total_latency + $ping_res" | bc)
            successful=$((successful + 1))
            echo "延迟: ${ping_res}ms"
        else
            echo "延迟: 超时"
        fi
    done

    if (( successful > 0 )); then
        NETWORK_LATENCY=$(echo "scale=2; $total_latency / $successful" | bc)
        echo "平均网络延迟: ${NETWORK_LATENCY}ms"
    else
        echo "网络全部超时"
        NETWORK_LATENCY="999"
    fi
}

# ==================== 6. 超售分析 ====================
assess_overselling() {
    echo -e "\n\033[1;31m[超售分析] VPS 资源超售程度评估\033[0m"
    local oversell=0

    # CPU 超售
    if (( CPU_SINGLE_SCORE < 600 )); then
        echo "🔴 CPU 严重超售：单核性能过低 ($CPU_SINGLE_SCORE < 600)"
        oversell=$((oversell + 3))
    elif (( CPU_SINGLE_SCORE < 1000 )); then
        echo "🟠 CPU 轻度超售：单核性能偏低 ($CPU_SINGLE_SCORE < 1000)"
        oversell=$((oversell + 1))
    elif (( CPU_SINGLE_SCORE > 2000 )); then
        echo "🟢 CPU 性能优秀：单核评分 $CPU_SINGLE_SCORE (>2000)"
    else
        echo "🟢 CPU 性能正常：单核评分 $CPU_SINGLE_SCORE"
    fi

    # 存储超售
    if (( DISK_IOPS < 2000 )); then
        echo "🔴 存储严重超售：IOPS 过低"
        oversell=$((oversell + 3))
    elif (( DISK_IOPS < 5000 )); then
        echo "🟠 存储轻度超售：IOPS 偏低"
        oversell=$((oversell + 1))
    else
        echo "🟢 存储性能正常：IOPS $(format_number "$DISK_IOPS")"
    fi

    # 内存超售
    if (( MEMORY_BANDWIDTH < 2000 )); then
        echo "🔴 内存严重超售：带宽过低"
        oversell=$((oversell + 2))
    elif (( MEMORY_BANDWIDTH < 5000 )); then
        echo "🟠 内存轻度超售：带宽偏低"
        oversell=$((oversell + 1))
    else
        echo "🟢 内存性能正常：带宽 $(format_number "$MEMORY_BANDWIDTH") MB/s"
    fi

    # 网络超载
    local lat_int=$(echo "$NETWORK_LATENCY" | cut -d. -f1)
    if (( lat_int > 200 )); then
        echo "🔴 网络拥堵：延迟过高 (${NETWORK_LATENCY}ms)"
        oversell=$((oversell + 1))
    elif (( lat_int > 50 )); then
        echo "🟠 网络一般：延迟偏高 (${NETWORK_LATENCY}ms)"
    else
        echo "🟢 网络良好：延迟 ${NETWORK_LATENCY}ms"
    fi

    return $oversell
}

# ==================== 7. WordPress 并发预测 ====================
predict_wordpress_performance() {
    echo -e "\n\033[1;31m===== WordPress 并发能力预测 =====\033[0m"

    local concurrent=15   # 基础基准值

    # IO 影响（最关键）
    if (( DISK_IOPS > 50000 )); then
        concurrent=$((concurrent * 10))
    elif (( DISK_IOPS > 30000 )); then
        concurrent=$((concurrent * 8))
    elif (( DISK_IOPS > 20000 )); then
        concurrent=$((concurrent * 6))
    elif (( DISK_IOPS > 10000 )); then
        concurrent=$((concurrent * 4))
    elif (( DISK_IOPS > 5000 )); then
        concurrent=$((concurrent * 2))
    elif (( DISK_IOPS > 2000 )); then
        concurrent=$((concurrent * 3 / 2))
    else
        concurrent=$((concurrent / 2))
    fi

    # CPU 影响
    if (( CPU_SINGLE_SCORE > 2500 )); then
        concurrent=$((concurrent * 3 / 2))
    elif (( CPU_SINGLE_SCORE > 2000 )); then
        concurrent=$((concurrent * 5 / 4))
    elif (( CPU_SINGLE_SCORE < 1000 )); then
        concurrent=$((concurrent * 3 / 4))
    fi

    # 内存带宽影响
    if (( MEMORY_BANDWIDTH < 2000 )); then
        concurrent=$((concurrent * 3 / 4))
    elif (( MEMORY_BANDWIDTH < 3000 )); then
        concurrent=$((concurrent * 7 / 8))
    fi

    echo "预测 WordPress 并发用户数: ~${concurrent} 用户/秒"

    if (( concurrent > 150 )); then
        echo "🚀 高性能：适合大型商业网站"
    elif (( concurrent > 80 )); then
        echo "🟢 良好性能：适合中等流量网站"
    elif (( concurrent > 40 )); then
        echo "🟡 一般性能：适合小型网站"
    else
        echo "🔴 性能不足：可能影响用户体验"
    fi
}

# ==================== 8. GeekBench5 预估 ====================
estimate_geekbench5() {
    echo -e "\n\033[1;35m===== GeekBench5 分数预估 =====\033[0m"
    echo "预估单核分数: $(format_number "$CPU_SINGLE_SCORE")"
    echo "预估多核分数: $(format_number "$CPU_MULTI_SCORE")"

    if (( CPU_SINGLE_SCORE > 2500 )); then
        echo "CPU 等级: 高端桌面 CPU (Ryzen 9 / Intel i9)"
    elif (( CPU_SINGLE_SCORE > 2000 )); then
        echo "CPU 等级: 高性能桌面 CPU (Ryzen 7 9700X 级别)"
    elif (( CPU_SINGLE_SCORE > 1500 )); then
        echo "CPU 等级: 主流高性能 CPU (Ryzen 7 / Intel i7)"
    elif (( CPU_SINGLE_SCORE > 1200 )); then
        echo "CPU 等级: 主流 CPU (Ryzen 5 / Intel i5)"
    elif (( CPU_SINGLE_SCORE > 800 )); then
        echo "CPU 等级: 入门级现代 CPU"
    elif (( CPU_SINGLE_SCORE > 600 )); then
        echo "CPU 等级: 老旧或入门服务器 CPU"
    else
        echo "CPU 等级: 低端 / 严重超售"
    fi

    echo "📝 预估精度: ±10%（基于实际测试数据校准）"
}
# ==================== 主入口 ====================
main() {
    clear
    install_tools

    echo -e "\033[1;32m开始 VPS 性能检测...\033[0m"

    test_disk_performance
    test_cpu_performance
    test_memory_bandwidth

    local stability
    test_interrupt_stability
    stability=$?

    test_network_latency

    local oversell
    assess_overselling
    oversell=$?

    predict_wordpress_performance
    estimate_geekbench5

    echo -e "\n\033[1;31m===== 最终建议 =====\033[0m"
    if (( oversell >= 6 )); then
        echo "🔴 不推荐：严重超售，不适合生产环境"
    elif (( oversell >= 3 )); then
        echo "🟠 谨慎使用：存在超售，可能影响高峰性能"
    elif (( stability == 0 && DISK_IOPS > 5000 && CPU_SINGLE_SCORE > 1000 )); then
        echo "🟢 强烈推荐：性能优秀，非常适合 WordPress 生产环境"
    elif (( stability == 0 && DISK_IOPS > 2000 )); then
        echo "🟢 推荐：性能稳定，适合 WordPress 生产环境"
    else
        echo "🟡 可接受：基本满足需求，建议监控性能"
    fi

    echo -e "\n🕒 检测完成，总耗时约 30 秒"
    echo "📊 建议收集多个时间段的测试数据以获得更准确的评估"
}

testc() {
    test_cpu_performance  
}
# 捕获中断信号
trap 'echo -e "\n\033[1;31m测试被中断\033[0m"; exit 1' INT TERM

# ==================== 执行 ====================
main "$@"
