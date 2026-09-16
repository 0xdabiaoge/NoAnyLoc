#!/usr/bin/env bash
#
# ==============================================================================
# 项目名称: NoAnyLoc-Host (宿主机全局防送中系统)
# 适用系统: Debian / Ubuntu 系列 (深度支持 Proxmox VE / PVE 宿主机)
# 适用场景: LXC / KVM 虚拟化宿主机、物理母机出网总闸门
# 核心作用: 在宿主机出网总闸门处，强力阻断流经系统及所有 LXC 容器的定位 API 请求，
#           从根本上防止客户端因开启定位/Google GMS 上报导致宿主机与小鸡 IP 被“送中”。
# 项目主页: https://github.com/0xdabiaoge/NoAnyLoc
# ==============================================================================

set -o pipefail

# 全局配置常量
SCRIPT_VERSION="v2.1"
GITHUB_RAW_URL="https://raw.githubusercontent.com/0xdabiaoge/NoAnyLoc/main/noanyloc.sh"
GHPROXY_RAW_URL="https://ghfast.top/https://raw.githubusercontent.com/0xdabiaoge/NoAnyLoc/main/noanyloc.sh"

CONF_DIR="/etc/noanyloc"
DOMAINS_FILE="${CONF_DIR}/domains.conf"
CONFIG_FILE="${CONF_DIR}/noanyloc.conf"
SCRIPT_PATH="/usr/local/bin/noanyloc"
SYSTEMD_SERVICE="/etc/systemd/system/noanyloc.service"
SYSTEMD_TIMER="/etc/systemd/system/noanyloc-update.timer"
SYSTEMD_TIMER_SERVICE="/etc/systemd/system/noanyloc-update.service"

IPSET4="noanyloc_v4"
IPSET6="noanyloc_v6"
CHAIN_NAME="NOANYLOC"

# 终端色彩定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 内置高精度定位 API 域名列表（严格剔除 www.googleapis.com 等业务域名，零误杀）
DEFAULT_DOMAINS="
geolocation.googleapis.com
geocode.googleapis.com
gspe1-ssl.ls.apple.com
gs-loc.apple.com
maps-api.apple.com
ls.apple.com
location.services.mozilla.com
location.microsoft.com
inference.location.live.net
"

# 公共 DNS 列表（并发解析，抵御 Anycast 节点局限与 DNS 污染）
DNS_SERVERS="1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222"

# ==============================================================================
# 基础工具函数
# ==============================================================================

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[错误]${NC} 必须使用 root 权限执行此脚本！"
        exit 1
    fi
}

# 人性化数据流量单位转换 (B / KB / MB / GB)
format_bytes() {
    local bytes="$1"
    if [ -z "${bytes}" ] || ! [[ "${bytes}" =~ ^[0-9]+$ ]]; then
        echo "0 B"
        return
    fi
    if [ "${bytes}" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "${bytes}" -lt 1048576 ]; then
        awk "BEGIN {printf \"%.2f KB\", ${bytes}/1024}"
    elif [ "${bytes}" -lt 1073741824 ]; then
        awk "BEGIN {printf \"%.2f MB\", ${bytes}/1048576}"
    else
        awk "BEGIN {printf \"%.2f GB\", ${bytes}/1073741824}"
    fi
}

check_os() {
    local os_id=""
    local os_like=""
    if [ -f /etc/os-release ]; then
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        os_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi

    if [[ "${os_id}" =~ (debian|ubuntu) ]] || [[ "${os_like}" =~ (debian|ubuntu) ]] || [ -f /etc/debian_version ]; then
        return 0
    else
        echo -e "${RED}[错误]${NC} 本脚本专为 Debian / Ubuntu (包含 Proxmox VE) 宿主机环境深度定制。"
        echo -e "${RED}[错误]${NC} 当前系统不支持 (非 Debian/Ubuntu)，脚本已安全终止。"
        exit 1
    fi
}

log_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_err() {
    echo -e "${RED}[错误]${NC} $1"
}

# 检测宿主机是否拥有可用的 IPv6 出口
has_ipv6() {
    if [ -f /proc/net/if_inet6 ]; then
        if ip -6 route show default 2>/dev/null | grep -qE 'default'; then
            return 0
        elif ip -6 route show 2>/dev/null | grep -qE '^[0-9a-fA-F:]+/'; then
            return 0
        fi
    fi
    return 1
}

