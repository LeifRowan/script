#!/usr/bin/env bash
# =============================================================================
# server-init: Debian / Ubuntu 新服务器初始化脚本
#
# 支持: Debian 12/13, Ubuntu 22.04/24.04/26.04 LTS
# 配置优先级: 环境变量 > --config 本地文件 > INIT_CONFIG_URL 远程文件 > 交互输入 > 默认值
#
# 用法:
#   sudo bash init.sh [--config FILE] [--config-url URL] [--non-interactive]
#   sudo bash init.sh --ssh-lockdown          # 仅执行 SSH 锁定（之前跳过时补做）
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/init.sh | sudo bash
#
# 注意: sudo 默认会清空环境变量, 传变量请写成 `sudo NEW_USER=ops bash init.sh`
# =============================================================================
#
# 整个脚本包在 main() 里, 最后一行才调用。curl | bash 时如果下载中断,
# 不会执行半截脚本。

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.1.0"
readonly STATE_DIR="/etc/server-init"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly LOG_FILE="/var/log/server-init.log"
readonly LOCK_FILE="/run/server-init.lock"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/00-server-init.conf"
readonly F2B_JAIL="/etc/fail2ban/jail.d/server-init.local"
readonly UFW_AFTER_RULES="/etc/ufw/after.rules"
readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly SWAP_FILE="/swapfile"
readonly SYSCTL_FILE="/etc/sysctl.d/99-server-init.conf"
readonly SYSCTL_NET_FILE="/etc/sysctl.d/99-server-init-net.conf"
readonly MODULES_LOAD_NET="/etc/modules-load.d/server-init-net.conf"
readonly JOURNALD_DROPIN="/etc/systemd/journald.conf.d/00-server-init.conf"
readonly BASHRC_SHARED="${STATE_DIR}/bashrc.sh"
readonly VIMRC_SHARED="${STATE_DIR}/vimrc.vim"
readonly MARK_BEGIN=">>> server-init >>>"
readonly MARK_END="<<< server-init <<<"
RUN_TS=$(date +%Y%m%d%H%M%S)
readonly RUN_TS

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# 允许从配置文件/远程配置读取的变量白名单, 其他 key 一律忽略
readonly KNOWN_KEYS=(
  NONINTERACTIVE FORCE
  ENABLE_UPDATE ENABLE_BASELINE ENABLE_PACKAGES ENABLE_USER ENABLE_SSH
  ENABLE_UFW ENABLE_FAIL2BAN ENABLE_DOCKER ENABLE_SWAP ENABLE_NET ENABLE_SHELL_ENV
  TIMEZONE JOURNALD_MAX_USE
  PACKAGE_PROFILE EXTRA_PACKAGES
  NEW_USER USER_PASSWORD USER_PASSWORD_HASH USER_SUDO USER_SUDO_NOPASSWD
  SSH_GITHUB_USERS SSH_PUBLIC_KEYS SSH_PORT SSH_ALLOW_IPS
  SSH_CLIENT_ALIVE_INTERVAL SSH_CLIENT_ALIVE_COUNT_MAX SSH_LOCKDOWN
  UFW_ALLOW_HTTP UFW_ALLOW_HTTPS UFW_ALLOW_PORTS
  F2B_MAXRETRY F2B_FINDTIME F2B_BANTIME F2B_BANTIME_MAX
  DOCKER_USER_GROUP DOCKER_LOG_MAX_SIZE DOCKER_LOG_MAX_FILE
  SWAP_SIZE SWAPPINESS
  TCP_CONGESTION TCP_QDISC TCP_WINDOW_MAX TCP_BANDWIDTH TCP_RTT_MS
  SHELL_ENV_SCOPE SHELL_ENV_USERS
  AUTO_REBOOT
)

# 模块: key|说明。顺序即执行顺序
readonly MODULES=(
  "UPDATE|系统更新 (apt full-upgrade)"
  "BASELINE|时区 / 时间同步 / journald 日志上限"
  "PACKAGES|常用软件"
  "USER|创建用户"
  "UFW|UFW 防火墙 (含 Docker 端口接管)"
  "SSH|SSH 公钥 + 加固 (改端口/禁 root/禁密码)"
  "FAIL2BAN|fail2ban (sshd)"
  "DOCKER|Docker CE (官方源)"
  "SWAP|swap"
  "SHELL_ENV|Shell 环境优化 (alias / PS1 / vim)"
)

PKG_MINIMAL=(curl wget vim git ca-certificates gnupg unzip htop)
PKG_STANDARD=("${PKG_MINIMAL[@]}" tmux jq zip rsync lsof net-tools bind9-dnsutils
  iputils-ping traceroute mtr-tiny tree ncdu bash-completion sysstat iotop)

# 配置变量大多通过 ${!name} 间接读取, shellcheck 无法追踪
# shellcheck disable=SC2034
true

# 运行期状态
INTERACTIVE=0
CLI_CONFIG=""
CLI_CONFIG_URL=""
MODE="full"
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
CUR_SSH_PORTS=()
SSH_KEYS_TO_ADD=()
REBOOT_REQUIRED=0
SUMMARY_LINES=()

# -----------------------------------------------------------------------------
# 输出 / 日志
# -----------------------------------------------------------------------------
if [[ -t 1 ]] || { : >/dev/tty; } 2>/dev/null; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_BLU=$'\e[34m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
else
  C_RED="" C_GRN="" C_YLW="" C_BLU="" C_BLD="" C_RST=""
fi

ts()    { date '+%F %T'; }
info()  { printf '%s %s[INFO]%s  %s\n' "$(ts)" "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s %s[ OK ]%s  %s\n' "$(ts)" "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s %s[WARN]%s  %s\n' "$(ts)" "$C_YLW" "$C_RST" "$*" >&2; }
err()   { printf '%s %s[FAIL]%s  %s\n' "$(ts)" "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST"; }
note()  { SUMMARY_LINES+=("$*"); }

on_err() {
  local rc=$1 line=$2 cmd=$3
  err "第 ${line} 行命令失败 (exit ${rc}): ${cmd}"
  err "完整日志: ${LOG_FILE}。修改的文件已备份为 *.bak.server-init.${RUN_TS}"
  exit "$rc"
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

setup_logging() {
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "server-init v${SCRIPT_VERSION} 开始 (${RUN_TS}), 日志: ${LOG_FILE}"
}

# -----------------------------------------------------------------------------
# 交互工具: 一律读写 /dev/tty, 兼容 curl | bash (stdin 被管道占用)
# -----------------------------------------------------------------------------
tty_print() { printf '%s' "$*" >/dev/tty; }

# 注意: 下面几个函数通过 printf -v 写调用方的变量, 局部变量一律用 __ 前缀,
# 否则调用方变量同名时 (如 ask ans ...) 会写进函数自己的局部变量

# ask VAR "提示" "默认值"
ask() {
  local __var=$1 __prompt=$2 __default=${3:-} __ans=""
  if [[ -n $__default ]]; then
    tty_print "${C_BLD}?${C_RST} ${__prompt} [${__default}]: "
  else
    tty_print "${C_BLD}?${C_RST} ${__prompt}: "
  fi
  IFS= read -r __ans </dev/tty || true
  [[ -z $__ans ]] && __ans=$__default
  printf -v "$__var" '%s' "$__ans"
  echo "[ask] ${__prompt} -> ${__ans}" >>"$LOG_FILE"
}

# ask_yn VAR "提示" y|n  -> VAR = yes|no
ask_yn() {
  local __var=$1 __prompt=$2 __default=${3:-n} __ans="" __hint
  [[ $__default == y ]] && __hint="Y/n" || __hint="y/N"
  while true; do
    tty_print "${C_BLD}?${C_RST} ${__prompt} [${__hint}]: "
    IFS= read -r __ans </dev/tty || true
    __ans=${__ans:-$__default}
    case ${__ans,,} in
      y|yes) printf -v "$__var" yes; break ;;
      n|no)  printf -v "$__var" no;  break ;;
      *) tty_print "  请输入 y 或 n"$'\n' ;;
    esac
  done
  echo "[ask] ${__prompt} -> ${!__var}" >>"$LOG_FILE"
}

# ask_secret VAR "提示"  (不回显, 不记日志)
ask_secret() {
  local __var=$1 __prompt=$2 __ans=""
  tty_print "${C_BLD}?${C_RST} ${__prompt}: "
  IFS= read -rs __ans </dev/tty || true
  tty_print $'\n'
  printf -v "$__var" '%s' "$__ans"
}

is_set()  { [[ -n ${!1+x} ]]; }
is_yes()  { [[ ${!1:-no} =~ ^([Yy]|[Yy][Ee][Ss]|1|true)$ ]]; }
norm_yn() { if is_yes "$1"; then printf -v "$1" yes; else printf -v "$1" no; fi; }

# resolve_yn VAR "提示" 默认(y|n): 已配置则用配置, 否则交互询问或取默认
resolve_yn() {
  local __v=$1 __p=$2 __d=$3
  if is_set "$__v"; then
    norm_yn "$__v"
  elif (( INTERACTIVE )); then
    ask_yn "$__v" "$__p" "$__d"
  elif [[ $__d == y ]]; then
    printf -v "$__v" yes
  else
    printf -v "$__v" no
  fi
}

# resolve_val VAR "提示" 默认值
resolve_val() {
  local __v=$1 __p=$2 __d=$3
  if is_set "$__v"; then
    return 0
  elif (( INTERACTIVE )); then
    ask "$__v" "$__p" "$__d"
  else
    printf -v "$__v" '%s' "$__d"
  fi
}

# -----------------------------------------------------------------------------
# 通用工具
# -----------------------------------------------------------------------------
backup_file() {
  local f=$1
  [[ -e $f ]] || return 0
  local bak="${f}.bak.server-init.${RUN_TS}"
  [[ -e $bak ]] || cp -a "$f" "$bak" || die "备份 ${f} 失败"
}

# 写文件 (内容从 stdin 读): 内容相同则不动返回 1, 不同则先备份再原子替换, 返回 0
# 出错一律 die, 不靠 set -e: 调用方常写成 `if write_file` / `write_file ... || true`,
# 这种上下文里 bash 会关闭整个函数体内的 set -e。
# 不要放在管道右侧调用 (`... | write_file`): 那样跑在子 shell 里, die 只会退出子 shell
write_file() {
  local f=$1 mode=${2:-644} dir tmp
  dir=$(dirname "$f")
  mkdir -p "$dir" || die "无法创建目录 ${dir}"
  # 临时文件和目标同目录, 才能 mv 原子替换; 后缀不是 .conf/.local, 不会被 Include 读到
  tmp=$(mktemp "${f}.tmp.XXXXXX") || die "无法在 ${dir} 创建临时文件"
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    die "写入 ${tmp} 失败 (磁盘已满?)"
  fi
  if [[ -f $f ]] && cmp -s "$tmp" "$f"; then
    rm -f "$tmp"
    return 1
  fi
  backup_file "$f"
  if ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    die "无法写入 ${f}"
  fi
  return 0
}

apt_get() {
  apt-get -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold -y "$@"
}

apt_install() { apt_get install --no-install-recommends "$@"; }

pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }

# 注意: 不用 `cmd | grep -q`, pipefail 下 grep 提前退出会让上游 SIGPIPE 导致误判
port_in_use() { [[ -n $(ss -Htln "sport = :$1" 2>/dev/null) ]]; }

has_password() { [[ $(passwd -S "$1" 2>/dev/null | awk '{print $2}') == P ]]; }

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

valid_uint() { [[ $1 =~ ^[0-9]{1,9}$ ]]; }

