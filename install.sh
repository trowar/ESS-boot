#!/bin/bash

# 即使用户使用 sh install.sh，也自动切换到 Bash 执行。
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi

set -e

BASE_DIR=/srv/ess-boot
TARGET_SCRIPT=/srv/ess-boot/boot.sh
STARTUP_SCRIPT=/srv/ess-boot/run.sh
LOG_FILE=/srv/ess-boot/boot.log
RSYNC_USER=root
RSYNC_MODULE=ess_sync
RSYNC_PASSWORD_FILE=/srv/ess-boot/client.pwd
RSYNC_SECRETS_FILE=/srv/ess-boot/server.secret
RSYNC_CONFIG=/etc/rsyncd.conf

detect_system() {
  if command -v apt-get >/dev/null 2>&1; then
    SYSTEM=ubuntu_debian
    REQUIRED_PACKAGES='rsync iproute2 procps util-linux gawk coreutils grep sed'
  elif command -v dnf >/dev/null 2>&1; then
    SYSTEM=centos_rocky_alma
    REQUIRED_PACKAGES='rsync iproute procps-ng util-linux gawk coreutils grep sed policycoreutils'
  elif command -v yum >/dev/null 2>&1; then
    SYSTEM=centos
    REQUIRED_PACKAGES='rsync iproute procps-ng util-linux gawk coreutils grep sed policycoreutils'
  else
    SYSTEM=unknown
    REQUIRED_PACKAGES=''
  fi
}

get_host_ips() {
  ip -o -4 addr show scope global 2>/dev/null |
    awk '$2 !~ /^(docker[0-9]*|br-|veth|cni|cali|flannel|virbr|lxcbr|podman|zt|tailscale|tun|tap)/ {
      split($4, address, "/"); print address[1]
    }'
}

# 隐藏软件包管理器的正常下载明细；执行失败时再显示完整输出。
run_package_command() {
  local description="$1"
  local output_file

  shift
  output_file="$(mktemp /tmp/ess-boot-package.XXXXXX)"
  if "$@" >"$output_file" 2>&1; then
    rm -f "$output_file"
    return 0
  fi

  echo "错误：${description}失败，详细信息如下：" >&2
  cat "$output_file" >&2
  rm -f "$output_file"
  exit 1
}

detect_system

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请使用 root 用户运行：sudo ./install.sh" >&2
  exit 1
fi

printf '[1/7] '
case "$SYSTEM" in
  ubuntu_debian)
    MISSING_PACKAGES=()
    for package in $REQUIRED_PACKAGES; do
      dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || MISSING_PACKAGES+=("$package")
    done
    if [ "${#MISSING_PACKAGES[@]}" -eq 0 ]; then
      echo "所需软件包均已安装，跳过 apt 更新和安装。"
    else
      echo "需要安装：${MISSING_PACKAGES[*]}"
      run_package_command "更新 apt 软件源" apt-get update -qq
      run_package_command "安装所需软件包" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING_PACKAGES[@]}"
    fi
    ;;
  centos_rocky_alma)
    MISSING_PACKAGES=()
    for package in $REQUIRED_PACKAGES; do
      rpm -q "$package" >/dev/null 2>&1 || MISSING_PACKAGES+=("$package")
    done
    if [ "${#MISSING_PACKAGES[@]}" -eq 0 ]; then
      echo "所需软件包均已安装，跳过 dnf 安装。"
    else
      echo "需要安装：${MISSING_PACKAGES[*]}"
      run_package_command "安装所需软件包" dnf install -y -q "${MISSING_PACKAGES[@]}"
    fi
    ;;
  centos)
    MISSING_PACKAGES=()
    for package in $REQUIRED_PACKAGES; do
      rpm -q "$package" >/dev/null 2>&1 || MISSING_PACKAGES+=("$package")
    done
    if [ "${#MISSING_PACKAGES[@]}" -eq 0 ]; then
      echo "所需软件包均已安装，跳过 yum 安装。"
    else
      echo "需要安装：${MISSING_PACKAGES[*]}"
      run_package_command "安装所需软件包" yum install -y -q "${MISSING_PACKAGES[@]}"
    fi
    ;;
  *)
    echo "错误：无法识别包管理器。" >&2
    exit 1
    ;;
esac

echo "[2/7] 配置 rsync 令牌和只读模块"
install -d -m 0700 "$BASE_DIR"
if [ ! -s "$RSYNC_PASSWORD_FILE" ]; then
  RSYNC_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s\n' "$RSYNC_PASSWORD" > "$RSYNC_PASSWORD_FILE"
else
  RSYNC_PASSWORD="$(tr -d '\r\n' < "$RSYNC_PASSWORD_FILE")"