# 检测内核是否支持 xt_string 字符串匹配模块
has_xt_string() {
    if iptables -m string --help 2>&1 | grep -q "\-\-algo" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# 初始化配置目录与默认域名库
init_env() {
    mkdir -p "${CONF_DIR}"
    if [ ! -f "${DOMAINS_FILE}" ]; then
        cat <<EOF > "${DOMAINS_FILE}"
# NoAnyLoc 拦截域名列表
# 每一行代表一个需要阻断的定位 API 域名
# 默认配置已排除正常业务域名，请谨慎添加！
geolocation.googleapis.com
geocode.googleapis.com
gspe1-ssl.ls.apple.com
gs-loc.apple.com
maps-api.apple.com
ls.apple.com
location.services.mozilla.com
location.microsoft.com
inference.location.live.net
EOF
    fi

    if [ ! -f "${CONFIG_FILE}" ]; then
        cat <<EOF > "${CONFIG_FILE}"
# 自动更新间隔（小时），默认 2 小时
UPDATE_INTERVAL_HOURS=2
# 是否开启高级 SNI 字符串熔断 (0: 关闭, 1: 开启)
ENABLE_SNI_BLOCK=1
EOF
    fi

    # 软链接自身到 /usr/local/bin/noanyloc
    CURRENT_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    if [ -f "${CURRENT_SCRIPT}" ] && [ "${CURRENT_SCRIPT}" != "${SCRIPT_PATH}" ]; then
        cp -f "${CURRENT_SCRIPT}" "${SCRIPT_PATH}"
        chmod +x "${SCRIPT_PATH}"
    fi
}

# ==============================================================================
# 自动依赖安装
# ==============================================================================

install_dependencies() {
    local need_install=0
    command -v ipset >/dev/null 2>&1 || need_install=1
    command -v iptables >/dev/null 2>&1 || need_install=1
    command -v curl >/dev/null 2>&1 || need_install=1
    command -v dig >/dev/null 2>&1 || need_install=1

    if has_ipv6; then
        command -v ip6tables >/dev/null 2>&1 || need_install=1
    fi

    if [ "${need_install}" -eq 0 ]; then
        return 0
    fi

    log_info "正在自动检测并补齐系统必要组件 (ipset, iptables, curl, dnsutils)..."

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq ipset iptables iproute2 curl dnsutils ca-certificates >/dev/null 2>&1
    else
        log_err "未找到 apt-get 套件管理器，此脚本仅支持 Debian / Ubuntu 系列宿主机！"
        exit 1
    fi

    if ! command -v ipset >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1; then
        log_err "关键网络组件 ipset/iptables 安装失败，请检查系统网络与源配置！"
        exit 1
    fi

    log_info "组件安装就绪。"
}

# ==============================================================================
# 宿主机环境与网络拓扑侦测
# ==============================================================================

detect_host_network() {
    # 物理外网接口
    HOST_DEFAULT_IF=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
    [ -z "${HOST_DEFAULT_IF}" ] && HOST_DEFAULT_IF="未知/未检测到"

    # 虚拟网桥接口（常见于 PVE / LXD）
    HOST_BRIDGES=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | tr '\n' ',' | sed 's/,$//')
    [ -z "${HOST_BRIDGES}" ] && HOST_BRIDGES="无桥接网卡或独立物理网卡直出"

    # 宿主机公网 IPv4
    HOST_IPV4=$(curl -s4m 3 https://api.ipify.org 2>/dev/null || curl -s4m 3 https://ip.sb 2>/dev/null || echo "无法获取")
    
    # 宿主机公网 IPv6
    if has_ipv6; then
        HOST_IPV6=$(curl -s6m 3 https://api64.ipify.org 2>/dev/null || curl -s6m 3 https://ip.sb 2>/dev/null || echo "已启用但获取超时")
    else
        HOST_IPV6="未启用或无路由"
    fi
}

# ==============================================================================
# DNS 并发解析引擎与 IP 汇聚
# ==============================================================================

resolve_targets() {
    local v4_tmp_file="/tmp/noanyloc_v4.tmp"
    local v6_tmp_file="/tmp/noanyloc_v6.tmp"
    rm -f "${v4_tmp_file}" "${v6_tmp_file}"
    touch "${v4_tmp_file}" "${v6_tmp_file}"

    # 读取域名配置
    local domains
    if [ -f "${DOMAINS_FILE}" ]; then
        domains=$(grep -vE '^\s*#|^\s*$' "${DOMAINS_FILE}")
    else
        domains="${DEFAULT_DOMAINS}"
    fi

    log_info "正在利用多路权威 DNS 并发解析定位 API IP 资产池..."

    for domain in ${domains}; do
        # 1. 本机 getent / ahostsv4 解析
        getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' >> "${v4_tmp_file}"
        if has_ipv6; then
            getent ahostsv6 "${domain}" 2>/dev/null | awk '{print $1}' >> "${v6_tmp_file}"
        fi

        # 2. 外部公共 DNS 并发深挖 (1.1.1.1, 8.8.8.8 等)
        if command -v dig >/dev/null 2>&1; then
            for dns in ${DNS_SERVERS}; do
                (
                    dig +short +time=2 +tries=1 "@${dns}" "${domain}" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "${v4_tmp_file}"
                    if has_ipv6; then
                        dig +short +time=2 +tries=1 "@${dns}" "${domain}" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' >> "${v6_tmp_file}"
                    fi
                ) &
            done
        fi
    done
    wait

    # 排序去重过滤
    local new_v4="/tmp/noanyloc_v4_new.txt"
    local new_v6="/tmp/noanyloc_v6_new.txt"
    sort -u "${v4_tmp_file}" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' > "${new_v4}" 2>/dev/null || true
    sort -u "${v6_tmp_file}" | grep -iE '^([0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}$' > "${new_v6}" 2>/dev/null || true
    rm -f "${v4_tmp_file}" "${v6_tmp_file}"

    local count_v4 count_v6
    count_v4=$(wc -l < "${new_v4}" 2>/dev/null || echo 0)
    count_v6=$(wc -l < "${new_v6}" 2>/dev/null || echo 0)

    # 容错防空机制：若本次外部解析因断网为空，且本地存在历史缓存，则平滑沿用历史缓存
    if [ "${count_v4}" -gt 0 ]; then
        mv -f "${new_v4}" "${CONF_DIR}/ips_v4.txt"
    else
        rm -f "${new_v4}"
        if [ -s "${CONF_DIR}/ips_v4.txt" ]; then
            count_v4=$(wc -l < "${CONF_DIR}/ips_v4.txt" 2>/dev/null || echo 0)
            log_warn "外部 DNS 解析 IPv4 暂无响应，已自动平滑沿用本地有效规则缓存 (${count_v4} 个 IP)。"
        fi
    fi

    if [ "${count_v6}" -gt 0 ]; then
        mv -f "${new_v6}" "${CONF_DIR}/ips_v6.txt"
    else
        rm -f "${new_v6}"
        if [ -s "${CONF_DIR}/ips_v6.txt" ]; then
            count_v6=$(wc -l < "${CONF_DIR}/ips_v6.txt" 2>/dev/null || echo 0)
            log_warn "外部 DNS 解析 IPv6 暂无响应，已自动平滑沿用本地有效规则缓存 (${count_v6} 个 IP)。"
        fi
    fi

    log_info "DNS 解析与资产汇聚完毕：有效 IPv4 节点 ${count_v4} 个，IPv6 节点 ${count_v6} 个。"
}

# ==============================================================================
# IPSet 原子化更新与防火墙链条装载
# ==============================================================================

apply_rules() {
    install_dependencies
    resolve_targets

    log_info "正在注入宿主机全局 Netfilter 拦截流水线..."

    # ----------------- IPv4 处理 -----------------
    local TEMP_SET4="${IPSET4}_tmp"
    ipset create "${TEMP_SET4}" hash:ip family inet hashsize 1024 maxelem 65536 -exist
    ipset flush "${TEMP_SET4}"

    if [ -f "${CONF_DIR}/ips_v4.txt" ]; then
        while read -r ip; do
            [ -n "${ip}" ] && ipset add "${TEMP_SET4}" "${ip}" -exist
        done < "${CONF_DIR}/ips_v4.txt"
    fi

    # 确保主 set 存在
    ipset create "${IPSET4}" hash:ip family inet hashsize 1024 maxelem 65536 -exist
    # 原子替换：毫秒级热更新，零丢包
    ipset swap "${TEMP_SET4}" "${IPSET4}"
    ipset destroy "${TEMP_SET4}" 2>/dev/null || true

    # 构建 IPv4 自定义 Chain
    iptables -N "${CHAIN_NAME}" 2>/dev/null || true
    iptables -F "${CHAIN_NAME}"

    # REJECT 规则：针对 TCP 回送 RST，针对 UDP/ICMP 回送 unreachable，让客户端瞬间放弃
    iptables -A "${CHAIN_NAME}" -m set --match-set "${IPSET4}" dst -p tcp -j REJECT --reject-with tcp-reset
    iptables -A "${CHAIN_NAME}" -m set --match-set "${IPSET4}" dst -j REJECT --reject-with icmp-port-unreachable

    # 进阶特性：SNI 字符串熔断（若内核支持且配置开启）
    local enable_sni=1
    if [ -f "${CONFIG_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
        [ -n "${ENABLE_SNI_BLOCK}" ] && enable_sni="${ENABLE_SNI_BLOCK}"
    fi

    if [ "${enable_sni}" = "1" ] && has_xt_string; then
        # 针对 TLS Client Hello 的 SNI 扩展通常位于握手包前 200 字节，限定搜索区间降低 CPU 消耗并防止误杀
        iptables -A "${CHAIN_NAME}" -p tcp --dport 443 -m string --string "geolocation.googleapis.com" --algo bm --from 40 --to 180 -j REJECT --reject-with tcp-reset 2>/dev/null || true
        iptables -A "${CHAIN_NAME}" -p tcp --dport 443 -m string --string "gs-loc.apple.com" --algo bm --from 40 --to 180 -j REJECT --reject-with tcp-reset 2>/dev/null || true
        iptables -A "${CHAIN_NAME}" -p tcp --dport 443 -m string --string "maps-api.apple.com" --algo bm --from 40 --to 180 -j REJECT --reject-with tcp-reset 2>/dev/null || true
        iptables -A "${CHAIN_NAME}" -p tcp --dport 443 -m string --string "location.services.mozilla.com" --algo bm --from 40 --to 180 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    fi

    # 清理并挂载到系统入口：FORWARD 链（拦截全体小鸡）与 OUTPUT 链（拦截宿主机自身）
    while iptables -C FORWARD -j "${CHAIN_NAME}" 2>/dev/null; do
        iptables -D FORWARD -j "${CHAIN_NAME}" 2>/dev/null
    done
    iptables -I FORWARD 1 -j "${CHAIN_NAME}"

    while iptables -C OUTPUT -j "${CHAIN_NAME}" 2>/dev/null; do
        iptables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null
    done
    iptables -I OUTPUT 1 -j "${CHAIN_NAME}"

    # ----------------- IPv6 处理 -----------------
    if has_ipv6 && command -v ip6tables >/dev/null 2>&1; then
        local TEMP_SET6="${IPSET6}_tmp"
        ipset create "${TEMP_SET6}" hash:ip family inet6 hashsize 1024 maxelem 65536 -exist
        ipset flush "${TEMP_SET6}"

        if [ -f "${CONF_DIR}/ips_v6.txt" ]; then
            while read -r ip; do
                [ -n "${ip}" ] && ipset add "${TEMP_SET6}" "${ip}" -exist 2>/dev/null || true
            done < "${CONF_DIR}/ips_v6.txt"
        fi

        ipset create "${IPSET6}" hash:ip family inet6 hashsize 1024 maxelem 65536 -exist
        ipset swap "${TEMP_SET6}" "${IPSET6}"
        ipset destroy "${TEMP_SET6}" 2>/dev/null || true

        ip6tables -N "${CHAIN_NAME}" 2>/dev/null || true
        ip6tables -F "${CHAIN_NAME}"

        ip6tables -A "${CHAIN_NAME}" -m set --match-set "${IPSET6}" dst -p tcp -j REJECT --reject-with tcp-reset
        ip6tables -A "${CHAIN_NAME}" -m set --match-set "${IPSET6}" dst -j REJECT --reject-with icmp6-port-unreachable

        # IPv6 SNI 熔断
        if [ "${enable_sni}" = "1" ] && has_xt_string; then
            ip6tables -A "${CHAIN_NAME}" -p tcp --dport 443 -m string --string "geolocation.googleapis.com" --algo bm --from 40 --to 180 -j REJECT --reject-with tcp-reset 2>/dev/null || true
            ip6tables -A "${CHAIN_NAME}" -p tcp --dport 443 -m string --string "gs-loc.apple.com" --algo bm --from 40 --to 180 -j REJECT --reject-with tcp-reset 2>/dev/null || true
            ip6tables -A "${CHAIN_NAME}" -p tcp --dport 443 -m string --string "maps-api.apple.com" --algo bm --from 40 --to 180 -j REJECT --reject-with tcp-reset 2>/dev/null || true
            ip6tables -A "${CHAIN_NAME}" -p tcp --dport 443 -m string --string "location.services.mozilla.com" --algo bm --from 40 --to 180 -j REJECT --reject-with tcp-reset 2>/dev/null || true
        fi

        while ip6tables -C FORWARD -j "${CHAIN_NAME}" 2>/dev/null; do
            ip6tables -D FORWARD -j "${CHAIN_NAME}" 2>/dev/null
        done
        ip6tables -I FORWARD 1 -j "${CHAIN_NAME}"

        while ip6tables -C OUTPUT -j "${CHAIN_NAME}" 2>/dev/null; do
            ip6tables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null
        done
        ip6tables -I OUTPUT 1 -j "${CHAIN_NAME}"
    fi

    # 持久化规则保存
    save_system_rules

    log_info "宿主机全局防送中规则已成功部署并生效！"
}

# ==============================================================================
# 防火墙卸载与平滑释放（杜绝任何残留与报错）
# ==============================================================================

remove_rules() {
    log_info "正在平滑卸载宿主机全局拦截规则..."

    # 循环解除所有 FORWARD / OUTPUT 引用
    while iptables -C FORWARD -j "${CHAIN_NAME}" 2>/dev/null; do
        iptables -D FORWARD -j "${CHAIN_NAME}" 2>/dev/null || break
    done

    while iptables -C OUTPUT -j "${CHAIN_NAME}" 2>/dev/null; do
        iptables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null || break
    done

    iptables -F "${CHAIN_NAME}" 2>/dev/null || true
    iptables -X "${CHAIN_NAME}" 2>/dev/null || true
    ipset destroy "${IPSET4}" 2>/dev/null || true

    # IPv6 解除
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C FORWARD -j "${CHAIN_NAME}" 2>/dev/null; do
            ip6tables -D FORWARD -j "${CHAIN_NAME}" 2>/dev/null || break
        done

        while ip6tables -C OUTPUT -j "${CHAIN_NAME}" 2>/dev/null; do
            ip6tables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null || break
        done

        ip6tables -F "${CHAIN_NAME}" 2>/dev/null || true
        ip6tables -X "${CHAIN_NAME}" 2>/dev/null || true
    fi
    ipset destroy "${IPSET6}" 2>/dev/null || true

    # 挂起定时更新服务，防止定时任务在暂停期间自动激活规则
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet noanyloc-update.timer 2>/dev/null; then
        systemctl stop noanyloc-update.timer >/dev/null 2>&1 || true
        log_info "已同步挂起后台定时刷新服务 (重新开启防护时将自动恢复)。"
    fi

    # 持久化同步
    save_system_rules

    log_info "所有防送中规则已安全移除，宿主机已恢复原始网络转发状态。"
}

# ==============================================================================
# 持久化与开机自愈服务管理 (解决 iptables-restore 顺序死锁)
# ==============================================================================

save_system_rules() {
    mkdir -p "${CONF_DIR}/backup"
    # 严格仅备份本系统专用的 IPSet 集合，绝不扫描或导出宿主机其他软件自建的规则与集合
    if command -v ipset >/dev/null 2>&1; then
        ipset save "${IPSET4}" > "${CONF_DIR}/backup/ipset4.save" 2>/dev/null || true
        if has_ipv6; then
            ipset save "${IPSET6}" > "${CONF_DIR}/backup/ipset6.save" 2>/dev/null || true
        fi
    fi
}

setup_systemd_daemon() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "系统未检测到 Systemd，将使用 Crontab 作为定时备选方案。"
        setup_cron_fallback
        return 0
    fi

    local hours=2
    [ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"
    [ -n "${UPDATE_INTERVAL_HOURS}" ] && hours="${UPDATE_INTERVAL_HOURS}"

    # 1. 开机自启服务（确保在网络连通后自动载入规则）
    cat <<EOF > "${SYSTEMD_SERVICE}"
[Unit]
Description=NoAnyLoc Host Level Anti-Relocation Protection
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT_PATH} start
ExecStop=${SCRIPT_PATH} stop

[Install]
WantedBy=multi-user.target
EOF

    # 2. 定时保鲜服务与定时器
    cat <<EOF > "${SYSTEMD_TIMER_SERVICE}"
[Unit]
Description=NoAnyLoc Dynamic IP Resolver Updater
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} update
EOF

    cat <<EOF > "${SYSTEMD_TIMER}"
[Unit]
Description=Periodically Refresh NoAnyLoc Anti-Relocation IP Sets
After=network.target

[Timer]
OnBootSec=10min
OnUnitActiveSec=${hours}h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable noanyloc.service >/dev/null 2>&1
    systemctl enable noanyloc-update.timer >/dev/null 2>&1
    systemctl restart noanyloc-update.timer >/dev/null 2>&1

    log_info "Systemd 开机自愈服务与定时刷新定时器 (${hours} 小时/次) 已启用！"
}

disable_systemd_daemon() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop noanyloc-update.timer >/dev/null 2>&1 || true
        systemctl disable noanyloc-update.timer >/dev/null 2>&1 || true
        systemctl stop noanyloc.service >/dev/null 2>&1 || true
        systemctl disable noanyloc.service >/dev/null 2>&1 || true
        rm -f "${SYSTEMD_SERVICE}" "${SYSTEMD_TIMER}" "${SYSTEMD_TIMER_SERVICE}"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH}" | crontab - 2>/dev/null || true
    log_info "后台守护与定时任务已注销。"
}

