# Server A 腾讯云从零实操文档

> Server A = 腾讯云国内服务器。  
> 它负责入口、Caddy、管理面板、WireGuard 网关，以及把流量转到 Server B。  
> 这份文档按“第一次接触服务器也能照着做”的方式写。不要一口气复制整篇，每次只复制一个代码块。

## 0. 先把这些信息填在纸上

先不要开终端，先把下面这些信息准备好。

| 名称 | 你要填什么 | 示例 |
| --- | --- | --- |
| Server A 公网 IP | 腾讯云实例的公网 IPv4 | `1.2.3.4` |
| Server A 初始 SSH 用户 | 腾讯云 Ubuntu 通常是 `ubuntu`，不是 `root` | `ubuntu` |
| Server A 初始登录方式 | 腾讯云控制台给你的密码或密钥 | 不要写进文档 |
| Server A 新 SSH 端口 | 建议先固定一个，不要随机 | `22222` |
| Server B 公网 IP | 海外 VPS 的公网 IPv4 | `8.8.8.8` |
| 仓库地址 | 这个项目的 Git 地址 | `https://github.com/ZRainbow1275/bifrost.git` |
| 你的本机 | 你现在操作的 Windows 电脑 | PowerShell |

文档里的 `<SERVER_A_IP>` 要替换成 Server A 的公网 IP。  
文档里的 `<SERVER_A_LOGIN_USER>` 默认先写 `ubuntu`。  
文档里的 `<SERVER_B_IP>` 要替换成 Server B 的公网 IP。  
仓库地址已经写成你的远端仓库：`https://github.com/ZRainbow1275/bifrost.git`。
输入命令时不要保留尖括号。

如果你现在的 Server A 上已经有一个“初步仓库”，比如 `/opt/bifrost` 已存在，但还没有同步到最新远端版本，不要把它当成完全空白机器重新 clone。
这时要先走“已有旧 checkout”的更新路径：先看 `git status --short --branch`，再用 `bash ./install.sh --github-hosts-repair` 和 `git pull --ff-only` 把它拉到最新。

## 1. 在你的 Windows 电脑上准备 SSH key

先在 Windows 上打开 PowerShell。

打开方法：

1. 按键盘 `Win`
2. 输入 `PowerShell`
3. 点开 `Windows PowerShell`

先创建一把专门给服务器登录用的 SSH key：

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -C "bifrost-root"
```

它会问你：

```text
Enter passphrase
```

新手测试阶段可以直接按回车两次，表示暂时不设置 key 密码。  
如果你已经熟悉 SSH，也可以设置一个 passphrase。

看一下公钥内容：

```powershell
type "$env:USERPROFILE\.ssh\bifrost_root_ed25519.pub"
```

你会看到一长行，类似：

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... bifrost-root
```

后面脚本让你粘贴 SSH 公钥时，就粘贴这一整行。

## 2. 在腾讯云控制台先放行端口

先在腾讯云网页控制台操作，不是在服务器里操作。

进入路径大概是：

1. 腾讯云控制台
2. 云服务器 CVM
3. 找到 Server A 实例
4. 点它绑定的安全组
5. 入站规则

至少先放行这些端口：

| 协议 | 端口 | 来源 | 用途 |
| --- | --- | --- | --- |
| TCP | `22` | 你的公网 IP | 第一次登录 |
| TCP | `22222` | 你的公网 IP | 加固后的 SSH |
| TCP | `80` | `0.0.0.0/0` | 申请证书 / HTTP |
| TCP | `443` | `0.0.0.0/0` | HTTPS 入口 |
| UDP | `51820` | `0.0.0.0/0` | WireGuard |

如果你不知道自己的公网 IP，可以在浏览器打开：

```text
https://ipinfo.io/ip
```

如果你暂时不知道怎么限制来源，可以先用 `0.0.0.0/0` 测通，跑通后再收紧。  
但 SSH 端口长期不建议对全网开放。

## 3. 第一次用 SSH 连上 Server A

回到 Windows PowerShell。

腾讯云 Ubuntu 镜像一般不给 root 密码，默认登录用户通常是 `ubuntu`。  
所以第一次先这样连：