fi
chmod 0600 "$RSYNC_PASSWORD_FILE"
printf '%s:%s\n' "$RSYNC_USER" "$RSYNC_PASSWORD" > "$RSYNC_SECRETS_FILE"
chmod 0600 "$RSYNC_SECRETS_FILE"
unset RSYNC_PASSWORD

if grep -q '^# BEGIN ESS-boot rsync$' "$RSYNC_CONFIG" 2>/dev/null && \
   grep -q "^\[${RSYNC_MODULE}\]$" "$RSYNC_CONFIG" && \
   grep -q "^[[:space:]]*auth users[[:space:]]*=[[:space:]]*${RSYNC_USER}[[:space:]]*$" "$RSYNC_CONFIG"; then
  echo "      rsync 模块已经配置，跳过重复配置。"
else
  if grep -q "^\[${RSYNC_MODULE}\]$" "$RSYNC_CONFIG" 2>/dev/null && \
     ! grep -q '^# BEGIN ESS-boot rsync$' "$RSYNC_CONFIG"; then
    echo "      错误：rsync 模块 ${RSYNC_MODULE} 已存在且不属于 ESS-boot。" >&2
    exit 1
  fi
  if [ -f "$RSYNC_CONFIG" ]; then
    cp -a "$RSYNC_CONFIG" "${RSYNC_CONFIG}.backup.$(date '+%Y%m%d%H%M%S')"
  else
    : > "$RSYNC_CONFIG"
  fi
  sed -i '/^# BEGIN ESS-boot rsync$/,/^# END ESS-boot rsync$/d' "$RSYNC_CONFIG"
  cat >> "$RSYNC_CONFIG" <<EOF

# BEGIN ESS-boot rsync
[${RSYNC_MODULE}]
    path = /
    comment = Read-only root filesystem
    read only = yes
    list = no
    uid = root
    gid = root
    auth users = ${RSYNC_USER}
    secrets file = ${RSYNC_SECRETS_FILE}
    exclude = /srv/ess-boot/client.pwd /srv/ess-boot/server.secret /srv/ess-boot/boot.log /srv/ess-boot/boot.sh
    strict modes = yes
# END ESS-boot rsync
EOF
  echo "      已配置 rsync 只读模块。"
fi

if [ ! -f "$STARTUP_SCRIPT" ]; then
  cat > "$STARTUP_SCRIPT" <<'STARTUP_SCRIPT_CONTENT'
#!/bin/bash
set -e

echo "[$(date '+%F %T')] 开始执行脚本"

# ==================== 执行内容 ====================
rsync -avz --timeout=60 --contimeout=15 --password-file=/srv/ess-boot/client.pwd root@${RSYNC_IP}::ess_sync/srv/ess-boot/rsync-test.sh /tmp/rsync-test.sh
chmod 0755 /tmp/rsync-test.sh
/bin/bash /tmp/rsync-test.sh
# ==================== 执行内容结束 ====================

echo "[$(date '+%F %T')] 脚本执行成功"
STARTUP_SCRIPT_CONTENT
fi
chmod 0755 "$STARTUP_SCRIPT"

if systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -qx 'rsync.service'; then
  [ ! -f /etc/default/rsync ] || sed -i 's/^[#[:space:]]*RSYNC_ENABLE=.*/RSYNC_ENABLE=true/' /etc/default/rsync
  RSYNC_SERVICE=rsync.service
elif systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -qx 'rsyncd.service'; then
  RSYNC_SERVICE=rsyncd.service
else
  echo "      错误：找不到 rsync 或 rsyncd 服务单元。" >&2
  exit 1
fi

if systemctl is-enabled --quiet "$RSYNC_SERVICE" && systemctl is-active --quiet "$RSYNC_SERVICE"; then
  echo "      $RSYNC_SERVICE 已启用并运行，跳过重复配置。"
else
  if systemctl enable --now "$RSYNC_SERVICE" >/dev/null 2>&1; then
    echo "      已启用并启动 $RSYNC_SERVICE。"
  else
    echo "      错误：无法启用或启动 $RSYNC_SERVICE。" >&2
    exit 1
  fi
fi

# CentOS/RHEL 开启 SELinux 时，允许 rsync 只读导出配置的目录。
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
  if command -v getsebool >/dev/null 2>&1 && getsebool rsync_export_all_ro >/dev/null 2>&1; then
    if getsebool rsync_export_all_ro | grep -q -- '--> on'; then
      echo "      SELinux rsync 只读权限已经开启，跳过重复配置。"
    else
      setsebool -P rsync_export_all_ro 1
      echo "      已配置 SELinux：允许 rsync 只读导出。"
    fi
  else
    echo "      错误：SELinux 已启用，但无法配置 rsync_export_all_ro。" >&2
    exit 1
  fi
