# Linux 弹性伸缩开机脚本

适用于 Ubuntu、Debian、CentOS、Rocky Linux 和 AlmaLinux。

本项目用于制作云主机镜像。它在原主机安装一套开机控制和只读 rsync 环境；使用该镜像创建的新机器开机后，会自动识别自己不是原主机，从原主机取得最新的 `/srv/ess-boot/run.sh`，然后执行其中的业务命令。项目自身生成的文件统一保存在 `/srv/ess-boot/`。

## 能解决什么问题

- 制作镜像前不需要反复修改或注释 `rc.local`。
- 同一镜像可同时用于原主机和弹性伸缩实例。
- 原主机重启时不会误执行伸缩实例的业务任务。
- 伸缩实例每次开机都会取得原主机最新的业务脚本。
- Ubuntu 网卡启动较慢时会自动等待，不会因为暂时没有 IP 立即失败。
- Docker、CNI、Veth 等虚拟网卡不会参与原主机判断。
- rsync 中断时不会破坏本机已有的 `run.sh`。
- Ubuntu 和 CentOS 使用同一个安装脚本。
- 所有控制脚本和业务脚本的输出统一保存到独立日志。

## 整体架构

```text
                    原主机
                       │
           install.sh 安装和生成配置
                       │
       ┌───────────────┼────────────────┐
       │               │                │
 /srv/ess-boot/boot.sh     /srv/ess-boot/run.sh      rsync只读服务
  开机控制脚本      业务脚本          TCP 873
       │                                │
       │ 随镜像复制                     │ 提供最新run.sh和文件
       ▼                                │
               弹性伸缩实例             │
                       │                │
                /etc/rc.local           │
                       │                │
                /srv/ess-boot/boot.sh ───────────┘
                       │ rsync同步
                       ▼
                 /srv/ess-boot/run.sh
                       │
                       ▼
                 执行业务任务
```

## 文件及作用

| 文件 | 作用 |
|---|---|
| `install.sh` | 一次性安装入口，识别系统、安装缺少的软件包、记录原主机 IP、配置 rsync 和 `rc.local`。 |
| `/srv/ess-boot/boot.sh` | 开机控制脚本。等待网络、判断机器身份、安全同步并执行 `run.sh`。由 `install.sh` 自动生成。 |
| `/srv/ess-boot/run.sh` | 用户维护的业务脚本。填写伸缩实例开机后真正需要执行的命令。 |
| `/srv/ess-boot/rsync-test.sh` | 安装时用于验证 rsync 下载及文件内容的测试脚本。 |
| `/etc/rc.local` | Ubuntu/Debian 的开机入口。仅在缺少调用时追加 `boot.sh`。 |
| `/etc/rc.d/rc.local` | CentOS/Rocky/AlmaLinux 的开机入口。 |
| `/etc/rsyncd.conf` | 原主机 rsync 服务配置。模块名固定为 `ess_sync`，只读映射根目录 `/`。 |
| `/srv/ess-boot/client.pwd` | 伸缩实例连接原主机 rsync 服务使用的令牌，权限为 `600`。 |
| `/srv/ess-boot/server.secret` | 原主机 rsync 服务端认证文件，权限为 `600`。 |
| `/srv/ess-boot/boot.log` | 独立开机日志，记录 `boot.sh` 和 `run.sh` 的标准输出与错误。 |

## 安装

### 一键下载安装

```bash
curl -fsSL https://raw.githubusercontent.com/trowar/ESS-boot/main/install.sh -o install.sh && chmod +x install.sh && sudo ./install.sh
```

使用 root 用户时可以执行：

```bash
curl -fsSL https://raw.githubusercontent.com/trowar/ESS-boot/main/install.sh -o /root/install.sh && chmod 700 /root/install.sh && /root/install.sh
```

### 本地安装

在准备制作镜像的原主机上执行：

```bash
chmod +x install.sh
./install.sh
```

也支持：

```bash
sh install.sh
```

脚本检测到当前解释器不是 Bash 时会自动切换到 `/bin/bash`。

安装完成后编辑业务脚本：

```bash
vi /srv/ess-boot/run.sh
```

## 开机调用逻辑

