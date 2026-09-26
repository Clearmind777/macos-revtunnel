链路已实测打通。下面是完整方案。

## 先确认的既有事实(我实测的)

```
Windows ──ssh──▶ A(172.16.134.43:2233) ──▶ A 的 127.0.0.1:12222 ──隧道──▶ Mac sshd:26259
                                                                              │
                                                              Mac 的 DSH web:127.0.0.1:3080(只绑回环 + token 认证)
```

| 检查项 | 结果 |
|---|---|
| Windows→A | 需要你确认可达(`PasswordAuthentication yes`,可用密码) |
| A→Mac | ✅ 密钥免密已通(隧道那条 `ssh -p 12222`) |
| Mac 的 DSH web | ✅ `127.0.0.1:3080`,返回 `401` 表示**有认证**,不是裸奔 |
| Mac sshd 接受 | ✅ `publickey` + `password` + `keyboard-interactive`(三种都能用) |
| Mac `authorized_keys` | 只有 1 把 key:`ssh-rsa ... zjl@dell-70DGA02ACN`(即 A 的公钥) |
| A 的转发设置 | 全默认:`AllowTcpForwarding yes`、`GatewayPorts no` |
| A 需要配什么吗 | **完全不用改** |

关键机制(决定了端口怎么选):DSH web 的 session cookie **绑定请求的 `Host` 头**,而信任栅栏只认 `localhost`、`[::1]`、整个 `127/8`(不看端口)。我实测过:

| Host 头 | 结果 |
|---|---|
| `127.0.0.1:3080` / `127.0.0.1:13080` / `localhost:13080` | ✅ 401(放行到认证层) |
| `192.168.3.135:13080` | ❌ 403(栅栏拒绝) |

**所以隧道必须用 `127.0.0.1`,不能用局域网 IP。** 下面方案 A 让 Windows 本地端口也叫 3080,这样 authority 与 DSH 自己的完全一致,最省事。

---

## 方案 A(推荐):Windows 侧一条 ssh 命令

### 第 1 步:在 Windows 上确认有 OpenSSH

Win10 1809+ / Win11 自带。PowerShell 里:

```powershell
ssh -V
```

没有的话:「设置 → 应用 → 可选功能 → 添加功能 → OpenSSH 客户端」。

### 第 2 步:先让 Windows 能免密登 A(可选但强烈建议)

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_ed25519
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh -p 2233 zjl@172.16.134.43 "cat >> ~/.ssh/authorized_keys"
```

会被问一次 A 的密码,之后就不用再输了。不想配也行,每次手输 A 的密码。

### 第 3 步:建 SSH 配置(一次写好,以后只敲 `ssh mac`)

```powershell
notepad $env:USERPROFILE\.ssh\config
```

粘贴:

```
Host mac
    HostName 127.0.0.1
    Port 12222
    User jalen
    IdentityFile ~/.ssh/id_ed25519

Host mac-jump
    HostName 172.16.134.43
    Port 2233
    User zjl