fi

# 只在 firewalld/ufw 已经启用时开放 rsync 端口，不主动启用防火墙。
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  if firewall-cmd --permanent --query-port=873/tcp >/dev/null 2>&1; then
    echo "      firewalld 已开放 TCP 873，跳过重复配置。"
  else
    firewall-cmd --permanent --add-port=873/tcp >/dev/null
    firewall-cmd --reload >/dev/null
    echo "      已在 firewalld 开放 TCP 873。"
  fi
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  if ufw status | grep -Eq '873/tcp[[:space:]]+ALLOW'; then
    echo "      ufw 已开放 TCP 873，跳过重复配置。"
  else
    ufw allow 873/tcp >/dev/null
    echo "      已在 ufw 开放 TCP 873。"
  fi
fi

echo "[3/7] 生成开机控制脚本"
mkdir -p /srv
mapfile -t ORIGIN_IPS < <(get_host_ips)
[ "${#ORIGIN_IPS[@]}" -gt 0 ] || {
  echo "错误：无法获取原主机真实网卡 IP，请确认网卡已经启动。" >&2
  exit 1
}
printf '#!/bin/bash\n\nif [ -z "${BASH_VERSION:-}" ]; then\n  exec /bin/bash "$0" "$@"\nfi\n\nORIGIN_IPS=(' > "$TARGET_SCRIPT"
for ip_address in "${ORIGIN_IPS[@]}"; do
  printf ' %q' "$ip_address" >> "$TARGET_SCRIPT"
done
printf ' )\nRSYNC_IP=%q\n' "${ORIGIN_IPS[0]}" >> "$TARGET_SCRIPT"
cat >> "$TARGET_SCRIPT" <<'BOOT_SCRIPT'
# -----------------------------------------------------------------------------
# /srv/ess-boot/boot.sh
#
# 本脚本由 install.sh 自动生成，并由 /etc/rc.local 在开机时调用。
# 主要流程：
#   1. 等待真实网卡获得 IP。
#   2. 如果当前机器是原主机，直接退出。
#   3. 如果当前机器是伸缩实例，从原主机同步 run.sh。
#   4. 同步成功后执行 run.sh。
# -----------------------------------------------------------------------------

LOG_FILE=/srv/ess-boot/boot.log
NETWORK_RETRY_COUNT=60
NETWORK_RETRY_INTERVAL=5
RSYNC_RETRY_COUNT=12
RSYNC_RETRY_INTERVAL=10
IGNORE_IP=0

if [ "${1:-}" = "--ignore-ip" ]; then
  IGNORE_IP=1
fi

log() {
  echo "[$(date '+%F %T')] $*"
}

# 检查运行所需的基础命令。
check_required_commands() {
  local required_command

  for required_command in ip awk sort grep seq rsync; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
      log "缺少必需命令：$required_command"
      return 1
    fi
  done
}

# 获取真实网卡的全部 IPv4，排除 Docker、CNI、VPN 等虚拟接口。
get_host_ips() {
  ip -o -4 addr show scope global 2>/dev/null |
    awk '$2 !~ /^(docker[0-9]*|br-|veth|cni|cali|flannel|virbr|lxcbr|podman|zt|tailscale|tun|tap)/ {
      split($4, address, "/"); print address[1]
    }'
}

# 等待网卡启动，并将结果写入 CURRENT_IPS 数组。
wait_for_network() {
  local attempt

  CURRENT_IPS=()
  for attempt in $(seq 1 "$NETWORK_RETRY_COUNT"); do
    mapfile -t CURRENT_IPS < <(get_host_ips)
    if [ "${#CURRENT_IPS[@]}" -gt 0 ]; then
      return 0
    fi

    log "等待网卡启动，${NETWORK_RETRY_INTERVAL} 秒后重试（${attempt}/${NETWORK_RETRY_COUNT}）"
    sleep "$NETWORK_RETRY_INTERVAL"
  done

  return 1
}

# 当前任意真实 IP 与原主机 IP 相同，即判定为原主机。
is_origin_host() {
  local current_ip
  local origin_ip

  for current_ip in "${CURRENT_IPS[@]}"; do
    for origin_ip in "${ORIGIN_IPS[@]}"; do
      if [ "$current_ip" = "$origin_ip" ]; then
        MATCHED_ORIGIN_IP="$current_ip"
        return 0
      fi
    done
  done

  return 1
}

