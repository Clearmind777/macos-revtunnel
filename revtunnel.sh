#!/usr/bin/env bash
#
# revtunnel.sh —— 反向 SSH 隧道(保活 + 自愈)
#
# 场景:
#   本机(Mac)在 NAT 后面,只能主动连出;机器 A(172.16.134.43)无法反向连回本机。
#   本脚本在 Mac 上建立一条到 A 的反向隧道,让 A 能通过 127.0.0.1:<远端端口> 访问本机的 sshd。
#
# 关键设计(与普通 ssh -R 的差别):
#   ServerAliveInterval=30 / ServerAliveCountMax=3
#       每 30s 发一个 SSH 层心跳。既刷新中间 NAT 的会话映射,又能在 90s 内
#       发现"半开假死"连接并让 ssh 退出(避免默认 2 小时才发现的假死窗口)。
#   ExitOnForwardFailure=yes
#       远端端口被占用导致转发失败时立即退出,而不是"连上了但没转发"地赖着。
#   KeepAlive=true 的 launchd 服务
#       上面的参数负责让死掉的 ssh 尽快退出,launchd 负责立刻把它拉起来。
#       两者必须成对使用,缺一不可。
#
# 用法: revtunnel.sh help
#
set -Eeuo pipefail

# launchd 的 PATH 极简,这里补全,避免找不到 ssh / launchctl
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ---------------------------------------------------------------------------
# 自身路径解析(供 launchd 用绝对路径调用)
# ---------------------------------------------------------------------------
SELF="${BASH_SOURCE[0]}"
while [[ -L "$SELF" ]]; do
  _target="$(readlink "$SELF")"
  [[ "$_target" == /* ]] && SELF="$_target" || SELF="$(dirname "$SELF")/$_target"
done
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$SELF")"

# ---------------------------------------------------------------------------
# 配置(全部可用同名环境变量覆盖)
# ---------------------------------------------------------------------------
RT_HOST="${RT_HOST:-172.16.134.43}"          # 机器 A 的地址
RT_PORT="${RT_PORT:-2233}"                   # 机器 A 的 sshd 端口
RT_USER="${RT_USER:-zjl}"                    # 机器 A 上的登录用户
RT_REMOTE_BIND="${RT_REMOTE_BIND:-127.0.0.1}" # 隧道在 A 上绑定的地址(0.0.0.0 需 A 侧 GatewayPorts)
RT_REMOTE_PORT="${RT_REMOTE_PORT:-12222}"    # 隧道在 A 上监听的端口
RT_LOCAL_HOST="${RT_LOCAL_HOST:-127.0.0.1}"  # 目标地址,由"本机"侧解析连接(默认即本机 sshd)
RT_LOCAL_PORT="${RT_LOCAL_PORT:-26259}"      # 目标端口:Mac 上 sshd 的监听端口(需先用 macos-sshd-extra-port.sh 开放)
RT_IDENTITY="${RT_IDENTITY:-}"               # 私钥路径,留空用 ssh 默认查找
RT_BATCH="${RT_BATCH:-yes}"                  # yes=只允许密钥认证(launchd 必须);no=允许交互输密码
RT_LABEL="${RT_LABEL:-com.jalen.revtunnel}"  # launchd 服务标识

RT_ALIVE_INTERVAL="${RT_ALIVE_INTERVAL:-30}" # 心跳间隔(秒)
RT_ALIVE_COUNT_MAX="${RT_ALIVE_COUNT_MAX:-3}"  # 连续丢失多少个心跳后判定死亡
RT_CONNECT_TIMEOUT="${RT_CONNECT_TIMEOUT:-10}"
RT_THROTTLE="${RT_THROTTLE:-10}"             # launchd 重启最小间隔(秒),防止疯狂重启
RT_LOG_MAX_BYTES="${RT_LOG_MAX_BYTES:-5242880}" # 日志超过 5MB 时滚动一次

RT_LOG="${RT_LOG:-$HOME/Library/Logs/revtunnel.log}"
RT_PLIST="$HOME/Library/LaunchAgents/${RT_LABEL}.plist"
RT_DOMAIN="gui/$(id -u)"
RT_LOCAL_USER="$(id -un)"

# launchd 以什么脚本启动隧道。
# 关键:不能直接用 SELF_PATH。若脚本位于 ~/Documents、~/Desktop、~/Downloads,
# 这些目录受 macOS TCC 保护,而 launchd 启动的 job 没有 UI、无法弹出授权对话框,
# bash 读取脚本时会直接拿到 "Operation not permitted"(EPERM),于是 KeepAlive
# 让它每 ThrottleInterval 秒崩一次、日志刷屏,隧道永远起不来。
# 因此 install 会在非受保护目录生成一个 exec 包装器,由 plist 指向它。
RT_RUN_DIR="${RT_RUN_DIR:-$HOME/.local/libexec/revtunnel}"   # TCC 安全、无需 sudo
RT_WRAPPER="$RT_RUN_DIR/launch.sh"
# 已安装副本。这才是 launchd 真正运行的东西,必须保持与原脚本同名($0 推导)。
RT_INSTALLED="$RT_RUN_DIR/revtunnel.sh"

SSH_ARGS=()

# ---------------------------------------------------------------------------
# 输出helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
info() { printf '%s [INFO] %s\n' "$(_ts)" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '%s [ERR ] %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }
ok()   { printf '  %s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_ERR" "$C_OFF" "$*"; }
note() { printf '  %s•%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

# ---------------------------------------------------------------------------
# 组装 ssh 参数
# ---------------------------------------------------------------------------
build_ssh_args() {
  SSH_ARGS=(
    -p "$RT_PORT"
    -o "ServerAliveInterval=${RT_ALIVE_INTERVAL}"
    -o "ServerAliveCountMax=${RT_ALIVE_COUNT_MAX}"
    -o "TCPKeepAlive=yes"
    -o "ExitOnForwardFailure=yes"
    -o "ConnectTimeout=${RT_CONNECT_TIMEOUT}"
    -o "StrictHostKeyChecking=accept-new"
  )
  [[ -n "$RT_IDENTITY" ]] && SSH_ARGS+=(-i "$RT_IDENTITY")
  if [[ "$RT_BATCH" == "yes" ]]; then
    # launchd 里没人能输密码,必须禁用交互,失败就退出让 launchd 重试
    SSH_ARGS+=(-o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no)
  fi
  return 0
}

# 仅用于在 A 上执行命令(不加 -N / -R)
ssh_remote() { ssh "${SSH_ARGS[@]}" "$RT_USER@$RT_HOST" "$@"; }

# ---------------------------------------------------------------------------
# 公共小工具
# ---------------------------------------------------------------------------
ensure_dirs() {
  mkdir -p "$(dirname "$RT_LOG")" "$(dirname "$RT_PLIST")"
}

rotate_log() {
  [[ "$RT_LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || return 0
  [[ -f "$RT_LOG" ]] || return 0
  local sz
  sz="$(wc -c < "$RT_LOG" 2>/dev/null || echo 0)"
  sz="${sz//[!0-9]/}"
  [[ -n "$sz" ]] || return 0
  if (( sz > RT_LOG_MAX_BYTES )); then
    mv -f "$RT_LOG" "$RT_LOG.1" 2>/dev/null || true
  fi
}

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  printf '%s' "$s"
}

is_installed() { [[ -f "$RT_PLIST" ]]; }
is_loaded()    { launchctl print "$RT_DOMAIN/$RT_LABEL" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# TCC 检测 / 包装器
# ---------------------------------------------------------------------------
# 该路径是否落在 macOS 隐私保护目录里(Documents / Desktop / Downloads 等)。
# 落在里面时:用户从终端手工运行没问题(终端已被授权),但 launchd 启动的
# LaunchAgent 没有 UI 可弹窗,读取会被直接拒绝(EPERM),报
# "Operation not permitted"。
is_tcc_unsafe_path() {
  local p="$1"
  case "$p" in
    "$HOME/Documents"/*|"$HOME/Desktop"/*|"$HOME/Downloads"/*|\
    "$HOME/Movies"/*|"$HOME/Music"/*|"$HOME/Pictures"/*)
      return 0 ;;
  esac
  return 1
}

# 当前进程读得到自己这个脚本文件吗(在 launchd 环境里就是那条 EPERM)
self_readable() {
  [[ -r "$SELF_PATH" ]] && head -c 1 "$SELF_PATH" >/dev/null 2>&1
}

# 生成由 launchd 直接执行的包装器:把环境固定成脚本默认值(这样 status/config
# 在任何 shell 下都与已安装服务一致),再 exec 原始脚本。
# 同时写入脚本副本,作为源脚本被移动/删除时的兜底。
# 生成由 launchd 直接执行的包装器。
#
# ★ 这里有一条铁律:包装器和它启动的一切,**绝不能读取 ~/Documents 下的任何文件**。
#   被拦的是"读取受保护目录里的文件"这个行为,与谁去读无关:
#   经实测,即使包装器位于安全目录,只要它 exec 的目标仍在 ~/Documents,
#   依然会被 kTCCServiceSystemPolicyDocumentsFolder 拒绝(exit 126)。
#   而 /bin/bash 是 platform binary,tccd 明确 "Platform binary prompting is
#   'Deny'",不会给用户弹窗授权的机会 —— 所以只能绕开,不能授权。
#   → 包装器只执行安装到安全目录的副本,不做任何指向源目录的回退。
install_wrapper() {
  mkdir -p "$RT_RUN_DIR"
  cp -f "$SELF_PATH" "$RT_INSTALLED"
  chmod 755 "$RT_INSTALLED"

  cat > "$RT_WRAPPER" <<EOF
#!/bin/bash
# 由 revtunnel.sh install 生成 —— 不要手改。
#
# 为什么需要它(踩过的坑):
#   launchd 启动的 bash 读取 ~/Documents 下的任何文件都会被 TCC 拒绝:
#     tccd: service=kTCCServiceSystemPolicyDocumentsFolder + "Platform binary
#           prompting is 'Deny' because: is Platform Binary"  →  exit 126
#   因此这里只执行安装到安全目录的副本,绝不触碰源目录。
#
# 改完配置/代码后必须重新执行 '../revtunnel.sh install' 才会生效。
set -Eeuo pipefail

# 固定已安装时的配置(改配置请重新 install)
export RT_HOST=$(printf '%q' "$RT_HOST")
export RT_PORT=$(printf '%q' "$RT_PORT")
export RT_USER=$(printf '%q' "$RT_USER")
export RT_REMOTE_BIND=$(printf '%q' "$RT_REMOTE_BIND")
export RT_REMOTE_PORT=$(printf '%q' "$RT_REMOTE_PORT")
export RT_LOCAL_HOST=$(printf '%q' "$RT_LOCAL_HOST")
export RT_LOCAL_PORT=$(printf '%q' "$RT_LOCAL_PORT")
export RT_IDENTITY=$(printf '%q' "$RT_IDENTITY")
export RT_ALIVE_INTERVAL=$(printf '%q' "$RT_ALIVE_INTERVAL")
export RT_ALIVE_COUNT_MAX=$(printf '%q' "$RT_ALIVE_COUNT_MAX")
export RT_CONNECT_TIMEOUT=$(printf '%q' "$RT_CONNECT_TIMEOUT")
export RT_THROTTLE=$(printf '%q' "$RT_THROTTLE")
export RT_LOG=$(printf '%q' "$RT_LOG")
export RT_LOG_MAX_BYTES=$(printf '%q' "$RT_LOG_MAX_BYTES")
export RT_LABEL=$(printf '%q' "$RT_LABEL")

INSTALLED=$(printf '%q' "$RT_INSTALLED")
if [ ! -r "\$INSTALLED" ]; then
  echo "revtunnel: 已安装副本不存在: \$INSTALLED" >&2
  echo "revtunnel: 请在源目录重新执行 revtunnel.sh install" >&2
  exit 1
fi

exec /bin/bash "\$INSTALLED" "\$@"
EOF
  chmod 755 "$RT_WRAPPER"
}

remove_wrapper() {
  rm -f "$RT_WRAPPER" "$RT_INSTALLED" 2>/dev/null || true
  rmdir "$RT_RUN_DIR" 2>/dev/null || true
}

# 隧道为什么起不来?把 "Operation not permitted" / exit 126 这类 TCC 症状翻译成人话。
explain_launch_failure() {
  local dump="$1"
  local last_exit
  last_exit="$(sed -n 's/^[[:space:]]*last exit code = //p' <<<"$dump" | head -n1)"
  if grep -q "Operation not permitted" "$RT_LOG" 2>/dev/null || [[ "$last_exit" == "126" ]]; then
    bad "运行时仍在读取受 TCC 保护的路径(exit=${last_exit:-?}) —— 这不是权限位问题"
    note "macOS 会拒绝任何进程读取 ~/Documents、~/Desktop、~/Downloads 下的文件;"
    note "又因为 /bin/bash 是 platform binary,系统不会弹窗让你授权(直接 Deny)。"
    note "本脚本的应对:运行时不读源目录,只执行安装副本 —— 若仍报此错,说明安装副本过期:"
    note "  重新执行 '$0 install'(会刷新 $RT_INSTALLED)"
    return 0
  fi
  [[ -n "$last_exit" ]] && note "launchd 记录的最后退出码: $last_exit"
  return 0
}

# ---------------------------------------------------------------------------
# run —— 前台运行隧道(launchd 也是调用这个子命令)
# ---------------------------------------------------------------------------
cmd_run() {
  local interactive=0
  while (( $# )); do
    case "$1" in
      -i|--interactive) interactive=1 ;;
      --launchd) : ;;  # 兼容占位,语义与默认一致
      *) die "run: 未知参数 $1" ;;
    esac
    shift
  done
  if (( interactive )); then RT_BATCH="no"; fi

  # launchd 环境下先自检:确认当前进程真的读得到自己的脚本。
  # 读不到 = TCC 拦了(见 is_tcc_unsafe_path 的说明),继续下去只会白崩。
  if ! self_readable; then
    err "无法读取脚本自身: $SELF_PATH"
    err "这通常是 macOS TCC 隐私保护拦截(不是权限位问题)。"
    err "修复:在终端执行 '$0 install',它会把包装器装到 TCC 安全目录 $RT_RUN_DIR"
    exit 1
  fi

  need_cmd ssh
  ensure_dirs
  rotate_log
  build_ssh_args

  info "目标 A      : ${RT_USER}@${RT_HOST}:${RT_PORT}"
  info "反向映射    : A:${RT_REMOTE_BIND}:${RT_REMOTE_PORT}  ->  本机 ${RT_LOCAL_HOST}:${RT_LOCAL_PORT}"
  info "心跳        : ${RT_ALIVE_INTERVAL}s x ${RT_ALIVE_COUNT_MAX} (约 $(( RT_ALIVE_INTERVAL * RT_ALIVE_COUNT_MAX ))s 判定死亡)"
  info "认证模式    : $( [[ "$RT_BATCH" == yes ]] && echo '仅密钥(非交互)' || echo '允许交互输入密码' )"

  # exec 保证 launchd 直接跟踪 ssh 进程;ssh 退出即服务退出,由 KeepAlive 拉起
  exec ssh "${SSH_ARGS[@]}" -N \
    -R "${RT_REMOTE_BIND}:${RT_REMOTE_PORT}:${RT_LOCAL_HOST}:${RT_LOCAL_PORT}" \
    "${RT_USER}@${RT_HOST}"
}

# ---------------------------------------------------------------------------
# plist 生成
# ---------------------------------------------------------------------------
generate_plist() {
  local log_x; log_x="$(xml_escape "$RT_LOG")"
  # 注意:$RT_BATCH 必须用花括号形式,否则 "$RT_BATCH_x" 会被当成变量名
  local log_max_x; log_max_x="$(xml_escape "$RT_LOG_MAX_BYTES")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$RT_LABEL")</string>

  <!-- 指向 TCC 安全目录里的包装器,而不是可能位于 ~/Documents 的源脚本。
       必须带上 run --launchd:否则脚本默认子命令是 help,会打印帮助后正常退出,
       表现为"服务不报错但隧道永远不建立"。 -->
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_escape "$RT_WRAPPER")</string>
    <string>run</string>
    <string>--launchd</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>RT_HOST</key><string>$(xml_escape "$RT_HOST")</string>
    <key>RT_PORT</key><string>$(xml_escape "$RT_PORT")</string>
    <key>RT_USER</key><string>$(xml_escape "$RT_USER")</string>
    <key>RT_REMOTE_BIND</key><string>$(xml_escape "$RT_REMOTE_BIND")</string>
    <key>RT_REMOTE_PORT</key><string>$(xml_escape "$RT_REMOTE_PORT")</string>
    <key>RT_LOCAL_HOST</key><string>$(xml_escape "$RT_LOCAL_HOST")</string>
    <key>RT_LOCAL_PORT</key><string>$(xml_escape "$RT_LOCAL_PORT")</string>
    <key>RT_IDENTITY</key><string>$(xml_escape "$RT_IDENTITY")</string>
    <key>RT_BATCH</key><string>yes</string>
    <key>RT_ALIVE_INTERVAL</key><string>$(xml_escape "$RT_ALIVE_INTERVAL")</string>
    <key>RT_ALIVE_COUNT_MAX</key><string>$(xml_escape "$RT_ALIVE_COUNT_MAX")</string>
    <key>RT_CONNECT_TIMEOUT</key><string>$(xml_escape "$RT_CONNECT_TIMEOUT")</string>
    <key>RT_LOG</key><string>$log_x</string>
    <key>RT_LOG_MAX_BYTES</key><string>$log_max_x</string>
  </dict>

  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>${RT_THROTTLE}</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$log_x</string>
  <key>StandardErrorPath</key><string>$log_x</string>
</dict>
</plist>
EOF
}

# ---------------------------------------------------------------------------
# install / uninstall
# ---------------------------------------------------------------------------
cmd_install() {
  local dry=0
  while (( $# )); do
    case "$1" in
      --dry-run|-n) dry=1 ;;
      *) die "install: 未知参数 $1" ;;
    esac
    shift
  done
  need_cmd launchctl
  ensure_dirs

  if (( dry )); then
    printf '%s\n' "===== 将写入: $RT_PLIST ====="
    generate_plist
    printf '%s\n' "===== 将写入: $RT_WRAPPER(TCC 安全目录,launchd 实际执行它)====="
    printf '%s\n' "  #!/bin/bash ... exec /bin/bash $(printf '%q' "$SELF_PATH") \"\$@\""
    printf '%s\n' "  (并复制脚本自身到 $RT_INSTALLED —— launchd 只运行这份副本)"
    printf '%s\n' "===== 将执行 ====="
    printf '%s\n' "launchctl bootout $RT_DOMAIN/$RT_LABEL   # 忽略失败"
    printf '%s\n' "launchctl bootstrap $RT_DOMAIN $RT_PLIST"
    printf '%s\n' "launchctl kickstart -k $RT_DOMAIN/$RT_LABEL"
    return 0
  fi

  # 先做一次连通性预检,避免装上一个永远起不来的服务
  build_ssh_args
  if ! ssh_remote true >/dev/null 2>&1; then
    die "预检失败: 无法免密登录 ${RT_USER}@${RT_HOST}:${RT_PORT}。请先运行 '$0 doctor' 排查,或配置好公钥认证。"
  fi
  info "预检通过: ${RT_USER}@${RT_HOST}:${RT_PORT} 免密登录正常"

  # TCC 安全路径:launchd 读不了 ~/Documents|Desktop|Downloads 下的脚本
  if is_tcc_unsafe_path "$SELF_PATH"; then
    note "脚本位于 macOS 隐私保护目录(~/Documents 等),launchd 无法直接读取它"
    note "→ 已改为通过包装器启动: $RT_WRAPPER"
  fi
  install_wrapper
  info "已写入包装器 $RT_WRAPPER"
  info "已复制脚本到 $RT_INSTALLED(launchd 只运行这份,不读源目录)"

  local tmp="${RT_PLIST}.tmp.$$"
  generate_plist > "$tmp"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die "plist 语法校验失败"; }
  fi
  mv -f "$tmp" "$RT_PLIST"
  info "已写入 $RT_PLIST"

  launchctl bootout "$RT_DOMAIN/$RT_LABEL" >/dev/null 2>&1 || true
  if ! launchctl bootstrap "$RT_DOMAIN" "$RT_PLIST" 2>/dev/null; then
    warn "bootstrap 失败,回退到旧式 load(旧版 macOS)"
    launchctl load -w "$RT_PLIST" || die "launchctl load 失败"
  else
    launchctl kickstart -k "$RT_DOMAIN/$RT_LABEL" >/dev/null 2>&1 || true
  fi

  sleep 2
  cmd_status || true
  printf '\n'
  info "安装完成。日志: $RT_LOG"
  info "下一步可在 A 上执行:  ssh -p ${RT_REMOTE_PORT} ${RT_LOCAL_USER}@127.0.0.1"
}

cmd_uninstall() {
  need_cmd launchctl
  if is_loaded; then
    launchctl bootout "$RT_DOMAIN/$RT_LABEL" >/dev/null 2>&1 || launchctl unload -w "$RT_PLIST" 2>/dev/null || true
    info "已停止并卸载 launchd 服务"
  fi
  if is_installed; then
    rm -f "$RT_PLIST"
    info "已删除 $RT_PLIST"
  else
    info "未发现已安装的服务($RT_PLIST 不存在)"
  fi
  if [[ -f "$RT_WRAPPER" ]]; then
    remove_wrapper
    info "已删除包装器 $RT_WRAPPER"
  fi
  info "日志保留在 $RT_LOG(如需清理: rm -f \"$RT_LOG\"*)"
}

# ---------------------------------------------------------------------------
# start / stop / restart
# ---------------------------------------------------------------------------
cmd_start() {
  is_installed || die "尚未安装,请先执行: $0 install"
  need_cmd launchctl
  if launchctl bootstrap "$RT_DOMAIN" "$RT_PLIST" 2>/dev/null; then
    info "已启动"
  elif is_loaded; then
    if launchctl kickstart "$RT_DOMAIN/$RT_LABEL" >/dev/null 2>&1; then
      info "已在运行,已确保启动"
    else
      warn "kickstart 未成功,请查看: $0 logs -n 30"
    fi
  elif ! launchctl load -w "$RT_PLIST" 2>/dev/null; then
    die "启动失败,请查看: $0 logs -n 30"
  fi
  sleep 1
  echo
  cmd_status || true
}

cmd_stop() {
  need_cmd launchctl
  is_loaded || { info "服务未在运行"; return 0; }
  launchctl bootout "$RT_DOMAIN/$RT_LABEL" >/dev/null 2>&1 || launchctl unload -w "$RT_PLIST" 2>/dev/null || true
  info "已停止(本次登录会话内不再自动拉起;重新登录或执行 '$0 start' 会恢复)"
  info "需要永久停止请用: $0 uninstall"
}

cmd_restart() {
  need_cmd launchctl
  is_installed || die "尚未安装,请先执行: $0 install"
  if is_loaded; then
    launchctl kickstart -k "$RT_DOMAIN/$RT_LABEL" >/dev/null 2>&1 || true
    info "已重启"
  else
    launchctl bootstrap "$RT_DOMAIN" "$RT_PLIST" >/dev/null 2>&1 || launchctl load -w "$RT_PLIST"
    info "已启动"
  fi
  sleep 1
  echo
  cmd_status || true
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
  build_ssh_args
  printf '%s===== 隧道状态 =====%s\n' "$C_DIM" "$C_OFF"

  # launchd
  if ! is_installed; then
    bad "launchd 服务未安装(运行 '$0 install' 安装)"
  elif ! is_loaded; then
    note "launchd 服务已安装但未加载(运行 '$0 start')"
  else
    local dump state pid
    dump="$(launchctl print "$RT_DOMAIN/$RT_LABEL" 2>/dev/null || true)"
    state="$(sed -n 's/^[[:space:]]*state = //p' <<<"$dump" | head -n1)"
    pid="$(sed -n 's/^[[:space:]]*pid = //p' <<<"$dump" | head -n1)"
    if [[ "$state" == "running" ]]; then
      ok "launchd 服务运行中 (state=${state:-?}, pid=${pid:-?})"
    else
      note "launchd 服务已加载但当前未运行 (state=${state:-unknown}, 可能是刚崩溃、正在节流重试)"
      explain_launch_failure "$dump"
    fi
  fi

  # 包装器与安装副本(launchd 实际执行的文件)
  if is_installed; then
    if [[ -x "$RT_WRAPPER" && -r "$RT_INSTALLED" ]]; then
      ok "包装器与安装副本就位: $RT_WRAPPER"
    else
      bad "包装器或安装副本缺失(重新执行 '$0 install')"
      [[ -x "$RT_WRAPPER" ]] || note "缺少: $RT_WRAPPER"
      [[ -r "$RT_INSTALLED" ]] || note "缺少: $RT_INSTALLED"
    fi
  fi

  # 本机 sshd
  if netstat -an 2>/dev/null | grep -E "[.*:]${RT_LOCAL_PORT}[[:space:]]" | grep -qi listen; then
    ok "本机 sshd 正在监听 :${RT_LOCAL_PORT}"
  else
    bad "本机 :${RT_LOCAL_PORT} 没有监听 —— 请在 系统设置 > 通用 > 共享 中打开「远程登录」"
  fi

  # A 侧隧道端口
  local rlisten
  if rlisten="$(ssh_remote "ss -tln 2>/dev/null | grep -c '[:.]${RT_REMOTE_PORT}[[:space:]]' || true" 2>/dev/null)"; then
    rlisten="${rlisten//[!0-9]/}"
    if [[ -n "$rlisten" && "$rlisten" -gt 0 ]]; then
      ok "A 上 :${RT_REMOTE_PORT} 正在监听 ${RT_REMOTE_BIND}"
    else
      note "A 上 :${RT_REMOTE_PORT} 未监听(隧道可能未建立,或正被其它进程/旧连接占用)"
    fi
  else
    bad "无法 SSH 到 ${RT_HOST}(网络或认证问题)"
  fi

  # 日志尾部
  if [[ -f "$RT_LOG" ]]; then
    printf '%s--- 最近日志 ---%s\n' "$C_DIM" "$C_OFF"
    tail -n 5 "$RT_LOG" | sed 's/^/  /'
  fi
}

# ---------------------------------------------------------------------------
# verify —— 从 A 侧真正走一遍隧道
# ---------------------------------------------------------------------------
cmd_verify() {
  build_ssh_args
  info "从 A 侧通过隧道连接本机 sshd ..."
  local out rc
  set +e
  out="$(ssh_remote "timeout ${RT_CONNECT_TIMEOUT} ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=$((RT_CONNECT_TIMEOUT-3)) -p ${RT_REMOTE_PORT} ${RT_LOCAL_USER}@127.0.0.1 true" 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    ok "隧道链路正常,且 A -> 本机 的密钥认证也通过"
    return 0
  fi
  if grep -qi "permission denied" <<<"$out"; then
    ok "隧道链路是通的(A 已连到本机 sshd)"
    note "但认证未通过 —— 需要把 A 的公钥加入本机 ~/.ssh/authorized_keys"
    printf '  执行:  %s setup-auth\n' "$0"
    return 0
  fi
  bad "隧道链路不通 (exit=$rc)"
  printf '  %s\n' "$out" | sed 's/^/  /'
  note "排查: $0 status ; $0 logs -n 30"
  return 1
}

# ---------------------------------------------------------------------------
# setup-auth —— 让 A 能免密登录本机(把 A 的公钥装进本机 authorized_keys)
# ---------------------------------------------------------------------------
cmd_setup_auth() {
  build_ssh_args
  need_cmd ssh

  info "1/3 检查本机 -> A 的免密登录 ..."
  if ssh_remote true >/dev/null 2>&1; then
    ok "本机 -> A 免密登录正常"
  else
    die "本机 -> A 无法免密登录。请先: ssh-copy-id -p ${RT_PORT} ${RT_USER}@${RT_HOST}"
  fi

  info "2/3 在 A 上准备公钥 ..."
  local apub
  apub="$(ssh_remote 'if ! ls ~/.ssh/id_ed25519.pub >/dev/null 2>&1 && ! ls ~/.ssh/id_rsa.pub >/dev/null 2>&1; then ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 >/dev/null; fi; cat ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null | head -n1')"
  [[ -n "$apub" ]] || die "无法在 A 上获取/生成公钥"
  ok "拿到 A 的公钥: ${apub:0:40}..."

  info "3/3 写入本机 ~/.ssh/authorized_keys ..."
  local blob; blob="$(awk '{print $2}' <<<"$apub")"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  if grep -qF "$blob" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    ok "该公钥已存在,无需重复添加"
  else
    printf '%s\n' "$apub" >> "$HOME/.ssh/authorized_keys"
    ok "已追加到 ~/.ssh/authorized_keys"
  fi

  printf '\n'
  info "完成。可在 A 上验证:  ssh -p ${RT_REMOTE_PORT} ${RT_LOCAL_USER}@127.0.0.1"
}

# ---------------------------------------------------------------------------
# doctor —— 上线前体检
# ---------------------------------------------------------------------------
cmd_doctor() {
  build_ssh_args
  local problems=0

  printf '\n%s===== 环境体检 =====%s\n' "$C_DIM" "$C_OFF"
  printf '%s[1] 本机基础环境%s\n' "$C_DIM" "$C_OFF"
  for c in ssh launchctl netstat; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c 可用"
    else bad "$c 缺失"; problems=$((problems + 1)); fi
  done
  [[ -x "$SELF_PATH" ]] && ok "脚本可执行: $SELF_PATH" || note "脚本无执行位(用 bash $SELF_PATH 调用即可)"

  printf '\n%s[2] 本机 sshd(被访问的一端)%s\n' "$C_DIM" "$C_OFF"
  if netstat -an 2>/dev/null | grep -E "[.*:]${RT_LOCAL_PORT}[[:space:]]" | grep -qi listen; then
    ok "sshd 正在监听 :${RT_LOCAL_PORT}(隧道的目标端口)"
  else
    bad "本机 :${RT_LOCAL_PORT} 未监听 —— 隧道会连不上"; problems=$((problems + 1))
    if [[ "$RT_LOCAL_PORT" == "22" ]]; then
      note "打开 系统设置 > 通用 > 共享 > 远程登录"
    else
      note "macOS 的 sshd 端口由 launchd socket 决定,改 sshd_config 无效。执行:"
      note "  sudo bash macos-sshd-extra-port.sh install    # 额外开放 ${RT_LOCAL_PORT}"
    fi
  fi
  if [[ "$RT_LOCAL_PORT" != "22" ]]; then
    if netstat -an 2>/dev/null | grep -E "[.*:]22[[:space:]]" | grep -qi listen; then
      ok "系统 sshd 的 22 端口也在监听(两者并存)"
    else
      note "22 端口未监听(只用额外端口也可以,但说明系统自带 sshd 没在跑)"
    fi
  fi
  if command -v /usr/libexec/ApplicationFirewall/socketfilterfw >/dev/null 2>&1; then
    local fw; fw="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true)"
    if grep -qi "disabled" <<<"$fw"; then ok "应用防火墙已关闭"
    else note "应用防火墙状态: ${fw:-未知}(若开启,需允许 sshd 接受连接)"; fi
  fi
  local sleepstate
  sleepstate="$(pmset -g 2>/dev/null | sed -n 's/^[[:space:]]*sleep[[:space:]]*//p' | head -n1)"
  if [[ -n "$sleepstate" ]]; then
    if grep -q "prevented" <<<"$sleepstate" || [[ "${sleepstate%% *}" == "0" ]]; then
      ok "系统睡眠已禁止/为 0,不会因休眠断隧道"
    else
      note "系统睡眠设置: $sleepstate —— 休眠会断开隧道,恢复后由 launchd 自动重连"
    fi
  fi

  printf '\n%s[3] 网络与认证%s\n' "$C_DIM" "$C_OFF"
  local myip; myip="$(ipconfig getifaddr en0 2>/dev/null || echo '未知')"
  note "本机 LAN 地址: ${myip}(位于 NAT 后,A 无法直接回连,这正是需要反向隧道的原因)"
  if ssh_remote true >/dev/null 2>&1; then
    ok "SSH 可达 A 且已配置免密登录: ${RT_USER}@${RT_HOST}:${RT_PORT}"
  else
    bad "无法免密登录 ${RT_USER}@${RT_HOST}:${RT_PORT}"; problems=$((problems + 1))
    note "修复: ssh-copy-id -p ${RT_PORT} ${RT_USER}@${RT_HOST}"
  fi
  if ssh_remote "command -v ss >/dev/null 2>&1" >/dev/null 2>&1; then
    ok "A 上有 ss 命令(用于端口状态检查)"
  else
    note "A 上没有 ss,status 的远端端口检查会退化为未知"
  fi

  printf '\n%s[4] A -> 本机 的免密认证%s\n' "$C_DIM" "$C_OFF"
  local apub blob
  apub="$(ssh_remote 'cat ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null | head -n1' 2>/dev/null || true)"
  if [[ -z "$apub" ]]; then
    note "A 上还没有 SSH 公钥(执行 '$0 setup-auth' 会自动生成并安装)"
  else
    blob="$(awk '{print $2}' <<<"$apub")"
    if [[ -f "$HOME/.ssh/authorized_keys" ]] && grep -qF "$blob" "$HOME/.ssh/authorized_keys"; then
      ok "A 的公钥已在本机 authorized_keys 中"
    else
      note "缺少 A 的公钥 —— 执行 '$0 setup-auth' 一键安装"
    fi
  fi

  printf '\n%s[5] launchd 服务%s\n' "$C_DIM" "$C_OFF"
  if is_tcc_unsafe_path "$SELF_PATH"; then
    note "源脚本位于 macOS 隐私保护目录: $SELF_PATH"
    note "launchd 读取该目录会被 TCC 直接拒绝(EPERM / exit 126,且 platform binary 无法弹窗授权)"
    note "因此运行时不读源目录,只执行安装副本: $RT_INSTALLED"
    note "→ 改完代码或配置后必须重新执行 '$0 install' 才会生效"
  else
    ok "源脚本不在 macOS 隐私保护目录"
  fi
  if [[ -x "$RT_WRAPPER" && -r "$RT_INSTALLED" ]]; then
    ok "包装器与安装副本就位: $RT_WRAPPER"
  else
    note "包装器/安装副本尚未生成('$0 install' 时创建)"
  fi
  if ! is_installed; then
    note "未安装(执行 '$0 install')"
  elif ! is_loaded; then
    note "plist 已存在但未加载(执行 '$0 start')"
  else
    local dump state
    dump="$(launchctl print "$RT_DOMAIN/$RT_LABEL" 2>/dev/null || true)"
    state="$(sed -n 's/^[[:space:]]*state = //p' <<<"$dump" | head -n1)"
    if [[ "$state" == "running" ]]; then ok "服务运行中"
    else
      note "已加载但未运行 (state=${state:-unknown})"
      explain_launch_failure "$dump"
      problems=$((problems + 1))
    fi
  fi

  printf '\n%s===== 结论 =====%s\n' "$C_DIM" "$C_OFF"
  if (( problems == 0 )); then
    ok "未发现阻塞性问题。推荐流程: $0 setup-auth  ->  $0 install  ->  $0 verify"
  else
    bad "发现 $problems 个阻塞性问题,请先按上面提示修复"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# logs / config
# ---------------------------------------------------------------------------
cmd_logs() {
  local n=40 follow=0
  while (( $# )); do
    case "$1" in
      -f|--follow) follow=1 ;;
      -n) shift; n="${1:-40}" ;;
      -n*) n="${1#-n}" ;;
      *) die "logs: 未知参数 $1" ;;
    esac
    shift
  done
  [[ -f "$RT_LOG" ]] || { info "日志还不存在: $RT_LOG"; return 0; }
  if (( follow )); then tail -n "$n" -f "$RT_LOG"; else tail -n "$n" "$RT_LOG"; fi
}

