# server-init

Debian / Ubuntu 新服务器初始化脚本。单文件，可重复执行，所有修改前自动备份。

支持系统：Debian 12 / 13，Ubuntu 22.04 / 24.04 / 26.04 LTS（其他版本需 `FORCE=yes`）。

| 文件 | 说明 |
| --- | --- |
| `init.sh` | 主脚本 |
| `init.env.example` | 全部配置项及说明 |

## 功能

| 模块 | 内容 |
| --- | --- |
| UPDATE | `apt full-upgrade` + `autoremove`，自动等待 cloud-init 和 apt 锁 |
| BASELINE | 时区（默认 UTC）、systemd-timesyncd（已有 chrony 则保留）、journald 上限 500M |
| PACKAGES | 内存 ≥2G 且根分区可用 ≥10G 装标准包，否则装最小包 |
| USER | 创建用户、家目录 750、可选 sudo 组 / 免密 sudo（`visudo -c` 校验） |
| UFW | 入站默认拒绝；SSH 可设白名单；80/443 逐个询问；接管 Docker 发布的端口 |
| SSH | 公钥（GitHub 用户名或 https 链接拉取 / 粘贴 / 配置）、改端口、保活；**验证登录后**再禁 root、禁密码 |
| FAIL2BAN | sshd jail，systemd 日志后端，3 次失败封 24 小时，再犯时封禁时间递增，最长 4 周。白名单 IP 自动加入 ignoreip；**没有白名单时自己的 IP 也会被封**，不要在当前来源 IP 上做失败登录测试（解封：`fail2ban-client set sshd unbanip <IP>`） |
| DOCKER | 官方源安装 CE + compose 插件，日志轮转，live-restore，可选加入 docker 组 |
| SWAP | 按内存给出建议值，已有 swap 或在容器中运行时跳过，swappiness=10 |
| NET | BBR + fq，TCP 窗口按带宽 × 延迟计算。**默认关闭**，交互时单独询问 |
| SHELL_ENV | alias、彩色 PS1（显示退出码）、vim 配置（鼠标 + OSC52 复制） |

## 三种运行方式

配置优先级：**环境变量 > `--config` 本地文件 > `--config-url` 远程文件 > 交互输入 > 默认值**

### 1. 交互式（最常用）

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/init.sh -o init.sh
sudo bash init.sh
```

或直接用管道执行（交互输入走 `/dev/tty`，管道模式下也能正常提问）：

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/init.sh | sudo bash
```

开头会列出所有模块供你关闭、一次问完所有参数、展示执行计划，确认后一口气跑完。只有最后验证 SSH 登录时会再暂停一次。

### 2. 环境变量

`sudo` 默认会清空环境变量，所以变量要写在 `sudo` **后面**：

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/init.sh \
  | sudo NEW_USER=ops SSH_GITHUB_USERS=your-gh-name UFW_ALLOW_HTTPS=yes bash
```

没提供的参数仍会交互询问。要完全无人值守，加上 `NONINTERACTIVE=yes`。

### 3. 配置文件（本地或 GitHub）

```bash
cp init.env.example init.env && chmod 600 init.env && vim init.env
sudo bash init.sh --config init.env

# 远程配置 (只允许 https)
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/init.sh \
  | sudo bash -s -- --config-url https://raw.githubusercontent.com/<you>/<repo>/main/init.env
```

`SSH_GITHUB_USERS` 里除了 GitHub 用户名，也可以直接填 https 链接（内容为 authorized_keys 格式的公钥列表，例如 raw.githubusercontent.com 上的文件），两者可以混用。

配置文件只按 `KEY=VALUE` 解析，**不会被 `source` 执行**，也只接受白名单内的 key，远程配置无法注入命令。不要把明文密码放进公开仓库，改用 `USER_PASSWORD_HASH`（用 `openssl passwd -6` 生成）。

## SSH 安全切换流程

为避免把自己锁在门外，SSH 分两个阶段：

1. **过渡阶段**（自动）：写入 `/etc/ssh/sshd_config.d/00-server-init.conf`，新旧端口同时监听，开启公钥认证和保活（`ClientAliveInterval 60` / `ClientAliveCountMax 10`）；UFW 放行新端口（受白名单限制），旧端口临时对所有 IP 开放作为兜底。
2. **锁定阶段**（你确认后）：脚本暂停并打印登录命令。**不要关闭当前会话**，另开终端测试：
   ```bash
   ssh -p <新端口> <用户>@<服务器IP>
   ```
   ```bash
   sudo -v && echo SUDO_OK
   ```
   都正常后回到原会话输入 `yes`，脚本会禁止 root 登录、禁用密码 / keyboard-interactive 认证、只保留新端口，并删除 UFW 中的旧端口规则和收紧 fail2ban 的端口。

输入 `no` 或非交互模式（默认 `SSH_LOCKDOWN=no`）会保持过渡状态，之后补做：

```bash
sudo bash init.sh --ssh-lockdown
```

`--ssh-lockdown` 在没有终端的环境（如自动化）里会直接执行锁定，失败时以非 0 退出。

锁定前后脚本都会用 `sshd -T` 检查 sshd 实际生效的端口和认证选项；不一致（例如 `sshd_config` 里显式写了 `Port 22`，或 Include 之前有 `PasswordAuthentication yes`）会自动回滚并中止。其他配置文件里的 `Port` 指令会被注释掉，端口统一由 `/etc/ssh/sshd_config.d/00-server-init.conf` 管理。

锁定后重新执行并修改 `SSH_PORT`：认证保持仅公钥，新旧端口暂时同时监听，同样要验证新端口后再锁定。

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/init.sh | sudo bash -s -- --ssh-lockdown
```

