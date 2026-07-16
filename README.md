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
- Sub-Store 前端：`http://127.0.0.1:40007/`
- Sub-Store 后端：`http://127.0.0.1:40008/`（仅脚本和前端代理访问）
- 混合代理：`0.0.0.0:30890`，认证沿用旧配置。
- TUN 网卡固定为 `Meta`；服务启动后会对 `Meta` 和 `vEthernet (Network Bridge)` 开启 IP forwarding。

修改手工域名后，或需要更新订阅时，以管理员身份执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Update-Config.ps1
```

更新失败不会覆盖当前 `config.json`。上一个配置保存在 `work\config.previous.json`。sing-box 在 Windows 上不能通过 Clash API 重载自身，因此更新脚本必须由 WinSW 重启服务；Zashboard 只负责运行时节点选择和连接管理。

若新配置通过校验但 WinSW 重启失败，更新脚本会恢复上一个配置并再次启动服务，然后以错误退出，便于计划任务或监控发现此次更新失败。

## DNS 与 PKU

`pku.edu.cn`、`openjudge.cn` 和 `qmazon.local` 默认使用系统分配的 DNS（sing-box `type: dhcp`，等价于原 Mihomo 的 `system://`）。相关域名和 `10.0.0.0/8`、`162.105.0.0/16`、`115.27.0.0/16` 进入 `🎓 北京大学` 选择器，可在 Zashboard 中选择直连或 PKU 私有节点。

DNS 尽量复刻原 Mihomo 配置：保留两组 114 bootstrap、阿里/腾讯/360 DoT、三组通用 DoH、系统 DNS、hosts 和 Fake-IP。默认查询策略为 `prefer_ipv6`，`edu.cn`、`sukaka.ai6.me`、`luogu.com.cn` 保留原配置的 `prefer_ipv4` 特例；Fake-IP 地址段为 `198.18.0.0/15` 与 `fd18:1111:1111::/64`。hosts、系统 DNS、私有域名和 IPv4 特例先返回真实地址，其他 A/AAAA 查询返回 Fake-IP；非地址记录再按国内/国外规则选择上游。`settings.psd1` 的 `DirectDnsServer`/`RemoteDnsServer` 决定当前主用服务器；其他服务器作为可手工切换的备用项。sing-box 1.13 不支持 Mihomo 式 DNS fallback/balancer，因此不能在单条规则中自动按顺序切换多个 DNS。

修改 `settings.psd1` 的 DNS 标签、Fake-IP 段或 `EducationDomains`/`EducationCidrs` 后运行更新脚本即可。修改 Sub-Store 端口后需重新运行 `Install.ps1`，安装器会同步 WinSW XML。

## 服务命令

```powershell
.\sing-box-service.exe status
.\sing-box-service.exe restart
.\sub-store-service.exe status
.\sub-store-service.exe restart
```

卸载时先运行两个服务各自的 `stop`，再运行 `uninstall`。不要同时启动旧 Mihomo 服务。
