#!/usr/bin/env bash
#
# macos-sshd-extra-port.sh —— 让 macOS 的 sshd 在保留 22 的同时,额外监听一个端口
#
# ── 为什么需要这个脚本 ────────────────────────────────────────────────────────
# macOS 默认的 sshd 由 launchd 以 **socket 激活** 方式启动:
#   /System/Library/LaunchDaemons/ssh.plist
#     Program        = /usr/libexec/sshd-keygen-wrapper
#     Sockets.Listeners.SockServiceName = ssh     ← 端口由这里决定
# 这种模式(inetd 风格:套接字由 launchd 建好再交给 sshd)下,
# **sshd_config 里的 Port / ListenAddress 会被忽略**。
#
# ── 关键坑:为什么不能照抄 Apple 的 plist 只把 ssh 换成端口号 ─────────────────
# 直觉做法是复制 Apple 的写法、把 SockServiceName 从 "ssh" 换成 "26259"。
# 这样做 **在 macOS 上永远起不来监听**,因为 launchd 是拿这个字符串去调
# getaddrinfo(host, serv) 的,而 macOS 的 getaddrinfo **只接受 /etc/services 里
# 注册过的服务名或端口**,不接受任意数字字符串:
#
#   $ getaddrinfo("", "26259")  ->  EAI_SERVICE (8) nodename nor servname provided
#   $ getaddrinfo("", "ssh")    ->  0 (OK)
#
# 实测证据(launchd 日志):
#   launchd[1]: [system/local.sshd-extra-port - Listeners:]
#               getaddrinfo(3): 8: nodename nor servname provided, or not known
#
# 表现就是:服务"已加载"、`launchctl print` 里能看到 sockets 段,但
# `error = 3`、端口永远不 LISTEN。而 /etc/services 属 SIP 保护,不该去改。
#
# ── 本脚本的做法 ─────────────────────────────────────────────────────────────
# 不碰 launchd 的 socket 激活,改为让 **sshd 自己去监听**:
#
#   /usr/sbin/sshd -D -p 26259 [-o ListenAddress=127.0.0.1]
#
# 由 launchd 负责保活(RunAtLoad + KeepAlive),sshd 以 -D 保持前台。
# 关键是把端口/地址写在**命令行**上,因为 /etc/ssh/sshd_config 里已有生效的
# `Port 22` 和 `ListenAddress 0.0.0.0`。按 man sshd:
#     "-p: Ports specified in the configuration file with the Port option are
#          ignored when a command-line port is specified."
#     "-o: Ports specified using the ListenAddress option override
#          command-line ports."
# 所以 `-p` 覆盖 config 的 Port、`-o ListenAddress=` 覆盖 config 的 ListenAddress。
# → 22 端口完全不受影响(仍由系统自带的 com.openssh.sshd 负责)。
#
# 注:sshd 的 `-p` 只接受**纯数字端口**,不支持 `host:port` 写法
#     (`sshd -p 127.0.0.1:26259` 会报 "Bad port number"),所以绑定地址必须
#     用 `-o ListenAddress=` 单独给。
#
# ── 用法 ─────────────────────────────────────────────────────────────────────
#   sudo bash macos-sshd-extra-port.sh install      # 安装并立即生效
#   sudo bash macos-sshd-extra-port.sh uninstall    # 关闭并删除
#        bash macos-sshd-extra-port.sh status       # 查看状态(不需要 sudo)
#        bash macos-sshd-extra-port.sh verify       # 验证端口真的能握手(不需要 sudo)
#        bash macos-sshd-extra-port.sh help
#
# 环境变量(注意:sudo 默认会丢弃非白名单环境变量,必须写在 sudo 后面):
#   SSHD_EXTRA_PORT=26259                 额外监听的端口
#   SSHD_EXTRA_BIND=127.0.0.1             只绑回环(更安全;留空=监听所有网卡)
#   SSHD_EXTRA_LABEL=local.sshd-extra-port launchd 服务标识
#
#   ✔ 正确:  sudo SSHD_EXTRA_BIND=127.0.0.1 bash macos-sshd-extra-port.sh install
#   ✘ 错误:  SSHD_EXTRA_BIND=127.0.0.1 sudo bash macos-sshd-extra-port.sh install
#            (变量只对 sudo 之前的 shell 生效,脚本里读不到)
#   也可以:  sudo -E bash ...   (保留环境,但会连带传递其它变量)
#
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