```

> ⚠️ **必须这样写,不能图省事用 `ssh -J zjl@172.16.134.43:2233`** —— OpenSSH 的 `-J` **不接受内联端口**,那是常见踩坑点。

### 第 4 步:起隧道(这条命令要一直开着)

```powershell
ssh -N -L 3080:127.0.0.1:3080 -J mac-jump mac
```

解释:`-J mac-jump` 先连 A,再从 A 连 Mac;`-L 3080:127.0.0.1:3080` 在 **Windows 本地**开 3080,把流量送到 **Mac 的** `127.0.0.1:3080`。

### 第 5 步:在 Mac 上取带 token 的 URL

Mac 上启动 `dsh web`(或看它已在跑的窗口),它会打印一行形如:

```
http://127.0.0.1:3080/?token=<一长串>
```

**把整行连同 `?token=...` 复制出来。** 这就是你需要的登录凭据(401 那句提示"reopen the URL printed by dsh web"正是这个意思)。

### 第 6 步:Windows 浏览器打开

把刚复制的 URL **原样**粘贴到 Windows 浏览器。url 里是 `127.0.0.1:3080`,与本机隧道端口一致,所以 Host 头、cookie 的 authority 全部对得上,能正常登录。

### 顺便:文件传输也走同一条

```powershell
scp -o ProxyJump=mac-jump D:\some\file.txt mac:/tmp/
```

---

## 方案 B(可选增强):让 Mac 主动开个通道给 A

如果你希望**Windows 上完全不用敲 ssh**(只要 A→Windows 可达),可以让 Mac 再开一个反向门,Windows 直接连 A:

```bash
# 在 Mac 上
ssh -N -R 13080:127.0.0.1:3080 zjl@172.16.134.43 -p 2233
```

然后 Windows 上只需 `ssh -N -L 3080:127.0.0.1:13080 -p 2233 zjl@172.16.134.43`,但**代价**是 Mac 上的 DSH 必须带 `--trusted-host` 启动:

```bash
dsh web --host 127.0.0.1 --port 3080 --trusted-host 127.0.0.1:13080
```

因为这种情况下 authority 会是 `127.0.0.1:13080`,超出 DSH 自己认为的 authority,需要显式声明。多一个参数、多一个端口要记 —— **所以我推荐方案 A**。

---

## ⚠️ 安全提醒

- **DSH harness 等于 Mac 上的远程代码执行**。能打开那个 GUI 的人就能读写你的文件、跑命令。
- **隧道必须绑回环**(上面 `-L 3080:...` 默认就是只绑 Windows 本地),**不要**改成 `-L 0.0.0.0:3080`,否则同网段的人都能进你的 harness。
- **token 就是密码**。别丢进聊天记录、别提交进 git;DSH 每次重启会换新 token,旧 URL 自动失效。
- 整条链路是**双层 SSH 加密**(Windows→A、A→Mac),中间没有明文。
- 保持方案 A 的好处:**3080 始终只绑在 Mac 回环上**,局域网完全看不到它(这点我已验证:局域网 IP 访问是 403)。

## 故障排查

| 症状 | 原因 / 处理 |
|---|---|
| `channel 2: open failed: connect failed: Connection refused` | **Mac 侧隧道断了**,A 上 12222 没人监听。到 Mac 上跑 `./revtunnel.sh status` |
| Windows 上连接被拒 / 超时 | 检查 A 是否可达:`Test-NetConnection 172.16.134.43 -Port 2233` |
| SSH 连上但 `Permission denied (publickey,password...)` | Windows 的密钥不在 Mac 的 `authorized_keys` 里 → 加公钥,或直接输 Mac 登录密码 |
| 浏览器 401 | URL 里没带 `?token=...`,或 token 已过期(DSH 重启过)→ 重新从 Mac 上取 |
| 浏览器 403 | Host 头不是 loopback → 确认访问的是 `127.0.0.1`,不是 `192.168.x.x` |
| 连接几分钟后断 | 建议在 Windows 的 `Host mac` 里加 `ServerAliveInterval 30` / `ServerAliveCountMax 3` |

---

## 有两点需要你确认

1. **Windows 能直接访问 172.16.134.43:2233 吗?**(这是前提,我在这台 Mac 上无法探测你的 Windows)
2. **要不要我把方案 B 的 Mac 侧做成常驻服务?** 这样 Mac 一登录就自动开好到 A 的 13080 通道,不用你每次手动跑 —— 我可以照 `macos-sshd-extra-port.sh` 的路子写一个 `dsh-web-tunnel` 的 launchd 脚本,带保活和自愈。

另外提醒:目前那个 `sudo SSHD_EXTRA_BIND=127.0.0.1 bash macos-sshd-extra-port.sh install`(**收紧 26259 只绑回环**)你还没跑,26259 现在仍暴露在局域网上。这个和上面 Windows 方案互相独立,建议一并做掉。