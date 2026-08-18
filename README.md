# EasyTier OneClick

面向日常使用的 EasyTier 跨平台终端管理脚本。参考 xui-cf 的交互方式，把安装、快速组网、开机自启和状态查看收敛到一个 `easytier` 命令，同时保留原始 TOML 高级入口。

## 支持范围

- Windows 10/11、Windows Server：x86_64、ARM64、i686。
- macOS：Apple Silicon、Intel。
- Debian / Ubuntu：使用 EasyTier 官方 Release 支持的常见架构。
- 默认下载 EasyTier 最新稳定版，也可指定固定版本。

脚本直接使用 [EasyTier 官方 Release](https://github.com/EasyTier/EasyTier/releases) 中的 `easytier-core` 和 `easytier-cli`，不会修改或重新编译 EasyTier。

## 一键安装

### Debian / Ubuntu

```bash
curl -fsSL https://raw.githubusercontent.com/wzh195879702/easytier-oneclick/main/install.sh \
  | sudo bash
```

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/wzh195879702/easytier-oneclick/main/install.sh \
  | sudo bash
```

### Windows

使用“以管理员身份运行”的 Windows PowerShell：

```powershell
irm https://raw.githubusercontent.com/wzh195879702/easytier-oneclick/main/install.ps1 | iex
```

安装指定版本：

```bash
sudo easytier install v2.6.4
```

```powershell
easytier install v2.6.4
```

安装完成后执行：

```text
easytier configure
easytier service install
```

Windows 需要管理员 PowerShell；macOS、Debian、Ubuntu 的写配置和服务操作需要 `sudo`。

## 快速组网

运行：

```text
easytier configure
```

第一步只选择一种角色：

1. 创建首个节点：不填写 peer，只监听连接。
2. 加入已有自建网络：填写一个或多个自建 peer URI。

两种模式都不使用公共共享节点。默认只生成：

```text
tcp://0.0.0.0:11010
udp://0.0.0.0:11010
```

常用配置支持：

- DHCP 或静态虚拟 IPv4。
- 网络名称、网络密钥、设备名称。
- 多个自建 peer。
- 可选子网代理 CIDR。
- 可选出口节点虚拟 IPv4。

快速配置不包含 WS、WSS、WireGuard listener、WireGuard 门户、端口转发和多实例。确有需要时使用 `easytier edit-config` 编辑原始 TOML。

## 开机自启服务

EasyTier 官方 CLI 已支持跨平台服务管理。本项目直接调用官方命令：

- Windows：Windows Service。
- macOS：launchd。
- Debian / Ubuntu：systemd。

一键注册、启动并启用开机自启：

```text
easytier service install
```

常用服务命令：

```text
easytier service start
easytier service stop
easytier service restart
easytier service status
easytier service uninstall
```

重复执行 `service install` 会使用当前配置重新注册服务。

## 常用命令

不带参数运行 `easytier` 会打开中文菜单。

```text
easytier install [version]          安装最新稳定版或指定版本
easytier update [version]           确认后更新并保留配置
easytier configure                  快速配置
easytier service <action>           管理开机自启服务
easytier info                       查看服务与脱敏配置摘要
easytier peer                       查看节点
easytier route                      查看路由
easytier node                       查看本机节点
easytier edit-config                备份后编辑原始 TOML
easytier uninstall                  卸载程序，保留配置
easytier uninstall --purge          卸载并删除配置与备份
```

## 更新与回滚

- 默认查询最新稳定版，不后台自动更新。
- `update` 会显示当前版本和目标版本并要求确认。
- 下载、解压和二进制 `--version` 校验完成后，才停止正在运行的旧服务。
- 新版本替换或启动失败时，脚本恢复旧二进制并尝试恢复服务。
- 配置目录与二进制目录分离，安装和更新不会覆盖配置。

## 配置与安装路径

| 内容 | macOS / Debian / Ubuntu | Windows |
|---|---|---|
| 程序 | `/opt/easytier-oneclick/` | `%ProgramFiles%\EasyTierOneClick\` |
| 配置 | `/etc/easytier-oneclick/config.toml` | `%ProgramData%\EasyTierOneClick\config.toml` |
| 备份 | `/etc/easytier-oneclick/backups/` | `%ProgramData%\EasyTierOneClick\backups\` |

`easytier info` 不显示明文网络密钥。项目仓库和示例也不保存任何真实网络名称、密钥或节点地址。

## 防火墙与云安全组

本项目不会自动修改 Windows/macOS/Linux 防火墙，也不会修改 VPS 云安全组。

创建首节点时，请按实际配置手动放行默认的 TCP/UDP `11010`。如果服务器还有云厂商安全组，也需要同步放行。加入已有网络的节点是否需要入站规则取决于 NAT、P2P 和实际监听环境。

## 本地开发

macOS / Debian / Ubuntu：

```bash
sudo bash install.sh --local
bash -n install.sh easytier.sh tests/shell_test.sh
bash tests/shell_test.sh
bash tests/release_assets_test.sh
```

Windows：

```powershell
.\install.ps1 -SourceDir $PWD
Invoke-Pester .\tests\powershell.Tests.ps1 -CI
```

测试通过临时目录和 mock 边界运行，不会修改开发机真实服务或防火墙。