valid_ipv4() {
  local o
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

valid_ip_or_cidr() {
  local x=$1
  if [[ $x =~ ^([0-9.]+)(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
    valid_ipv4 "${BASH_REMATCH[1]}"
    return
  fi
  if [[ $x =~ ^([0-9A-Fa-f:]+)(/([0-9]{1,3}))?$ && $x == *:* ]]; then
    [[ -z ${BASH_REMATCH[3]} ]] || (( BASH_REMATCH[3] <= 128 ))
    return
  fi
  return 1
}

ipv4_to_int() {
  local -a o
  IFS=. read -r -a o <<<"$1"
  echo $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# ip_allowed IP "白名单列表": IP 是否被白名单覆盖。
# IPv4 支持 CIDR; IPv6 只做精确匹配, CIDR 无法判断时返回 2 (未知)
ip_allowed() {
  local ip=$1 list=$2 e net bits mask unknown=0
  for e in $list; do
    [[ $e == "$ip" ]] && return 0
    if [[ $ip != *:* && $e != *:* ]]; then
      net=${e%/*}
      bits=32
      [[ $e == */* ]] && bits=${e#*/}
      mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
      (( ($(ipv4_to_int "$ip") & mask) == ($(ipv4_to_int "$net") & mask) )) && return 0
    elif [[ $ip == *:* && $e == */* ]]; then
      unknown=1
    fi
  done
  (( unknown )) && return 2
  return 1
}

# 把 "512M" / "2G" / "1024" 转成 MB
size_to_mb() {
  local s=${1^^}
  # 10#: 防止 "08G" 之类前导 0 被当成八进制
  case $s in
    *G) echo $(( 10#${s%G} * 1024 )) ;;
    *M) echo $(( 10#${s%M} )) ;;
    *)  echo $(( 10#$s )) ;;
  esac
}

# 把 "64K" / "16M" / "1G" / 纯数字 转成字节
size_to_bytes() {
  local s=${1^^}
  case $s in
    *G) echo $(( 10#${s%G} * 1024 * 1024 * 1024 )) ;;
    *M) echo $(( 10#${s%M} * 1024 * 1024 )) ;;
    *K) echo $(( 10#${s%K} * 1024 )) ;;
    *)  echo $(( 10#$s )) ;;
  esac
}

bytes_human() {
  local b=$1
  if (( b % 1048576 == 0 )); then
    echo "$(( b / 1048576 ))M"
  elif (( b % 1024 == 0 )); then
    echo "$(( b / 1024 ))K"
  else
    echo "$b"
  fi
}

# 100Mbit / 1Gbit / 纯数字 (bit/s)。用十进制, 和网卡 speed 的 Mbps 一致
parse_bandwidth_bps() {
  local s=${1^^} n
  s=${s//[[:space:]]/}
  if [[ $s =~ ^([0-9]{1,6})(GBIT|GBPS|MBIT|MBPS|KBIT|KBPS)$ ]]; then
    n=$(( 10#${BASH_REMATCH[1]} ))
    case ${BASH_REMATCH[2]} in
      GBIT|GBPS) echo $(( n * 1000000000 )) ;;
      MBIT|MBPS) echo $(( n * 1000000 )) ;;
      KBIT|KBPS) echo $(( n * 1000 )) ;;
    esac
    return 0
  fi
  if [[ $s =~ ^[0-9]{1,15}$ ]]; then
    echo $(( 10#$s ))
    return 0
  fi
  return 1
}

bits_human() {
  local b=$1
  if (( b % 1000000000 == 0 )); then echo "$(( b / 1000000000 ))Gbit"
  elif (( b % 1000000 == 0 )); then echo "$(( b / 1000000 ))Mbit"
  elif (( b % 1000 == 0 )); then echo "$(( b / 1000 ))Kbit"
  else echo "${b}bit"
  fi
}

# 单连接缓冲上限 (字节) = 2 × 带宽 × RTT。
# 线上要填满管道需要一个 BDP (带宽×延迟); 套接字缓冲含协议开销, 要大于在途数据,
# 窗口才真能涨到这个 BDP, 所以取 2 倍。内存不参与这个乘法, 只在后面封顶。
# 输出一行: "<字节> <0|1 是否封顶> <封顶前字节>"
tcp_window_bytes() {
  local bps=$1 rtt_ms=$2 mem_quarter=$3 raw unclamped limit hard=$(( 128 * 1024 * 1024 ))
  raw=$(( bps / 4000 * rtt_ms + (bps % 4000) * rtt_ms / 4000 ))
  (( raw < 1 )) && raw=1
  if (( raw >= 1048576 )); then
    raw=$(( (raw + 1048576 - 1) / 1048576 * 1048576 ))
  else
    raw=$(( (raw + 65536 - 1) / 65536 * 65536 ))
  fi
  unclamped=$raw
  limit=$mem_quarter
  (( limit > hard )) && limit=$hard
  (( limit < 65536 )) && limit=65536
  if (( raw > limit )); then
    raw=$limit
    (( raw >= 1048576 )) && raw=$(( raw / 1048576 * 1048576 ))
    (( raw < 65536 )) && raw=65536
    echo "$raw 1 $unclamped"
  else
    echo "$raw 0 $unclamped"
  fi
}

# ssh 公钥校验 (ssh-keygen -l 能解析才算合法)
# 不接受 ssh-dss: OpenSSH 7.0 起默认禁用, 10.0 (Debian 13) 已移除, 算作有效会导致锁定后无法登录。
# RSA 小于 1024 位会被 sshd (RequiredRSASize) 拒绝, 同样不算有效
valid_pubkey() {
  local key=$1 tmp rc=0 bits
  [[ $key =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]] ]] || return 1
  tmp=$(mktemp) || return 1
  printf '%s\n' "$key" >"$tmp"
  bits=$(ssh-keygen -l -f "$tmp" 2>/dev/null | awk '{print $1}') || rc=1
  rm -f "$tmp"
  (( rc == 0 )) && valid_uint "$bits" || return 1
  if [[ $key == ssh-rsa* ]] && (( bits < 1024 )); then return 1; fi
  return 0
}

user_home() { getent passwd "$1" | cut -d: -f6 || true; }

server_ips() {
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v ':' || true
}

# 当前 SSH 会话的来源 IP (白名单默认值 / 防锁死检查用)。
# 优先 SSH_CONNECTION (sudo 默认会清掉), 否则沿父进程链找到本会话的 sshd 进程, 取它持有的
# TCP 连接的对端。不能用"所有已建立的 22 端口连接": 公网机器上随时有爆破者处于认证阶段,
# 它们的 IP 会被误当成自己的来源 (误中止, 或被当成白名单默认值推荐给用户)。
# 不是通过 SSH 运行 (控制台 / cloud-init) 时输出为空
ssh_peer_ips() {
  local peer=""
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    peer=${SSH_CONNECTION%% *}
  else
    local pid=$$ comm
    while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
      comm=$(cat "/proc/${pid}/comm" 2>/dev/null || true)
      if [[ $comm == sshd* ]]; then
        # ss -p 的最后一列是进程信息, 倒数第二列是对端地址
        peer=$(ss -Htnp state established 2>/dev/null \
          | awk -v p="pid=${pid}," 'index($0, p) {print $(NF-1); exit}') || true
        break
      fi
      pid=$(awk '/^PPid:/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)
    done
  fi
  [[ -n $peer ]] || return 0
  sed -E 's/^\[?([^]]*)\]?:[0-9]+$/\1/; s/^::ffff://' <<<"$peer"
}

sshd_bin() { command -v sshd || echo /usr/sbin/sshd; }

# 读取上次执行保存的状态值 (state.env 由 save_state 以 %q 写入)
state_get() {
  local line v=""
  [[ -r $STATE_FILE ]] || return 0
  while IFS= read -r line; do
    if [[ $line == "$1="* ]]; then
      eval "v=${line#*=}"
    fi
  done <"$STATE_FILE"
  printf '%s' "$v"
}

# 需要在锁定时关闭的旧端口 (排除新端口)
old_ssh_ports() {
  local p out=()
  for p in "${CUR_SSH_PORTS[@]}"; do [[ $p == "${SSH_PORT:-}" ]] || out+=("$p"); done
  echo "${out[*]}"
}

detect_ssh_ports() {
  mkdir -p /run/sshd
  mapfile -t CUR_SSH_PORTS < <("$(sshd_bin)" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un)
  (( ${#CUR_SSH_PORTS[@]} )) || CUR_SSH_PORTS=(22)
}

# -----------------------------------------------------------------------------
# 配置加载: 只解析 KEY=VALUE, 不 source, 防止远程配置注入命令
# 已经存在的变量 (环境变量 / 更高优先级来源) 不会被覆盖
# -----------------------------------------------------------------------------
is_known_key() {
  local k
  for k in "${KNOWN_KEYS[@]}"; do [[ $k == "$1" ]] && return 0; done
  return 1
}

parse_config() {
  local label=$1 line key val n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[2]}
      val=${BASH_REMATCH[3]}
      val=${val%"${val##*[![:space:]]}"}
      # 引号内原样保留, 引号外允许 `  # 注释`; 未加引号时 "空白+#" 之后视为注释
      if [[ $val =~ ^\"([^\"]*)\"([[:space:]]+#.*)?$ || $val =~ ^\'([^\']*)\'([[:space:]]+#.*)?$ ]]; then
        val=${BASH_REMATCH[1]}
      else
        val=$(sed -E 's/[[:space:]]+#.*$//' <<<"$val")
      fi
      if ! is_known_key "$key"; then
        warn "${label}:${n} 未知配置项 ${key}, 已忽略"
        continue
      fi
      is_set "$key" || printf -v "$key" '%s' "$val"
    else
      warn "${label}:${n} 无法解析的行, 已忽略"
    fi
  done
}

# 先加载的来源优先级更高 (parse_config 不覆盖已存在的变量)
load_local_config() {
  local local_cfg=${CLI_CONFIG:-${INIT_CONFIG:-}}
  [[ -n $local_cfg ]] || return 0
  [[ -r $local_cfg ]] || die "配置文件不可读: ${local_cfg}"
  info "加载本地配置: ${local_cfg}"
  parse_config "$local_cfg" <"$local_cfg"
}

load_remote_config() {
  local url=${CLI_CONFIG_URL:-${INIT_CONFIG_URL:-}}
  if [[ -n $url ]]; then
    [[ $url == https://* ]] || die "INIT_CONFIG_URL 只允许 https: ${url}"
    info "拉取远程配置: ${url}"
    local body
    body=$(curl -fsSL --proto '=https' --max-time 20 "$url") || die "远程配置拉取失败: ${url}"
    parse_config "$url" <<<"$body"
  fi
}

# -----------------------------------------------------------------------------
# 前置检查
# -----------------------------------------------------------------------------
require_root() {
  [[ $EUID -eq 0 ]] || die "请用 root 运行 (sudo bash init.sh)"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有 server-init 实例在运行"
  mkdir -p "$STATE_DIR"
  # 目录 755: 共享的 bashrc/vimrc 放在这里, 普通用户要能读; 敏感文件单独 600
  chmod 755 "$STATE_DIR"
}

check_os() {
  [[ -r /etc/os-release ]] || die "找不到 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-}
  OS_VERSION_ID=${VERSION_ID:-}
  OS_CODENAME=${VERSION_CODENAME:-}

  local supported=0
  case "${OS_ID}:${OS_VERSION_ID}" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) supported=1 ;;
  esac
  if (( ! supported )); then
    if is_yes FORCE; then
      warn "未验证的系统 ${PRETTY_NAME:-unknown}, FORCE=yes 继续执行"
    else
      die "不支持的系统: ${PRETTY_NAME:-unknown}。支持 Debian 12/13, Ubuntu 22.04/24.04/26.04 (FORCE=yes 强制)"
    fi
  fi
  [[ -d /run/systemd/system ]] || die "需要 systemd 作为 init"
  info "系统: ${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"
}

# 收集参数阶段就要用到的工具, 最小化镜像里可能没有
ensure_base_tools() {
  local -a need=()
  # 在 check_os 之前执行 (远程配置里的 FORCE 要先拉下来), 先粗略确认是 apt 系发行版
  command -v apt-get >/dev/null || die "仅支持 Debian / Ubuntu (未找到 apt-get)"
  command -v curl >/dev/null       || need+=(curl)
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || need+=(ca-certificates)
  command -v ssh-keygen >/dev/null || need+=(openssh-client)
  command -v ss >/dev/null         || need+=(iproute2)
  [[ -d /usr/share/zoneinfo ]]    || need+=(tzdata)
  (( ${#need[@]} )) || return 0
  info "安装基础工具: ${need[*]}"
  apt_get update
  apt_install "${need[@]}"
}

decide_interactive() {
  if is_yes NONINTERACTIVE; then
    INTERACTIVE=0
  elif { : >/dev/tty; } 2>/dev/null; then
    INTERACTIVE=1
  else
    INTERACTIVE=0
  fi
  info "运行模式: $( (( INTERACTIVE )) && echo 交互 || echo 非交互 )"
}

# 本脚本是否由 cloud-init 拉起 (runcmd / user-data 脚本): 沿父进程链查找
under_cloud_init() {
  local pid=$PPID cmd
  while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    cmd=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
    [[ $cmd == *cloud-init* ]] && return 0
    pid=$(awk '/^PPid:/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)
  done
  return 1
}

# 在第一次 apt 之前执行, 避免和 cloud-init 抢 apt 锁
wait_for_boot_jobs() {
  command -v cloud-init >/dev/null 2>&1 || return 0
  [[ $(cloud-init status 2>/dev/null || true) == *running* ]] || return 0
  if under_cloud_init; then
    # 由 cloud-init 自己调用时它的状态必然是 running, 等待只会空等到超时
    info "由 cloud-init 调用, 不等待 cloud-init 完成"
    return 0
  fi
  info "cloud-init 仍在运行, 等待完成 (最多 10 分钟)..."
  timeout 600 cloud-init status --wait >/dev/null 2>&1 || warn "等待 cloud-init 超时, 继续"
}

# -----------------------------------------------------------------------------
# 参数收集 (所有问题在开头一次问完)
# -----------------------------------------------------------------------------
select_modules() {
  local m key
  for m in "${MODULES[@]}"; do
    key="ENABLE_${m%%|*}"
    is_set "$key" || printf -v "$key" yes
    norm_yn "$key"
  done
  (( INTERACTIVE )) || return 0

  step "选择要执行的模块"
  local i=1 flag
  for m in "${MODULES[@]}"; do
    key="ENABLE_${m%%|*}"
    [[ ${!key} == yes ]] && flag="[x]" || flag="[ ]"
    tty_print "  ${i}) ${flag} ${m#*|}"$'\n'
    i=$((i + 1))
  done
  local off=""
  ask off "输入要关闭的模块编号 (空格分隔, 回车全部按上面执行)" ""
  local n
  for n in $off; do
    [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#MODULES[@]} )) || { warn "忽略无效编号: $n"; continue; }
    m=${MODULES[$((n - 1))]}
    printf -v "ENABLE_${m%%|*}" no
  done
}

# 网络优化不进上面的模块列表。那个列表默认全开, 只能填编号关闭。
# 这里单独问, 默认关。配置或环境变量里写了 ENABLE_NET 时, 菜单里的初始状态跟配置走。
select_net() {
  if ! is_set ENABLE_NET; then
    ENABLE_NET=no
  fi
  norm_yn ENABLE_NET
  (( INTERACTIVE )) || return 0

  step "网络优化 (默认关闭)"
  local flag="[ ]" choice=""
  [[ $ENABLE_NET == yes ]] && flag="[x]"
  tty_print "  1) ${flag} BBR + fq + TCP 窗口"$'\n'
  ask choice "输入 1 切换开关, 回车保持上面的状态" ""
  if [[ $choice == 1 ]]; then
    if [[ $ENABLE_NET == yes ]]; then ENABLE_NET=no; else ENABLE_NET=yes; fi
  elif [[ -n $choice ]]; then
    warn "忽略无效输入: ${choice}, 网络优化保持$( [[ $ENABLE_NET == yes ]] && echo 开启 || echo 关闭 )"
  fi
}

collect_baseline() {
  [[ $ENABLE_BASELINE == yes ]] || return 0
  while true; do
    resolve_val TIMEZONE "时区" "UTC"
    if [[ $TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f /usr/share/zoneinfo/${TIMEZONE} ]]; then
      break
    fi
    (( INTERACTIVE )) || die "无效时区: ${TIMEZONE}"
    warn "无效时区: ${TIMEZONE} (例如 UTC / Asia/Shanghai)"
    unset TIMEZONE
  done
  is_set JOURNALD_MAX_USE || JOURNALD_MAX_USE=500M
  [[ ${JOURNALD_MAX_USE^^} =~ ^[0-9]+[KMGT]?$ ]] || die "JOURNALD_MAX_USE 格式错误: ${JOURNALD_MAX_USE} (如 500M / 1G)"
}

collect_packages() {
  [[ $ENABLE_PACKAGES == yes ]] || return 0
  local mem_mb disk_mb
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  disk_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if ! is_set PACKAGE_PROFILE || [[ $PACKAGE_PROFILE == auto ]]; then
    # 内存按 1.8G 判定, 2G 机器扣掉内核保留后通常只有 1.9G 左右
    if (( mem_mb >= 1843 && disk_mb >= 10240 )); then
      PACKAGE_PROFILE=standard
    else
      PACKAGE_PROFILE=minimal
    fi
    info "内存 ${mem_mb}MB, 根分区可用 ${disk_mb}MB -> 软件包档位: ${PACKAGE_PROFILE}"
  fi
  [[ $PACKAGE_PROFILE =~ ^(minimal|standard)$ ]] || die "PACKAGE_PROFILE 只能是 auto|minimal|standard"
  is_set EXTRA_PACKAGES || EXTRA_PACKAGES=""
  local p
  for p in $EXTRA_PACKAGES; do
    [[ $p =~ ^[a-z0-9][a-z0-9+.-]+(:[a-z0-9]+)?$ ]] || die "EXTRA_PACKAGES 包名无效: ${p}"
  done
}

collect_user() {
  # SSH / Docker / 环境模块也需要知道目标用户
  if [[ $ENABLE_USER == no && $ENABLE_SSH == no ]]; then
    is_set NEW_USER || NEW_USER=""
    return 0
  fi

  while true; do
    resolve_val NEW_USER "新建/管理的用户名" ""
    if valid_username "$NEW_USER" && [[ $NEW_USER != root ]]; then break; fi
    (( INTERACTIVE )) || die "NEW_USER 无效或为空: '${NEW_USER}' (小写字母开头, 仅 a-z0-9_-)"
    warn "用户名无效: '${NEW_USER}'"
    unset NEW_USER
  done

  if [[ $ENABLE_USER == no ]]; then
    id "$NEW_USER" >/dev/null 2>&1 || die "未启用创建用户模块, 但用户 ${NEW_USER} 不存在"
    return 0
  fi

  resolve_yn USER_SUDO "是否把 ${NEW_USER} 加入 sudo 组" y
  if [[ $USER_SUDO == yes ]]; then
    resolve_yn USER_SUDO_NOPASSWD "是否给 ${NEW_USER} 配置免密 sudo (NOPASSWD)" n
  else
    USER_SUDO_NOPASSWD=no
  fi

  # 密码: 优先 hash, 其次明文; 都没有则交互输入
  if is_set USER_PASSWORD_HASH && [[ -n $USER_PASSWORD_HASH ]]; then
    :
  elif is_set USER_PASSWORD && [[ -n $USER_PASSWORD ]]; then
    :
  elif (( INTERACTIVE )); then
    local p1 p2 pw_required=0
    [[ $USER_SUDO == yes && $USER_SUDO_NOPASSWD == no ]] && pw_required=1
    if id "$NEW_USER" >/dev/null 2>&1 && has_password "$NEW_USER"; then
      info "用户 ${NEW_USER} 已有密码, 回车跳过则保持不变"
      pw_required=0
    fi
    while true; do
      ask_secret p1 "设置 ${NEW_USER} 的密码 (用于 sudo; $( (( pw_required )) && echo 必填 || echo 回车跳过))"
      if [[ -z $p1 ]]; then
        (( pw_required )) && { warn "sudo 需要密码, 不能为空"; continue; }
        break
      fi
      (( ${#p1} >= 12 )) || { warn "密码至少 12 位"; continue; }
      ask_secret p2 "再输入一次"
      [[ $p1 == "$p2" ]] && { USER_PASSWORD=$p1; break; }
      warn "两次输入不一致"
    done
  else
    if [[ $USER_SUDO == yes && $USER_SUDO_NOPASSWD == no ]] \
      && ! { id "$NEW_USER" >/dev/null 2>&1 && has_password "$NEW_USER"; }; then
      die "sudo 需要密码, 请设置 USER_PASSWORD_HASH 或 USER_PASSWORD, 或设置 USER_SUDO_NOPASSWD=yes"
    fi
  fi

  if [[ $ENABLE_DOCKER == yes ]]; then
    resolve_yn DOCKER_USER_GROUP "是否把 ${NEW_USER} 加入 docker 组 (等同 root 权限)" y
  fi
}

# 把一行公钥加入 SSH_KEYS_TO_ADD, 返回 1 表示无效
add_key() {
  local key
  key=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$1")
  [[ -n $key ]] && valid_pubkey "$key" || return 1
  SSH_KEYS_TO_ADD+=("${key}${2:+ $2}")
}

# 每项可以是 GitHub 用户名 (拉取 https://github.com/<user>.keys), 也可以是一个 https 链接
# (内容为 authorized_keys 格式的公钥列表, 如 raw.githubusercontent.com 上的文件)
add_github_keys() {
  local u key body n url label
  local -a gh_users=()
  read -ra gh_users <<<"${1:-}"
  for u in "${gh_users[@]}"; do
    if [[ $u == https://* ]]; then
      url=$u label=$u
    elif [[ $u =~ ^[A-Za-z0-9-]{1,39}$ ]]; then
      url="https://github.com/${u}.keys" label="github:${u}"
    else
      warn "无效 GitHub 用户名或公钥链接 (只允许 https): $u"
      continue
    fi
    if ! body=$(curl -fsSL --proto '=https' --max-time 15 "$url"); then
      warn "拉取 ${url} 失败"
      continue
    fi
    n=0
    while IFS= read -r key; do
      add_key "$key" "$label" && n=$((n + 1))
    done <<<"$body"
    if (( n )); then info "${url}: 获取到 ${n} 个公钥"; else warn "${url} 没有可用公钥"; fi
  done
}

add_pasted_keys() {
  local line
  tty_print "  粘贴公钥, 每行一个, 空行结束 (没有就直接回车):"$'\n'
  while true; do
    tty_print "  > "
    IFS= read -r line </dev/tty || break
    [[ -z ${line//[[:space:]]/} ]] && break
    if add_key "$line"; then
      tty_print "    ${C_GRN}已接受${C_RST}"$'\n'
    else
      tty_print "    ${C_RED}不是有效的 SSH 公钥 (不支持 ssh-dss 和小于 1024 位的 RSA), 已忽略${C_RST}"$'\n'
    fi
  done
}

collect_ssh_keys() {
  local key existing again more

  # 1) GitHub 用户名  2) 配置里的公钥 (; 或换行分隔), 都只处理一次
  if ! is_set SSH_GITHUB_USERS && (( INTERACTIVE )); then
    ask SSH_GITHUB_USERS "GitHub 用户名或公钥 https 链接 (空格分隔, 回车跳过)" ""
  fi
  add_github_keys "${SSH_GITHUB_USERS:-}"
  if [[ -n ${SSH_PUBLIC_KEYS:-} ]]; then
    while IFS= read -r key; do
      [[ -z ${key//[[:space:]]/} ]] && continue
      add_key "$key" || warn "无效公钥已忽略: ${key:0:40}..."
    done < <(tr ';' '\n' <<<"$SSH_PUBLIC_KEYS")
  fi

  existing=0
  id "$NEW_USER" >/dev/null 2>&1 && existing=$(count_valid_keys "$NEW_USER")

  # 3) 交互粘贴; 一个公钥都没有时可以重试, 或明确选择不锁定继续
  while true; do
    (( INTERACTIVE )) && add_pasted_keys
    info "待添加公钥 ${#SSH_KEYS_TO_ADD[@]} 个, ${NEW_USER} 已有有效公钥 ${existing} 个"
    (( ${#SSH_KEYS_TO_ADD[@]} + existing > 0 )) && return 0
    warn "没有任何公钥, 禁用密码登录后将无法登录"
    if (( INTERACTIVE )); then
      ask_yn again "重新提供公钥? (选 n 则只改端口, 不禁用密码/root 登录)" y
      if [[ $again == yes ]]; then
        more=""
        ask more "GitHub 用户名或公钥 https 链接 (空格分隔, 回车跳过)" ""
        add_github_keys "$more"
        continue
      fi
    fi
    warn "将跳过 SSH 锁定 (不禁用密码/root 登录)"
    SSH_LOCKDOWN=no
    return 0
  done
}

# 随机高位端口: 20000-32767, 避开 Linux 临时端口范围 (32768-60999), 防止和出站连接撞车
random_free_port() {
  local p
  while true; do
    p=$(shuf -i 20000-32767 -n 1)
    port_in_use "$p" || { echo "$p"; return 0; }
  done
}

collect_ssh() {
  [[ $ENABLE_SSH == yes ]] || return 0
  step "SSH 参数"
  collect_ssh_keys

  # 端口: 配置里没有则沿用上次执行的端口, 再没有则随机高位端口
  if ! is_set SSH_PORT || [[ -z $SSH_PORT ]]; then
    local rnd
    rnd=$(state_get SSH_PORT)
    [[ -n $rnd ]] || rnd=$(random_free_port)
    if (( INTERACTIVE )); then
      ask SSH_PORT "SSH 新端口" "$rnd"
    else
      SSH_PORT=$rnd
    fi
  fi
  while true; do
    if valid_port "$SSH_PORT"; then
      if [[ " ${CUR_SSH_PORTS[*]} " == *" ${SSH_PORT} "* ]] || ! port_in_use "$SSH_PORT"; then
        break
      fi
      warn "端口 ${SSH_PORT} 已被占用"
    else
      warn "无效端口: ${SSH_PORT}"
    fi
    (( INTERACTIVE )) || die "SSH_PORT 不可用: ${SSH_PORT}"
    ask SSH_PORT "SSH 新端口" "$(random_free_port)"
  done

  is_set SSH_CLIENT_ALIVE_INTERVAL || SSH_CLIENT_ALIVE_INTERVAL=60
  is_set SSH_CLIENT_ALIVE_COUNT_MAX || SSH_CLIENT_ALIVE_COUNT_MAX=10
  valid_uint "$SSH_CLIENT_ALIVE_INTERVAL" || die "SSH_CLIENT_ALIVE_INTERVAL 必须是非负整数"
  valid_uint "$SSH_CLIENT_ALIVE_COUNT_MAX" || die "SSH_CLIENT_ALIVE_COUNT_MAX 必须是非负整数"
  # shellcheck disable=SC2034  # 由 is_yes SSH_LOCKDOWN 间接读取
  is_set SSH_LOCKDOWN || SSH_LOCKDOWN=""
}

collect_ssh_whitelist() {
  # UFW 和 fail2ban 都会用到
  [[ $ENABLE_UFW == yes || $ENABLE_FAIL2BAN == yes ]] || return 0
  if ! is_set SSH_ALLOW_IPS && (( INTERACTIVE )); then
    local peers want
    peers=$(ssh_peer_ips | tr '\n' ' ')
    [[ -n $peers ]] && info "当前 SSH 连接来源 IP: ${peers}"
    ask_yn want "是否限制 SSH 只允许白名单 IP 访问" n
    if [[ $want == yes ]]; then
      ask SSH_ALLOW_IPS "白名单 IP/CIDR (空格分隔)" "${peers% }"
    else
      SSH_ALLOW_IPS=""
    fi
  fi
  is_set SSH_ALLOW_IPS || SSH_ALLOW_IPS=""
  local ip
  for ip in $SSH_ALLOW_IPS; do
    valid_ip_or_cidr "$ip" || die "白名单格式错误: ${ip}"
  done
  check_whitelist_covers_peers
}

# 当前 SSH 会话的来源 IP 必须在白名单内: 否则 UFW 启用后 (ENABLE_SSH=no 时立即,
# 否则在锁定关闭旧端口后) 就无法再从这里登录
check_whitelist_covers_peers() {
  [[ $ENABLE_UFW == yes && -n $SSH_ALLOW_IPS ]] || return 0
  local peer rc go
  local -a missing=()
  for peer in $(ssh_peer_ips); do
    rc=0
    ip_allowed "$peer" "$SSH_ALLOW_IPS" || rc=$?
    case $rc in
      0) ;;
      2) warn "无法确认 IPv6 来源 ${peer} 是否在白名单 CIDR 内, 请自行核对" ;;
      *) missing+=("$peer") ;;
    esac
  done
  (( ${#missing[@]} )) || return 0
  warn "当前 SSH 来源 ${missing[*]} 不在白名单 [${SSH_ALLOW_IPS}] 内, 启用后将无法从这里登录"
  if (( INTERACTIVE )); then
    ask_yn go "仍然继续" n
    [[ $go == yes ]] || die "已取消, 请调整 SSH 白名单后重新执行"
  elif is_yes FORCE; then
    warn "FORCE=yes, 继续执行"
  else
    die "白名单不包含当前 SSH 来源 ${missing[*]}, 为防止锁死已中止 (确认无误可设 FORCE=yes)"
  fi
}

collect_ufw() {
  [[ $ENABLE_UFW == yes ]] || return 0
  resolve_yn UFW_ALLOW_HTTP "是否放开 80/tcp (HTTP)" n
  resolve_yn UFW_ALLOW_HTTPS "是否放开 443/tcp (HTTPS)" n
  if ! is_set UFW_ALLOW_PORTS; then
    if (( INTERACTIVE )); then
      ask UFW_ALLOW_PORTS "其他需要放开的端口 (如 8080/tcp 51820/udp, 回车跳过)" ""
    else
      UFW_ALLOW_PORTS=""
    fi
  fi
  local p
  for p in $UFW_ALLOW_PORTS; do
    valid_ufw_port "$p" || die "UFW_ALLOW_PORTS 格式错误: ${p} (如 8080/tcp, 51820/udp, 6000:6007/tcp; 端口范围必须带协议)"
  done
}

# 8080 | 8080/tcp | 6000:6007/tcp (ufw 要求端口范围必须指定协议)
valid_ufw_port() {
  [[ $1 =~ ^([0-9]{1,5})(:([0-9]{1,5}))?(/(tcp|udp))?$ ]] || return 1
  local lo=${BASH_REMATCH[1]} hi=${BASH_REMATCH[3]} proto=${BASH_REMATCH[5]}
  valid_port "$lo" || return 1
  [[ -z $hi ]] && return 0
  valid_port "$hi" && (( 10#$lo < 10#$hi )) && [[ -n $proto ]]
}

# fail2ban 时间: 纯秒数, 或 10m / 24h / 4w / 1mo 等 (多段如 1h30m 也可)
valid_f2b_time() { [[ $1 =~ ^([0-9]+(s|m|h|d|w|mo|y)?)+$ ]]; }

collect_fail2ban() {
  [[ $ENABLE_FAIL2BAN == yes ]] || return 0
  is_set F2B_MAXRETRY    || F2B_MAXRETRY=3
  is_set F2B_FINDTIME    || F2B_FINDTIME=10m
  is_set F2B_BANTIME     || F2B_BANTIME=24h
  is_set F2B_BANTIME_MAX || F2B_BANTIME_MAX=4w
  [[ $F2B_MAXRETRY =~ ^[1-9][0-9]*$ ]] || die "F2B_MAXRETRY 必须是正整数: ${F2B_MAXRETRY}"
  local k
  for k in F2B_FINDTIME F2B_BANTIME F2B_BANTIME_MAX; do
    valid_f2b_time "${!k}" || die "${k} 格式错误: ${!k} (如 10m / 24h / 4w)"
  done
}

collect_docker() {
  [[ $ENABLE_DOCKER == yes ]] || return 0
  is_set DOCKER_LOG_MAX_SIZE || DOCKER_LOG_MAX_SIZE=50m
  is_set DOCKER_LOG_MAX_FILE || DOCKER_LOG_MAX_FILE=3
  [[ $DOCKER_LOG_MAX_SIZE =~ ^[1-9][0-9]*[kmg]$ ]] || die "DOCKER_LOG_MAX_SIZE 格式错误: ${DOCKER_LOG_MAX_SIZE} (如 50m)"
  [[ $DOCKER_LOG_MAX_FILE =~ ^[1-9][0-9]*$ ]] || die "DOCKER_LOG_MAX_FILE 必须是正整数: ${DOCKER_LOG_MAX_FILE}"
  # ENABLE_USER=yes 时 collect_user 已询问 (默认 yes); 否则不改动已有用户的组, 默认 no
  is_set DOCKER_USER_GROUP || DOCKER_USER_GROUP=no
  norm_yn DOCKER_USER_GROUP
  if [[ $DOCKER_USER_GROUP == yes ]]; then
    if [[ -z ${NEW_USER:-} ]]; then
      DOCKER_USER_GROUP=no
    elif [[ $ENABLE_USER == no ]] && ! id "$NEW_USER" >/dev/null 2>&1; then
      warn "用户 ${NEW_USER} 不存在且未启用创建用户模块, 不加入 docker 组"
      DOCKER_USER_GROUP=no
    fi
  fi
}

suggest_swap_mb() {
  local mem_mb=$1 disk_mb=$2 s
  if   (( mem_mb <= 2048 )); then s=$(( mem_mb * 2 ))
  elif (( mem_mb <= 8192 )); then s=$mem_mb
  else s=4096
  fi
  (( s > disk_mb / 4 )) && s=$(( disk_mb / 4 ))
  # 取整到 256M
  s=$(( s / 256 * 256 ))
  echo "$s"
}

collect_swap() {
  [[ $ENABLE_SWAP == yes ]] || return 0
  is_set SWAPPINESS || SWAPPINESS=10
  if ! [[ $SWAPPINESS =~ ^[0-9]{1,3}$ ]] || (( 10#$SWAPPINESS > 200 )); then
    die "SWAPPINESS 必须是 0-200 的整数: ${SWAPPINESS}"
  fi

  local virt
  virt=$(systemd-detect-virt -c 2>/dev/null || true)
  if [[ -n $virt && $virt != none ]]; then
    warn "运行在容器 (${virt}) 中, 无法管理 swap, 跳过"
    ENABLE_SWAP=no
    return 0
  fi
  if [[ -n $(swapon --noheadings --show 2>/dev/null) ]]; then
    info "已存在 swap, 跳过:"
    swapon --show
    ENABLE_SWAP=no
    return 0
  fi

  local mem_mb disk_mb sug
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  disk_mb=$(df -Pm / | awk 'NR==2{print $4}')
  sug=$(suggest_swap_mb "$mem_mb" "$disk_mb")
  info "内存 ${mem_mb}MB, 根分区可用 ${disk_mb}MB, 建议 swap ${sug}MB"

  # 自动大小: 磁盘太小时直接跳过; 用户明确指定的大小不合理才报错
  local auto=0
  if ! is_set SWAP_SIZE || [[ $SWAP_SIZE == auto ]]; then
    if (( sug < 256 || sug > disk_mb - 2048 )); then
      warn "根分区可用空间不足 (${disk_mb}MB), 跳过 swap"
      ENABLE_SWAP=no
      return 0
    fi
    auto=1
    if (( INTERACTIVE )); then
      ask SWAP_SIZE "swap 大小 (如 2G / 1024M, 0 表示不加)" "${sug}M"
    else
      SWAP_SIZE="${sug}M"
    fi
  fi
  [[ ${SWAP_SIZE^^} =~ ^[0-9]{1,7}[MG]?$ ]] || die "SWAP_SIZE 格式错误: ${SWAP_SIZE}"
  local want
  want=$(size_to_mb "$SWAP_SIZE")
  if (( want == 0 )); then
    ENABLE_SWAP=no
  elif (( want < 256 )); then
    warn "swap 小于 256M 意义不大, 跳过"
    ENABLE_SWAP=no
  elif (( want > disk_mb - 2048 )); then
    (( auto && ! INTERACTIVE )) && { warn "根分区空间不足, 跳过 swap"; ENABLE_SWAP=no; return 0; }
    die "swap ${want}MB 过大, 根分区仅剩 ${disk_mb}MB (需保留 2048MB)"
  fi
}

# 默认路由使用的网卡。窗口要填的是这台服务器的上行, 不是本机开发机
default_route_iface() {
  command -v ip >/dev/null 2>&1 || return 0
  local iface=""
  iface=$(ip -4 route show default 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)
  if [[ -z $iface ]]; then
    iface=$(ip -6 route show default 2>/dev/null \
      | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)
  fi
  printf '%s' "${iface%%@*}"
}

# /sys/class/net/<if>/speed 单位是 Mbit/s。虚拟网卡经常是 -1
nic_speed_mbps() {
  local iface=$1 speed
  [[ -n $iface && -r /sys/class/net/${iface}/speed ]] || return 1
  speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || true)
  [[ $speed =~ ^[0-9]+$ ]] || return 1
  (( speed >= 1 && speed <= 400000 )) || return 1
  echo "$speed"
}

# 当前 SSH 会话的 RTT (毫秒, 向上取整)。没有 SSH 会话时不输出。
# 这只是一条已经存在的路径, 不能代表所有客户端
ssh_rtt_ms() {
  local peer line whole frac rtt max=0
  command -v ss >/dev/null 2>&1 || return 0
  while IFS= read -r peer; do
    [[ -n $peer ]] || continue
    while IFS= read -r line; do
      if [[ $line =~ rtt:([0-9]+)\.([0-9]+) ]]; then
        whole=${BASH_REMATCH[1]}
        frac=${BASH_REMATCH[2]}
      elif [[ $line =~ rtt:([0-9]+) ]]; then
        whole=${BASH_REMATCH[1]}
        frac=""
      else
        continue
      fi
      rtt=$whole
      [[ -n $frac && $frac =~ [^0] ]] && rtt=$(( whole + 1 ))
      (( rtt > max )) && max=$rtt
    done < <(ss -ti "dst ${peer}" 2>/dev/null || true)
  done < <(ssh_peer_ips || true)
  (( max > 0 )) && echo "$max"
}

bandwidth_in_range() {
  [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 10000 && $1 <= 400000000000 ))
}

resolve_tcp_bandwidth() {
  local iface="" speed=""
  TCP_BANDWIDTH_SRC=""
  if ! is_set TCP_BANDWIDTH || [[ -z $TCP_BANDWIDTH || ${TCP_BANDWIDTH,,} == auto ]]; then
    iface=$(default_route_iface)
    if speed=$(nic_speed_mbps "$iface"); then
      TCP_BANDWIDTH_BPS=$(( speed * 1000000 ))
      TCP_BANDWIDTH_SRC="网卡 ${iface} 报告 ${speed}Mbit"
      (( speed >= 10000 )) && TCP_BANDWIDTH_SRC+=", 虚拟网卡经常虚报, 厂商有限速请设 TCP_BANDWIDTH"
      return 0
    fi
    if (( INTERACTIVE )); then
      warn "网卡 ${iface:-无默认路由} 没有报告速率"
      while true; do
        ask TCP_BANDWIDTH "上行带宽 (如 100Mbit / 1Gbit)" "1Gbit"
        TCP_BANDWIDTH_BPS=$(parse_bandwidth_bps "$TCP_BANDWIDTH" || true)
        if bandwidth_in_range "$TCP_BANDWIDTH_BPS"; then
          TCP_BANDWIDTH_SRC="手动指定 ${TCP_BANDWIDTH}"
          return 0
        fi
        warn "带宽格式错误: ${TCP_BANDWIDTH} (如 100Mbit / 1Gbit, 范围 10Kbit-400Gbit)"
        unset TCP_BANDWIDTH
      done
    fi
    warn "网卡速率未知, 按 1Gbit 计算。不是这个带宽请设 TCP_BANDWIDTH"
    TCP_BANDWIDTH_BPS=1000000000
    TCP_BANDWIDTH_SRC="网卡速率未知, 按 1Gbit 假设"
    return 0
  fi
  TCP_BANDWIDTH_BPS=$(parse_bandwidth_bps "$TCP_BANDWIDTH" || true)
  bandwidth_in_range "$TCP_BANDWIDTH_BPS" \
    || die "TCP_BANDWIDTH 格式错误或超出 10Kbit-400Gbit: ${TCP_BANDWIDTH} (如 100Mbit / 1Gbit)"
  TCP_BANDWIDTH_SRC="配置 ${TCP_BANDWIDTH}"
}

# auto: 至少按 200ms 算, 让一条连接能填满跨区路径。
# 不去 ping 公共 DNS: 那些地址是就近的, 测出来只有几毫秒, 窗口会被算得太小。
# 当前 SSH 比 200ms 更差时改用实测, 避免把已经看到的长延迟忽略掉。
resolve_tcp_rtt() {
  local ssh_rtt="" floor=200
  TCP_RTT_SRC=""
  if ! is_set TCP_RTT_MS || [[ -z $TCP_RTT_MS || ${TCP_RTT_MS,,} == auto ]]; then
    ssh_rtt=$(ssh_rtt_ms || true)
    TCP_RTT_USED=$floor
    if [[ $ssh_rtt =~ ^[0-9]+$ ]] && (( ssh_rtt > floor )); then
      TCP_RTT_USED=$ssh_rtt
      TCP_RTT_SRC="当前 SSH 延迟 ${ssh_rtt}ms, 高于 ${floor}ms, 按实测计算"
    elif [[ $ssh_rtt =~ ^[0-9]+$ ]]; then
      TCP_RTT_SRC="按 ${floor}ms 计算 (当前 SSH ${ssh_rtt}ms, 只代表这条连接)"
    else
      TCP_RTT_SRC="按 ${floor}ms 计算 (要覆盖的跨区延迟, 客户端更远或更近请设 TCP_RTT_MS)"
    fi
    return 0
  fi
  [[ $TCP_RTT_MS =~ ^[0-9]+$ ]] && (( TCP_RTT_MS >= 1 && TCP_RTT_MS <= 10000 )) \
    || die "TCP_RTT_MS 必须是 1-10000 的毫秒数, 或 auto: ${TCP_RTT_MS}"
  TCP_RTT_USED=$TCP_RTT_MS
  TCP_RTT_SRC="配置 ${TCP_RTT_MS}ms"
}

collect_net() {
  [[ $ENABLE_NET == yes ]] || return 0
  is_set TCP_CONGESTION || TCP_CONGESTION=bbr
  is_set TCP_QDISC || TCP_QDISC=fq
  is_set TCP_WINDOW_MAX || TCP_WINDOW_MAX=auto
  [[ $TCP_CONGESTION =~ ^[a-z][a-z0-9_]*$ ]] || die "TCP_CONGESTION 无效: ${TCP_CONGESTION}"
  [[ $TCP_QDISC =~ ^[a-z][a-z0-9_]*$ ]] || die "TCP_QDISC 无效: ${TCP_QDISC}"

  local mem_mb mem_quarter
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  (( mem_mb > 0 )) || die "读不到内存大小, 无法计算 TCP 窗口"
  mem_quarter=$(( mem_mb * 1024 * 1024 / 4 ))

  TCP_BANDWIDTH_SRC=""
  TCP_RTT_SRC=""
  if [[ ${TCP_WINDOW_MAX,,} != auto ]]; then
    [[ ${TCP_WINDOW_MAX^^} =~ ^[0-9]{1,10}[KMG]?$ ]] \
      || die "TCP_WINDOW_MAX 格式错误: ${TCP_WINDOW_MAX} (如 auto / 16M / 16777216)"
    TCP_WINDOW_BYTES=$(size_to_bytes "$TCP_WINDOW_MAX")
    (( TCP_WINDOW_BYTES >= 65536 )) || die "TCP_WINDOW_MAX 至少 64K: ${TCP_WINDOW_MAX}"
    (( TCP_WINDOW_BYTES <= 128 * 1024 * 1024 )) || die "TCP_WINDOW_MAX 最大 128M: ${TCP_WINDOW_MAX}"
    (( TCP_WINDOW_BYTES <= mem_quarter )) \
      || die "TCP_WINDOW_MAX ${TCP_WINDOW_MAX} 超过内存的 1/4 (内存 ${mem_mb}MB)"
    TCP_WINDOW_DESC="$(bytes_human "$TCP_WINDOW_BYTES") (手动指定)"
    info "TCP 窗口上限: ${TCP_WINDOW_DESC}"
    return 0
  fi

  resolve_tcp_bandwidth
  resolve_tcp_rtt
  read -r TCP_WINDOW_BYTES TCP_WINDOW_CAPPED TCP_WINDOW_RAW \
    < <(tcp_window_bytes "$TCP_BANDWIDTH_BPS" "$TCP_RTT_USED" "$mem_quarter")
  if (( TCP_WINDOW_CAPPED )); then
    TCP_WINDOW_DESC="$(bytes_human "$TCP_WINDOW_BYTES") (带宽×延迟为 $(bytes_human "$TCP_WINDOW_RAW"), 已按内存 1/4 与 128M 封顶) = $(bits_human "$TCP_BANDWIDTH_BPS") x ${TCP_RTT_USED}ms x 2"
  else
    TCP_WINDOW_DESC="$(bytes_human "$TCP_WINDOW_BYTES") = $(bits_human "$TCP_BANDWIDTH_BPS") x ${TCP_RTT_USED}ms x 2"
  fi
  info "TCP 窗口上限: ${TCP_WINDOW_DESC}"
  info "带宽: ${TCP_BANDWIDTH_SRC}"
  info "延迟: ${TCP_RTT_SRC}"
}

collect_shell_env() {
  [[ $ENABLE_SHELL_ENV == yes ]] || return 0
  if ! is_set SHELL_ENV_SCOPE; then
    if (( INTERACTIVE )); then
      local c
      ask c "环境优化范围: 1) 全部用户(含 root) 2) 指定用户" "1"
      [[ $c == 2 ]] && SHELL_ENV_SCOPE=users || SHELL_ENV_SCOPE=global
    else
      SHELL_ENV_SCOPE=global
    fi
  fi
  [[ $SHELL_ENV_SCOPE =~ ^(global|users)$ ]] || die "SHELL_ENV_SCOPE 只能是 global|users"
  if [[ $SHELL_ENV_SCOPE == users ]]; then
    resolve_val SHELL_ENV_USERS "要优化的用户 (空格分隔)" "${NEW_USER:-root}"
    [[ -n $SHELL_ENV_USERS ]] || die "SHELL_ENV_USERS 不能为空"
  fi
}

show_plan() {
  step "执行计划确认"
  local m key
  for m in "${MODULES[@]}"; do
    key="ENABLE_${m%%|*}"
    printf '  %-4s %s\n' "$( [[ ${!key} == yes ]] && echo '[x]' || echo '[ ]')" "${m#*|}"
  done
  echo
  [[ $ENABLE_BASELINE == yes ]] && echo "  时区: ${TIMEZONE}, journald 上限: ${JOURNALD_MAX_USE}"
  [[ $ENABLE_PACKAGES == yes ]] && echo "  软件包档位: ${PACKAGE_PROFILE} ${EXTRA_PACKAGES:+(额外: ${EXTRA_PACKAGES})}"
  if [[ -n ${NEW_USER:-} ]]; then
    echo "  用户: ${NEW_USER}"
    [[ $ENABLE_USER == yes ]] && echo "    sudo 组: ${USER_SUDO}, 免密 sudo: ${USER_SUDO_NOPASSWD}, 密码: $( [[ -n ${USER_PASSWORD_HASH:-}${USER_PASSWORD:-} ]] && echo 已设置 || echo 不修改)"
    if [[ $ENABLE_DOCKER == yes ]]; then echo "    docker 组: ${DOCKER_USER_GROUP}"; fi
  fi
  if [[ $ENABLE_SSH == yes ]]; then
    echo "  SSH: 端口 ${CUR_SSH_PORTS[*]} -> ${SSH_PORT}, 新增公钥 ${#SSH_KEYS_TO_ADD[@]} 个, 保活 ${SSH_CLIENT_ALIVE_INTERVAL}s x ${SSH_CLIENT_ALIVE_COUNT_MAX}"
    echo "       验证登录后: 禁止 root 登录 / 禁用密码登录 / 关闭旧端口"
  fi
  if [[ $ENABLE_UFW == yes ]]; then
    echo "  UFW: SSH 白名单 ${SSH_ALLOW_IPS:-无(任意 IP)}, 80: ${UFW_ALLOW_HTTP}, 443: ${UFW_ALLOW_HTTPS}, 其他: ${UFW_ALLOW_PORTS:-无}"
  fi
  [[ $ENABLE_FAIL2BAN == yes ]] && echo "  fail2ban: ${F2B_MAXRETRY} 次/${F2B_FINDTIME} 封 ${F2B_BANTIME}, 递增至 ${F2B_BANTIME_MAX}"
  [[ $ENABLE_SWAP == yes ]] && echo "  swap: ${SWAP_SIZE}, swappiness=${SWAPPINESS}"
  if [[ $ENABLE_NET == yes ]]; then
    echo "  网络: 拥塞控制 ${TCP_CONGESTION}, qdisc ${TCP_QDISC}, TCP 窗口上限 ${TCP_WINDOW_DESC}"
    [[ -n ${TCP_BANDWIDTH_SRC:-} ]] && echo "       带宽: ${TCP_BANDWIDTH_SRC}"
    [[ -n ${TCP_RTT_SRC:-} ]] && echo "       延迟: ${TCP_RTT_SRC}"
  else
    echo "  网络优化 (BBR + fq + TCP 窗口): 关闭"
  fi
  if [[ $ENABLE_SHELL_ENV == yes ]]; then
    echo "  环境优化: $( [[ $SHELL_ENV_SCOPE == global ]] && echo '全部用户(含 root)' || echo "${SHELL_ENV_USERS}")"
  fi
  echo

  if (( INTERACTIVE )); then
    local go
    ask_yn go "确认按以上计划执行" y
    [[ $go == yes ]] || die "已取消"
  fi
}

# -----------------------------------------------------------------------------
# 模块实现
# -----------------------------------------------------------------------------
do_update() {
  step "系统更新"
  apt_get update
  apt_get full-upgrade
  apt_get autoremove --purge
  ok "系统更新完成"
}

do_baseline() {
  step "时区 / 时间同步 / journald"
  timedatectl set-timezone "$TIMEZONE"
  ok "时区: ${TIMEZONE}"

  if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
    info "检测到 chrony 在运行, 保留现有时间同步"
  else
    dpkg -s systemd-timesyncd >/dev/null 2>&1 || apt_install systemd-timesyncd
    # 容器 / LXC VPS 中 timesyncd 不可用, 时间由宿主机负责
    if timedatectl set-ntp true 2>/dev/null; then
      ok "systemd-timesyncd 已启用"
    else
      warn "当前环境不支持 NTP (可能是容器/LXC), 时间由宿主机同步"
    fi
  fi

  if write_file "$JOURNALD_DROPIN" 644 <<EOF
# Managed by server-init
[Journal]
SystemMaxUse=${JOURNALD_MAX_USE}
EOF
  then
    systemctl restart systemd-journald
  fi
  ok "journald SystemMaxUse=${JOURNALD_MAX_USE}"
}

do_packages() {
  step "安装常用软件 (${PACKAGE_PROFILE})"
  local -a pkgs want=() missing=() extra=()
  if [[ $PACKAGE_PROFILE == standard ]]; then pkgs=("${PKG_STANDARD[@]}"); else pkgs=("${PKG_MINIMAL[@]}"); fi
  read -ra extra <<<"$EXTRA_PACKAGES"
  pkgs+=("${extra[@]}")
  [[ $ENABLE_UPDATE == yes ]] || apt_get update
  local p
  for p in "${pkgs[@]}"; do
    if pkg_available "$p"; then want+=("$p"); else missing+=("$p"); fi
  done
  (( ${#missing[@]} )) && warn "仓库中不存在, 跳过: ${missing[*]}"
  apt_install "${want[@]}"
  ok "已安装: ${want[*]}"
}

do_user() {
  step "创建用户 ${NEW_USER}"
  dpkg -s sudo >/dev/null 2>&1 || apt_install sudo

  if id "$NEW_USER" >/dev/null 2>&1; then
    info "用户已存在, 只调整配置"
  else
    useradd --create-home --shell /bin/bash --user-group "$NEW_USER"
    ok "已创建用户 ${NEW_USER}"
  fi

  local home
  home=$(user_home "$NEW_USER")
  chmod 750 "$home"

  if [[ -n ${USER_PASSWORD_HASH:-} ]]; then
    printf '%s:%s\n' "$NEW_USER" "$USER_PASSWORD_HASH" | chpasswd -e
    ok "已设置密码 (hash)"
  elif [[ -n ${USER_PASSWORD:-} ]]; then
    printf '%s:%s\n' "$NEW_USER" "$USER_PASSWORD" | chpasswd
    ok "已设置密码"
  fi
  unset USER_PASSWORD

  if [[ $USER_SUDO == yes ]]; then
    usermod -aG sudo "$NEW_USER"
    ok "已加入 sudo 组"
  fi

  local sudoers="/etc/sudoers.d/90-server-init-${NEW_USER}"
  if [[ $USER_SUDO == yes && $USER_SUDO_NOPASSWD == yes ]]; then
    local tmp
    tmp=$(mktemp)
    printf '# Managed by server-init\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" >"$tmp"
    visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers 校验失败"; }
    install -m 440 "$tmp" "$sudoers"
    rm -f "$tmp"
    ok "已配置免密 sudo: ${sudoers}"
  elif [[ -f $sudoers ]]; then
    backup_file "$sudoers"
    rm -f "$sudoers"
    info "已移除旧的免密 sudo 配置"
  fi
  note "用户: ${NEW_USER} (sudo: ${USER_SUDO}, 免密: ${USER_SUDO_NOPASSWD})"
}

install_ssh_keys() {
  local home ssh_dir ak key body added=0
  home=$(user_home "$NEW_USER")
  ssh_dir="${home}/.ssh"
  ak="${ssh_dir}/authorized_keys"

  install -d -m 700 -o "$NEW_USER" -g "$(id -gn "$NEW_USER")" "$ssh_dir"
  [[ -f $ak ]] || install -m 600 -o "$NEW_USER" -g "$(id -gn "$NEW_USER")" /dev/null "$ak"

  for key in "${SSH_KEYS_TO_ADD[@]}"; do
    # 按 base64 主体去重, 注释不同也算同一把
    body=$(awk '{print $2}' <<<"$key")
    if grep -qF -- "$body" "$ak"; then continue; fi
    # 只在真的要改动时才备份, 重复执行不产生多余备份
    (( added )) || backup_file "$ak"
    printf '%s\n' "$key" >>"$ak"
    added=$((added + 1))
  done
  chown "$NEW_USER:$(id -gn "$NEW_USER")" "$ak"
  chmod 600 "$ak"
  ok "authorized_keys 新增 ${added} 个公钥 (${ak})"
}

# 当前有效公钥数
count_valid_keys() {
  local ak n=0 line
  ak="$(user_home "$1")/.ssh/authorized_keys"
  [[ -f $ak ]] || { echo 0; return; }
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    valid_pubkey "$line" && n=$((n + 1))
  done <"$ak"
  echo "$n"
}

ssh_uses_socket() {
  systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null
}

# 失败返回非 0 (不 die), 由调用方决定是否回滚。ssh_lockdown 在 if 中调用, set -e 不生效,
# 所以每一步都显式检查
restart_sshd() {
  mkdir -p /run/sshd || return 1
  "$(sshd_bin)" -t || return 1
  if ssh_uses_socket; then
    # Ubuntu 22.10+ socket 激活: 端口由 sshd-socket-generator 生成, 需要 daemon-reload
    systemctl daemon-reload || return 1
    systemctl restart ssh.socket || return 1
    if systemctl is-active --quiet ssh.service; then
      systemctl restart ssh.service || return 1
    fi
  else
    # 重启 ssh.service 不会断开现有会话 (KillMode=process)
    systemctl restart ssh.service || return 1
  fi
}

wait_port_listen() {
  local p=$1 i
  for i in {1..20}; do
    port_in_use "$p" && return 0
    sleep 0.5
  done
  return 1
}

# SSH 配置的三个阶段:
#   transition: 新旧端口同时监听, 认证保持系统默认 (首次执行, 等用户验证新端口)
#   moving:     新旧端口同时监听, 认证已锁定 (锁定后又改了端口, 不能因为换端口放宽认证)
#   locked:     仅新端口, 仅公钥, 禁止 root
write_sshd_dropin() {
  local stage=$1 p content
  content=$(
    # 不写时间戳: 内容不变时 write_file 不重写, 重复执行不会产生新备份或多余的 sshd 重启
    echo "# Managed by server-init (stage: ${stage})"
    echo "# 00- 前缀保证优先于 50-cloud-init.conf 等文件 (大多数选项首次匹配生效)。"
    echo "# 但 Port / ListenAddress 是累加的: 其他文件里的 Port 已被注释, 端口只在这里定义"
    if [[ $stage != locked ]]; then
      for p in "${CUR_SSH_PORTS[@]}"; do
        [[ $p == "$SSH_PORT" ]] || echo "Port ${p}"
      done
    fi
    echo "Port ${SSH_PORT}"
    echo "PubkeyAuthentication yes"
    echo "ClientAliveInterval ${SSH_CLIENT_ALIVE_INTERVAL}"
    echo "ClientAliveCountMax ${SSH_CLIENT_ALIVE_COUNT_MAX}"
    if [[ $stage != transition ]]; then
      echo "PermitRootLogin no"
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "PermitEmptyPasswords no"
    fi
  )
  # 不用管道: write_file 要在当前 shell 执行, 出错时 die 才能真正终止脚本
  write_file "$SSHD_DROPIN" 644 <<<"$content" || true
}

# 当前 drop-in 所处阶段 (transition|moving|locked), 没有文件时输出空
sshd_dropin_stage() {
  [[ -f $SSHD_DROPIN ]] || return 0
  sed -nE '1s/.*\(stage: ([a-z]+)\).*/\1/p' "$SSHD_DROPIN"
}

# sshd 的 Port 指令是累加的 (不是首次匹配), sshd_config 或其他 drop-in 里显式写的
# `Port 22` 会和我们的端口同时生效, 锁定后旧端口仍在监听。这里把它们注释掉,
# 端口统一由 SSHD_DROPIN 管理 (过渡阶段 SSHD_DROPIN 会重新列出这些旧端口)。
# 修改前的内容存一份快照, 校验失败时 restore_foreign_ports 回滚
SSHD_PORT_EDITS=()
disable_foreign_ports() {
  local f snap
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f $f && $f != "$SSHD_DROPIN" ]] || continue
    grep -qE '^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]' "$f" || continue
    backup_file "$f"
    snap=$(mktemp) || die "mktemp 失败"
    cp -a "$f" "$snap" || die "无法备份 ${f}"
    SSHD_PORT_EDITS+=("${f}|${snap}")
    sed -i -E 's/^([[:space:]]*[Pp][Oo][Rr][Tt][[:space:]].*)$/# disabled by server-init: \1/' "$f" \
      || die "无法修改 ${f}"
    warn "已注释 ${f} 中的 Port 指令 (端口统一由 ${SSHD_DROPIN} 管理)"
  done
}

restore_foreign_ports() {
  local e
  for e in "${SSHD_PORT_EDITS[@]}"; do
    if cp -a "${e#*|}" "${e%%|*}"; then
      rm -f "${e#*|}"
    else
      err "回滚 ${e%%|*} 失败, 原文件备份: ${e%%|*}.bak.server-init.${RUN_TS}"
    fi
  done
  SSHD_PORT_EDITS=()
}

# 以 sshd -T 输出的实际生效配置为准, 检查端口和认证选项, 而不是相信写进文件的内容
# (Include 位置、Match 块、累加型指令都可能让实际值和 drop-in 不一致)
# 用法: verify_sshd_effective transition|moving|locked。不一致返回 1
verify_sshd_effective() {
  local stage=$1 eff got want kv k v actual
  eff=$("$(sshd_bin)" -T 2>/dev/null) || { err "sshd -T 执行失败"; return 1; }
  got=$(awk '$1=="port" {print $2}
             $1=="listenaddress" {n=split($2, a, ":"); print a[n]}' <<<"$eff" | sort -un | paste -sd' ' -)
  if [[ $stage == locked ]]; then
    want=$SSH_PORT
  else
    want=$(printf '%s\n' "$SSH_PORT" "${CUR_SSH_PORTS[@]}" | sort -un | paste -sd' ' -)
  fi
  if [[ $got != "$want" ]]; then
    err "sshd 实际生效端口 [${got}], 预期 [${want}]"
    return 1
  fi
  [[ $stage != transition ]] || return 0
  for kv in pubkeyauthentication:yes passwordauthentication:no \
            kbdinteractiveauthentication:no permitrootlogin:no; do
    k=${kv%%:*} v=${kv#*:}
    actual=$(awk -v k="$k" '$1==k {print $2; exit}' <<<"$eff")
    if [[ $actual != "$v" ]]; then
      err "sshd 实际生效 ${k}=${actual:-<缺失>}, 预期 ${v} (可能被 Include 之前的配置覆盖)"
      return 1
    fi
  done
}

check_sshd_include() {
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    backup_file /etc/ssh/sshd_config
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    warn "sshd_config 缺少 Include, 已在首行补上"
  fi
}

save_state() {
  local k content
  content=$(
    # 不写时间戳: 内容不变时 write_file 不重写, 重复执行不产生多余备份 (时间见 summary.txt)
    echo "# server-init state"
    for k in NEW_USER SSH_PORT SSH_ALLOW_IPS SSH_CLIENT_ALIVE_INTERVAL SSH_CLIENT_ALIVE_COUNT_MAX \
             ENABLE_UFW ENABLE_FAIL2BAN SSH_LOCKED; do
      printf '%s=%q\n' "$k" "${!k:-}"
    done
    printf 'CUR_SSH_PORTS=%q\n' "${CUR_SSH_PORTS[*]}"
  )
  write_file "$STATE_FILE" 600 <<<"$content" || true
}

do_ssh() {
  step "SSH: 公钥 + sshd 配置"
  dpkg -s openssh-server >/dev/null 2>&1 || apt_install openssh-server
  install_ssh_keys
  check_sshd_include
  disable_foreign_ports

  # 已锁定 (或正在换端口) 时认证保持锁定; 端口有变化就先进入 moving, 新旧端口同时监听,
  # 和首次执行一样等用户验证新端口后再关闭旧端口, 而不是直接切走
  local stage=transition old
  old=$(old_ssh_ports)
  case $(sshd_dropin_stage) in
    locked|moving)
      if [[ -z $old ]]; then
        info "SSH 之前已锁定, 本次重新写入锁定配置"
        stage=locked
      else
        warn "SSH 已锁定, 端口改为 ${SSH_PORT}: 新旧端口 (${old}) 暂时同时监听, 认证保持仅公钥"
        stage=moving
      fi
      ;;
  esac
  SSH_LOCKED=$( [[ $stage == locked ]] && echo yes || echo no )
  write_sshd_dropin "$stage"

  if ! "$(sshd_bin)" -t || ! verify_sshd_effective "$stage"; then
    local bak="${SSHD_DROPIN}.bak.server-init.${RUN_TS}"
    if [[ -f $bak ]]; then mv -f "$bak" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
    restore_foreign_ports
    die "sshd 配置校验失败, 已回滚"
  fi
  restart_sshd || die "sshd 重启失败, 当前会话不受影响, 请勿断开。检查: journalctl -u ssh"
  wait_port_listen "$SSH_PORT" || die "sshd 未在端口 ${SSH_PORT} 上监听, 请检查: journalctl -u ssh"
  ok "sshd 已在端口 ${SSH_PORT} 监听${old:+ (旧端口 ${old} 保留到锁定前)}"
  save_state
}

# 放行 SSH 端口, 并清理同一端口上与当前白名单不一致的旧规则 (重复执行时白名单可能
# 从"任意 IP"改为指定 IP, 或 IP 列表有变化; 只追加不删除会让白名单形同虚设)
ufw_allow_ssh_port() {
  local port=$1 comment=$2 ip prev
  prev=$(state_get SSH_ALLOW_IPS)
  if [[ -n ${SSH_ALLOW_IPS:-} ]]; then
    ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
    for ip in $prev; do
      [[ " ${SSH_ALLOW_IPS} " == *" ${ip} "* ]] && continue
      ufw --force delete allow proto tcp from "$ip" to any port "$port" >/dev/null 2>&1 || true
    done
    for ip in $SSH_ALLOW_IPS; do
      ufw allow proto tcp from "$ip" to any port "$port" comment "$comment" >/dev/null
    done
  else
    for ip in $prev; do
      ufw --force delete allow proto tcp from "$ip" to any port "$port" >/dev/null 2>&1 || true
    done
    ufw allow "${port}/tcp" comment "$comment" >/dev/null
  fi
}

write_ufw_docker_rules() {
  # 方案来自 github.com/chaifeng/ufw-docker:
  # Docker 发布的端口默认绕过 UFW, 这里让 FORWARD 流量也走 ufw-user-forward,
  # 需要对外开放容器端口时用: ufw route allow proto tcp from any to any port <容器端口>
  if grep -qF "# BEGIN UFW AND DOCKER" "$UFW_AFTER_RULES"; then
    info "UFW Docker 规则已存在"
    return 0
  fi
  backup_file "$UFW_AFTER_RULES"
  cat >>"$UFW_AFTER_RULES" <<'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF
  ok "已写入 UFW 接管 Docker 端口规则"
}

do_ufw() {
  step "UFW 防火墙"
  dpkg -s ufw >/dev/null 2>&1 || apt_install ufw

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # 先放行 SSH 再 enable, 避免断连。旧端口在锁定前临时对所有 IP 开放, 作为兜底
  local p target_port
  target_port=${SSH_PORT:-}
  if [[ $ENABLE_SSH == yes ]]; then
    ufw_allow_ssh_port "$target_port" "server-init ssh"
    for p in "${CUR_SSH_PORTS[@]}"; do
      [[ $p == "$target_port" ]] && continue
      ufw allow "${p}/tcp" comment "server-init ssh-temp" >/dev/null
    done
  else
    for p in "${CUR_SSH_PORTS[@]}"; do ufw_allow_ssh_port "$p" "server-init ssh"; done
  fi

  [[ $UFW_ALLOW_HTTP == yes ]]  && ufw allow 80/tcp comment "server-init http" >/dev/null
  [[ $UFW_ALLOW_HTTPS == yes ]] && ufw allow 443/tcp comment "server-init https" >/dev/null
  for p in $UFW_ALLOW_PORTS; do ufw allow "$p" comment "server-init custom" >/dev/null; done

  write_ufw_docker_rules
  ufw --force enable >/dev/null
  ufw reload >/dev/null
  systemctl enable --quiet ufw
  ok "UFW 已启用"
  ufw status verbose
}

write_f2b_jail() {
  local ports=$1 banaction ignore="127.0.0.1/8 ::1 ${SSH_ALLOW_IPS:-}"
  if command -v ufw >/dev/null && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
    banaction=ufw
  else
    banaction=nftables-multiport
  fi
  write_file "$F2B_JAIL" 644 <<EOF
# Managed by server-init
[DEFAULT]
bantime  = ${F2B_BANTIME}
findtime = ${F2B_FINDTIME}
maxretry = ${F2B_MAXRETRY}
bantime.increment = true
bantime.maxtime   = ${F2B_BANTIME_MAX}
ignoreip = ${ignore% }
banaction = ${banaction}
banaction_allports = ${banaction%-multiport}$( [[ $banaction == ufw ]] || echo '-allports')

[sshd]
enabled = true
backend = systemd
port    = ${ports}
EOF
}

do_fail2ban() {
  step "fail2ban"
  local -a pkgs=(fail2ban python3-systemd)
  command -v ufw >/dev/null || pkgs+=(nftables)
  apt_install "${pkgs[@]}"

  local ports
  if [[ $ENABLE_SSH == yes ]]; then
    ports=$(printf '%s\n' "$SSH_PORT" "${CUR_SSH_PORTS[@]}" | sort -un | paste -sd, -)
    if [[ ${SSH_LOCKED:-no} == yes ]]; then ports=$SSH_PORT; fi
  else
    ports=$(printf '%s\n' "${CUR_SSH_PORTS[@]}" | paste -sd, -)
  fi
  write_f2b_jail "$ports" || true

  fail2ban-client -t >/dev/null || die "fail2ban 配置校验失败: fail2ban-client -t"
  systemctl enable --quiet fail2ban
  systemctl restart fail2ban
  sleep 2
  if fail2ban-client status sshd >/dev/null 2>&1; then
    ok "fail2ban sshd jail 运行中 (端口 ${ports})"
  else
    warn "fail2ban sshd jail 未正常运行, 请检查: journalctl -u fail2ban"
  fi
  # 自己的来源 IP 不在 ignoreip 时, 连续 ${F2B_MAXRETRY} 次登录失败 (包括测试性的失败登录)
  # 就会被封 ${F2B_BANTIME}; 提醒一下, 解封: fail2ban-client set sshd unbanip <IP>
  local peer
  for peer in $(ssh_peer_ips); do
    if ! ip_allowed "$peer" "${SSH_ALLOW_IPS:-}" 2>/dev/null; then
      warn "当前来源 ${peer} 不在 fail2ban ignoreip 内: 连续 ${F2B_MAXRETRY} 次登录失败会被封 ${F2B_BANTIME} (解封: fail2ban-client set sshd unbanip ${peer})"
      note "fail2ban: 来源 ${peer} 未加白, 请勿在此 IP 上做失败登录测试 (解封: fail2ban-client set sshd unbanip <IP>)"
    fi
  done
}

do_docker() {
  step "Docker CE"
  local repo="https://download.docker.com/linux/${OS_ID}"
  if ! curl -fsSI --max-time 15 "${repo}/dists/${OS_CODENAME}/Release" >/dev/null; then
    warn "Docker 官方源暂不支持 ${OS_ID} ${OS_CODENAME}, 跳过 Docker"
    note "Docker: 跳过 (官方源不支持 ${OS_CODENAME})"
    return 0
  fi

  local old
  for old in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    dpkg -s "$old" >/dev/null 2>&1 && apt_get remove "$old"
  done

  apt_install ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "${repo}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  write_file /etc/apt/sources.list.d/docker.list 644 <<EOF || true
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${repo} ${OS_CODENAME} stable
EOF
  apt_get update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  if write_file "$DOCKER_DAEMON_JSON" 644 <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  },
  "live-restore": true
}
EOF
  then
    info "daemon.json 已更新 (日志轮转 + live-restore)"
  fi
  systemctl enable --quiet docker containerd
  systemctl restart docker

  if [[ $DOCKER_USER_GROUP == yes ]]; then
    usermod -aG docker "$NEW_USER"
    ok "${NEW_USER} 已加入 docker 组 (重新登录后生效)"
  fi
  # docker 启动会重建 DOCKER-USER 链, reload 一次让 UFW 规则生效
  if [[ $ENABLE_UFW == yes ]]; then ufw reload >/dev/null; fi
  ok "Docker: $(docker --version)"
  note "Docker: 容器端口默认不对公网开放, 放行用: ufw route allow proto tcp from any to any port <容器端口>"
}

do_swap() {
  step "swap"
  local mb fstype
  mb=$(size_to_mb "$SWAP_SIZE")
  if [[ -e $SWAP_FILE ]]; then
    warn "${SWAP_FILE} 已存在但未启用, 不覆盖, 跳过"
    return 0
  fi
  fstype=$(findmnt -no FSTYPE /)
  if [[ $fstype == btrfs ]]; then
    btrfs filesystem mkswapfile --size "${mb}M" "$SWAP_FILE" \
      || { warn "btrfs 创建 swapfile 失败, 跳过"; return 0; }
  else
    fallocate -l "${mb}M" "$SWAP_FILE" 2>/dev/null \
      || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$mb" status=none
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
  fi
  swapon "$SWAP_FILE"
  if ! grep -qE "^[^#]*${SWAP_FILE}[[:space:]]" /etc/fstab; then
    backup_file /etc/fstab
    echo "${SWAP_FILE} none swap sw 0 0" >>/etc/fstab
  fi
  # 网络参数在 SYSCTL_NET_FILE, 不要写进这个文件, 两个模块会互相覆盖
  write_file "$SYSCTL_FILE" 644 <<EOF || true
# Managed by server-init
vm.swappiness = ${SWAPPINESS}
EOF
  sysctl -q -p "$SYSCTL_FILE"
  ok "swap ${mb}MB 已启用, swappiness=${SWAPPINESS}"
  note "swap: ${mb}MB (${SWAP_FILE})"
}

# modprobe -n -v 对真正的模块打印 insmod, 对内建模块打印 builtin。
# 内建模块写进 modules-load.d 会让每次开机都打一条警告。
module_needs_load() {
  local out
  out=$(modprobe -n -v "$1" 2>/dev/null || true)
  [[ $out == *insmod* ]]
}

# 网卡是否该改 qdisc: 跳过容器网卡; operstate=down 不动
net_iface_tunable() {
  local iface=$1 state flags
  [[ $iface =~ ^(lo|veth|docker|br-|virbr|cali|flannel|cni|lxc|ifb|dummy|kube-) ]] && return 1
  state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || true)
  [[ $state == down ]] && return 1
  [[ $state == up ]] && return 0
  flags=$(cat "/sys/class/net/${iface}/flags" 2>/dev/null || true)
  [[ $flags =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  (( flags & 1 ))
}

# 只动默认队列。mq 只替换子队列, 不把多队列根换成单个 fq (那样会失去多队列)。
# htb/cake 等整形队列一律保留。
apply_net_qdisc() {
  local qdisc=$1 iface root parent n
  command -v tc >/dev/null 2>&1 || {
    warn "没有 tc, 跳过当前网卡 qdisc (重启后 default_qdisc 对新网卡生效)"
    return 0
  }
  while IFS= read -r iface; do
    [[ -n $iface ]] || continue
    net_iface_tunable "$iface" || continue
    root=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2}' || true)
    [[ -n $root ]] || continue
    if [[ $root == "$qdisc" ]]; then
      info "${iface}: qdisc 已是 ${qdisc}"
      continue
    fi
    case $root in
      mq|mqprio)
        n=0
        while IFS= read -r parent; do
          [[ -n $parent ]] || continue
          if tc qdisc replace dev "$iface" parent "$parent" "$qdisc" >/dev/null 2>&1; then
            n=$((n + 1))
          fi
        done < <(tc qdisc show dev "$iface" 2>/dev/null \
          | awk 'NR>1 { for (i=1;i<=NF;i++) if ($i=="parent") { print $(i+1); break } }' || true)
        if (( n > 0 )); then
          ok "${iface}: ${n} 个子队列已设为 ${qdisc}"
        else
          warn "${iface}: 多队列网卡未能立即切换 ${qdisc}, 重启后 default_qdisc 生效"
        fi
        ;;
      fq_codel|pfifo_fast|pfifo|noqueue|fq_pie|pfifo_head_drop|fq)
        if tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1; then
          ok "${iface}: qdisc ${root} -> ${qdisc}"
        else
          warn "${iface}: 切换到 ${qdisc} 失败, 重启后 default_qdisc 对新网卡生效"
        fi
        ;;
      *)
        warn "${iface}: 保留已有 qdisc ${root}"
        ;;
    esac
  done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 || true)
}

