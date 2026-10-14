# 经跳板机访问 Mac 上的 DeepSeek Harness Web

目标:让一台**无法直连 Mac** 的 Windows 客户端,经过中间的 Linux 跳板机,访问 Mac 上的 DSH web UI(`http://127.0.0.1:3080`)。

> 本文档已对公开仓库脱敏:真实 IP 用占位符表示,含义见下表。

---

## 1. 网络拓扑

```
Windows 客户端 ──路由器 a──▶ Linux 跳板机 B ──路由器 b──▶ Mac C
(无法直连 C)                 (公网可达)                    (NAT 后, 127.0.0.1:3080)
```

| 角色 | 占位符 | 本文所处环境 | 说明 |
|---|---|---|---|
| Windows 客户端 | `WIN` | `<WIN_HOSTNAME>` | 与 C **不同网段**,无法直连 C |
| Linux 跳板机 | `B` | `<JUMP_HOST>` | 公网可达;C 与 WIN 都能免密登录它 |
| Mac | `C` | `<MAC_LAN_IP>` | NAT 后;DSH web 只绑 `127.0.0.1:3080` |
| 路由器 a / b | — | — | 两级 NAT,导致 WIN 与 C 互不可见 |

> 公钥注释里的 `<WIN_USER>@<WIN_HOSTNAME>` 是**对端机器自己生成 key 时填的注释**,用 `ssh-keygen -lf` 就能看到,可用来识别"这条授权属于哪台机器"。

**已具备的免密登录关系**:

- `WIN -> B` ✅(本文方案的唯一硬前提)
- `C -> B` ✅(revtunnel 的既有能力,也是下面「方法二」的基础)
- `B -> C` ✅(revtunnel 建立的反向隧道)
- `WIN -> C` ⚠️ **取决于 C 的 `authorized_keys` 是否含 WIN 的公钥**(方法一需要)

---

## 2. 三个关键事实(决定了方案怎么写)

### 2.1 DSH web 只绑回环

```
$ lsof -nP -iTCP:3080 -sTCP:LISTEN
node ... TCP 127.0.0.1:3080 (LISTEN)
```

它**不在** `0.0.0.0` 上监听,所以局域网/公网都够不到,必须靠 SSH 隧道。

### 2.2 DSH web 有 token 认证,不是裸奔

```
$ curl -s http://127.0.0.1:3080/
dsh web authentication required; reopen the URL printed by dsh web.
```

登录凭据是 `dsh web` 启动时打印在 URL 上的 token(见 §5)。

### 2.3 ⚠️ 为什么「直接 `-L` 转发到 3080」行不通

这是最容易踩的坑。`ssh -L` 的**最后一跳是由跳板机发起的**,而 C 的 3080 只绑在自己的回环上 —— 跳板机够不到它。

实测(在 C 上模拟 WIN 经 B 转发到 C 的 3080):

```
$ ssh -N -L 14082:127.0.0.1:12222 -J B C &
$ curl -v http://127.0.0.1:14082/
* Connected to 127.0.0.1 port 14082
> GET / HTTP/1.1
* Received HTTP/0.9 when not allowed      ← 对手方只是 C 的 sshd,不是 DSH web
* Closing connection
```

`Received HTTP/0.9 when not allowed` 就是这个坑的典型症状:**你以为转到了 3080,其实转到了 C 的 sshd(22 / 26259)**。

**结论:必须补一个「最后一跳在 C 上发起」的环节。** 下面两个方法各是一种补法。

---

## 3. 方法一(推荐先试):经 B 一跳直达 C

前提:C 的 `authorized_keys` 里有 WIN 的公钥。检查方法(在 C 上):

```bash
ssh-keygen -lf ~/.ssh/authorized_keys
# 期望能看到一条来自 WIN 的公钥,例如:
# 3072 SHA256:SFcpYV... jalen <WIN_USER>@<WIN_HOSTNAME>
```

### 3.1 WIN 上的 `%USERPROFILE%\.ssh\config`

```
Host dsh-jump
    HostName <JUMP_HOST>
    User <JUMP_USER>
    Port 22
    ServerAliveInterval 30
    ServerAliveCountMax 3

Host dsh-mac
    HostName 127.0.0.1
    Port 12222
    User <MAC_USER>
```

> `dsh-mac` 的 `Port 12222` **必须写进 config** —— `-J` 之后的最终目标端口只能从配置读,不能内联在命令行里。

### 3.2 起隧道(一条命令)

```powershell
ssh -N -L 3080:127.0.0.1:3080 -J dsh-jump dsh-mac
```

链路:`WIN:3080` → B → C 的 sshd → **最后一跳在 C 上** → C 的 `127.0.0.1:3080`。