setup_cron_fallback() {
    local hours=2
    [ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"
    [ -n "${UPDATE_INTERVAL_HOURS}" ] && hours="${UPDATE_INTERVAL_HOURS}"

    (crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH}" ; echo "0 */${hours} * * * ${SCRIPT_PATH} update >/dev/null 2>&1") | crontab -
    log_info "Crontab 定时刷新任务已设置 (每 ${hours} 小时一次)。"
}

# ==============================================================================
# 全景送中健康体检引擎 (Diagnosis Engine)
# ==============================================================================

diagnose_relocation_status() {
    echo ""
    echo -e "${CYAN}${BOLD}================================================================${NC}"
    echo -e "${CYAN}${BOLD}           宿主机 IP 全景“送中”健康体检报告                     ${NC}"
    echo -e "${CYAN}${BOLD}================================================================${NC}"
    echo -e "正在向海外各大厂检测探针发起穿透测试，请稍候...\n"

    # 1. 基础 IP 与 ASN
    local ip_info
    ip_info=$(curl -s4m 5 https://ipinfo.io/json 2>/dev/null)
    local ip=$(echo "${ip_info}" | grep -o '"ip": *"[^"]*"' | cut -d'"' -f4)
    local country=$(echo "${ip_info}" | grep -o '"country": *"[^"]*"' | cut -d'"' -f4)
    local city=$(echo "${ip_info}" | grep -o '"city": *"[^"]*"' | cut -d'"' -f4)
    local org=$(echo "${ip_info}" | grep -o '"org": *"[^"]*"' | cut -d'"' -f4)

    echo -e "${BOLD}【1. IP 基础档案与机房属性】${NC}"
    echo -e "  * 当前公网 IP : ${GREEN}${ip:-未知}${NC}"
    echo -e "  * 注册归属地  : ${GREEN}${country:-未知} - ${city:-未知}${NC}"
    echo -e "  * 运营商/ASN  : ${GREEN}${org:-未知}${NC}"
    echo ""

    # 2. Google 搜索引擎及位置标签测试
    echo -e "${BOLD}【2. Google 搜索服务与位置标签检测】${NC}"
    local g_res
    g_res=$(curl -s4ILm 5 "https://www.google.com" 2>/dev/null)
    local g_loc=$(echo "${g_res}" | grep -i "^location:" | tr -d '\r' | awk '{print $2}')
    
    if echo "${g_loc}" | grep -qi "google.com.hk"; then
        echo -e "  * 首页跳转检测: ${RED}[送中高危]${NC} 自动重定向至 google.com.hk (香港/大陆特征)"
    else
        echo -e "  * 首页跳转检测: ${GREEN}[正常]${NC} 正常停留在 google.com 国际站"
    fi

    # 探测搜索底栏物理位置 (兼顾中英文返回内容)
    local g_page
    g_page=$(curl -s4m 5 "https://www.google.com/search?q=my+location" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" 2>/dev/null)
    local detected_loc
    detected_loc=$(echo "${g_page}" | grep -oE '(来自您的(互联网地址|IP 地址|设备)|From your (IP address|device|Internet location))' -A 1 | tail -n1 | sed -e 's/<[^>]*>//g' | tr -d '\n\r ')
    if [ -z "${detected_loc}" ]; then
        detected_loc=$(echo "${g_page}" | grep -oE '([A-Z][a-z]+,[ ]*)*(China|Beijing|Shanghai|Guangdong|Shenzhen|Guangzhou|Hangzhou|Chengdu)' | head -n1)
    fi

    if echo "${g_page}" | grep -qiE "(中国|Guangdong|Beijing|Shanghai|Shenzhen|Guangzhou|Hangzhou|Chengdu|China)"; then
        echo -e "  * 底栏地理位置: ${RED}[已被送中]${NC} Google 底栏标注地检测到中国大陆特征: ${detected_loc:-中国}"
    else
        echo -e "  * 底栏地理位置: ${GREEN}[正常/无大陆标记]${NC} 当前标注为海外正常区域"
    fi
    echo ""

    # 3. YouTube 区域归属与功能完整性
    echo -e "${BOLD}【3. YouTube 流媒体区域与高级权限检测】${NC}"
    local yt_trace
    yt_trace=$(curl -s4m 5 "https://www.youtube.com" 2>/dev/null | grep -o '"countryCode":"[A-Z]*"' | head -n1 | cut -d'"' -f4)
    if [ "${yt_trace}" = "CN" ]; then
        echo -e "  * 归属国家代码: ${RED}[已被送中: CN]${NC} (画中画/后台播放将失效，版权库受限)"
    elif [ -n "${yt_trace}" ]; then
        echo -e "  * 归属国家代码: ${GREEN}[正常: ${yt_trace}]${NC} (支持后台播放与 YouTube Premium 完整功能)"
    else
        echo -e "  * 归属国家代码: ${YELLOW}[检测超时或未返回]${NC}"
    fi
    echo ""

    # 4. Cloudflare CDN 边缘识别
    echo -e "${BOLD}【4. Cloudflare 边缘定位检测】${NC}"
    local cf_trace
    cf_trace=$(curl -s4m 5 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
    local cf_loc=$(echo "${cf_trace}" | grep "^loc=" | cut -d'=' -f2)
    local cf_warp=$(echo "${cf_trace}" | grep "^warp=" | cut -d'=' -f2)
    if [ "${cf_loc}" = "CN" ]; then
        echo -e "  * Cloudflare 判定: ${RED}[已被送中: CN]${NC}"
    elif [ -n "${cf_loc}" ]; then
        echo -e "  * Cloudflare 判定: ${GREEN}[海外正常: ${cf_loc}]${NC} (WARP状态: ${cf_warp:-off})"
    else
        echo -e "  * Cloudflare 判定: ${YELLOW}[检测超时]${NC}"
    fi
    echo ""

    # 5. 防护体系拦截实测 (验证当前本机是否成功拦截)
    echo -e "${BOLD}【5. 本机当前防护拦截实战测试】${NC}"
    local test_res
    test_res=$(curl -s4m 3 -I "https://geolocation.googleapis.com" 2>&1 || true)
    if echo "${test_res}" | grep -qE "(Connection refused|Failed to connect|timed out|reset)"; then
        echo -e "  * 定位 API 阻断: ${GREEN}[拦截成功 - 流量已被拒绝或切断]${NC}"
    else
        echo -e "  * 定位 API 阻断: ${YELLOW}[未被拦截或规则尚未加载]${NC}"
    fi

    echo -e "${CYAN}================================================================${NC}\n"
    read -r -p "按回车键返回主菜单..."
}

# ==============================================================================
# 状态监控与防火墙命中统计
# ==============================================================================

show_detailed_status() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}================================================================================${NC}"
        echo -e "${CYAN}${BOLD}           NoAnyLoc-Host 防火墙实时拦截战报与命中统计面板 (Dashboard)           ${NC}"
        echo -e "${CYAN}${BOLD}================================================================================${NC}"

        local count_v4="0"
        local count_v6="0"
        if command -v ipset >/dev/null 2>&1; then
            count_v4=$(ipset list "${IPSET4}" 2>/dev/null | grep -E '^Number of entries:' | awk '{print $4}' || echo "0")
            count_v6=$(ipset list "${IPSET6}" 2>/dev/null | grep -E '^Number of entries:' | awk '{print $4}' || echo "0")
        fi

        # 解析 IPv4 数据包与字节统计
        local v4_lines=""
        local v4_total_pkts=0
        local v4_total_bytes=0
        local v4_active=0

        if iptables -L "${CHAIN_NAME}" -v -n -x >/dev/null 2>&1; then
            v4_active=1
            v4_lines=$(iptables -L "${CHAIN_NAME}" -v -n -x 2>/dev/null | tail -n +3)
            while read -r pkts bytes rest; do
                if [[ "${pkts}" =~ ^[0-9]+$ ]]; then
                    v4_total_pkts=$((v4_total_pkts + pkts))
                    v4_total_bytes=$((v4_total_bytes + bytes))
                fi
            done <<< "${v4_lines}"
        fi

        # 解析 IPv6 数据包与字节统计
        local v6_lines=""
        local v6_total_pkts=0
        local v6_total_bytes=0
        local v6_active=0

        if has_ipv6 && command -v ip6tables >/dev/null 2>&1 && ip6tables -L "${CHAIN_NAME}" -v -n -x >/dev/null 2>&1; then
            v6_active=1
            v6_lines=$(ip6tables -L "${CHAIN_NAME}" -v -n -x 2>/dev/null | tail -n +3)
            while read -r pkts bytes rest; do
                if [[ "${pkts}" =~ ^[0-9]+$ ]]; then
                    v6_total_pkts=$((v6_total_pkts + pkts))
                    v6_total_bytes=$((v6_total_bytes + bytes))
                fi
            done <<< "${v6_lines}"
        fi

        local grand_total_pkts=$((v4_total_pkts + v6_total_pkts))
        local grand_total_bytes=$((v4_total_bytes + v6_total_bytes))
        local fmt_grand_bytes=$(format_bytes "${grand_total_bytes}")
        local fmt_v4_bytes=$(format_bytes "${v4_total_bytes}")
        local fmt_v6_bytes=$(format_bytes "${v6_total_bytes}")

        echo -e " ${BOLD}【核心拦截战报总览】${NC}"
        echo -e "  * 累计成功阻断定位次数 : ${GREEN}${BOLD}${grand_total_pkts} 次${NC} (已为宿主机及全部容器小鸡击落 ${grand_total_pkts} 次潜在定位上报)"
        echo -e "  * 累计物理阻断定位流量 : ${GREEN}${BOLD}${fmt_grand_bytes}${NC}"
        echo -e "  * 防护总闸门实时状态   : $([ "${v4_active}" -eq 1 ] && echo -e "${GREEN}[ 运行中 / ACTIVE - 保护中 ]${NC}" || echo -e "${RED}[ 未激活 / INACTIVE ]${NC}")"
        echo -e "  * 内存拦截规则池规模   : IPv4: ${CYAN}${count_v4:-0}${NC} 个节点 | IPv6: ${CYAN}${count_v6:-0}${NC} 个节点"
        echo -e " --------------------------------------------------------------------------------"

        echo -e " ${BOLD}【IPv4 细分规则拦截战报 (详细命中)】${NC}"
        if [ "${v4_active}" -eq 1 ]; then
            while read -r pkts bytes target prot opt in_if out_if src dst rest; do
                [ -z "${pkts}" ] && continue
                local tag="[扩展规则]"
                local desc="自定义扩展规则"
                if echo "${rest}" | grep -q "match-set.*tcp-reset"; then
                    tag="[IPSet-TCP]"
                    desc="IPSet 核心定位目标池 (TCP 握手直接熔断)"
                elif echo "${rest}" | grep -q "match-set.*icmp"; then
                    tag="[IPSet-UDP]"
                    desc="IPSet 核心定位目标池 (UDP/ICMP 阻断)"
                elif echo "${rest}" | grep -q "geolocation.googleapis.com"; then
                    tag="[SNI-Google]"
                    desc="Google 定位 API (TLS Client Hello 熔断)"
                elif echo "${rest}" | grep -q "gs-loc.apple.com"; then
                    tag="[SNI-Apple]"
                    desc="Apple 定位服务 (TLS Client Hello 熔断)"
                elif echo "${rest}" | grep -q "maps-api.apple.com"; then
                    tag="[SNI-AppleMap]"
                    desc="Apple 地图服务 (TLS Client Hello 熔断)"
                elif echo "${rest}" | grep -q "location.services.mozilla.com"; then
                    tag="[SNI-Mozilla]"
                    desc="Mozilla MLS 定位 (TLS Client Hello 熔断)"
                fi
                local rule_bytes
                rule_bytes=$(format_bytes "${bytes}")
                echo -e "  * ${CYAN}${tag}${NC} ${desc} : 成功拦截 ${GREEN}${BOLD}${pkts} 次${NC} (阻断数据: ${GREEN}${rule_bytes}${NC})"
            done <<< "${v4_lines}"

            echo ""
            echo -e "  * IPv4 统计小计: 累计拦截 ${GREEN}${BOLD}${v4_total_pkts} 次${NC} | 累计丢弃定位流量 ${GREEN}${BOLD}${fmt_v4_bytes}${NC}"
        else
            echo -e "  ${YELLOW}未检测到 IPv4 NOANYLOC 规则链，防护尚未开启。${NC}"
        fi
        echo -e " --------------------------------------------------------------------------------"

        if has_ipv6 && [ "${v6_active}" -eq 1 ]; then
            echo -e " ${BOLD}【IPv6 细分规则拦截战报 (详细命中)】${NC}"
            while read -r pkts bytes target prot opt in_if out_if src dst rest; do
                [ -z "${pkts}" ] && continue
                local tag="[IPv6-扩展]"
                local desc="IPv6 自定义拦截规则"
                if echo "${rest}" | grep -q "match-set.*tcp-reset"; then
                    tag="[IPv6-TCP]"
                    desc="IPv6 IPSet 核心定位池 (TCP 握手直接熔断)"
                elif echo "${rest}" | grep -q "match-set.*icmp"; then
                    tag="[IPv6-ICMP]"
                    desc="IPv6 IPSet 核心定位池 (ICMPv6 阻断)"
                elif echo "${rest}" | grep -q "geolocation.googleapis.com"; then
                    tag="[IPv6-Google]"
                    desc="Google 定位 API (IPv6 SNI 握手熔断)"
                elif echo "${rest}" | grep -q "gs-loc.apple.com"; then
                    tag="[IPv6-Apple]"
                    desc="Apple 定位服务 (IPv6 SNI 握手熔断)"
                elif echo "${rest}" | grep -q "maps-api.apple.com"; then
                    tag="[IPv6-AppleMap]"
                    desc="Apple 地图服务 (IPv6 SNI 握手熔断)"
                elif echo "${rest}" | grep -q "location.services.mozilla.com"; then
                    tag="[IPv6-Mozilla]"
                    desc="Mozilla MLS 定位 (IPv6 SNI 握手熔断)"
                fi
                local rule_bytes
                rule_bytes=$(format_bytes "${bytes}")
                echo -e "  * ${CYAN}${tag}${NC} ${desc} : 成功拦截 ${GREEN}${BOLD}${pkts} 次${NC} (阻断数据: ${GREEN}${rule_bytes}${NC})"
            done <<< "${v6_lines}"

            echo ""
            echo -e "  * IPv6 统计小计: 累计拦截 ${GREEN}${BOLD}${v6_total_pkts} 次${NC} | 累计丢弃定位流量 ${GREEN}${BOLD}${fmt_v6_bytes}${NC}"
            echo -e " --------------------------------------------------------------------------------"
        fi

        echo -e "${CYAN}${BOLD}================================================================================${NC}"
        echo -e "  ${BOLD}[C]${NC} 清零统计计数器 (重置数据包统计)   ${BOLD}[R]${NC} 实时刷新   ${BOLD}[回车键]${NC} 返回主菜单"
        echo -e "${CYAN}${BOLD}================================================================================${NC}"
        read -r -p "请选择操作 [c/r/回车]: " op_act
        case "${op_act}" in
            [cC])
                iptables -Z "${CHAIN_NAME}" 2>/dev/null || true
                if has_ipv6 && command -v ip6tables >/dev/null 2>&1; then
                    ip6tables -Z "${CHAIN_NAME}" 2>/dev/null || true
                fi
                log_info "所有拦截计数器已成功清零重置！"
                sleep 1
                ;;
            [rR])
                continue
                ;;
            *)
                break
                ;;
        esac
    done
}