PORT="${SSHD_EXTRA_PORT:-26259}"
LABEL="${SSHD_EXTRA_LABEL:-local.sshd-extra-port}"
BIND_ADDR="${SSHD_EXTRA_BIND:-}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
META="/var/run/${LABEL}.conf"     # install 时落地的配置,供 status 回读
JOB="system/${LABEL}"
SSHD_BIN="/usr/sbin/sshd"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_BAK="/etc/ssh/sshd_config.bak-revtunnel"

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

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "该操作需要 root,请用: sudo bash $0 $*"
}

# 端口是否处于 LISTEN。
# [[:space:]] 收在端口后面,避免 :26259 误匹配到 :126259 这类端口。
port_listening() {
  netstat -an 2>/dev/null | grep -E "[.*:]$1[[:space:]].*LISTEN" >/dev/null 2>&1
}

# 抓一次 SSH banner,成功回显 banner,失败返回非 0
grab_banner() {
  local p="$1" banner=""
  exec 3<>"/dev/tcp/127.0.0.1/${p}" 2>/dev/null || return 1
  IFS= read -r -t 5 banner <&3 || true
  exec 3<&- 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  [[ -n "$banner" ]] || return 1
  printf '%s' "$banner"
}

# 回读已安装的配置,使 status 在非 root、未导出环境变量时也显示正确的端口/绑定
load_meta() {
  [[ -f "$META" ]] || return 1
  local line k v
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      PORT)  PORT="$v" ;;
      BIND)  BIND_ADDR="$v" ;;
      LABEL) LABEL="$v"; JOB="system/${LABEL}"; PLIST="/Library/LaunchDaemons/${LABEL}.plist" ;;
    esac
  done < "$META"
  return 0
}

# ---------------------------------------------------------------------------
# /etc/ssh/sshd_config 的 Port / ListenAddress 处理
# ---------------------------------------------------------------------------
# 为什么必须处理:
#   命令行 `-o ListenAddress=` 在 OpenSSH 里是**追加语义**,不是覆盖 —— 它排在
#   config 文件之后处理,所以 config 里那句 `ListenAddress 0.0.0.0` 会留下来,
#   结果是**同时监听 0.0.0.0 和 127.0.0.1**,端口被暴露到整个局域网。
#   实测(sshd -G,无需 host key):
#     sshd -G -f /etc/ssh/sshd_config -p 26259 -o ListenAddress=127.0.0.1
#       port 26259
#       listenaddress 127.0.0.1:26259
#       listenaddress 0.0.0.0:26259     ← 就是这里漏出去的
#   且端口取的是**后出现的** Port(命令行 -p),所以显示 26259 而非 22,极具迷惑性。
#
# 系统自带的 sshd 会不会受影响?不会。
#   /System/Library/LaunchDaemons/ssh.plist 用 launchd **socket 激活**
#   (Sockets.Listeners.SockServiceName = ssh),套接字由 launchd 建好再交给 sshd,
#   sshd_config 里的 Port / ListenAddress 在这种模式下**被忽略** —— 这也是
#   "改 macOS 的 Port 没效果" 的原因。所以注释掉这两行,22 端口行为不变。
#
# 因此本脚本在 install 时把这两行注释掉,让命令行参数成为唯一来源。

# 是否还有生效的 ListenAddress / Port 需要注释掉
sshd_config_needs_fix() {
  [[ -f "$SSHD_CONFIG" ]] || return 1
  grep -qE '^[[:space:]]*(ListenAddress|Port)[[:space:]]' "$SSHD_CONFIG"
}

