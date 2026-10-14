#!/usr/bin/env bash
#
# dsh-web-tunnel.sh —— 把 Mac 上的 DSH web(127.0.0.1:3080)暴露到跳板机的回环
#
# 解决什么问题:
#   DSH web 只绑 127.0.0.1,而 ssh -L 的最后一跳是由**你连的那台机器**发起的。
#   所以"用 -L 转发到 Mac 的 3080"是行不通的 —— 实测会得到
#   `Received HTTP/0.9 when not allowed`,因为对手方只是 Mac 的 sshd。
#
#   正确做法:让 Mac 主动开一条反向通道,把「跳板机的某个回环端口」映射回
#   Mac 自己的 127.0.0.1:3080。这样链路变成:
#
#     客户端 ──-L──▶ 跳板机 127.0.0.1:<REMOTE_PORT>
#                        └──反向隧道(最后一跳在 Mac 上)──▶ Mac 127.0.0.1:3080
#
#   于是客户端只要 curl/浏览器访问 127.0.0.1:3080 就能到 DSH web,
#   Host 头保持 loopback,DSH 的信任栅栏与 cookie authority 都不会错位。
#
# 用法:
#   ./dsh-web-tunnel.sh install     # 安装并启动 launchd 常驻服务
#   ./dsh-web-tunnel.sh uninstall   # 停止并删除
#   ./dsh-web-tunnel.sh status      # 查看状态
#   ./dsh-web-tunnel.sh attach      # 打印客户端(跳板机侧)该怎么连
#   ./dsh-web-tunnel.sh run         # 前台运行,调试用
#   ./dsh-web-tunnel.sh help
#
# 环境变量(下面三项是占位符,部署时用环境变量覆盖):
#   DSH_PORT=3080                   本机 DSH web 端口
#   DSH_TUNNEL_HOST=203.0.113.10    跳板机地址
#   DSH_TUNNEL_PORT=2233            跳板机 sshd 端口
#   DSH_TUNNEL_USER=user            跳板机登录用户
#   DSH_REMOTE_PORT=13080           在跳板机上开放的回环端口
#   DSH_LABEL=com.jalen.dsh-tunnel  launchd 服务标识
#
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

DSH_PORT="${DSH_PORT:-3080}"
TUNNEL_HOST="${DSH_TUNNEL_HOST:-203.0.113.10}"   # 占位符(RFC 5737 文档保留地址),部署时用 DSH_TUNNEL_HOST 覆盖
TUNNEL_PORT="${DSH_TUNNEL_PORT:-2233}"
TUNNEL_USER="${DSH_TUNNEL_USER:-user}"           # 占位符,部署时用 DSH_TUNNEL_USER 覆盖
REMOTE_PORT="${DSH_REMOTE_PORT:-13080}"
LABEL="${DSH_LABEL:-com.jalen.dsh-tunnel}"

LOG="${DSH_LOG:-$HOME/Library/Logs/dsh-web-tunnel.log}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
THROTTLE="${DSH_THROTTLE:-10}"
ALIVE_INTERVAL="${DSH_ALIVE_INTERVAL:-30}"
ALIVE_COUNT_MAX="${DSH_ALIVE_COUNT_MAX:-3}"

# 与 revtunnel.sh 相同的原因:若本脚本位于 ~/Documents 等 TCC 保护目录,
# launchd 读取会被直接拒绝(EPERM)。安装时复制到安全目录并生成包装器。
RUN_DIR="${DSH_RUN_DIR:-$HOME/.local/libexec/dsh-web-tunnel}"
WRAPPER="$RUN_DIR/launch.sh"
INSTALLED="$RUN_DIR/dsh-web-tunnel.sh"
META="$RUN_DIR/installed.conf"   # install 时落地的真实配置,供 status/attach 回读

# ---------------------------------------------------------------------------
# 回读已部署的配置
#
# 为什么需要:源码里的默认值是占位符(便于公开仓库脱敏),直接跑
# `./dsh-web-tunnel.sh status` 会拿着占位符去连跳板机 —— 探测必然失败,
# 表现为"服务明明在跑,却报无法 SSH 到跳板机"。
# install 会把本次真实生效的值写到 $META,status/attach 读回它,
# 这样无论从源码还是从安装副本调用,看到的都是**实际部署的那份配置**。
#
# 若部署时用了真实值(推荐),install 会额外固化一份可直接运行的副本到
# $RUN_DIR/installed-run.sh,使源码里的占位符不再参与任何运行路径。
# ---------------------------------------------------------------------------
load_meta() {
  [[ -f "$META" ]] || return 1
  # 与 revtunnel.sh 同一套做法:先转 JSON 再用 python3 取值,
  # 避免 shell → sed/awk 之间的引号转义陷阱。
  local json kv
  json="$(/usr/bin/python3 -c '
import json, sys
d = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        d[k.strip()] = v
print(json.dumps(d))
' "$META" 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1
  kv="$(printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("DSH_PORT","DSH_TUNNEL_HOST","DSH_TUNNEL_PORT","DSH_TUNNEL_USER",
          "DSH_REMOTE_PORT","DSH_LABEL"):
    v = d.get(k)
    if v is not None:
        print("%s=%s" % (k, str(v).replace(chr(10), " ")))