net_sysctl_has() { sysctl -n "$1" >/dev/null 2>&1; }

do_net() {
  step "网络优化 (${TCP_CONGESTION} + ${TCP_QDISC} + TCP 窗口)"
  command -v sysctl >/dev/null 2>&1 || apt_install procps
  command -v tc >/dev/null 2>&1 || apt_install iproute2

  local cc_ok=0 qdisc_ok=0 virt
  virt=$(systemd-detect-virt -c 2>/dev/null || true)
  if [[ -n $virt && $virt != none ]]; then
    warn "运行在容器 (${virt}) 中, 网络 sysctl / qdisc 可能由宿主机决定"
  fi

  if modprobe "tcp_${TCP_CONGESTION}" >/dev/null 2>&1 \
    && grep -qw "$TCP_CONGESTION" /proc/sys/net/ipv4/tcp_available_congestion_control; then
    cc_ok=1
  else
    warn "拥塞控制 ${TCP_CONGESTION} 不可用, 不修改 tcp_congestion_control"
  fi
  if modprobe "sch_${TCP_QDISC}" >/dev/null 2>&1; then
    qdisc_ok=1
  else
    warn "队列规则 ${TCP_QDISC} 不可用, 不修改 default_qdisc"
  fi

  local body=""
  (( cc_ok )) && module_needs_load "tcp_${TCP_CONGESTION}" && body+="tcp_${TCP_CONGESTION}"$'\n'
  (( qdisc_ok )) && module_needs_load "sch_${TCP_QDISC}" && body+="sch_${TCP_QDISC}"$'\n'
  if [[ -n $body ]]; then
    write_file "$MODULES_LOAD_NET" 644 <<EOF || true
# Managed by server-init
${body}
EOF
  elif [[ -f $MODULES_LOAD_NET ]]; then
    backup_file "$MODULES_LOAD_NET"
    rm -f "$MODULES_LOAD_NET"
    info "内核已内建或不支持对应模块, 已移除 ${MODULES_LOAD_NET}"
  fi

  # min <= default <= max。默认接收 128K、发送 16K, 只把上限抬到 TCP_WINDOW_BYTES。
  # 不改 rmem_default/wmem_default: 那是所有 socket (含 UDP) 的初始值, 抬高会白占内存。
  # 不改 tcp_mem: 那是全部 TCP 连接共享的页数上限, 内核已按内存算好。
  local max=$TCP_WINDOW_BYTES rdef=131072 wdef=16384
  (( rdef > max )) && rdef=$max
  (( wdef > max )) && wdef=$max
  local lowat=16384
  (( lowat > max / 2 )) && lowat=$(( max / 2 ))

  local lines="" key
  # ipv4 命名空间里的 tcp_* 同时作用于 IPv6
  if (( qdisc_ok )) && net_sysctl_has net.core.default_qdisc; then
    lines+="net.core.default_qdisc = ${TCP_QDISC}"$'\n'
  fi
  if (( cc_ok )) && net_sysctl_has net.ipv4.tcp_congestion_control; then
    lines+="net.ipv4.tcp_congestion_control = ${TCP_CONGESTION}"$'\n'
  fi
  # 窗口 >64K 依赖 window scaling; moderate_rcvbuf 关掉的话接收缓冲不会自动涨
  for key in net.ipv4.tcp_window_scaling net.ipv4.tcp_moderate_rcvbuf; do
    net_sysctl_has "$key" && lines+="${key} = 1"$'\n'
  done
  net_sysctl_has net.core.rmem_max && lines+="net.core.rmem_max = ${max}"$'\n'
  net_sysctl_has net.core.wmem_max && lines+="net.core.wmem_max = ${max}"$'\n'
  net_sysctl_has net.ipv4.tcp_rmem && lines+="net.ipv4.tcp_rmem = 4096 ${rdef} ${max}"$'\n'
  net_sysctl_has net.ipv4.tcp_wmem && lines+="net.ipv4.tcp_wmem = 4096 ${wdef} ${max}"$'\n'
  # BBR 把窗口放大之后, 这三项避免空闲重置、PMTU 黑洞和本地发送队列堆积
  net_sysctl_has net.ipv4.tcp_mtu_probing && lines+="net.ipv4.tcp_mtu_probing = 1"$'\n'
  net_sysctl_has net.ipv4.tcp_slow_start_after_idle && lines+="net.ipv4.tcp_slow_start_after_idle = 0"$'\n'
  net_sysctl_has net.ipv4.tcp_notsent_lowat && lines+="net.ipv4.tcp_notsent_lowat = ${lowat}"$'\n'

  if [[ -z $lines ]]; then
    warn "没有可写的网络 sysctl, 跳过"
    return 0
  fi
  write_file "$SYSCTL_NET_FILE" 644 <<EOF || true
# Managed by server-init
# ${TCP_CONGESTION} + ${TCP_QDISC}, 单连接 TCP 窗口上限 ${TCP_WINDOW_DESC}
# tcp_rmem/tcp_wmem: min default max (字节)。只提高上限。
# 不写 net.ipv4.tcp_mem (全局页数上限, 内核按内存计算)。
${lines}
EOF
  if ! sysctl -q -p "$SYSCTL_NET_FILE"; then
    warn "部分网络参数未能立即生效, 配置已写入 ${SYSCTL_NET_FILE}"
  fi

  local got
  if (( cc_ok )); then
    got=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [[ $got == "$TCP_CONGESTION" ]]; then
      ok "拥塞控制: ${got} (新连接生效, 已有连接不变)"
    else
      warn "拥塞控制当前是 ${got:-未知}, 未能设为 ${TCP_CONGESTION}"
    fi
  fi
  if (( qdisc_ok )); then
    got=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    if [[ $got == "$TCP_QDISC" ]]; then
      ok "default_qdisc: ${got}"
    else
      warn "default_qdisc 当前是 ${got:-未知}, 未能设为 ${TCP_QDISC}"
    fi
    apply_net_qdisc "$TCP_QDISC"
  fi

  got=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $NF}' || true)
  local gotw
  gotw=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $NF}' || true)
  if [[ $got == "$max" && $gotw == "$max" ]]; then
    ok "TCP 窗口上限: $(bytes_human "$max") (rmem/wmem)"
  else
    warn "TCP 窗口上限当前 rmem=${got:-未知} wmem=${gotw:-未知}, 预期 $(bytes_human "$max")"
  fi
  note "网络: ${TCP_CONGESTION} + ${TCP_QDISC}, TCP 窗口上限 ${TCP_WINDOW_DESC} (新连接生效)"
}