# 注释掉这两行(先备份)。只在 install 时以 root 调用。
#
# 刻意不用 sed:BSD sed 的 -E 在替换文本含 "|" / 括号时报
# "RE error: parentheses not balanced",且一旦出错会把目标文件清空 ——
# 对 sshd_config 来说这是灾难性的。这里用 bash 逐行重写,语义明确。
fix_sshd_config() {
  if ! sshd_config_needs_fix; then
    ok "${SSHD_CONFIG} 无需改动(没有生效的 Port / ListenAddress)"
    return 0
  fi

  if [[ ! -f "$SSHD_CONFIG_BAK" ]]; then
    cp -p "$SSHD_CONFIG" "$SSHD_CONFIG_BAK"
    ok "已备份到 $SSHD_CONFIG_BAK"
  else
    note "备份已存在,保留原备份: $SSHD_CONFIG_BAK"
  fi

  local tmp="${SSHD_CONFIG}.tmp.$$"
  local marker="# 以下两行由 macos-sshd-extra-port.sh 注释:改用命令行 -p / -o ListenAddress"
  local marker_done=0 line trimmed
  shopt -s extglob

  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line##+([[:space:]])}"
    if [[ "$trimmed" == Port[[:space:]]* || "$trimmed" == ListenAddress[[:space:]]* ]]; then
      if (( ! marker_done )); then
        printf '%s\n' "$marker" >> "$tmp"
        marker_done=1
      fi
      printf '#%s\n' "$line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$SSHD_CONFIG"
  shopt -u extglob

  # 双保险:结果必须非空,且行数不能比原文件少
  local orig_lines new_lines
  orig_lines="$(wc -l < "$SSHD_CONFIG")"
  new_lines="$(wc -l < "$tmp")"
  if (( new_lines < orig_lines )); then
    rm -f "$tmp"
    die "重写后行数变少(${orig_lines} -> ${new_lines}),已放弃修改(原文件未动)"
  fi

  # 必须先用 sshd -t 校验,否则改坏了会导致 sshd 起不来
  if ! "$SSHD_BIN" -t -f "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "改动后的 sshd_config 校验失败,已放弃修改(原文件未动)"
  fi

  chmod 644 "$tmp"
  chown root:wheel "$tmp"
  mv -f "$tmp" "$SSHD_CONFIG"
  ok "已注释掉 ${SSHD_CONFIG} 中的 Port / ListenAddress(改由命令行指定)"
  info "还原方法: sudo cp -p ${SSHD_CONFIG_BAK} ${SSHD_CONFIG}"
}

# 打印 sshd 实际会监听什么(sshd -G 不需要 host key,非 root 也能跑)
sshd_effective_listeners() {
  local -a extra=()
  [[ -n "$BIND_ADDR" ]] && extra=(-o "ListenAddress=${BIND_ADDR}")
  "$SSHD_BIN" -G -f "$SSHD_CONFIG" -p "$PORT" "${extra[@]}" 2>/dev/null \
    | grep -iE '^(port|listenaddress)'
}

# ---------------------------------------------------------------------------
generate_plist() {
  local bind_arg=""
  if [[ -n "$BIND_ADDR" ]]; then
    bind_arg="    <string>-o</string>
    <string>ListenAddress=${BIND_ADDR}</string>"
  fi
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- 由 macos-sshd-extra-port.sh 生成:让 sshd 额外监听 ${PORT} -->
  <!-- 这里刻意不使用 launchd 的 socket 激活(Sockets/SockServiceName):
       macOS 的 getaddrinfo 不接受未在 /etc/services 注册的端口号,会导致
       sockets 创建失败(launchd error 3 / EAI_SERVICE 8)、端口永不 LISTEN。
       因此改为让 sshd 自己监听(-D -p)。 -->
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${SSHD_BIN}</string>
    <string>-D</string>
    <string>-p</string>
    <string>${PORT}</string>
${bind_arg}
  </array>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>

  <key>StandardErrorPath</key>
  <string>/dev/null</string>
  <key>POSIXSpawnType</key>
  <string>Interactive</string>
  <key>MaterializeDatalessFiles</key>
  <true/>
</dict>
</plist>
EOF
}

