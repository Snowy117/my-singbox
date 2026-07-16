# Windows sing-box + WinSW + Sub-Store

这套目录替代现有的 `WinSW + Mihomo`：

- `sing-box-service.exe` / `sing-box-service.xml`：TUN、DNS、路由和 Zashboard。
- `sub-store-service.exe` / `sub-store-service.xml`：仅监听本机，负责订阅拉取与协议转换。
- `scripts/Update-Config.ps1`：拉取订阅、套用 Lanlan 模板、本地覆盖、`sing-box check`、原子替换、WinSW 重启。
- `rules/manual-direct.txt` / `rules/manual-proxy.txt`：最高优先级的手工域名规则。
- `settings.psd1`：端口、DNS 上游/Fake-IP、PKU 网段、TUN 名称等非敏感设置。
- `local/runtime.json`：订阅 URL、API 密钥和私有节点；已被 Git 忽略。

## 首次安装

1. 将整个目录复制到最终位置，例如 `C:\Services\sing-box`。安装后不要移动目录。
2. 关闭并停止 Mihomo 服务，避免端口和 TUN 路由冲突。
3. 以管理员身份打开 PowerShell 7，执行：

```powershell
Set-Location C:\Services\sing-box
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install.ps1
```

安装脚本会从同目录的 `mihomo.yaml` 提取现有订阅、认证、Clash API 密钥和 PKU 节点到 `local/runtime.json`，下载固定版本的 sing-box、Node、Sub-Store、Sub-Store 前端、Zashboard 和 WinSW，然后安装两个服务。

迁移默认忽略已停用的 `Weiba` provider。需要调整时，可先单独运行
`scripts\Migrate-Mihomo.ps1 -ExcludeProviders Weiba,OtherProvider`，再执行安装。

若不迁移旧配置，先从 `local/runtime.example.json` 创建 `local/runtime.json`，再使用 `Install.ps1 -SkipMigration`。

## 日常使用

- Zashboard / sing-box Clash API：`http://127.0.0.1:40090/ui/`
- Clash API 状态检查：`GET http://127.0.0.1:40090/version`，使用 `local/runtime.json` 中的 `clash_secret` 作为 Bearer token。
- sing-box 原生 gRPC/gRPC-Web API：`127.0.0.1:40091`，使用同一个 Bearer token。`/daemon.StartedService/GetVersion` 是 gRPC 方法，不能用浏览器普通 GET 请求测试。
- Sub-Store 前端：`http://127.0.0.1:40007/`
- Sub-Store 后端：`http://127.0.0.1:40008/`（仅脚本和前端代理访问）
- 混合代理：`0.0.0.0:30890`，认证沿用旧配置。
- DNS：`0.0.0.0:53`，同时监听 UDP 和 TCP；Windows 防火墙只允许 `LocalSubnet` 访问。DNS inbound 默认开启 `reuse_addr`，允许与 Hyper-V/ICS 的 `SharedAccess` UDP 53 共存。
- TUN 网卡固定为 `Meta`；服务启动后会对 `Meta` 和 `vEthernet (Network Bridge)` 显式开启 IPv4、IPv6 forwarding。

修改手工域名后，或需要更新订阅时，以管理员身份执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Update-Config.ps1
```

更新失败不会覆盖当前 `config.json`。上一个配置保存在 `work\config.previous.json`。sing-box 在 Windows 上不能通过 Clash API 重载自身，因此更新脚本必须由 WinSW 重启服务；Zashboard 只负责运行时节点选择和连接管理。

若新配置通过校验但 WinSW 重启失败，更新脚本会恢复上一个配置并再次启动服务，然后以错误退出，便于计划任务或监控发现此次更新失败。

## DNS 与 PKU

`pku.edu.cn`、`openjudge.cn` 和 `qmazon.local` 默认使用系统分配的 DNS（sing-box `type: dhcp`，等价于原 Mihomo 的 `system://`）。相关域名和 `10.0.0.0/8`、`162.105.0.0/16`、`115.27.0.0/16` 进入 `🎓 北京大学` 选择器，可在 Zashboard 中选择直连或 PKU 私有节点。

DNS 尽量复刻原 Mihomo 配置：保留两组 114 bootstrap、阿里/腾讯/360 DoT、三组通用 DoH、系统 DNS、本地预定义域名和 Fake-IP。默认查询和代理服务器域名解析策略为 `prefer_ipv6`，对应原 provider 的 `ip-version: ipv6-prefer`；代理服务器 hostname 默认通过 `System-DNS` 的 `local` transport 交给 Windows 系统 resolver，避免本地只有 IPv6 上联时依赖 IPv4 的 DHCP/114 bootstrap。`edu.cn`、`sukaka.ai6.me`、`luogu.com.cn` 保留原配置的禁用 AAAA 特例。Fake-IP 地址段为 `198.18.0.0/15` 与 `fd18:1111:1111::/64`。`local/dns-hosts.json` 中每个域名的根域及所有层级子域都会返回同一组预定义 A/AAAA 地址；这些规则、系统 DNS、私有域名和 IPv4 特例优先于 Fake-IP。其他 A/AAAA 查询返回 Fake-IP；非地址记录再按国内/国外规则选择上游。`settings.psd1` 的 `DirectDnsServer`/`RemoteDnsServer` 决定当前主用服务器，`ProxyServerDnsServer` 决定节点入口域名解析；其他服务器作为可手工切换的备用项。sing-box 不支持 Mihomo 式 DNS fallback/balancer，因此不能在单条规则中自动按顺序切换多个 DNS。

