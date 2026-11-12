# 通过 curl 直接运行 init.sh

脚本已为 `curl | bash` 做好设计（整个逻辑包在 `main()` 里、交互输入走 `/dev/tty`），仓库已推送到 GitHub，raw 地址可以直接访问。不需要 git，也不需要先 apt 装任何东西。

## 最常用：交互式一条命令

```bash
curl -fsSL https://raw.githubusercontent.com/LeifRowan/script/main/init.sh | sudo bash
```

会先列出模块让你勾选、一次问完参数、展示执行计划后再跑。管道占用了 stdin，但脚本的提问都读写 `/dev/tty`，所以能正常交互。

## 带参数：变量要写在 `sudo` 后面

sudo 默认清空环境变量，写在前面会丢。

```bash
curl -fsSL https://raw.githubusercontent.com/LeifRowan/script/main/init.sh \
  | sudo NEW_USER=ops SSH_GITHUB_USERS=LeifRowan UFW_ALLOW_HTTPS=yes bash
```

仓库里已经提交了 `keys/comk` 这个公钥文件，也可以直接用它的 raw 链接作为公钥来源：

```bash
curl -fsSL https://raw.githubusercontent.com/LeifRowan/script/main/init.sh \
  | sudo NEW_USER=ops \
         SSH_GITHUB_USERS=https://raw.githubusercontent.com/LeifRowan/script/main/keys/comk \
         bash
```

## 完全无人值守

加 `NONINTERACTIVE=yes`，没给的参数全部用默认值。注意默认 `SSH_LOCKDOWN=no`，所以不会禁 root 和密码登录，之后登上去补一句 `--ssh-lockdown`：

```bash
curl -fsSL https://raw.githubusercontent.com/LeifRowan/script/main/init.sh \
  | sudo NONINTERACTIVE=yes NEW_USER=ops SSH_GITHUB_USERS=LeifRowan bash

# 验证新端口能登录后再执行
curl -fsSL https://raw.githubusercontent.com/LeifRowan/script/main/init.sh | sudo bash -s -- --ssh-lockdown
```

## 用远程配置文件

脚本参数要通过 `bash -s --` 传进去，否则 bash 会把参数当成脚本文件名：

```bash
curl -fsSL https://raw.githubusercontent.com/LeifRowan/script/main/init.sh \
  | sudo bash -s -- --config-url https://raw.githubusercontent.com/LeifRowan/script/main/init.env
```

不过 `init.env` 目前在 `.gitignore` 里没有提交，公开仓库也不该放明文密码。要走这条路的话，复制一份只含非敏感项的配置提交上去，密码用 `USER_PASSWORD_HASH`（`openssl passwd -6` 生成）。

## 补充

- **机器上没有 curl 时**用 wget 替换：`wget -qO- <url> | sudo bash`。Debian 和 Ubuntu 的云镜像一般两者都带。
- **raw.githubusercontent.com 有 CDN 缓存**，刚 push 完几分钟内可能拉到旧版本。要保证最新可以用 commit hash 替换 `main`，比如 `.../LeifRowan/script/e8ad053/init.sh`。