# ==============================================================================
# 在线更新升级功能 (从 GitHub 官方仓库拉取最新版)
# ==============================================================================

update_self() {
    clear
    echo -e "${CYAN}${BOLD}======================================================================${NC}"
    echo -e "${CYAN}${BOLD}           NoAnyLoc-Host 在线检查与更新 (GitHub 官方源)               ${NC}"
    echo -e "${CYAN}${BOLD}======================================================================${NC}"
    echo -e "  当前本地版本 : ${GREEN}${SCRIPT_VERSION}${NC}"
    echo -e "  官方开源仓库 : ${CYAN}https://github.com/0xdabiaoge/NoAnyLoc${NC}"
    echo -e "  正在连接 GitHub 检索最新版本，请稍候...\n"

    local tmp_new="/tmp/noanyloc_update.sh"
    rm -f "${tmp_new}"

    # 优先从官方 Raw 拉取，超时 6 秒自动切换到加速镜像
    local downloaded=0
    if curl -fsSL -m 8 "${GITHUB_RAW_URL}" -o "${tmp_new}" 2>/dev/null; then
        downloaded=1
    elif curl -fsSL -m 8 "${GHPROXY_RAW_URL}" -o "${tmp_new}" 2>/dev/null; then
        downloaded=1
        log_info "已通过全球加速节点成功获取更新脚本。"
    fi

    if [ "${downloaded}" -ne 1 ] || [ ! -s "${tmp_new}" ]; then
        log_err "从 GitHub 获取最新脚本失败，请检查宿主机外网网络连通性！"
        rm -f "${tmp_new}"
        read -r -p "按回车键返回主菜单..."
        return 1
    fi

    # 完整性校验：检查文件必须包含核心标识与函数
    if ! grep -q "NOANYLOC" "${tmp_new}" || ! grep -q "check_os" "${tmp_new}"; then
        log_err "下载到的脚本文件完整性校验失败（可能被网络劫持或源站尚未同步），已终止更新！"
        rm -f "${tmp_new}"
        read -r -p "按回车键返回主菜单..."
        return 1
    fi

    # 提取远程版本号
    local remote_version
    remote_version=$(grep -E '^SCRIPT_VERSION=' "${tmp_new}" | head -n1 | cut -d'"' -f2)
    [ -z "${remote_version}" ] && remote_version="最新版"

    echo -e "  最新远程版本 : ${GREEN}${remote_version}${NC}"
    echo ""

    if [ "${remote_version}" = "${SCRIPT_VERSION}" ]; then
        read -r -p "当前已经是最新版本 (${SCRIPT_VERSION})，是否强制重新覆盖更新？(y/N): " force_up
        if [[ ! "${force_up}" =~ ^[yY]$ ]]; then
            log_info "已取消更新。"
            rm -f "${tmp_new}"
            sleep 1
            return 0
        fi
    fi

    log_info "正在平滑覆盖安装新版本..."
    chmod +x "${tmp_new}"
    
    # 覆盖系统全局命令与当前脚本自身
    cp -f "${tmp_new}" "${SCRIPT_PATH}"
    chmod +x "${SCRIPT_PATH}"

    local current_exec
    current_exec="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    if [ -f "${current_exec}" ] && [ "${current_exec}" != "${SCRIPT_PATH}" ]; then
        cp -f "${tmp_new}" "${current_exec}"
        chmod +x "${current_exec}"
    fi

    rm -f "${tmp_new}"
    echo ""
    log_info "NoAnyLoc 系统已成功平滑升级至 ${remote_version}！"

    read -r -p "是否立即重载并应用最新防送中规则库？(Y/n): " reload_rules
    if [[ ! "${reload_rules}" =~ ^[nN]$ ]]; then
        apply_rules
    fi

    read -r -p "升级完成！按回车键返回主菜单..."
}