write_shared_bashrc() {
  write_file "$BASHRC_SHARED" 644 <<'EOF' || true
# Managed by server-init. 修改请编辑本文件, 重新执行脚本会覆盖
[[ $- == *i* ]] || return 0

export EDITOR=vim VISUAL=vim

alias ls='ls --color=auto'
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ports='ss -tulpn'
alias dps='docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
alias dlog='docker logs -f --tail 200'
alias dc='docker compose'

# PS1: root 红色 / 普通用户绿色, 上条命令失败时显示退出码
__si_prompt() {
  local ec=$?
  local r='\[\e[1;31m\]' g='\[\e[1;32m\]' b='\[\e[1;34m\]' z='\[\e[0m\]' uc code=''
  if (( EUID == 0 )); then uc=$r; else uc=$g; fi
  (( ec != 0 )) && code="${r}[${ec}]${z} "
  PS1="${code}${uc}\u@\h${z}:${b}\w${z}\\\$ "
}
case ";${PROMPT_COMMAND:-};" in
  *";__si_prompt;"*) ;;
  *) PROMPT_COMMAND="__si_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
EOF
}

write_shared_vimrc() {
  write_file "$VIMRC_SHARED" 644 <<'EOF' || true
" Managed by server-init. 修改请编辑本文件, 重新执行脚本会覆盖
set nocompatible
syntax on
filetype plugin indent on
set encoding=utf-8
set fileencodings=ucs-bom,utf-8,gb18030,latin1
set number ruler showcmd laststatus=2 wildmenu
set hlsearch incsearch ignorecase smartcase
set tabstop=4 shiftwidth=4 softtabstop=4 expandtab autoindent
set backspace=indent,eol,start
set scrolloff=5
if exists('+pastetoggle')
  set pastetoggle=<F2>
endif

" 鼠标: vim 接管点击/滚轮; 按住 Shift (iTerm2 为 Option) 拖动仍是终端原生选择复制
if has('mouse')
  set mouse=a
  if has('mouse_sgr')
    set ttymouse=sgr
  endif
endif

augroup server_init
  autocmd!
  " 打开文件时回到上次光标位置
  autocmd BufReadPost * if line("'\"") >= 1 && line("'\"") <= line("$") && &ft !~# 'commit'
        \ | exe "normal! g`\"" | endif
  " OSC52: y 复制的内容通过终端转义序列发到本地剪贴板 (SSH / tmux 均可)
  if exists('##TextYankPost') && exists('*echoraw')
    autocmd TextYankPost * call s:Osc52Yank()
  endif
augroup END

function! s:Osc52Yank() abort
  if v:event.operator !=# 'y' || (v:event.regname !=# '' && v:event.regname !=# '"')
    return
  endif
  let l:text = join(v:event.regcontents, "\n")
  if v:event.regtype ==# 'V'
    let l:text .= "\n"
  endif
  if len(l:text) > 100000
    return
  endif
  let l:b64 = substitute(system('base64 | tr -d "\n"', l:text), '\n', '', 'g')
  if v:shell_error
    return
  endif
  call echoraw("\e]52;c;" . l:b64 . "\x07")
endfunction
EOF
}

