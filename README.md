# sing-box Reality 一键部署脚本

在 VPS 上一键部署 **VLESS + TCP + Reality + xtls-rprx-vision** 节点，使用 sing-box 官方 apt 源安装稳定版内核，并附带 `sb` 快捷管理命令。

## 特性

- 使用官方 apt 源（deb822 格式），安装并升级到官方源中的最新稳定版
- 运行时交互输入端口、SNI、节点名称，直接回车即采用默认值；节点名称支持中文
- 每次运行都会重新随机生成 UUID、ShortId 和 Reality 密钥对
- 自动检测并开启 BBR + FQ，已开启则跳过
- 配置先校验再生效，服务启动失败自动回滚到旧配置
- systemd 开机自启、异常自动重启，仅保留 `CAP_NET_BIND_SERVICE` 最小权限
- `sb` 命令可随时改端口、SNI、节点名，重置凭据，升级内核，一键自检

## 支持系统

Debian 12 / 13，Ubuntu 22.04 / 24.04 / 26.04 LTS。其他系统默认拒绝运行，确认风险后可加 `FORCE=1` 强行继续。

## 一键安装

需要 root 权限和外网连接：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ljbzbj520/singbox-vless/main/install.sh)
```

脚本会依次询问：

| 提示 | 默认值 |
| --- | --- |
| Reality 监听端口 | `443` |
| 伪装目标域名 SNI | `itunes.apple.com` |
| 节点名称（支持中文） | `my-singbox-node` |

端口会检查是否被其他进程占用，SNI 会检测是否同时支持 TLS 1.3 和 h2（只警告，不阻断）。安装结束后会打印节点信息和 `vless://` 分享链接，导入客户端即可使用。

如需下载到本地固定 UUID 后再运行，可编辑脚本顶部的 `PRESET_UUID`（默认留空即自动生成）并执行 `sudo bash install.sh`。

重复运行安装脚本时，端口、SNI、节点名会作为默认值提供，而 UUID、ShortId、密钥对会全部重新生成，**旧的分享链接随之失效**。

## sb 命令

安装完成后可直接使用（需要 root）：

| 命令 | 说明 |
| --- | --- |
| `sb` / `sb info` | 查看节点信息和分享链接 |
| `sb port [端口]` | 修改端口，自动检测占用 |
| `sb sni [域名]` | 修改 SNI，并检测 TLS 1.3 + h2 |
| `sb name [名称]` | 修改节点名称，支持中文 |
| `sb uuid [UUID]` | 随机生成或指定新 UUID |
| `sb shortid [ID]` | 随机生成或指定新 ShortId |
| `sb key` | 重新生成 Reality 密钥对 |
| `sb reset` | 一次性重置 UUID、ShortId 和密钥对 |
| `sb upgrade` | 升级内核到官方源最新稳定版，升级前自动备份配置 |
| `sb version` | 查看内核版本 |
| `sb doctor` | 一键自检 |
| `sb qr` | 显示分享链接二维码 |
| `sb status` / `log` / `start` / `stop` / `restart` | 服务管理 |
| `sb check` | 校验当前配置文件 |
| `sb uninstall` | 彻底卸载 |

带参数的命令省略参数时会交互询问。修改端口、SNI、UUID、ShortId、密钥后，客户端需要换成新的分享链接。

### sb doctor 检查项

服务是否运行并开机自启、配置是否通过校验、端口是否由 sing-box 监听、BBR + FQ 是否生效、出口 IP 是否相比上次发生变化、SNI 目标是否可达且支持 TLS 1.3 + h2、最近 10 分钟是否有错误日志。外部能否连通你的端口无法在服务器上检测，需要在客户端测试。

## 卸载

```bash
sudo sb uninstall
# 或
bash <(curl -fsSL https://raw.githubusercontent.com/ljbzbj520/singbox-vless/main/install.sh) --uninstall
```

会停止服务，卸载 sing-box 包，并删除 apt 源、配置目录和 `sb` 命令。BBR 的 sysctl 配置不会被删除。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `/etc/sing-box/config.json` | sing-box 配置，由 `sb` 根据节点信息生成 |
| `/etc/sing-box/node_info.conf` | 节点信息（含 Reality 私钥，权限 600），是所有修改的数据源 |
| `/etc/sing-box/backups/` | 配置备份，每次改配置和升级前都会生成 |
| `/etc/sing-box/last_ip` | 上次记录的出口 IP，供 `sb doctor` 对比 |
| `/etc/systemd/system/sing-box.service.d/override.conf` | 自动重启与权限设置 |
| `/etc/sysctl.d/99-singbox-bbr.conf` | BBR + FQ 配置 |
| `/usr/local/bin/sb` | 快捷管理命令 |

## 注意事项

- **防火墙需要自己放行端口。** 脚本不会改动 ufw、firewalld 或云厂商安全组，安装和修改端口后请手动放行对应的 TCP 端口。
- **BBR 在容器型 VPS 上可能无法开启。** OpenVZ、LXC 等共享内核的环境不允许修改内核参数，脚本会警告并跳过，不影响节点使用。
- **升级后建议确认服务正常。** `sb upgrade` 会在升级后校验配置并检查服务状态，若新内核弃用了某些配置项，会给出警告；需要降级可用 `apt-get install sing-box=<旧版本号>`，升级前的配置备份在 `/etc/sing-box/backups/`。
- **SNI 建议选择与 VPS 同地区、支持 TLS 1.3 和 h2 的大站**，不要和大量其他用户使用同一个。
- **妥善保管 `node_info.conf`**，其中包含 Reality 私钥。