cmd_config() {
  cat <<EOF
RT_HOST               = $RT_HOST
RT_PORT               = $RT_PORT
RT_USER               = $RT_USER
RT_REMOTE_BIND        = $RT_REMOTE_BIND
RT_REMOTE_PORT        = $RT_REMOTE_PORT
RT_LOCAL_HOST         = $RT_LOCAL_HOST
RT_LOCAL_PORT         = $RT_LOCAL_PORT
RT_IDENTITY           = ${RT_IDENTITY:-(默认)}
RT_BATCH              = $RT_BATCH
RT_LABEL              = $RT_LABEL
RT_ALIVE_INTERVAL     = $RT_ALIVE_INTERVAL
RT_ALIVE_COUNT_MAX    = $RT_ALIVE_COUNT_MAX
RT_CONNECT_TIMEOUT    = $RT_CONNECT_TIMEOUT
RT_THROTTLE           = $RT_THROTTLE
RT_LOG                = $RT_LOG
RT_LOG_MAX_BYTES      = $RT_LOG_MAX_BYTES
RT_PLIST              = $RT_PLIST
RT_RUN_DIR            = $RT_RUN_DIR
RT_WRAPPER            = $RT_WRAPPER
RT_INSTALLED          = $RT_INSTALLED
源脚本                = $SELF_PATH$(
  if is_tcc_unsafe_path "$SELF_PATH"; then
    printf '\n本脚本位置          = ⚠ 位于 macOS 隐私保护目录(launchd 无法直接读取,靠包装器启动)'
  fi
)
launchd domain        = $RT_DOMAIN
本机(被访问方)用户     = $RT_LOCAL_USER
A 上登录命令           = ssh -p $RT_REMOTE_PORT $RT_LOCAL_USER@127.0.0.1
EOF
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
cmd_help() {
  cat <<EOF
revtunnel.sh —— 反向 SSH 隧道(保活 + 自愈)

用法: $0 <子命令> [参数]

子命令
  doctor              上线前体检:检查 sshd、防火墙、睡眠、认证、launchd 状态
  setup-auth          把 A 的公钥装进本机 authorized_keys(A -> 本机 免密登录用)
  install [--dry-run] 安装并启动 launchd 常驻服务(--dry-run 只打印 plist 不落地)
  uninstall           停止并删除 launchd 服务
  start               启动已安装的服务
  stop                停止服务(重新登录或 start 会恢复)
  restart             重启服务
  status              查看隧道状态(launchd / 本机 sshd / A 侧端口 / 日志尾部)
  verify              从 A 侧真实走一遍隧道,验证链路与认证
  run [-i]            前台运行隧道,-i 允许交互输入密码(调试用,Ctrl-C 结束)
  logs [-n N] [-f]    查看日志,-f 持续跟踪
  config              打印当前生效配置
  help                显示本帮助

示例
  $0 doctor && $0 setup-auth && $0 install && $0 verify

环境变量覆盖(安装时会写入 plist)
  RT_HOST=172.16.134.43   RT_PORT=2233        RT_USER=zjl
  RT_REMOTE_PORT=12222    RT_REMOTE_BIND=127.0.0.1
  RT_LOCAL_PORT=26259     RT_LOCAL_HOST=127.0.0.1
  RT_ALIVE_INTERVAL=30    RT_ALIVE_COUNT_MAX=3   RT_THROTTLE=10
  RT_LOG=\$HOME/Library/Logs/revtunnel.log

注意
  RT_LOCAL_PORT 默认 26259,要求 Mac 上确实有 sshd 在该端口监听。
  未开放时先执行: sudo bash macos-sshd-extra-port.sh install
  用系统默认的 22:  RT_LOCAL_PORT=22 $0 install
EOF
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift || true
  case "$cmd" in
    run)         cmd_run "$@" ;;
    install)     cmd_install "$@" ;;
    uninstall)   cmd_uninstall "$@" ;;
    start)       cmd_start "$@" ;;
    stop)        cmd_stop "$@" ;;
    restart)     cmd_restart "$@" ;;
    status)      cmd_status "$@" ;;
    verify)      cmd_verify "$@" ;;
    setup-auth)  cmd_setup_auth "$@" ;;
    doctor)      cmd_doctor "$@" ;;
    logs)        cmd_logs "$@" ;;
    config)      cmd_config "$@" ;;
    help|-h|--help) cmd_help ;;
    *) err "未知子命令: $cmd"; echo; cmd_help; exit 2 ;;
  esac
}

main "$@"