# ---------------------------------------------------------------------------
cmd_install() {
  require_root install

  [[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须是纯数字: ${PORT}"
  (( PORT >= 1 && PORT <= 65535 )) || die "端口超出范围(1-65535): ${PORT}"
  (( PORT != 22 )) || die "22 由系统自带的 sshd 负责,请换一个端口"

  # 用数组拼 -o ListenAddress=...,避免引号外展开把两个参数粘成一个
  local -a bind_o=()
  [[ -n "$BIND_ADDR" ]] && bind_o=(-o "ListenAddress=${BIND_ADDR}")

  [[ -x "$SSHD_BIN" ]] || die "找不到 ${SSHD_BIN}"
  command -v launchctl >/dev/null 2>&1 || die "找不到 launchctl(这不是 macOS?)"

  if port_listening "$PORT"; then
    die "端口 ${PORT} 已经在监听,请换一个: SSHD_EXTRA_PORT=<其它端口> sudo bash $0 install"
  fi
  if [[ -f "$PLIST" ]]; then
    warn "$PLIST 已存在,将覆盖重建"
    launchctl bootout "$JOB" >/dev/null 2>&1 || true
  fi

  # 关键:注释掉 sshd_config 里生效的 Port / ListenAddress。
  # 否则命令行 -o ListenAddress= 只是追加,config 的 0.0.0.0 会留下,
  # 端口被暴露到整个局域网(详见本函数上方注释)。
  fix_sshd_config

  # 校验 + 打印实际会监听的地址,装之前就把"漏到局域网"暴露出来
  if "$SSHD_BIN" -t -p "$PORT" "${bind_o[@]}" 2>/dev/null; then
    ok "sshd -t 配置校验通过"
  else
    warn "sshd -t 校验未通过,请检查 ${SSHD_CONFIG}(继续安装,但可能起不来)"
  fi
  printf '%s\n' "  sshd 实际将监听:"
  local listeners; listeners="$(sshd_effective_listeners)"
  printf '%s\n' "$listeners" | sed 's/^/    /'
  if grep -qiE 'listenaddress[[:space:]]+(0\.0\.0\.0|\*|\[::\])' <<<"$listeners"; then
    if [[ -n "$BIND_ADDR" ]]; then
      warn "仍有监听地址落在所有网卡上 —— 请检查 ${SSHD_CONFIG}"
    else
      note "监听在所有网卡(${SSHD_EXTRA_BIND:-未设置});如需只允许本机隧道回连,用 SSHD_EXTRA_BIND=127.0.0.1"
    fi
  fi

  info "生成 $PLIST (端口 ${PORT}${BIND_ADDR:+, 绑定 ${BIND_ADDR}})"
  local tmp="${PLIST}.tmp.$$"
  generate_plist > "$tmp"
  plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die "plist 语法校验失败"; }

  # launchd 拒绝加载权限不对的 plist:必须 root:wheel + 0644
  chown root:wheel "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$PLIST"
  ok "已写入 $PLIST"

  # 记录本次生效的配置,供 status 在非 root / 无环境变量时回读
  printf 'PORT=%s\nBIND=%s\nLABEL=%s\n' "$PORT" "$BIND_ADDR" "$LABEL" > "$META"
  chmod 644 "$META"
  ok "已记录配置 $META"

  launchctl bootout "$JOB" >/dev/null 2>&1 || true
  launchctl enable "$JOB" >/dev/null 2>&1 || true
  if ! launchctl bootstrap system "$PLIST" 2>/dev/null; then
    warn "bootstrap 失败,回退到旧式 load"
    launchctl load -w "$PLIST" || die "加载失败,请检查 plist 权限与内容"
  fi
  ok "已加载 launchd 服务 ${LABEL}"

  # 等它真的监听(最多约 5 秒)
  local i
  for i in 1 2 3 4 5; do
    port_listening "$PORT" && break
    sleep 1
  done

  printf '\n'
  cmd_status || true
  printf '\n'
  if port_listening "$PORT"; then
    info "完成:22 保持原样,${PORT} 已额外开放"
    info "验证握手: bash $0 verify"
    info "隧道侧配置: RT_LOCAL_PORT=${PORT} ./revtunnel.sh install"
  else
    warn "服务已加载,但 ${PORT} 仍未处于 LISTEN。排查:"
    warn "  launchctl print $JOB"
    warn "  log show --last 2m --predicate 'process == \"launchd\"' | grep -i ${LABEL}"
    warn "  ${SSHD_BIN} -D -p ${PORT}${BIND_ADDR:+ -o ListenAddress=${BIND_ADDR}}   # 手动前台跑,直接看报错"
    return 1
  fi
}

# ---------------------------------------------------------------------------
cmd_uninstall() {
  require_root uninstall
  load_meta >/dev/null 2>&1 || true
  if launchctl print "$JOB" >/dev/null 2>&1; then
    launchctl bootout "$JOB" >/dev/null 2>&1 || launchctl unload -w "$PLIST" >/dev/null 2>&1 || true
    ok "已停止服务 ${LABEL}"
  else
    note "服务未在运行"
  fi
  launchctl disable "$JOB" >/dev/null 2>&1 || true
  if [[ -f "$PLIST" ]]; then
    rm -f "$PLIST"
    ok "已删除 $PLIST"
  fi
  if [[ -f "$META" ]]; then
    rm -f "$META"
    ok "已删除 $META"
  fi

  sleep 1
  if port_listening "$PORT"; then
    warn "端口 ${PORT} 仍在监听 —— 可能有别的进程占用,执行: lsof -nP -iTCP:${PORT} -sTCP:LISTEN"
  else
    ok "端口 ${PORT} 已释放"
  fi
  info "系统自带的 22 端口未受影响"
}

# ---------------------------------------------------------------------------
cmd_status() {
  load_meta >/dev/null 2>&1 || true
  printf '%s===== sshd 额外端口状态 =====%s\n' "$C_DIM" "$C_OFF"
  printf '  端口    : %s\n  绑定    : %s\n  服务标识: %s\n' \
    "$PORT" "${BIND_ADDR:-(所有地址)}" "$LABEL"
  printf '  plist   : %s %s\n' "$PLIST" "$( [[ -f "$PLIST" ]] && echo '(存在)' || echo '(不存在)' )"
  printf '\n'

  # sshd_config 里是否还有会"追加"上来的 ListenAddress / Port
  if sshd_config_needs_fix; then
    warn "${SSHD_CONFIG} 里仍有生效的 Port / ListenAddress(会与命令行叠加,可能把端口暴露到局域网)"
    note "执行 'sudo bash $0 install' 会自动注释掉这两行(含备份与校验)"
    grep -nE '^[[:space:]]*(ListenAddress|Port)[[:space:]]' "$SSHD_CONFIG" | sed 's/^/    /'
  else
    ok "${SSHD_CONFIG} 无叠加的 Port / ListenAddress"
  fi

  if [[ -f "$PLIST" ]] && command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$PLIST" >/dev/null 2>&1; then ok "plist 语法正常"
    else bad "plist 语法异常"; fi
  fi

  if command -v launchctl >/dev/null 2>&1; then
    local dump state pid
    dump="$(launchctl print "$JOB" 2>/dev/null || true)"
    state="$(sed -n 's/^[[:space:]]*state = //p' <<<"$dump" | head -n1)"
    pid="$(sed -n 's/^[[:space:]]*pid = //p' <<<"$dump" | head -n1)"
    if [[ -n "$dump" ]]; then
      if [[ "$state" == "running" ]]; then ok "launchd 服务运行中 (pid=${pid:-?})"
      else bad "launchd 服务已加载但未运行 (state=${state:-unknown}) —— 见下方排查提示"; fi
    else
      bad "launchd 里没有 ${LABEL}"
    fi
  fi

  if port_listening "$PORT"; then ok "端口 ${PORT} 正在监听"
  else bad "端口 ${PORT} 未监听"; fi

  # 真实落到哪些地址?这才是"有没有暴露到局域网"的判据
  if port_listening "$PORT"; then
    local lan; lan="$(ipconfig getifaddr en0 2>/dev/null || true)"
    if [[ -n "$lan" ]] && nc -z -G 2 -w 2 "$lan" "$PORT" >/dev/null 2>&1; then
      bad "端口 ${PORT} 可从局域网访问(${lan}) —— 若只想给隧道回连用,应绑 127.0.0.1"
    elif [[ -n "$lan" ]]; then
      ok "端口 ${PORT} 不可从局域网访问(${lan} 连不上,仅回环)"
    fi
  fi

  if port_listening 22; then ok "系统 sshd 的 22 端口未受影响"
  else note "22 端口未监听(系统「远程登录」可能是关闭的)"; fi

  if ! port_listening "$PORT" && command -v launchctl >/dev/null 2>&1; then
    printf '\n%s--- 排查建议 ---%s\n' "$C_DIM" "$C_OFF"
    printf '  launchctl print %s\n' "$JOB"
    printf '  %s -D -p %s%s\n' "$SSHD_BIN" "$PORT" "${BIND_ADDR:+ -o ListenAddress=$BIND_ADDR}"
    printf '  log show --last 2m --predicate %s | grep -i %s\n' "'process == \"launchd\"'" "$LABEL"
  fi
}

# ---------------------------------------------------------------------------
cmd_verify() {
  load_meta >/dev/null 2>&1 || true
  printf '%s===== 握手验证 =====%s\n' "$C_DIM" "$C_OFF"
  local rc=0 b
  if b="$(grab_banner "$PORT")"; then
    ok "${PORT} 握手成功: ${b}"
  else
    bad "${PORT} 无法完成 SSH 握手"
    rc=1
  fi
  if b="$(grab_banner 22)"; then
    ok "22 仍正常: ${b}"
  else
    note "22 未响应(如果「远程登录」被关掉了,属预期)"
  fi
  return $rc
}

# ---------------------------------------------------------------------------
cmd_help() {
  cat <<EOF
macos-sshd-extra-port.sh —— 让 macOS 的 sshd 额外监听一个端口(默认 26259)

用法:
  sudo bash $0 install      安装 / 更新并立即生效(需要 sudo)
  sudo bash $0 uninstall    停止并删除(需要 sudo)
       bash $0 status       查看状态
       bash $0 verify       验证 SSH 握手
       bash $0 help         本帮助

原理:
  不复制 Apple 的 socket 激活方式:launchd 会用 SockServiceName 去调
  getaddrinfo,而 macOS 的 getaddrinfo 不接受未在 /etc/services 注册的端口号
  (报 EAI_SERVICE / launchd error 3),结果端口永远不 LISTEN。
  本脚本改为让 sshd 自己监听:
      /usr/sbin/sshd -D -p ${PORT} [-o ListenAddress=<绑定地址>]
  由 launchd 通过 RunAtLoad + KeepAlive 保活。22 由系统自带的
  com.openssh.sshd 负责,完全不受影响。

环境变量(必须写在 sudo 之后,否则会被 sudo 丢弃):
  SSHD_EXTRA_PORT=26259                 要额外开放的端口
  SSHD_EXTRA_BIND=127.0.0.1             只绑回环(只允许本机隧道回连,更安全)
  SSHD_EXTRA_LABEL=local.sshd-extra-port launchd 服务标识

示例:
  sudo SSHD_EXTRA_BIND=127.0.0.1 bash $0 install
  sudo SSHD_EXTRA_PORT=22222 bash $0 install
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    verify)    cmd_verify ;;
    help|-h|--help) cmd_help ;;
    *) err "未知子命令: $cmd"; echo; cmd_help; exit 2 ;;
  esac
}
main "$@"