# 在文件末尾追加带标记的块 (幂等): append_block FILE OWNER COMMENT_PREFIX CONTENT
append_block() {
  local f=$1 owner=$2 c=$3 content=$4
  if [[ -f $f ]] && grep -qF "${c} ${MARK_BEGIN}" "$f"; then return 0; fi
  [[ -f $f ]] && backup_file "$f"
  printf '\n%s %s\n%s\n%s %s\n' "$c" "$MARK_BEGIN" "$content" "$c" "$MARK_END" >>"$f"
  if [[ -n $owner ]]; then chown "$owner:$(id -gn "$owner")" "$f"; fi
  return 0
}

bashrc_hook() { echo "[ -r ${BASHRC_SHARED} ] && . ${BASHRC_SHARED}"; }
vimrc_hook()  { echo "if filereadable('${VIMRC_SHARED}') | exe 'source ${VIMRC_SHARED}' | endif"; }

apply_env_to_user() {
  local u=$1 home
  home=$(user_home "$u")
  [[ -n $home && -d $home ]] || { warn "用户 ${u} 没有家目录, 跳过"; return 0; }
  # 放在 ~/.bashrc 末尾, 才能覆盖发行版默认 .bashrc 里的 PS1/alias
  append_block "${home}/.bashrc" "$u" "#" "$(bashrc_hook)"
  if [[ $SHELL_ENV_SCOPE == users ]]; then
    append_block "${home}/.vimrc" "$u" '"' "$(vimrc_hook)"
  fi
  ok "环境优化: ${u}"
}