```text
/etc/rc.local
  └─ 后台调用 /srv/ess-boot/boot.sh
       ├─ 检查所需命令
       ├─ 等待真实网卡取得 IPv4
       ├─ 排除 Docker、CNI、Veth、VPN 等虚拟接口
       ├─ 获取当前机器全部真实 IPv4
       ├─ 与安装时记录的原主机 IP 逐一比较
       │
       ├─ 任意 IP 相同：判定为原主机
       │    └─ 写入日志并退出，不同步、不执行 run.sh
       │
       └─ 所有 IP 不同：判定为伸缩实例
            ├─ 使用原主机第一个真实 IP 作为 RSYNC_IP
            ├─ 从原主机下载 /srv/ess-boot/run.sh 到临时文件
            ├─ 失败时每隔 10 秒重试，最多 12 次
            ├─ 下载完整后设置执行权限
            ├─ 原子替换本机 /srv/ess-boot/run.sh
            ├─ 导出 RSYNC_IP
            └─ 执行 /srv/ess-boot/run.sh
```

`rc.local` 中追加的命令：

```bash
/bin/bash /srv/ess-boot/boot.sh >> /srv/ess-boot/boot.log 2>&1 &
```

`boot.sh` 同步业务脚本的命令：

```bash
rsync -az --timeout=60 --contimeout=15 --password-file=/srv/ess-boot/client.pwd root@${RSYNC_IP}::ess_sync/srv/ess-boot/run.sh /srv/ess-boot/run.sh.tmp
```

同步成功后：

```bash
export RSYNC_IP
exec /bin/bash /srv/ess-boot/run.sh
```

`exec` 让 `run.sh` 接管当前进程，因此 `run.sh` 的输出和错误会继续进入 `/srv/ess-boot/boot.log`，不需要在 `run.sh` 内重复设置日志。

## 安全更新 run.sh

`boot.sh` 不会直接覆盖正在使用的 `/srv/ess-boot/run.sh`，而是执行：

```text
下载到临时文件
→ 下载成功
→ 设置执行权限
→ 原子替换 /srv/ess-boot/run.sh
→ 执行新脚本
```

如果网络中断或下载失败，临时文件会被删除，原有 `run.sh` 保持完整。

## 编写 run.sh

`run.sh` 可以直接使用 `RSYNC_IP`，其他 rsync 参数采用固定值。例如同步网站目录：

```bash
#!/bin/bash
set -e

echo "[$(date '+%F %T')] 开始执行脚本"

# ==================== 执行内容 ====================
rsync -avz --timeout=60 --contimeout=15 --password-file=/srv/ess-boot/client.pwd root@${RSYNC_IP}::ess_sync/www/wwwroot/ /www/wwwroot/
# ==================== 执行内容结束 ====================

echo "[$(date '+%F %T')] 脚本执行成功"
```

## 测试

在原主机测试完整流程时，可临时忽略 IP 判断：

```bash
sh /srv/ess-boot/boot.sh --ignore-ip
```

正常开机调用不能添加 `--ignore-ip`，否则原主机也会同步并执行 `run.sh`。

测试可执行脚本同步时，可以在原主机准备 `/srv/ess-boot/rsync-test.sh`，并在 `run.sh` 中写入：

```bash
rsync -avz --timeout=60 --contimeout=15 --password-file=/srv/ess-boot/client.pwd root@${RSYNC_IP}::ess_sync/srv/ess-boot/rsync-test.sh /tmp/rsync-test.sh
chmod 0755 /tmp/rsync-test.sh
/bin/bash /tmp/rsync-test.sh
```

## 日志

查看全部开机日志：

```bash
cat /srv/ess-boot/boot.log
```

实时查看：

```bash
tail -f /srv/ess-boot/boot.log
```

## 重复安装

- 已安装的软件包不会重复安装。
- 已配置的 rsync 模块和服务会跳过。
- 已开放的防火墙端口会跳过。
- `/srv/ess-boot/run.sh` 已存在时不会覆盖用户内容。
- `rc.local` 已包含相同调用时不会修改或重复追加。

## 安全说明

- rsync 使用 TCP `873`，云平台安全组需要允许伸缩实例访问原主机该端口。
- rsync 模块 `ess_sync` 以只读方式映射原主机根目录 `/`，可读取原主机全部路径。
- 必须通过安全组或防火墙限制 TCP 873 的来源，只允许可信的伸缩实例访问。
- 必须保护 `/srv/ess-boot/client.pwd` 和 `/srv/ess-boot/server.secret`，不要输出、上传或提交到代码仓库。
- rsync 默认不会删除目标机多余文件。只有明确需要镜像删除行为时才添加 `--delete`。