' 2>/dev/null)" || true
  [[ -n "$kv" ]] || return 1
  eval "$kv"
  # 注意:配置键与变量名不同(DSH_TUNNEL_HOST -> TUNNEL_HOST),
  # 必须显式映射,否则 eval 设置的是带前缀的名字,脚本读到的一直是旧值。
  TUNNEL_HOST="${DSH_TUNNEL_HOST:-$TUNNEL_HOST}"
  TUNNEL_USER="${DSH_TUNNEL_USER:-$TUNNEL_USER}"
  TUNNEL_PORT="${DSH_TUNNEL_PORT:-$TUNNEL_PORT}"
  DSH_PORT="${DSH_PORT:-$DSH_PORT}"
  REMOTE_PORT="${DSH_REMOTE_PORT:-$REMOTE_PORT}"
  LABEL="${DSH_LABEL:-$LABEL}"
  # 标签可能被改过,重算依赖它的路径
  PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
  DOMAIN="gui/$(id -u)"
  return 0
}

# 占位符是否还在生效(说明没装过或没覆盖)
is_placeholder_host() {
  [[ "$TUNNEL_HOST" == "203.0.113.10" || "$TUNNEL_USER" == "user" ]]
}

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR ] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
ok()   { printf '  %s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_ERR" "$C_OFF" "$*"; }
note() { printf '  %s•%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

is_tcc_unsafe_path() {
  case "$1" in
    "$HOME/Documents"/*|"$HOME/Desktop"/*|"$HOME/Downloads"/*) return 0 ;;
  esac
  return 1
}

is_installed() { [[ -f "$PLIST" ]]; }
is_loaded()    { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

dsh_listening() {
  netstat -an 2>/dev/null | grep -E "[.*:]${DSH_PORT}[[:space:]].*LISTEN" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
cmd_run() {
  load_meta >/dev/null 2>&1 || true
  need_cmd ssh
  if is_placeholder_host; then
    err "跳板机地址/用户仍是占位符(${TUNNEL_HOST} / ${TUNNEL_USER}),拒绝连接。"
    err "请用真实值: DSH_TUNNEL_HOST=<跳板机> DSH_TUNNEL_USER=<用户> $0 install"
    exit 1
  fi
  mkdir -p "$(dirname "$LOG")"
  if ! dsh_listening; then
    warn "本机 ${DSH_PORT} 没有监听 —— DSH web 可能没在跑;先启动 dsh web"
  fi
  info "把 B:127.0.0.1:${REMOTE_PORT} 反向映射到 本机 127.0.0.1:${DSH_PORT}"
  # exec 让 launchd 直接跟踪 ssh 进程
  exec ssh -N \
    -p "$TUNNEL_PORT" \
    -o "ServerAliveInterval=${ALIVE_INTERVAL}" \
    -o "ServerAliveCountMax=${ALIVE_COUNT_MAX}" \
    -o TCPKeepAlive=yes \
    -o ExitOnForwardFailure=yes \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -R "${REMOTE_PORT}:127.0.0.1:${DSH_PORT}" \
    "${TUNNEL_USER}@${TUNNEL_HOST}"
}

# ---------------------------------------------------------------------------
install_wrapper() {
  mkdir -p "$RUN_DIR"
  cp -f "${BASH_SOURCE[0]}" "$INSTALLED"
  chmod 755 "$INSTALLED"
  cat > "$WRAPPER" <<EOF
#!/bin/bash
# 由 dsh-web-tunnel.sh install 生成 —— 不要手改。
# 只执行 TCC 安全目录里的副本,绝不读取源目录(原因见 revtunnel.sh 的说明)。
set -Eeuo pipefail
export DSH_PORT=$(printf '%q' "$DSH_PORT")
export DSH_TUNNEL_HOST=$(printf '%q' "$TUNNEL_HOST")
export DSH_TUNNEL_PORT=$(printf '%q' "$TUNNEL_PORT")
export DSH_TUNNEL_USER=$(printf '%q' "$TUNNEL_USER")
export DSH_REMOTE_PORT=$(printf '%q' "$REMOTE_PORT")
export DSH_LABEL=$(printf '%q' "$LABEL")
export DSH_LOG=$(printf '%q' "$LOG")
export DSH_RUN_DIR=$(printf '%q' "$RUN_DIR")
exec /bin/bash $(printf '%q' "$INSTALLED") run
EOF
  chmod 755 "$WRAPPER"
}

generate_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WRAPPER}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>${THROTTLE}</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
EOF
}

cmd_install() {
  need_cmd launchctl
  need_cmd ssh
  mkdir -p "$(dirname "$LOG")" "$(dirname "$PLIST")"

  # 防止把占位符装上:壳里必须用真实值覆盖
  if is_placeholder_host; then
    die "跳板机地址/用户仍是占位符(${TUNNEL_HOST} / ${TUNNEL_USER})。请显式覆盖,例如:
       DSH_TUNNEL_HOST=203.0.113.10 DSH_TUNNEL_USER=<你的用户> $0 install"
  fi

  # 预检:必须能免密登录跳板机
  if ! ssh -p "$TUNNEL_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
       "${TUNNEL_USER}@${TUNNEL_HOST}" true >/dev/null 2>&1; then
    die "预检失败: 无法免密登录 ${TUNNEL_USER}@${TUNNEL_HOST}:${TUNNEL_PORT}"
  fi
  info "预检通过: ${TUNNEL_USER}@${TUNNEL_HOST}:${TUNNEL_PORT} 免密登录正常"

  # 记录本次真实生效的配置,供 status/attach 回读
  mkdir -p "$RUN_DIR"
  {
    printf 'DSH_PORT=%s\n'        "$DSH_PORT"
    printf 'DSH_TUNNEL_HOST=%s\n' "$TUNNEL_HOST"
    printf 'DSH_TUNNEL_PORT=%s\n' "$TUNNEL_PORT"
    printf 'DSH_TUNNEL_USER=%s\n' "$TUNNEL_USER"
    printf 'DSH_REMOTE_PORT=%s\n' "$REMOTE_PORT"
    printf 'DSH_LABEL=%s\n'       "$LABEL"
  } > "$META"
  info "已记录配置 $META"

  if is_tcc_unsafe_path "${BASH_SOURCE[0]}"; then
    note "脚本位于 TCC 保护目录 → 运行时改用副本 $INSTALLED"
  fi
  install_wrapper
  info "已写入包装器 $WRAPPER"

  # 额外固化一份"带着真实值的可运行副本":即便源文件的默认值仍是占位符,
  # 它也能独立跑通(install/status 等)。纯属冗余,方便将来直接从 RUN_DIR 调用。
  sed -e "s|^TUNNEL_HOST=\"\${DSH_TUNNEL_HOST:-[^}]*}\"|TUNNEL_HOST=\"\${DSH_TUNNEL_HOST:-${TUNNEL_HOST}}\"|" \
      -e "s|^TUNNEL_USER=\"\${DSH_TUNNEL_USER:-[^}]*}\"|TUNNEL_USER=\"\${DSH_TUNNEL_USER:-${TUNNEL_USER}}\"|" \
      "${BASH_SOURCE[0]}" > "$RUN_DIR/installed-run.sh" 2>/dev/null || true
  chmod 755 "$RUN_DIR/installed-run.sh" 2>/dev/null || true

  local tmp="${PLIST}.tmp.$$"
  generate_plist > "$tmp"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die "plist 语法校验失败"; }
  fi
  mv -f "$tmp" "$PLIST"
  info "已写入 $PLIST"

  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    warn "bootstrap 失败,回退旧式 load"
    launchctl load -w "$PLIST" || die "launchctl load 失败"
  fi
  sleep 2
  cmd_status || true
  printf '\n'
  info "安装完成。客户端侧怎么连,见: $0 attach"
}

cmd_uninstall() {
  load_meta >/dev/null 2>&1 || true
  if is_loaded; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    info "已停止服务"
  fi
  [[ -f "$PLIST" ]] && { rm -f "$PLIST"; info "已删除 $PLIST"; }
  rm -f "$WRAPPER" "$INSTALLED" "$META" "$RUN_DIR/installed-run.sh" 2>/dev/null || true
  rmdir "$RUN_DIR" 2>/dev/null || true
  info "日志保留在 $LOG"
}

cmd_status() {
  load_meta >/dev/null 2>&1 || true
  printf '%s===== DSH web 隧道状态 =====%s\n' "$C_DIM" "$C_OFF"
  printf '  本机 DSH web : 127.0.0.1:%s\n' "$DSH_PORT"
  printf '  跳板机       : %s@%s:%s\n' "$TUNNEL_USER" "$TUNNEL_HOST" "$TUNNEL_PORT"
  printf '  跳板机上的门 : 127.0.0.1:%s(仅跳板机本机可连)\n' "$REMOTE_PORT"
  if [[ -f "$META" ]]; then
    printf '  %s(配置读自 %s)%s\n\n' "$C_DIM" "$META" "$C_OFF"
  else
    printf '  %s(未装过,以下为源码默认值;可能仍是占位符)%s\n\n' "$C_DIM" "$C_OFF"
  fi

  if is_loaded; then
    local dump state pid
    dump="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null || true)"
    state="$(sed -n 's/^[[:space:]]*state = //p' <<<"$dump" | head -n1)"
    pid="$(sed -n 's/^[[:space:]]*pid = //p' <<<"$dump" | head -n1)"
    if [[ "$state" == "running" ]]; then ok "launchd 服务运行中 (pid=${pid:-?})"
    else bad "服务已加载但未运行 (state=${state:-unknown}),看 $LOG"; fi
  else
    bad "服务未安装(执行 '$0 install')"
  fi

  if dsh_listening; then ok "本机 ${DSH_PORT} 正在监听"
  else bad "本机 ${DSH_PORT} 未监听 —— dsh web 没在跑"; fi

  # 从跳板机侧验证门是否真的通了
  local probe
  if probe="$(ssh -p "$TUNNEL_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
        "${TUNNEL_USER}@${TUNNEL_HOST}" \
        "curl -s --max-time 8 -o /dev/null -w '%{http_code}' http://127.0.0.1:${REMOTE_PORT}/ 2>/dev/null || echo fail" 2>/dev/null)"; then
    case "$probe" in
      401|200) ok "跳板机上 127.0.0.1:${REMOTE_PORT} 可达 DSH web(HTTP ${probe},401 = 只差 token)" ;;
      *)       bad "跳板机侧探测异常: HTTP ${probe} —— 看 $LOG" ;;
    esac
  else
    bad "无法 SSH 到跳板机或探测失败"
  fi
}

cmd_attach() {
  load_meta >/dev/null 2>&1 || true
  cat <<EOF
在跳板机(${TUNNEL_HOST})上执行:

  curl -s -H 'Host: 127.0.0.1:${DSH_PORT}' http://127.0.0.1:${REMOTE_PORT}/

  期望:401 + "dsh web authentication required; reopen the URL printed by dsh web."

如果你要从更远的机器(经跳板机)访问:

  # 一跳:本地 ${DSH_PORT} → 跳板机的 ${REMOTE_PORT}
  ssh -N -L ${DSH_PORT}:127.0.0.1:${REMOTE_PORT} ${TUNNEL_USER}@${TUNNEL_HOST} -p ${TUNNEL_PORT}

  # 然后浏览器打开 dsh web 打印的那行 URL(127.0.0.1:${DSH_PORT}/?token=...)

为什么可以用 127.0.0.1 而不是跳板机 IP:
  最后一跳在 Mac 上发起,落地就是 Mac 的 127.0.0.1:${DSH_PORT},
  Host 头保持 loopback,DSH 的信任栅栏与 cookie authority 都不会错位。
  若改成用跳板机 IP 访问(例:http://${TUNNEL_HOST}:${REMOTE_PORT}/),
  栅栏会按非 loopback 处理并拒绝(403),除非给 dsh web 加 --trusted-host。
EOF
}

cmd_help() {
  cat <<EOF
dsh-web-tunnel.sh —— 把 Mac 的 DSH web 暴露到跳板机的回环端口

用法:
  $0 install     安装并启动 launchd 常驻服务
  $0 uninstall   停止并删除
  $0 status      查看状态(含从跳板机侧的真实探测)
  $0 attach      打印客户端侧连接方式
  $0 run         前台运行(调试)
  $0 help        本帮助

原理:
  DSH web 只绑 127.0.0.1,而 ssh -L 的最后一跳由被连机器发起,所以无法直达。
  本脚本让 Mac 主动开反向通道(ssh -R),把跳板机的回环端口映射回 Mac 的
  127.0.0.1:${DSH_PORT}。客户端只需连跳板机的回环端口即可,Host 头仍是 loopback。

环境变量:
  DSH_PORT=${DSH_PORT}   DSH_TUNNEL_HOST=${TUNNEL_HOST}   DSH_TUNNEL_PORT=${TUNNEL_PORT}
  DSH_TUNNEL_USER=${TUNNEL_USER}   DSH_REMOTE_PORT=${REMOTE_PORT}   DSH_LABEL=${LABEL}
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    run)       cmd_run ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    attach)    cmd_attach ;;
    help|-h|--help) cmd_help ;;
    *) err "未知子命令: $cmd"; echo; cmd_help; exit 2 ;;
  esac
}
main "$@"