# ==============================================================================
# 配置管理菜单 (修改更新间隔 / 开关 SNI)
# ==============================================================================

configure_settings() {
    clear
    echo -e "${CYAN}${BOLD}================================================================${NC}"
    echo -e "${CYAN}${BOLD}               NoAnyLoc 守护参数与更新周期配置                  ${NC}"
    echo -e "${CYAN}${BOLD}================================================================${NC}"

    local current_interval=2
    local current_sni=1
    [ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"
    [ -n "${UPDATE_INTERVAL_HOURS}" ] && current_interval="${UPDATE_INTERVAL_HOURS}"
    [ -n "${ENABLE_SNI_BLOCK}" ] && current_sni="${ENABLE_SNI_BLOCK}"

    echo -e "当前配置:"
    echo -e "  1. 自动保鲜 IP 池刷新周期: ${GREEN}${current_interval} 小时${NC}"
    echo -e "  2. 高级 SNI 字符串阻断 (xt_string): $([ "${current_sni}" = "1" ] && echo -e "${GREEN}开启${NC}" || echo -e "${RED}关闭${NC}")"
    echo ""
    echo -e "  [1] 修改刷新周期 (小时)"
    echo -e "  [2] 切换 SNI 字符串过滤开关"
    echo -e "  [0] 返回主菜单"
    echo ""
    read -r -p "请输入选项 [0-2]: " cfg_opt
    case "${cfg_opt}" in
        1)
            read -r -p "请输入新的刷新间隔小时数 (建议 1-12 小时): " new_h
            if [[ "${new_h}" =~ ^[0-9]+$ ]] && [ "${new_h}" -gt 0 ]; then
                sed -i "s/^UPDATE_INTERVAL_HOURS=.*/UPDATE_INTERVAL_HOURS=${new_h}/" "${CONFIG_FILE}"
                setup_systemd_daemon
                log_info "更新周期已修改为 ${new_h} 小时，定时器已重载！"
            else
                log_warn "输入无效，必须是正整数。"
            fi
            sleep 1.5
            ;;
        2)
            if [ "${current_sni}" = "1" ]; then
                sed -i "s/^ENABLE_SNI_BLOCK=.*/ENABLE_SNI_BLOCK=0/" "${CONFIG_FILE}"
                log_info "已关闭 SNI 过滤，重新加载规则后生效。"
            else
                sed -i "s/^ENABLE_SNI_BLOCK=.*/ENABLE_SNI_BLOCK=1/" "${CONFIG_FILE}"
                log_info "已开启 SNI 过滤，重新加载规则后生效。"
            fi
            apply_rules
            sleep 1.5
            ;;
        *)
            return 0
            ;;
    esac
}