```powershell
ssh ubuntu@<SERVER_A_IP>
```

如果你的腾讯云镜像明确写的是其他用户，就把 `ubuntu` 换成控制台显示的用户名。  
如果你用的是密钥登录，还需要加 `-i`，例如：

```powershell
ssh -i "$env:USERPROFILE\.ssh\你的腾讯云密钥文件" ubuntu@<SERVER_A_IP>
```

第一次连接会问：

```text
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

输入：

```text
yes
```

然后输入腾讯云服务器密码。  
注意：你输入密码时屏幕不会显示星号，这是正常的。

登录成功后，你会看到类似：

```text
ubuntu@VM-xxx:~$
```

这表示你现在已经在 Server A 里面了。

这个项目的安装脚本需要 root 权限。  
所以登录进去后，先切到 root：

```bash
sudo -i
```

如果它问密码，就输入腾讯云给 `ubuntu` 用户的密码。  
成功后提示符会变成类似：

```text
root@VM-xxx:~#
```

从这里开始，后面的服务器命令都在这个 root 窗口里执行。

## 4. 在 Server A 上安装基础工具并拉项目

下面命令是在 Server A 的 SSH 窗口里执行，不是在 Windows PowerShell 里执行。

先确认系统：

```bash
cat /etc/os-release
```

如果是 Ubuntu / Debian，执行：

```bash
apt update
apt install -y git curl ca-certificates
```

如果是 Rocky / AlmaLinux / CentOS，执行：

```bash
dnf install -y git curl ca-certificates
```

然后先尝试从 GitHub 拉项目：

```bash
git clone https://github.com/ZRainbow1275/bifrost.git /opt/bifrost
cd /opt/bifrost
git status --short --branch
```

新版仓库已经自带脚本可执行权限。不要再执行 `chmod +x install.sh scripts/*.sh`，否则旧版本仓库会把很多脚本标成 `M`，干扰后面的 `git pull` 判断。

截至 `2026-05-21` 的实测结果：腾讯云到 GitHub 可能一会儿能通、一会儿又断，不稳定。
如果上面这三行已经成功，就直接跳到“确认你已经在项目目录里”。
如果 `git clone` 或后面的 `git pull --ff-only` 出现 `GnuTLS recv error (-110)`，不要反复重试，直接按下面的 hosts 或本机上传兜底方案处理。

如果这里出现类似下面的错误：

```text
fatal: unable to access 'https://github.com/ZRainbow1275/bifrost.git/': GnuTLS recv error (-110): The TLS connection was non-properly terminated.
```

不要继续反复 `git clone`。这通常不是仓库地址错，而是腾讯云到 GitHub 的 TLS 连接被中途断开。

先试 `/etc/hosts` 方案。
如果还是失败，再用后面的“本机打包上传”方案。

### 4.1 腾讯云拉不动 GitHub 时：先修改 /etc/hosts

这个方案就是你截图里的思路：手动告诉服务器 `github.com` 和 `raw.githubusercontent.com` 应该访问哪个 IP。
本项目已经内置了自动修复脚本。它不会乱删 `/etc/hosts`，只会维护一段 `BIFROST-GITHUB-HOSTS` 托管块，并且会先备份原文件。

如果 `/opt/bifrost` 目录已经存在，而且里面已经有最新脚本，先在 Server A 执行：

```bash
cd /opt/bifrost
git status --short --branch
./install.sh --github-hosts-repair
git pull --ff-only
```

如果这里报 `Permission denied`，不要先去改整棵仓库的权限，直接换成：

```bash
bash ./install.sh --github-hosts-repair
```

这通常表示你当前还是旧 checkout，`install.sh` 还没有可执行位。等后面 `git pull` 到最新版本后，再回到正常的 `./install.sh ...` 形式即可。

这条命令会自动做五件事：

1. 通过 DNS-over-HTTPS 查询 `github.com` 和 `raw.githubusercontent.com` 当前可用的 IPv4。
2. 备份 `/etc/hosts`，备份文件名类似 `/etc/hosts.bifrost-github.20260521-170000.bak`。
3. 写入 Bifrost 自己的 hosts 托管块。
4. 用 `git ls-remote https://github.com/ZRainbow1275/bifrost.git main` 验证 GitHub 是否真的能访问。
5. 如果当前解析到多个 GitHub 候选 IP，脚本会自动逐个尝试，不再只卡死在第一个 IP 上。

如果你用的是旧 checkout，脚本停在下面这一行很久不动：

```text
Verifying GitHub access: git ls-remote --heads https://github.com/ZRainbow1275/bifrost.git main
```

先按 `Ctrl+C` 退出。然后用旧脚本的跳过验证模式，只修 `/etc/hosts`，不要让旧脚本继续卡在 `git ls-remote`：

```bash
cd /opt/bifrost
BIFROST_GITHUB_HOSTS_SKIP_GIT_CHECK=1 bash ./install.sh --github-hosts-repair
timeout 20s git ls-remote --heads https://github.com/ZRainbow1275/bifrost.git main
echo "git-check-exit=$?"
```

这里要看最后一行退出码：

- `git-check-exit=0`，并且上面出现 `refs/heads/main`，说明 GitHub 已经能连上，可以继续 `git pull --ff-only`。
- `git-check-exit=124`，说明 20 秒超时，先不要继续 `git pull`。
- 其他非 `0` 数字，说明 GitHub 连接还是失败，先不要继续 `git pull`。

如果这条 `timeout 20s git ls-remote ...` 失败或超时，把从 `timeout 20s ...` 到 `git-check-exit=...` 的完整输出贴出来。新版脚本已经给 Git 验证加了超时，拉到新版后不会再无限卡住。

如果你已经确认是 `git-check-exit=124`，就执行下面这段候选 IP 轮询脚本。它会逐个改 `/etc/hosts`，每次最多等 20 秒，直到找到一个能访问 GitHub 的组合，然后自动执行 `git pull --ff-only`：

```bash
sudo -i
cd /opt/bifrost

cat > /tmp/bifrost-github-hosts-try.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: this script must run as root. Run: sudo bash /tmp/bifrost-github-hosts-try.sh"
  exit 1
fi

repo="https://github.com/ZRainbow1275/bifrost.git"

github_ips=(
  20.205.243.166
  140.82.112.4
  140.82.113.4
  140.82.114.4
  140.82.121.4
  140.82.112.3
)

raw_ips=(
  185.199.108.133
  185.199.109.133
  185.199.110.133
  185.199.111.133
)

for github_ip in "${github_ips[@]}"; do
  for raw_ip in "${raw_ips[@]}"; do
    echo
    echo ">>> Trying github.com=${github_ip}, raw.githubusercontent.com=${raw_ip}"

    BIFROST_GITHUB_HOSTS_RESOLVE_MODE=static \
    BIFROST_GITHUB_IP="${github_ip}" \
    BIFROST_RAW_GITHUB_IP="${raw_ip}" \
    BIFROST_GITHUB_HOSTS_SKIP_GIT_CHECK=1 \
      bash ./install.sh --github-hosts-repair

    getent hosts github.com
    getent hosts raw.githubusercontent.com

    if timeout 20s git ls-remote --heads "${repo}" main; then
      echo
      echo "SUCCESS: GitHub access works with github.com=${github_ip}, raw.githubusercontent.com=${raw_ip}"
      timeout 60s git -c http.version=HTTP/1.1 -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 pull --ff-only
      pull_exit=$?
      echo "pull-exit=${pull_exit}"
      exit "${pull_exit}"
    fi

    echo "FAILED: this pair did not work, trying next..."
  done
done

echo
echo "ERROR: no candidate pair worked. Paste this output back."
exit 1
EOF

bash /tmp/bifrost-github-hosts-try.sh
```

看到 `SUCCESS: GitHub access works ...` 只说明这一组 hosts 能连上 GitHub。脚本随后会继续执行 `git pull --ff-only`，并打印 `pull-exit=...`，这里一定要看最后的退出码：

- `pull-exit=0`：代码已经拉到最新，可以继续下面的检查。
- `pull-exit=124`：`git pull` 等了 60 秒仍然卡住，先不要反复重试，把从 `SUCCESS` 开始到 `pull-exit=124` 的输出贴出来。
- 其他非 `0` 数字：`git pull` 失败，把完整错误输出贴出来。

如果脚本执行成功，再确认当前代码版本：

```bash
git status --short --branch
git log --oneline -8
```

如果这里报的是 `fatal: unable to access 'https://github.com/...': SSL connection timeout`，说明前面的 `ls-remote` 只证明 GitHub 能返回引用信息，但真正拉对象时 HTTPS 传输还是太慢。先不要反复重试，改用下面这个更稳的命令再试一次：

```bash
timeout 60s git -c http.version=HTTP/1.1 -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 pull --ff-only
echo "pull-exit=$?"
```

如果 `pull-exit=124`，说明 60 秒内还是没拉完，先把这条报错贴回来，不要继续硬等。

如果这里直接出现下面这种输出：

```text
2026-05-22 14:50:33 [ERROR] 未知参数: --github-hosts-repair
```

这不是你输错了，而是服务器上的项目代码还太旧，还没有这个命令。
不要在旧版本里继续找这个参数。先按下面的“引导修复命令”把 GitHub hosts 修好，再把代码 `git pull --ff-only` 到最新版本，然后再回来执行 `./install.sh --github-hosts-repair`。

#### 4.1.1 已经有 `/opt/bifrost`，但旧代码还没有 `--github-hosts-repair`

如果你现在卡在这里：

```text
root@VM-0-16-ubuntu:/opt/bifrost# git pull --ff-only
fatal: unable to access 'https://github.com/ZRainbow1275/bifrost.git/': GnuTLS recv error (-110): The TLS connection was non-properly terminated.
```

并且你的服务器上已经有 `/opt/bifrost` 目录，但执行下面命令又提示没有 `--github-hosts-repair`：

```bash
cd /opt/bifrost
./install.sh --github-hosts-repair
```

那说明服务器上的项目代码太旧，还没包含自动修复脚本。
这种情况下，先用下面这段“引导修复命令”把 GitHub hosts 修好，再 `git pull` 拉到最新版本。

在 Server A 的 SSH 窗口里执行：

```bash
sudo -i
cd /opt/bifrost

GITHUB_IP="$(curl -4fsSL 'https://dns.alidns.com/resolve?name=github.com&type=A' | grep -Eo '"data"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.){3}[0-9]{1,3}"' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
RAW_GITHUB_IP="$(curl -4fsSL 'https://dns.alidns.com/resolve?name=raw.githubusercontent.com&type=A' | grep -Eo '"data"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.){3}[0-9]{1,3}"' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"

printf 'github.com -> %s\nraw.githubusercontent.com -> %s\n' "$GITHUB_IP" "$RAW_GITHUB_IP"
test -n "$GITHUB_IP"
test -n "$RAW_GITHUB_IP"

cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d-%H%M%S)"
sed -i '/# BIFROST-GITHUB-HOSTS-BEGIN/,/# BIFROST-GITHUB-HOSTS-END/d; /[[:space:]]github\.com$/d; /[[:space:]]raw\.githubusercontent\.com$/d' /etc/hosts
printf '\n# BIFROST-GITHUB-HOSTS-BEGIN\n%s github.com\n%s raw.githubusercontent.com\n# BIFROST-GITHUB-HOSTS-END\n' "$GITHUB_IP" "$RAW_GITHUB_IP" >> /etc/hosts

getent hosts github.com
getent hosts raw.githubusercontent.com

git pull --ff-only
git status --short --branch
./install.sh --github-hosts-repair
```

最后一行 `./install.sh --github-hosts-repair` 是拉到最新代码之后再跑一次项目内置脚本，让它接管后续维护，并验证 `https://github.com/ZRainbow1275/bifrost.git` 是否真的能访问。

如果这段执行成功，以后再遇到 `git pull` 的 `GnuTLS recv error (-110)`，就不用再复制这段长命令了，直接执行：

```bash
cd /opt/bifrost
./install.sh --github-hosts-repair
git pull --ff-only
```

#### 4.1.2 `git pull` 已经能联网，但被本地改动卡住

如果你已经把 GitHub hosts 修好了，`git pull --ff-only` 也开始能连上远端了，但又出现下面这种报错：

```text
error: Your local changes to the following files would be overwritten by merge:
        install.sh
        scripts/security.sh
Please commit your changes or stash them before you merge.
Aborting
```

这表示不是网络问题，而是这台服务器本地已经改过代码。
这里不要直接删文件，也不要上来就 `git reset --hard`。先把现场备份下来，再临时收起来，然后再拉最新代码。

在 Server A 的 SSH 窗口里按这个顺序做：

```bash
sudo -i
cd /opt/bifrost

git status --short

backup_dir="/root/bifrost-local-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
cp install.sh scripts/security.sh "$backup_dir"/
git diff -- install.sh scripts/security.sh > "$backup_dir/local-changes.diff"

git stash push -m "bifrost local changes before pull" -- install.sh scripts/security.sh
git pull --ff-only

git status --short --branch
./install.sh --github-hosts-repair
```

这段命令的意思是：

1. `git status --short` 先看看到底是哪两个文件被改了。
2. `cp ...` 和 `git diff ...` 先把现场留一份备份。
3. `git stash push ...` 先把本地改动暂存起来，避免 `git pull` 被卡住。
4. `git pull --ff-only` 拉最新代码。
5. 拉完后再跑新的 `./install.sh --github-hosts-repair`，让项目内置脚本接管后续 hosts 修复。

如果你后面想看那份本地改动，备份都在：

```bash
/root/bifrost-local-backup/
```

如果 `git status --short --branch` 看到一大串下面这种 `M scripts/*.sh`：

```text
 M install.sh
 M scripts/security.sh
 M scripts/server-a.sh
 M scripts/server-b.sh
```

并且你前面执行过 `chmod +x install.sh scripts/*.sh`，这通常只是“文件权限变化”，不是代码内容真的被你改了。
如果还看到 `M configs/sysctl/hardening.conf`，这是旧版安全脚本曾把运行时 sysctl 配置反写回项目目录造成的；新版脚本已经修掉这个行为。

为了不丢现场，先备份 diff，再恢复这些仓库文件到 Git 版本：

```bash
cd /opt/bifrost

backup_dir="/root/bifrost-local-backup/$(date +%Y%m%d-%H%M%S)-dirty-tree"
mkdir -p "$backup_dir"
git diff > "$backup_dir/all-local-changes.diff"

git restore -- configs/sysctl/hardening.conf install.sh scripts/*.sh
git pull --ff-only
./install.sh --github-hosts-repair
```

这段命令不会删除 `/etc/hosts`、`/etc/ssh/sshd_config`、`/etc/sysctl.d/` 这些真正的系统配置；它只把 `/opt/bifrost` 仓库里的文件恢复成远端版本。

#### 4.1.3 第一次 `git clone` 就失败，服务器上还没有 `/opt/bifrost`

如果你现在的 Server A 项目目录还没有这个新脚本，或者 `git clone` 第一次就失败导致 `/opt/bifrost` 还不存在，就按下面的手动方式做一次。
注意：截图里的 IP 只是当时可用，不一定永远可用。你要先查最新 IP，再写进服务器。

先在你的 Windows 浏览器里打开：

```text
https://www.ipaddress.com/
```

在网站里分别查询这两个域名：

```text
github.com
raw.githubusercontent.com
```

你会查到类似这样的 IPv4 地址：

```text
140.82.112.4 github.com
185.199.108.133 raw.githubusercontent.com
```

上面只是示例。你实际操作时，以你当场查到的结果为准。

回到 Server A 的 SSH 窗口，确认你已经是 root：

```bash
whoami
```

如果输出不是 `root`，先执行：

```bash
sudo -i
```

然后执行下面命令。
它会让你输入两次 IP，把你刚才查到的 IP 粘贴进去：

```bash
read -rp "请输入 github.com 的 IPv4: " GITHUB_IP
read -rp "请输入 raw.githubusercontent.com 的 IPv4: " RAW_GITHUB_IP

cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d-%H%M%S)"
sed -i '/# BIFROST-GITHUB-HOSTS-BEGIN/,/# BIFROST-GITHUB-HOSTS-END/d; /[[:space:]]github\.com$/d; /[[:space:]]raw\.githubusercontent\.com$/d' /etc/hosts
printf '\n# BIFROST-GITHUB-HOSTS-BEGIN\n%s github.com\n%s raw.githubusercontent.com\n# BIFROST-GITHUB-HOSTS-END\n' "$GITHUB_IP" "$RAW_GITHUB_IP" >> /etc/hosts
getent hosts github.com
getent hosts raw.githubusercontent.com
```

确认 `getent hosts` 能显示你刚写进去的 IP 后，再重新拉项目：

```bash
rm -rf /opt/bifrost
git clone https://github.com/ZRainbow1275/bifrost.git /opt/bifrost
cd /opt/bifrost
git status --short --branch
```

如果这次成功，继续往下做。
如果还是同样的 `GnuTLS recv error (-110)`，不要在这里卡住，直接走下一节的本机上传方案。

后续如果你已经有 `/opt/bifrost`，只是执行 `git pull --ff-only` 失败，优先回到本节开头执行：

```bash
cd /opt/bifrost
./install.sh --github-hosts-repair
git pull --ff-only
```

如果当前服务器上的项目代码太旧，没有 `--github-hosts-repair` 这个命令，或者脚本修复后还是拉不动，再走下一节的本机上传方案。
本机上传会用你 Windows 上的最新项目包覆盖服务器上的 `/opt/bifrost`，效果等同于把服务器代码更新到本机当前版本。

### 4.2 腾讯云改 hosts 后仍然拉不动：从 Windows 本机上传项目

这一步分成两边做。

先在你的 Windows PowerShell 里执行。这里假设你的本机项目目录是：

```text
D:\Desktop\CREATOR FIVE
```

执行：

```powershell
cd "D:\Desktop\CREATOR FIVE"
git archive --format=tar.gz -o "$env:USERPROFILE\Desktop\bifrost-main.tar.gz" HEAD
scp "$env:USERPROFILE\Desktop\bifrost-main.tar.gz" ubuntu@<SERVER_A_IP>:/tmp/bifrost-main.tar.gz
```

如果你的腾讯云第一次登录本来就是密钥登录，`scp` 也要加 `-i`，例如：

```powershell
scp -i "$env:USERPROFILE\.ssh\你的腾讯云密钥文件" "$env:USERPROFILE\Desktop\bifrost-main.tar.gz" ubuntu@<SERVER_A_IP>:/tmp/bifrost-main.tar.gz
```

上传完成后，回到 Server A 的 SSH 窗口。
确认你已经是 root，如果不是，先执行：

```bash
sudo -i
```

然后在 Server A 上执行：

```bash
rm -rf /opt/bifrost
mkdir -p /opt/bifrost
tar -xzf /tmp/bifrost-main.tar.gz -C /opt/bifrost
cd /opt/bifrost
git status --short --branch
```

确认你已经在项目目录里：

```bash
pwd
ls
```

`pwd` 应该输出：

```text
/opt/bifrost
```

`ls` 应该能看到：

```text
install.sh
scripts
bifrost-api
bifrost-api-web
```

## 5. 在 Server A 上先做云审查

先执行：

```bash
cd /opt/bifrost
./install.sh --cloud-review
```

这一步只检查，不会删除腾讯云监控、安全代理或云初始化组件。

如果看到 Tencent、qcloud、agent、monitoring 之类提示，不要慌。  
它的意思是：脚本发现这台机器可能有腾讯云组件，需要你知道它们存在。  
这些组件可能负责云监控、控制台救援、密钥注入、审计或备份。

新手阶段不要手动删除这些东西。  
我们先跑项目，不先破坏云厂商的救援链路。

## 6. 在 Server A 上做 SSH 加固

还在 Server A 里执行：

```bash
cd /opt/bifrost
./install.sh --security
```

脚本会问 SSH 端口。  
这里不要用随机默认值，输入你前面在腾讯云安全组放行过的端口：

```text
22222
```

脚本会让你粘贴 SSH 公钥。  
回到 Windows PowerShell 执行：

```powershell
type "$env:USERPROFILE\.ssh\bifrost_root_ed25519.pub"
```

复制输出的整行，粘贴到服务器脚本里。

注意：当前项目的安全脚本默认把这把公钥写进 `/root/.ssh/authorized_keys`。  
所以第一次是 `ubuntu` 登录，但加固后的运维登录会改成 `root + SSH key`。

这一轮加固的目标是：服务器不再识别密码登录，只接受 SSH 公钥登录。
脚本会把 SSH 配置改成下面这种效果：

```text
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PubkeyAuthentication yes
PermitRootLogin prohibit-password
```

脚本完成后，不要关闭当前 SSH 窗口。

重新打开一个新的 Windows PowerShell，测试新端口登录：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_A_IP>
```

如果新窗口能登录成功，再回到旧 SSH 窗口执行：

```bash
touch /tmp/ssh-port-change-confirmed
```

这一步很重要。  
脚本有 5 分钟自动回滚保护，如果你不确认，它可能会把 SSH 配置回滚。

确认后，在 Server A 的 SSH 窗口里检查一次实际生效配置：

```bash
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|authenticationmethods|pubkeyauthentication|permitrootlogin) '
```

你应该看到类似：

```text
passwordauthentication no
kbdinteractiveauthentication no
authenticationmethods publickey
pubkeyauthentication yes
permitrootlogin prohibit-password
```

再做一个反向验证：新开 Windows PowerShell，强制不用密钥、只尝试密码登录：

```powershell
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -p 22222 root@<SERVER_A_IP>
```

这条命令应该登录失败。
如果它还能让你用密码登录成功，立刻停下，不要继续后面的部署。

从现在开始，连接 Server A 都用：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_A_IP>
```

如果这条 `root@<SERVER_A_IP>` 测试失败，但旧的 `ubuntu` 窗口还开着，不要关闭旧窗口。  
先停下来排查，不要继续关密码登录后的操作。

## 7. 先在 Server A 上部署 WireGuard

Server B 后面要通过 WireGuard 接进来。  
所以 A 必须先把 VPN 网关建出来。

在 Server A 里执行：

```bash
cd /opt/bifrost
./install.sh --vpn
```

如果脚本问你选择 VPN 类型，第一次测试优先选择最普通的 WireGuard / standalone WireGuard。  
如果它没有问，按脚本默认继续。

完成后，给 Server B 创建一个 WireGuard 配置：

```bash
cd /opt/bifrost
bash scripts/vpn.sh create_user server-b
```

看一下配置文件是否生成：

```bash
ls -l /etc/bifrost/vpn/users/server-b/
```

你应该能看到：

```text
wg-server-b.conf
```

把这个文件下载到你的 Windows 桌面。  
在 Windows PowerShell 里执行，不是在服务器里执行：

```powershell
scp -P 22222 -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" root@<SERVER_A_IP>:/etc/bifrost/vpn/users/server-b/wg-server-b.conf "$env:USERPROFILE\Desktop\wg-server-b.conf"
```

确认桌面上出现了：

```text
wg-server-b.conf
```

做到这里，Server A 先暂停。  
现在去执行 `FROM_ZERO_SERVER_B_RUNBOOK.md`，把 Server B 做到 `wg0` 已经起来，并且分发栈已经启用。

## 8. Server B 做完后，回到 Server A 跑主部署

当 Server B 已经完成这些事情后，再回到这里：

- Server B 能 SSH 登录
- Server B 已经跑过 `./install.sh --server-b`
- Server B 的 `/root/ai-gateway-connection.txt` 已经生成
- Server B 已经导入 `wg-server-b.conf`
- Server B 上 `wg0` 已经是 active
- Server B 已经跑过 `scripts/server-b.sh --enable-distribution`

先从 Server B 文档里拿到这些值：

| A 端脚本会问什么 | 从 B 的哪个字段复制 |
| --- | --- |
| Server B IP address | `SERVER_IP` |
| Server B port | `LISTEN_PORT` |
| UUID | `UUID` |
| Reality public key | `PUBLIC_KEY` |
| SNI / Server name | `SNI` |
| Short ID | `SHORT_ID` |

然后在 Server A 里执行：

```bash
cd /opt/bifrost
export BIFROST_SERVER_A_TLS_MODE=ip
export BIFROST_SERVER_A_PUBLIC_IP=<SERVER_A_IP>
export BIFROST_ACME_EMAIL=<你的邮箱>
export BIFROST_SERVER_B_WG_IP=10.8.0.2
export BIFROST_SERVER_A_NEWAPI_MODE=distribution
export BIFROST_SKIP_DEPRECATION_WAIT=1
./install.sh --server-a
```

如果脚本问 Server B 信息，就按上表从 `/root/ai-gateway-connection.txt` 里复制。

如果脚本再次问 SSH 端口，继续填：

```text
22222
```

如果脚本问是否部署 VPN，而你已经在第 7 步部署过，可以选 `n`。  
如果你不确定，也可以选 `y`，但不要删除已有的 `server-b` 用户配置。

## 9. 部署 Bifrost API 管理平台

当前脚本有一个现实限制：`./install.sh --bifrost-api` 会先检查 Server A 本机 `127.0.0.1:3000` 是否能访问 NewAPI。  
但 distribution 模式下 NewAPI 在 Server B 的 `10.8.0.2:3000`。

所以第一次实操测试时，先在 A 上做一个本机转发：

```bash
apt install -y socat
nohup socat TCP-LISTEN:3000,bind=127.0.0.1,fork,reuseaddr TCP:10.8.0.2:3000 >/var/log/bifrost-newapi-forward.log 2>&1 &
curl -fsS http://127.0.0.1:3000/api/status
```

如果你的 Server A 不是 Ubuntu / Debian，而是 Rocky / AlmaLinux / CentOS，把第一行换成：

```bash
dnf install -y socat
```

如果最后一行能输出 NewAPI 状态，再执行：

```bash
cd /opt/bifrost
./install.sh --bifrost-api
```

脚本完成时会打印：

```text
Admin Key: xxxxx
```

把这个 `Admin Key` 复制保存到你自己的密码管理器或临时记事本。  
后面访问管理接口要用 `X-Admin-Key`。

## 10. 部署前端面板

先确认 Node 和 pnpm：

```bash
node --version
pnpm --version
```

面板需要：

- Node `>=20`
- pnpm `>=9`

如果没有 Node/pnpm，先安装。Ubuntu 常见做法：

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
npm install -g pnpm
```

然后构建并部署面板：

```bash
cd /opt/bifrost
pnpm -C bifrost-api-web install --frozen-lockfile
pnpm -C bifrost-api-web build
./install.sh --deploy-panel
```

确认面板文件已经放好：

```bash
test -f /var/www/bifrost-api-web/dist/index.html && echo "panel ok"
```

## 11. Server A 最小验收

在 Server A 上执行：

```bash
systemctl is-active caddy
systemctl is-active netdata
curl -fsS http://127.0.0.1:19999/api/v1/info | head
curl -fsS http://127.0.0.1:8000/health
```

如果你已经有域名，比如 `panel.example.com`，再在你的 Windows PowerShell 里测试：

```powershell
curl.exe -I https://panel.example.com/
```

如果还没有域名，先不要卡在域名这一步，先用上面的本机检查确认服务活着。

## 12. Server A 常见错误

### 连接不上 SSH

先检查你是不是还在用旧端口：

```powershell
ssh ubuntu@<SERVER_A_IP>
```

加固后应该用：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_A_IP>
```

如果还不行，去腾讯云安全组确认 `22222` 是否放行。

### `--cloud-review` 发现腾讯云 agent

这是正常的。  
它只是提示你机器上有云厂商组件，不代表失败。  
新手测试不要直接删除。

### `--bifrost-api` 提示 NewAPI 不可用

先确认 A 能访问 B 的 NewAPI：

```bash
curl -fsS http://10.8.0.2:3000/api/status
```

再确认 A 本机 3000 转发是否存在：

```bash
curl -fsS http://127.0.0.1:3000/api/status
```

如果第二条失败，重新执行第 9 步的 `socat` 转发。