# 从原主机下载真正的开机脚本，下载完成后再原子替换正式文件。
sync_startup_script() {
  local attempt
  local temp_script

  if [ ! -s /srv/ess-boot/client.pwd ]; then
    log "找不到 rsync 令牌：/srv/ess-boot/client.pwd"
    return 1
  fi

  temp_script="/srv/ess-boot/run.sh.tmp.$$"

  for attempt in $(seq 1 "$RSYNC_RETRY_COUNT"); do
    if rsync -az --timeout=60 --contimeout=15 --password-file=/srv/ess-boot/client.pwd root@${RSYNC_IP}::ess_sync/srv/ess-boot/run.sh "$temp_script"; then
      chmod 0755 "$temp_script"
      mv -f "$temp_script" /srv/ess-boot/run.sh
      return 0
    fi

    log "同步失败，${RSYNC_RETRY_INTERVAL} 秒后重试（${attempt}/${RSYNC_RETRY_COUNT}）"
    sleep "$RSYNC_RETRY_INTERVAL"
  done

  rm -f "$temp_script"
  return 1
}

main() {
  check_required_commands || exit 1

  if ! wait_for_network; then
    log "无法获取真实网卡 IP，停止执行"
    exit 1
  fi

  if [ "$IGNORE_IP" -eq 0 ] && is_origin_host; then
    log "检测到原主机，跳过启动任务"
    exit 0
  fi

  if [ "$IGNORE_IP" -eq 1 ]; then
    log "已忽略原主机 IP 判断，继续执行启动任务"
  fi

  log "检测到弹性伸缩实例，开始同步 /srv/ess-boot/run.sh"

  if ! sync_startup_script; then
    log "无法从原主机同步启动脚本，停止执行"
    exit 1
  fi

  log "同步完成，开始执行 /srv/ess-boot/run.sh"
  export RSYNC_IP
  exec /bin/bash /srv/ess-boot/run.sh
}

CURRENT_IPS=()
MATCHED_ORIGIN_IP=""

main "$@"
BOOT_SCRIPT
chmod 0755 "$TARGET_SCRIPT"

echo "[4/7] 已记录原主机网络信息"

echo "[5/7] 配置 rc.local"
if [ -e /etc/rc.d/rc.local ]; then
  RC_LOCAL=/etc/rc.d/rc.local
else
  RC_LOCAL=/etc/rc.local
fi

if [ ! -f "$RC_LOCAL" ]; then
  printf '%s\n' '#!/bin/bash' > "$RC_LOCAL"
fi

if [ ! -e "$LOG_FILE" ]; then
  install -m 0644 /dev/null "$LOG_FILE"
fi

RC_COMMAND='/bin/bash /srv/ess-boot/boot.sh >> /srv/ess-boot/boot.log 2>&1 &'
if grep -Fqx "$RC_COMMAND" "$RC_LOCAL"; then
  echo "      rc.local 已包含开机调用，跳过重复追加。"
else
  cp -a "$RC_LOCAL" "${RC_LOCAL}.backup.$(date '+%Y%m%d%H%M%S')"
  sed -i '/^[[:space:]]*exit[[:space:]]\+0[[:space:]]*$/d' "$RC_LOCAL"
  cat >> "$RC_LOCAL" <<'EOF'

# BEGIN ESS-boot
/bin/bash /srv/ess-boot/boot.sh >> /srv/ess-boot/boot.log 2>&1 &
# END ESS-boot

exit 0
EOF
  echo "      已将开机调用追加到 $RC_LOCAL"
fi
chmod +x "$RC_LOCAL"
[ ! -e /etc/rc.local ] || chmod +x /etc/rc.local

echo "[6/7] 验证 rsync 模块"
VERIFY_FILE="$(mktemp /tmp/run.verify.XXXXXX)"
if ! rsync -az --timeout=30 --contimeout=10 --password-file="$RSYNC_PASSWORD_FILE" "${RSYNC_USER}@127.0.0.1::${RSYNC_MODULE}/srv/$(basename "$STARTUP_SCRIPT")" "$VERIFY_FILE"; then
  rm -f "$VERIFY_FILE"
  echo "      错误：rsync 测试下载失败，安装未完成。" >&2
  exit 1
fi
if ! cmp -s "$STARTUP_SCRIPT" "$VERIFY_FILE"; then
  rm -f "$VERIFY_FILE"
  echo "      错误：rsync 下载内容与源文件不一致，安装未完成。" >&2
  exit 1
fi
rm -f "$VERIFY_FILE"
echo "      rsync 测试通过：已成功下载并确认文件内容一致。"

echo "[7/7] 验证脚本"
command -v rsync >/dev/null
bash -n "$TARGET_SCRIPT"
echo "      安装完成：系统已具备开机调用脚本和使用 rsync 的能力。"
echo
echo "============================================================"
echo "下一步："
echo "  /srv/ess-boot/run.sh 用于设置弹性伸缩实例开机后需要执行的命令。"
echo "  /srv/ess-boot/boot.log，每次启动的日志。"
echo "============================================================"