注意事项：

- 文件名用 `00-` 前缀，是因为 sshd 对同一项**首次匹配生效**，这样能压过云厂商 `50-cloud-init.conf` 里的 `PasswordAuthentication yes`。
- Ubuntu 22.10+ 使用 `ssh.socket` 激活，脚本会自动执行 `daemon-reload` 并重启 socket，端口修改才能生效。
- 新的保活参数**只对新连接生效**，当前会话仍用旧配置。担心等待期间断线的话，可以在本地 `~/.ssh/config` 加 `ServerAliveInterval 30`，或在 tmux 里运行脚本。
- 云服务器还需要在**安全组**里放行新端口，脚本管不到这一层。
- 防锁死检查只看**当前会话**的来源 IP（`SSH_CONNECTION`，或沿父进程链找到本会话的 sshd 连接），不会把其他正在爆破的连接误当成自己。
- 重复执行时会按最新的 `SSH_ALLOW_IPS` 同步 UFW 规则：从"任意 IP"改为白名单会删掉任意来源的放行，白名单 IP 变化时删掉不再需要的旧规则。

## Docker 与 UFW

Docker 发布的端口（`-p 8080:80`）默认直接写 iptables，**会绕过 UFW**。脚本按 [ufw-docker](https://github.com/chaifeng/ufw-docker) 的方案在 `/etc/ufw/after.rules` 中加入 `DOCKER-USER` 规则，效果是：

- 容器端口默认**不对公网开放**；容器之间的通信、容器访问外网不受影响
- 私有网段（10/8、172.16/12、192.168/16）发起的访问放行
- 要对公网开放容器端口，用**容器内端口**（不是宿主机端口）：
  ```bash
  sudo ufw route allow proto tcp from any to any port 80
  ```

## 网络优化 (BBR + fq + TCP 窗口)

默认关闭，不在主模块列表里。交互运行时会单独列出一项，初始是 `[ ]`，输入 `1` 才执行，直接回车保持关闭。非交互要开就设 `ENABLE_NET=yes`。

窗口在**目标服务器上**算：填满一条连接需要的在途数据是带宽 × 延迟（BDP），和编写脚本的电脑无关。

`TCP_WINDOW_MAX=auto` 时：

```text
单连接缓冲上限 = 2 × 上行带宽 × RTT
```

取 2 倍是因为套接字缓冲里还有协议开销，缓冲要比线上的在途数据大，窗口才真能涨到一个 BDP。这是上限，不是预分配。内核仍按每条连接自己的带宽和延迟自动涨，最多涨到这个值。

| 输入 | 从哪来 |
| --- | --- |
| 带宽 | 默认路由那块网卡的 `/sys/class/net/<网卡>/speed`。读不到时交互里会问；非交互按 1Gbit，并在计划里写明。虚拟网卡常把限速套餐报成 10G，这时设 `TCP_BANDWIDTH=200Mbit` 这类值 |
| 延迟 | 默认 200ms，表示一条连接要能填满的跨区路径。当前 SSH 的 RTT 更高时改用实测。不 ping 公共 DNS：那些地址是就近的，测出来只有几毫秒，窗口会被算小 |
| 内存 | 只做封顶，不参与乘法。结果不超过这台机器内存的 1/4，且不超过 128M |

例如 1Gbit × 200ms × 2 是 50,000,000 字节，向上取整后为 48M。10Gbit × 200ms 会算出大约 477M，然后被 128M 或内存 1/4 封顶。客户端都在近处时把 `TCP_RTT_MS` 写成实际毫秒数，窗口会按比例变小。

不修改 `net.ipv4.tcp_mem`（全部 TCP 连接共享的内存上限，内核已经按内存算过）。

| 参数 | 值 | 原因 |
| --- | --- | --- |
| `net.ipv4.tcp_congestion_control` | `bbr` | 同时作用于 IPv6。只影响之后新建的连接 |
| `net.core.default_qdisc` | `fq` | BBR 的 pacing 要靠 fq。`fq_codel` 不认这个节奏 |
| `net.ipv4.tcp_rmem` / `tcp_wmem` | `4096 131072 <上限>` / `4096 16384 <上限>` | 只提高单连接上限。min / 初始值不动，避免每条连接一上来就占内存 |
| `net.core.rmem_max` / `wmem_max` | 与上面的上限相同 | `setsockopt` 的上限。自动调节看的是 `tcp_rmem` / `tcp_wmem` |
| `tcp_window_scaling` / `tcp_moderate_rcvbuf` | `1` | 否则窗口过不了 64K，接收缓冲也不会自动涨 |
| `tcp_mtu_probing` | `1` | 路径把 ICMP 丢掉时，BBR 不会卡在错误的 MTU 上 |
| `tcp_slow_start_after_idle` | `0` | 连接空闲后再传数据时，不把拥塞窗口打回慢启动 |
| `tcp_notsent_lowat` | `16384` | 窗口变大之后，限制本地还没发出去的数据，避免延迟堆高 |

当前处于 UP 的普通网卡会立刻换成 fq：多队列网卡只改子队列，不拆掉 mq；htb、cake 这类整形队列保持原样。容器网卡（veth、docker、bridge 等）不动。重启后新网卡按 `default_qdisc=fq` 创建。

内核没有 `tcp_bbr` 或当前环境写不了这些 sysctl（常见于容器）时，会警告并跳过对应项，不中断后面的模块。

## vim 复制说明

vim 配置为 `mouse=a` + OSC52：

- 鼠标可以点击定位、滚轮滚动、拖动选择进入 visual 模式
- 在 visual 模式下按 `y`，内容会通过 OSC52 发送到**本地剪贴板**（跨屏、不带行号，经过 SSH 也能用）。需要终端支持：iTerm2（在 Preferences → General → Selection 里勾选允许剪贴板访问）、WezTerm、Windows Terminal、kitty、Alacritty 等都支持。tmux 中需要 `set -g set-clipboard on`
- 按住 **Shift**（iTerm2 为 **Option**）拖动，仍然是终端原生的选择复制，和以前的用法一样
- `F2` 切换粘贴模式（vim 不支持 `pastetoggle` 时自动跳过）

全局模式下写入 `/etc/vim/vimrc.local`，并设置 `g:skip_defaults_vim=1`。这是因为 Debian 的 `defaults.vim` 在 `vimrc.local` **之后**加载，会覆盖我们的配置。

## 文件位置

| 路径 | 说明 |
| --- | --- |
| `/var/log/server-init.log` | 完整执行日志（600，不含密码） |
| `/etc/server-init/state.env` | 用户名、SSH 端口等状态，供 `--ssh-lockdown` 和重复执行使用 |
| `/etc/server-init/summary.txt` | 最近一次执行的摘要 |
| `/etc/server-init/bashrc.sh` | 共享 shell 配置，由各用户 `~/.bashrc` 末尾 source |
| `/etc/server-init/vimrc.vim` | 共享 vim 配置 |
| `/etc/sysctl.d/99-server-init.conf` | swappiness |
| `/etc/sysctl.d/99-server-init-net.conf` | BBR、fq、TCP 窗口 |
| `/etc/modules-load.d/server-init-net.conf` | 开机加载 `tcp_bbr`、`sch_fq`（内建则不写） |
| `/etc/ssh/sshd_config.d/00-server-init.conf` | SSH 配置 |
| `/etc/fail2ban/jail.d/server-init.local` | fail2ban 配置 |
| `/etc/sudoers.d/90-server-init-<user>` | 免密 sudo（仅启用时存在） |
| `*.bak.server-init.<时间戳>` | 被修改文件的备份 |

## 回滚

| 要回滚的内容 | 操作 |
| --- | --- |
| SSH | `rm /etc/ssh/sshd_config.d/00-server-init.conf && systemctl restart ssh`（Ubuntu 24.04+ 还要先 `systemctl daemon-reload`，并重启 `ssh.socket`） |
| UFW | `ufw disable`；如需去掉 Docker 规则，用 `/etc/ufw/after.rules.bak.server-init.*` 还原 |
| fail2ban | `rm /etc/fail2ban/jail.d/server-init.local && systemctl restart fail2ban` |
| swap | `swapoff /swapfile && rm /swapfile`，再删除 `/etc/fstab` 中对应的行 |
| 网络优化 | `rm /etc/sysctl.d/99-server-init-net.conf /etc/modules-load.d/server-init-net.conf && sysctl --system`。已改的网卡可 `tc qdisc replace dev <网卡> root fq_codel`，或重启 |
| Shell 环境 | 删除 `~/.bashrc` 和 `/etc/skel/.bashrc` 中 `>>> server-init >>>` 到 `<<< server-init <<<` 之间的块，再删除 `/etc/vim/vimrc.local` |