### 3.3 验证

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:3080/
```

期望 **401**。拿到 401 就说明链路已通,只差 token(§5)。

---

## 4. 方法二(兜底,只依赖 `WIN -> B`)

原理:让 **C 主动**在 B 上开一道回环门,于是最后一跳由 C 发起。WIN 只需经 B 转发到 B 自己的回环端口,不需要对 C 有任何凭据。

```
WIN:3080 ──-L──▶ B 的 127.0.0.1:13080 ──反向隧道(最后一跳在 C 上)──▶ C 的 127.0.0.1:3080
```

这道门已由 C 上的常驻服务 [`dsh-web-tunnel.sh`](./dsh-web-tunnel.sh) 挂好:

```bash
./dsh-web-tunnel.sh status      # 含「从 B 侧真实探测」的结果
#   ✔ launchd 服务运行中
#   ✔ 本机 3080 正在监听
#   ✔ 跳板机上 127.0.0.1:13080 可达 DSH web(HTTP 401,401 = 只差 token)
```

### 4.1 起隧道(一条命令)

```powershell
ssh -N -L 3080:127.0.0.1:13080 <JUMP_USER>@<JUMP_HOST> -p 22
```

或复用 §3.1 的 config:

```powershell
ssh -N -L 3080:127.0.0.1:13080 -J dsh-jump dsh-jump
```

### 4.2 验证

同 §3.3,期望 **401**。

---

## 5. 取 token 并打开

1. **在 C 上**启动(或查看已在运行的)`dsh web`,它会打印一行:

   ```
   http://127.0.0.1:3080/?token=<一长串>
   ```

2. **在 WIN 的浏览器**里把这一行**原样**粘贴打开。

要点:

- token 随 `dsh web` 重启而更换,旧 URL 立即失效。
- **访问地址必须是 `127.0.0.1:3080`**,不能改用跳板机 IP 或 C 的局域网 IP —— DSH 的信任栅栏只放行 loopback(详见 §8)。
- 若本地 3080 被占用,可换成别的本地端口,但**浏览器地址要跟着改**(回环地址不看端口,仍然可用):

  ```powershell
  ssh -N -L 3081:127.0.0.1:13080 <JUMP_USER>@<JUMP_HOST> -p 22
  # 浏览器打开 http://127.0.0.1:3081/?token=...
  ```

---

## 6. C 侧的常驻服务(不需要手工干预)

| launchd 服务 | 作用 | 端口 |
|---|---|---|
| `com.jalen.revtunnel` | C ↔ B 的 SSH 反向隧道(B 能回连 C) | B 上 `127.0.0.1:12222` |
| `com.jalen.dsh-tunnel` | C → B 的 3080 反向门(服务方法二) | B 上 `127.0.0.1:13080` |

两者都是 `RunAtLoad` + `KeepAlive`,**开机自启、掉线自愈**。

```bash
# 查看/管理
./revtunnel.sh status
./dsh-web-tunnel.sh status
./dsh-web-tunnel.sh attach      # 打印客户端侧该怎么连
./dsh-web-tunnel.sh uninstall   # 临时关掉那道门
```

> 注意:`dsh-tunnel` 的日志里出现一次
> `Error: remote port forwarding failed for listen port 13080`
> 是**正常现象** —— 重启瞬间 B 上的旧端口还没释放,`ExitOnForwardFailure=yes` 让 ssh 立即退出,launchd 在 `ThrottleInterval`(10s)后重试即可。这与 revtunnel 的行为一致。

---

## 7. 两个方法怎么选

| | 方法一(一跳直达) | 方法二(经 B 上的门) |
|---|---|---|
| 命令数 | 1 条 | 1 条 |
| 依赖 | `WIN->B` **且** `WIN->C` | 仅 `WIN->B` |
| C 侧改动 | 无 | 需要 `dsh-tunnel` 服务(已装) |
| 建议 | **先试** | 方法一 `Permission denied` 时用它 |

---

## 8. 为什么不能用 IP 直接访问(栅栏实验)

DSH web 对每个请求做 authority 校验:只信任 loopback(`localhost`、`[::1]`、整个 `127/8`,**不看端口**)与显式声明的 `trustedHosts`。实测:

| `Host` 头 | 结果 |
|---|---|
| `127.0.0.1:3080` | ✅ 401(放行到认证层) |
| `127.0.0.1:13080` | ✅ 401(换端口也放行) |
| `localhost:13080` | ✅ 401 |
| `<MAC_LAN_IP>:13080` | ❌ 403(栅栏拒绝) |

所以隧道两端的地址都保持 `127.0.0.1` 时,Host 头天然对齐,cookie 的 authority 也不会错位。

若确实想用 IP 直连(例如让 B 上的其他人直接访问),必须让 C 这样启动:

```bash
dsh web --host 127.0.0.1 --port 3080 --trusted-host <B_IP>:13080
```

不推荐 —— 多一个端口要记,且扩大了可访问面。

---

## 9. 故障排查

| 症状 | 原因 / 处理 |
|---|---|
| `Received HTTP/0.9 when not allowed` | **用了 `-L` 转发到只有 sshd 的端口**。说明最后一跳没落在 C 上 → 改用 §3 或 §4 |
| `channel 2: open failed: connect failed: Connection refused` | 被转发的目标端口没人监听。①B 上 `12222` 没了 → C 上 `./revtunnel.sh status`;②B 上 `13080` 没了 → `./dsh-web-tunnel.sh status` |
| `Permission denied (publickey,password)` | 方法一里 `WIN->C` 的密钥没生效 → 换方法二;或把 WIN 的公钥加进 C 的 `authorized_keys` |
| 浏览器 **401** | URL 没带 `?token=`,或 token 已过期(`dsh web` 重启过)→ 重新从 C 取 |
| 浏览器 **403** | 访问的不是 loopback 地址 → 改成 `http://127.0.0.1:3080/...` |
| 本地 3080 被占用 | 换本地端口,并同步改访问 URL(见 §5) |
| 连接几分钟后断 | 确认 config 里有 `ServerAliveInterval 30` / `ServerAliveCountMax 3`(本文已含) |
| C 重启后不通 | 检查 C 是否处于**图形登录**状态 —— 两个服务都是用户级 LaunchAgent,停在登录界面不会启动 |
| `-J … :port` 报错 | 老版本 OpenSSH 的 `-J` 不接受内联端口 → 把端口写进 config 的 `Port`(本文已这样做) |