do_shell_env() {
  step "Shell 环境优化"
  write_shared_bashrc
  write_shared_vimrc

  local u
  if [[ $SHELL_ENV_SCOPE == global ]]; then
    # 全局: root + 所有普通登录用户 + /etc/skel (以后新建的用户)
    apply_env_to_user root
    while IFS=: read -r u _ uid _ _ _ shell; do
      (( uid >= 1000 && uid < 60000 )) || continue
      [[ $shell =~ (nologin|false)$ ]] && continue
      apply_env_to_user "$u"
    done < <(getent passwd)
    append_block /etc/skel/.bashrc "" "#" "$(bashrc_hook)"
    # Debian 的 defaults.vim 在 vimrc.local 之后加载, 会覆盖我们的设置, 所以跳过它
    write_file /etc/vim/vimrc.local 644 <<EOF || true
" Managed by server-init
let g:skip_defaults_vim = 1
$(vimrc_hook)
EOF
    ok "vim 全局配置: /etc/vim/vimrc.local"
  else
    for u in $SHELL_ENV_USERS; do
      id "$u" >/dev/null 2>&1 || { warn "用户 ${u} 不存在, 跳过"; continue; }
      apply_env_to_user "$u"
    done
  fi
  note "环境优化: 重新登录或执行 'source ~/.bashrc' 生效"
}