当前固定使用 sing-box `1.14.0-alpha.45`。端口 `40090` 仍是供 Zashboard 使用的 Clash REST API；端口 `40091` 是 `services` 中的原生 sing-box gRPC/gRPC-Web API。`/daemon.StartedService/GetVersion` 只存在于后者，调用方必须发送合法的 gRPC 或 gRPC-Web POST、protobuf 帧及 `authorization: Bearer <secret>` 元数据；普通浏览器 GET 返回 404 不代表 API 未开启。

## IPv6 与虚拟机

配置显式为 `Meta` 安装 IPv4 和 IPv6 默认路由，并为 TUN 设置双栈地址及双栈 DNS 地址。代理节点的服务器域名优先解析为 IPv6，因此在本地只有 IPv6 上联时仍可优先通过 IPv6 连接节点；目标网站的 IPv6 连接则由所选节点建立。两者是不同链路。

升级现有安装时，以管理员身份重新运行 `Install.ps1`，不能只运行 `Update-Config.ps1`，因为前者才会下载并替换 1.14 核心：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install.ps1
```

启动后检查主机 IPv6 路由和双栈 forwarding：

```powershell
Get-NetRoute -InterfaceAlias Meta -AddressFamily IPv6
Get-NetIPInterface -InterfaceAlias Meta,'vEthernet (Network Bridge)' |
  Select-Object InterfaceAlias,AddressFamily,Forwarding,ConnectionState
Test-NetConnection -ComputerName api6.ipify.org -Port 443
```

虚拟机将 DNS 服务器设为 Windows 主机在 VM 网络上的 IPv4 地址，而不是 `127.0.0.1`。防火墙规则仅绑定 `settings.psd1` 的 `DnsFirewallInterfaceAlias`（默认 `vEthernet (Network Bridge)`），不会向物理 LAN/WLAN 开放。可从虚拟机分别执行 `nslookup -type=A example.com <主机地址>` 和 `nslookup -type=AAAA example.com <主机地址>`；预期分别得到 `198.18.0.0/15` 和 `fd18:1111:1111::/64` 中的 Fake-IP。若服务无法启动，先以管理员身份运行 `Get-NetUDPEndpoint -LocalPort 53` 和 `Get-NetTCPConnection -LocalPort 53`，确认没有其他 DNS 服务占用端口。

Hyper-V Default Switch 或 Internet Connection Sharing 会由 `svchost.exe` 中的 `SharedAccess` 服务占用 UDP 53。Mihomo 会为 DNS UDP socket 设置 `SO_REUSEADDR`，且单独的 UDP DNS listener 启动失败不会终止整个核心；TUN `dns-hijack` 仍可能令查询表现正常。sing-box inbound 默认不复用地址，而且 UDP bind 失败会中止服务，因此本项目显式设置 `reuse_addr = true`。安装器仅对白名单服务 `SharedAccess` 的 UDP 53 冲突放行；TCP 53或其他进程占用仍会中止安装。Windows 对共享 UDP 端口的数据报分发不提供确定性，部署后必须从虚拟机验证实际应答来自 sing-box；若结果不稳定，应将 `DnsListen` 改成 Hyper-V 主机侧的具体 IPv4 地址，或停用 ICS 后由 sing-box 独占 53。

仅开启 Windows forwarding 不会自动给 Hyper-V 虚拟机分配 IPv6。若虚拟机本身也需要原生 IPv6 地址和默认路由，必须在 VM 侧使用独立于 TUN `/126` 的 IPv6 前缀（通常 `/64`），将主机 bridge 地址设为网关，并静态配置或额外提供 Router Advertisement；不要把 `fdfe:dcba:9876::/126` 直接复用到 VM 网段。

修改 `settings.psd1` 的 DNS 标签、Fake-IP 段或 `EducationDomains`/`EducationCidrs` 后运行更新脚本即可。修改 Sub-Store 端口后需重新运行 `Install.ps1`，安装器会同步 WinSW XML。

## 服务命令

```powershell
.\sing-box-service.exe status
.\sing-box-service.exe restart
.\sub-store-service.exe status
.\sub-store-service.exe restart
```

卸载时先运行两个服务各自的 `stop`，再运行 `uninstall`。不要同时启动旧 Mihomo 服务。