# ==============================================================================
# 完全卸载清理
# ==============================================================================

uninstall_all() {
    clear
    echo -e "${RED}${BOLD}================================================================${NC}"
    echo -e "${RED}${BOLD}                 NoAnyLoc-Host 系统完全卸载                     ${NC}"
    echo -e "${RED}${BOLD}================================================================${NC}"
    read -r -p "确定要彻底卸载 NoAnyLoc 并清除所有防火墙规则与自启服务吗？(y/N): " confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        log_info "操作已取消。"
        sleep 1
        return 0
    fi

    disable_systemd_daemon
    remove_rules
    rm -rf "${CONF_DIR}"
    rm -f /tmp/noanyloc* 2>/dev/null || true

    local current_exec
    current_exec="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    rm -f "${SCRIPT_PATH}"
    if [ -f "${current_exec}" ]; then
        rm -f "${current_exec}"
    fi

    echo ""
    log_info "NoAnyLoc 系统、防火墙规则、定时服务、配置文件及脚本自身已 100% 彻底清除！"
    exit 0
}

# ==============================================================================
# 交互式主菜单
# ==============================================================================

main_menu() {
    check_root
    check_os
    init_env
    detect_host_network

    while true; do
        clear
        # 实时检测运行状态
        local is_active=0
        if iptables -C FORWARD -j "${CHAIN_NAME}" 2>/dev/null; then
            is_active=1
        fi

        local v4_count="0"
        local v6_count="0"
        if command -v ipset >/dev/null 2>&1; then
            v4_count=$(ipset list "${IPSET4}" 2>/dev/null | grep -E '^Number of entries:' | awk '{print $4}' || echo "0")
            v6_count=$(ipset list "${IPSET6}" 2>/dev/null | grep -E '^Number of entries:' | awk '{print $4}' || echo "0")
        fi

        local timer_status="${RED}未启用${NC}"
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet noanyloc-update.timer 2>/dev/null; then
            timer_status="${GREEN}已启用 (Systemd Timer 自动保鲜)${NC}"
        elif crontab -l 2>/dev/null | grep -q "${SCRIPT_PATH}"; then
            timer_status="${GREEN}已启用 (Crontab 自动保鲜)${NC}"
        fi

        echo -e "${CYAN}${BOLD}======================================================================${NC}"
        echo -e "${CYAN}${BOLD}        NoAnyLoc-Host 宿主机全局防送中系统 (Debian/Ubuntu 专属)       ${NC}"
        echo -e "${CYAN}${BOLD}      专为 Debian / Ubuntu (含 Proxmox VE) 宿主机打造 | 纯 Shell 打造 ${NC}"
        echo -e "${CYAN}${BOLD}======================================================================${NC}"
        echo -e " ${BOLD}【宿主机网络信息】${NC}"
        echo -e "  * 公网 IPv4 地址 : ${GREEN}${HOST_IPV4}${NC}"
        echo -e "  * 公网 IPv6 状态 : ${GREEN}${HOST_IPV6}${NC}"
        echo -e "  * 出网物理网卡   : ${CYAN}${HOST_DEFAULT_IF}${NC}"
        echo -e "  * 容器网桥设备   : ${CYAN}${HOST_BRIDGES}${NC}"
        echo -e " --------------------------------------------------------------------"
        echo -e " ${BOLD}【防护状态监控】${NC}"
        if [ "${is_active}" -eq 1 ]; then
            echo -e "  * 拦截总闸门状态 : ${GREEN}${BOLD}[ 运行中 / ACTIVE - 保护全部小鸡出网 ]${NC}"
        else
            echo -e "  * 拦截总闸门状态 : ${RED}${BOLD}[ 已暂停 / INACTIVE - 未拦截 ]${NC}"
        fi
        echo -e "  * 当前规则条目数 : IPv4: ${GREEN}${v4_count:-0}${NC} 条 | IPv6: ${GREEN}${v6_count:-0}${NC} 条"
        echo -e "  * 动态保鲜守护   : ${timer_status}"
        echo -e "  * 拦截受控链条   : FORWARD (全体容器小鸡) + OUTPUT (宿主机本机)"
        echo -e "${CYAN}${BOLD}======================================================================${NC}"
        echo -e "  ${BOLD}1.${NC} 开启 / 重载 宿主机全局防送中 (一键构建双栈拦截规则链)"
        echo -e "  ${BOLD}2.${NC} 暂停 / 解除 全局防护 (安全清退，不残留任何内核规则)"
        echo -e "  ${BOLD}3.${NC} 立即强制刷新 IP 资产池 (多路 DNS 并发解析并原子替换)"
        echo -e "  ${BOLD}4.${NC} 运行【全景送中健康体检】(深度探测 Google/YouTube/Cloudflare)"
        echo -e "  ${BOLD}5.${NC} 配置自动保鲜守护参数 (修改刷新周期 / 调整 SNI 阻断)"
        echo -e "  ${BOLD}6.${NC} 查看【实时拦截战报与命中统计】(详细阻断次数与可视化仪表盘)"
        echo -e "  ${BOLD}7.${NC} 检查并在线更新脚本 (从 GitHub 官方源拉取最新版)"
        echo -e "  ${BOLD}8.${NC} 彻底卸载此脚本与所有自启服务"
        echo -e "  ${BOLD}0.${NC} 退出控制台"
        echo -e "${CYAN}${BOLD}======================================================================${NC}"
        read -r -p "请选择操作 [0-8]: " choice

        case "${choice}" in
            1)
                apply_rules
                setup_systemd_daemon
                read -r -p "按回车键继续..."
                ;;
            2)
                remove_rules
                read -r -p "按回车键继续..."
                ;;
            3)
                apply_rules
                read -r -p "按回车键继续..."
                ;;
            4)
                diagnose_relocation_status
                ;;
            5)
                configure_settings
                ;;
            6)
                show_detailed_status
                ;;
            7)
                update_self
                ;;
            8)
                uninstall_all
                ;;
            0)
                echo "退出脚本。"
                exit 0
                ;;
            *)
                log_warn "无效选项，请输入 0-8。"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 命令行参数快捷调用支持 (支持自动化脚本与定时器调用)
# ==============================================================================

check_root
check_os
init_env

case "${1:-}" in
    start|enable)
        apply_rules
        setup_systemd_daemon
        ;;
    stop|disable)
        remove_rules
        ;;
    restart|reload)
        remove_rules
        apply_rules
        ;;
    update|refresh)
        apply_rules
        ;;
    upgrade|update-self)
        update_self
        ;;
    status|stats|log)
        detect_host_network
        show_detailed_status
        ;;
    test|check)
        detect_host_network
        diagnose_relocation_status
        ;;
    uninstall)
        uninstall_all
        ;;
    *)
        main_menu
        ;;
esac