# -----------------------------------------------------------------------------
# SSH 锁定: 等用户确认新端口 + 公钥登录正常后, 禁 root / 禁密码 / 关旧端口
# -----------------------------------------------------------------------------
# 锁定失败时恢复到锁定前的阶段 (transition 或 moving), 新旧端口都监听
lockdown_rollback() {
  local stage=$1
  write_sshd_dropin "$stage"
  restore_foreign_ports
  restart_sshd || err "恢复 ${stage} 配置后 sshd 重启失败, 请勿断开当前会话, 检查: journalctl -u ssh"
}

# 删除 UFW 中某个 SSH 端口的放行规则 (任意来源 + 白名单来源两种写法)
ufw_delete_ssh_port() {
  local p=$1 ip
  ufw --force delete allow "${p}/tcp" >/dev/null 2>&1 || true
  for ip in ${SSH_ALLOW_IPS:-} $(state_get SSH_ALLOW_IPS); do
    ufw --force delete allow proto tcp from "$ip" to any port "$p" >/dev/null 2>&1 || true
  done
}

# 注意: 本函数在 `if ssh_lockdown` / `ssh_lockdown && ...` 中调用, bash 会关闭函数内的
# set -e, 每一步都必须显式检查。
# 顺序: 改 sshd -> 校验实际生效配置 -> 重启并确认监听 -> 最后才关防火墙旧端口。
# 前面任何一步失败, 旧端口在 sshd 和 UFW 上都还开着, 不会把人锁在外面
ssh_lockdown() {
  step "SSH 锁定"
  local nkeys p old prev
  nkeys=$(count_valid_keys "$NEW_USER")
  if (( nkeys == 0 )); then
    warn "${NEW_USER} 没有有效公钥, 拒绝锁定"
    return 1
  fi
  prev=$(sshd_dropin_stage)
  [[ $prev == moving ]] || prev=transition

  disable_foreign_ports
  write_sshd_dropin locked
  if ! "$(sshd_bin)" -t || ! verify_sshd_effective locked; then
    write_sshd_dropin "$prev"
    restore_foreign_ports
    die "锁定配置校验失败, 已恢复 ${prev} 配置 (sshd 未重启, 旧端口仍可用)"
  fi

  if ! restart_sshd || ! wait_port_listen "$SSH_PORT"; then
    lockdown_rollback "$prev"
    die "锁定后 sshd 未正常监听 ${SSH_PORT}, 已恢复 ${prev} 配置。请勿断开当前会话, 检查: journalctl -u ssh"
  fi

  old=$(old_ssh_ports)
  for p in $old; do
    if port_in_use "$p"; then
      warn "旧端口 ${p} 仍在监听 (ssh.socket 覆盖配置或其他程序占用?), 请检查: ss -tlnp 'sport = :${p}'"
    fi
  done

  # sshd 已确认只在新端口工作, 此时再关 UFW 旧端口
  if [[ ${ENABLE_UFW:-no} == yes ]] && command -v ufw >/dev/null; then
    for p in $old; do ufw_delete_ssh_port "$p"; done
    if [[ -n $old ]]; then ok "UFW 已关闭旧 SSH 端口: ${old}"; fi
  fi

  if [[ -f $F2B_JAIL ]]; then
    if sed -i -E "s/^port[[:space:]]*=.*/port    = ${SSH_PORT}/" "$F2B_JAIL" \
      && { systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban; }; then
      ok "fail2ban 已更新为只监控端口 ${SSH_PORT}"
    else
      warn "fail2ban 端口更新失败, 请检查 ${F2B_JAIL} 和 journalctl -u fail2ban"
    fi
  fi

  CUR_SSH_PORTS=("$SSH_PORT")
  SSH_LOCKED=yes
  save_state
  ok "SSH 已锁定: 仅 ${SSH_PORT} 端口, 仅公钥, 禁止 root"
}