排错三连:

```powershell
# WIN 侧
ssh -v -N -L 3080:127.0.0.1:13080 <JUMP_USER>@<JUMP_HOST> -p 22
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:3080/
```

```bash
# C 侧
./revtunnel.sh status
./dsh-web-tunnel.sh status
```

---

## 10. 安全提醒

- **DSH harness 等于 C 上的远程代码执行**。能打开那个 UI 的人就能读写你的文件、执行命令。
- **`-L` 永远只绑本地回环**:`-L 3080:127.0.0.1:3080` 是对的;写成 `-L 0.0.0.0:3080:...` 会让同网段所有人进入你的 harness。
- **B 上的两道门都只绑 `127.0.0.1`**(`GatewayPorts` 默认 `no`),B 之外的机器即使扫到也连不上 —— 没有扩大暴露面。
- **token 就是密码**,别贴进聊天记录、别提交进 git;`dsh web` 重启即更换。
- 整条链路是**双层 SSH 加密**(WIN→B、B→C),中间无明文。
- 建议给隧道用**专用密钥**,别与日常运维密钥混用。

---

## 11. 写给脚本作者

如果你的场景与本文不同,只需替换上表的三个角色,方法本身通用:

- **跳板机必须公网可达**,且客户端能免密登录它。
- **被访问的服务只绑回环** → 必须补一个「最后一跳在被访问机器上」的环节(`-J` 直达,或在被访问机器上开反向门)。
- **被访问机器在 NAT 后** → 反向门/隧道必须由它主动发起。

C 侧两个脚本可直接复用(均可用环境变量改目标):

- [`revtunnel.sh`](./revtunnel.sh) —— 通用反向隧道(launchd 自愈 + TCC 副本机制)
- [`dsh-web-tunnel.sh`](./dsh-web-tunnel.sh) —— 把本机某个回环端口暴露到跳板机(`DSH_PORT` / `DSH_REMOTE_PORT` / `DSH_TUNNEL_HOST` / `DSH_TUNNEL_PORT` / `DSH_TUNNEL_USER`)

---

## 12. 验证记录

实测环境:C 为 macOS(OpenSSH 9.9p2),B 为 Ubuntu 跳板机(OpenSSH 8.2p1)。

| 测试项 | 结果 |
|---|---|
| DSH web 监听与认证 | ✅ `127.0.0.1:3080`,匿名访问返回 401 + `authentication required` |
| `-L` 直接转发到 3080(错误做法) | ❌ `Received HTTP/0.9 when not allowed`(已作为 §2.3 的反例记录) |
| 从 B 的回环访问 `13080` | ✅ `HTTP 401` + `dsh web authentication required` → **证明最后一跳落在 C 上** |
| 信任栅栏 Host 实验 | ✅ loopback(任意端口)放行;非局域网/非 loopback 地址 403 |
| `dsh-tunnel` 服务自愈 | ✅ 端口冲突时先退出,`ThrottleInterval` 后自动重试成功 |
| `revtunnel` 服务自愈 | ✅ `kill -9` 隧道进程后 1 秒内自动拉起,链路自动恢复 |
| 方法一的 `-J … :port` 语法 | ✅ 语法有效(实测建立到 B 的跳板连接);`WIN->C` 的最终认证取决于 C 的 `authorized_keys` |