# 未锁定时的状态说明 (moving 阶段认证已锁定, 只是旧端口还开着)
unlocked_desc() {
  if [[ $(sshd_dropin_stage) == moving ]]; then
    echo "新旧端口均可用, 认证已是仅公钥"
  else
    echo "新旧端口均可用, 密码/root 登录未禁用"
  fi
}

confirm_and_lockdown() {
  local ip_hint target
  ip_hint=$(server_ips | sed -n 1p)
  target="ssh -p ${SSH_PORT} ${NEW_USER}@${ip_hint:-<服务器IP>}"

  if [[ ${SSH_LOCKED:-no} == yes ]]; then
    note "SSH: 已是锁定状态, 端口 ${SSH_PORT}"
    return 0
  fi
  if (( $(count_valid_keys "$NEW_USER") == 0 )); then
    note "SSH: ${NEW_USER} 没有有效公钥, 未锁定 ($(unlocked_desc))"
    note "     添加公钥后执行: sudo bash init.sh --ssh-lockdown"
    return 0
  fi

  if (( ! INTERACTIVE )); then
    if is_yes SSH_LOCKDOWN; then
      ssh_lockdown && note "SSH: 已锁定 (${target})" && return 0
    fi
    note "SSH: 未锁定 ($(unlocked_desc))"
    note "     验证 '${target}' 后执行: sudo bash init.sh --ssh-lockdown"
    return 0
  fi

  step "请验证新 SSH 登录"
  cat >/dev/tty <<EOT

  ${C_BLD}不要关闭当前会话!${C_RST} 在本地另开一个终端执行:

      ${C_GRN}${target}${C_RST}
      ${C_GRN}sudo -v && echo SUDO_OK${C_RST}

  公网 IP 与上面不同时请自行替换 (云服务器还要在安全组放行 ${SSH_PORT}/tcp)。
  当前会话是旧配置建立的, 新的保活参数对它无效; 如担心断开,
  可在本地 ~/.ssh/config 加 ServerAliveInterval 30, 或在 tmux 里运行本脚本。

EOT
  local ans
  while true; do
    ask ans "登录和 sudo 都正常? 输入 yes 执行锁定, no 跳过 (稍后可 --ssh-lockdown)" ""
    case ${ans,,} in
      yes)
        if ssh_lockdown; then
          note "SSH: 已锁定, 登录命令: ${target}"
        else
          note "SSH: 锁定失败 ($(unlocked_desc))"
        fi
        return 0 ;;
      no)
        note "SSH: 未锁定 ($(unlocked_desc))"
        note "     确认后执行: sudo bash init.sh --ssh-lockdown"
        return 0 ;;
      *) tty_print "  请输入 yes 或 no"$'\n' ;;
    esac
  done
}

run_lockdown_only() {
  [[ -r $STATE_FILE ]] || die "找不到 ${STATE_FILE}, 请先完整执行一次脚本"
  local SSH_LOCKED=""
  local saved_ports=""
  local line k v
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]}
    eval "v=${BASH_REMATCH[2]}"   # 值由 save_state 用 %q 写入, 可安全还原
    case $k in
      CUR_SSH_PORTS) saved_ports=$v ;;
      NEW_USER|SSH_PORT|SSH_ALLOW_IPS|SSH_CLIENT_ALIVE_INTERVAL|SSH_CLIENT_ALIVE_COUNT_MAX|ENABLE_UFW|ENABLE_FAIL2BAN|SSH_LOCKED)
        printf -v "$k" '%s' "$v" ;;
      *) warn "状态文件中的未知项 ${k}, 已忽略" ;;
    esac
  done <"$STATE_FILE"
  read -ra CUR_SSH_PORTS <<<"$saved_ports"
  [[ -n ${NEW_USER:-} && -n ${SSH_PORT:-} ]] || die "状态文件不完整"
  # 旧版本的状态文件可能没有这些项
  : "${SSH_CLIENT_ALIVE_INTERVAL:=60}" "${SSH_CLIENT_ALIVE_COUNT_MAX:=10}"
  # 明确传了 --ssh-lockdown: 非交互模式下直接执行, 不再要求 SSH_LOCKDOWN=yes
  # shellcheck disable=SC2034  # 由 confirm_and_lockdown 里的 is_yes SSH_LOCKDOWN 间接读取
  (( INTERACTIVE )) || SSH_LOCKDOWN=yes

  confirm_and_lockdown
  for line in "${SUMMARY_LINES[@]}"; do info "$line"; done
  # 追加到上次完整执行的摘要, 让 summary.txt 反映最新的 SSH 状态
  if [[ -f ${STATE_DIR}/summary.txt ]]; then
    {
      echo "--ssh-lockdown @ $(date '+%F %T')"
      for line in "${SUMMARY_LINES[@]}"; do echo "  - ${line}"; done
    } >>"${STATE_DIR}/summary.txt"
  fi
  if [[ $SSH_LOCKED != yes ]] && (( ! INTERACTIVE )); then
    die "SSH 未锁定"
  fi
}

# -----------------------------------------------------------------------------
# 收尾
# -----------------------------------------------------------------------------
# 是否需要重启。/run/reboot-required 是 Ubuntu (update-notifier) 的约定, Debian 默认没有,
# 所以再比较运行中的内核和已安装的最新内核
reboot_needed() {
  [[ -f /run/reboot-required ]] && return 0
  # 容器里的内核属于宿主机, 不归本机管
  [[ $(systemd-detect-virt -c 2>/dev/null || true) =~ ^(none)?$ ]] || return 1
  local ksta newest
  if command -v needrestart >/dev/null 2>&1; then
    # KSTA: 0 未知, 1 无需重启, 2/3 有新内核待生效
    ksta=$(needrestart -b 2>/dev/null | awk -F': ' '$1=="NEEDRESTART-KSTA"{print $2}' || true)
    [[ $ksta =~ ^[0-9]+$ ]] && { (( ksta >= 2 )); return; }
  fi
  newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
    | sed 's/^vmlinuz-//' | sort -V | tail -n 1 || true)
  [[ -n $newest && $newest != "$(uname -r)" ]]
}

print_summary() {
  step "完成"
  reboot_needed && REBOOT_REQUIRED=1
  (( REBOOT_REQUIRED )) && note "系统需要重启 (内核或核心库已更新)"
  local line
  {
    echo "server-init v${SCRIPT_VERSION} @ $(date '+%F %T')"
    for line in "${SUMMARY_LINES[@]}"; do echo "  - ${line}"; done
    echo "  - 日志: ${LOG_FILE}"
  } | tee "${STATE_DIR}/summary.txt"
  chmod 600 "${STATE_DIR}/summary.txt"
}

maybe_reboot() {
  (( REBOOT_REQUIRED )) || return 0
  local go
  if (( INTERACTIVE )); then
    ask_yn go "是否立即重启" n
  else
    is_yes AUTO_REBOOT && go=yes || go=no
  fi
  if [[ $go == yes ]]; then
    info "5 秒后重启..."
    sleep 5
    systemctl reboot
  fi
}

usage() {
  cat <<EOF
server-init v${SCRIPT_VERSION} - Debian 12/13, Ubuntu 22.04/24.04/26.04 初始化

用法:
  sudo bash init.sh [选项]
  curl -fsSL <raw-url>/init.sh | sudo bash -s -- [选项]

选项:
  -c, --config FILE       本地配置文件 (KEY=VALUE, 参考 init.env.example)
  -u, --config-url URL    远程配置文件 (仅 https)
  -n, --non-interactive   非交互模式 (缺失参数用默认值或报错)
      --ssh-lockdown      仅执行 SSH 锁定 (之前跳过时补做)
  -h, --help              显示帮助

配置优先级: 环境变量 > --config > --config-url > 交互 > 默认值
EOF
}

# shellcheck disable=SC2034  # NONINTERACTIVE 由 is_yes 间接读取
parse_args() {
  while (( $# )); do
    case $1 in
      -c|--config)          CLI_CONFIG=${2:?--config 需要参数}; shift 2 ;;
      -u|--config-url)      CLI_CONFIG_URL=${2:?--config-url 需要参数}; shift 2 ;;
      -n|--non-interactive) NONINTERACTIVE=yes; shift ;;
      --ssh-lockdown)       MODE=lockdown; shift ;;
      -h|--help)            usage; exit 0 ;;
      *) usage >&2; die "未知参数: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_root
  setup_logging
  load_local_config
  # 第一次 apt (ensure_base_tools) 之前先等 cloud-init, 避免抢 apt 锁
  [[ $MODE == lockdown ]] || wait_for_boot_jobs
  ensure_base_tools
  load_remote_config
  # 在远程配置之后检查系统, 远程配置里的 FORCE 才能生效
  check_os
  decide_interactive
  detect_ssh_ports

  if [[ $MODE == lockdown ]]; then
    run_lockdown_only
    return
  fi

  if (( INTERACTIVE )) && [[ -z ${TMUX:-} && ${TERM:-} != screen* && ${TERM:-} != tmux* ]]; then
    warn "建议在 tmux/screen 中运行, 防止网络抖动导致脚本中断"
  fi

  select_modules
  select_net
  collect_baseline
  collect_packages
  collect_user
  collect_ssh
  collect_ssh_whitelist
  collect_ufw
  collect_fail2ban
  collect_docker
  collect_swap
  collect_net
  collect_shell_env
  show_plan

  [[ $ENABLE_UPDATE == yes ]]    && do_update
  [[ $ENABLE_BASELINE == yes ]]  && do_baseline
  [[ $ENABLE_PACKAGES == yes ]]  && do_packages
  [[ $ENABLE_USER == yes ]]      && do_user
  [[ $ENABLE_UFW == yes ]]       && do_ufw
  [[ $ENABLE_SSH == yes ]]       && do_ssh
  [[ $ENABLE_FAIL2BAN == yes ]]  && do_fail2ban
  [[ $ENABLE_DOCKER == yes ]]    && do_docker
  [[ $ENABLE_SWAP == yes ]]      && do_swap
  [[ $ENABLE_NET == yes ]]       && do_net
  [[ $ENABLE_SHELL_ENV == yes ]] && do_shell_env
  [[ $ENABLE_SSH == yes ]]       && confirm_and_lockdown

  print_summary
  maybe_reboot
}

main "$@"
