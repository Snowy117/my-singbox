# Windows sing-box + Sub-Store

本目录使用 WinSW 管理 sing-box 与 Sub-Store。配置生成流程只有一条：

```text
config.yaml + local/runtime.json 中的节点数据 + Sub-Store 订阅节点
                              ↓
                         config.json
```

固定版本：

- sing-box `1.14.0-beta.5`
- Sub-Store 前端 `2.29.10`
- WinSW `3.0.0-alpha.11`（WinSW 当前公开的 3.0 预发布版本）
- 其余组件版本见 `versions.psd1`

`config.yaml` 是 sing-box 配置的唯一声明式来源。DNS、TUN、inbound、策略组、路由、rule-set、API 和缓存都直接在这个 YAML 文件中修改；PowerShell 不再从远程模板下载配置，也不会重写这些部分。`config.json` 是生成文件，不应手工修改。

sing-box 本身不读取 YAML，因此安装器会下载固定版本的 `yq`。构建脚本先把 YAML 转为 JSON，再使用固定版本的 `sing-box check` 验证候选配置，通过后才原子替换 `config.json`。

## 文件职责

- `config.yaml`：完整、可手工维护的 sing-box YAML 模板。
- `local/runtime.json`：订阅 URL、节点前缀、代理认证、API 密钥和私有节点；被 Git 忽略。
- `scripts/Build-Config.ps1`：向模板插入已经转换好的 outbounds/endpoints，并展开节点占位符。
- `scripts/Update-Config.ps1`：从正在运行的 Sub-Store 获取节点，调用构建脚本，校验并安装 `config.json`；默认不重启服务。
- `scripts/Migrate-Mihomo.ps1`：用 YAML 解析器读取 `mihomo.yaml`，迁移 provider、认证、API 密钥和支持的本地 VLESS 节点。
- `scripts/Install.ps1`：下载固定版本、替换程序文件并安装两个服务；不会启动服务，且把启动类型设为手动。
- `settings.psd1`：只保存 Sub-Store 端口和 post-start 所需的 Windows 部署设置，不保存 sing-box 配置。

## YAML 中的节点占位符

`config.yaml` 必须在 `outbounds` 中保留一个 tag 为 `__INSERT_NODES__` 的条目。构建时该条目会被私有节点和订阅 outbounds 替换；订阅 endpoints 则写入顶层 `endpoints`。

策略组的 `outbounds` 可使用以下占位符：

- `__ALL_NODES__`：全部私有、订阅 outbound 和订阅 endpoint。
- `__SUBSCRIPTION_NODES__`：全部订阅节点。
- `__CUSTOM_NODES__`：`local/runtime.json` 中的私有节点。
- `__HK_NODES__`、`__TW_NODES__`、`__SG_NODES__`、`__JP_NODES__`、`__US_NODES__`、`__EU_NODES__`：按节点 tag 匹配地区。

地区没有匹配节点时会插入 `🟢 直连`，避免生成空 selector/urltest。除此之外，构建脚本不会根据策略组名称猜测或修改配置。

认证和 API 密钥仍放在被 Git 忽略的 `local/runtime.json`。YAML 中的 `__RUNTIME_MIXED_USERS__` 与 `__RUNTIME_CLASH_SECRET__` 是对应的敏感值占位符；它们不是 DNS、TUN 或路由覆盖项。

## 首次安装

以管理员身份打开 PowerShell 7，在最终安装目录执行：

```powershell
Set-Location C:\Services\sing-box
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install.ps1
```

若 `local/runtime.json` 不存在，安装器默认从同目录且被 Git 忽略的 `mihomo.yaml` 迁移数据，并默认排除 `Weiba` provider。不要迁移时使用：

```powershell
Copy-Item .\local\runtime.example.json .\local\runtime.json
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install.ps1 -SkipMigration
```

安装结束时 `sing-box` 和 `sub-store` 都处于停止状态，启动类型为手动。首次生成配置需要显式执行：

```powershell
.\sub-store-service.exe start
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Initialize-SubStore.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Update-Config.ps1
.\sing-box-service.exe start
```

`Initialize-SubStore.ps1` 只创建或更新 `local/runtime.json` 中声明的订阅，不启动服务。

## 日常调整配置

直接编辑 `config.yaml`，然后在 Sub-Store 已运行时执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Update-Config.ps1
```

脚本会更新节点并生成、校验和安装 `config.json`，但不会重启正在运行的 sing-box。确认后可手动执行：

```powershell
.\sing-box-service.exe restart
```

明确希望构建成功后自动重启时，使用可选开关：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Update-Config.ps1 -Restart
```

`-Restart` 模式保留回滚：若 WinSW 重启失败，会恢复 `work\config.previous.json` 并尝试重新启动旧配置。默认模式不会触碰服务状态。

已经有节点 JSON 时，可绕过 Sub-Store 单独测试模板：

```powershell
pwsh -NoProfile -File .\scripts\Build-Config.ps1 `
  -NodesPath .\work\nodes.json `
  -OutputPath .\work\config.candidate.json
```

节点文件结构为：

```json
{
  "outbounds": [],
  "endpoints": []
}
```

## Schema 与 rule-set

`config.yaml` 的 `$schema` 指向：

```text
https://raw.githubusercontent.com/SagerNet/sing-box/refs/heads/testing/docs/schema.json
```

该 schema 与 `v1.14.0-beta.5` 仓库中的 schema 当前完全一致。配置使用 1.14 的显式 DNS server 类型、`domain_resolver`、HTTP client、组合 TUN 地址字段、顶层 `services` 和独立的 `experimental.cache_file`，不再使用旧模板中的 `download_detour`、旧 DNS transport 写法或已移除字段。

分流统一使用 DustinWin 的当前 sing-box SRS 发布通道：

```text
https://github.com/DustinWin/ruleset_geodata/releases/download/sing-box-ruleset/<name>.srs
```

模板保留了当前 `mihomo.yaml` 的主要选择逻辑、地区节点组、PKU 规则、直连/代理例外、DNS 上游、Fake-IP 和 TUN 接口设置。DustinWin 的规则集比原 Mihomo provider 粗：例如提供聚合的 `proxy`、`media`、`games` 和 `ai`，但没有独立的 GitHub、Meta、Wise、PayPal、LINE 等集合。因此这些流量由聚合集合接管，无法继续保留每个服务的独立规则命中；需要更细策略时，可以直接在 `config.yaml` 中添加 rule-set、selector 和 route rule，脚本不会覆盖。

sing-box 没有 Mihomo 的有序 `fallback` outbound。模板把 `故障转移` 保留为 `urltest`，它会在全部节点中选择可用且延迟较低的节点，不保证按订阅顺序选择第一个健康节点；该组位于 `节点选择` 的末尾，首次启动仍优先使用与 `mihomo.yaml` 一致的香港节点组。

## 服务与端口

模板默认提供：

- Zashboard / Clash API：`http://127.0.0.1:40090/ui/`
- sing-box 原生 gRPC/gRPC-Web API：`127.0.0.1:40091`
- Sub-Store 前端：`http://127.0.0.1:40007/`
- Sub-Store 后端：`http://127.0.0.1:40008/`
- Mixed inbound：`0.0.0.0:30890` 和 `[::]:30890`
- DNS：IPv4/IPv6 TCP 与 UDP `53`
- TUN：`Meta`

这些 sing-box 端口都应在 `config.yaml` 中调整。TUN 有意设置为 `auto_route: false` 与 `strict_route: false`：服务只创建 TUN，不替 Windows 自动安装默认路由，路由由系统侧手工管理。Sub-Store 端口在 `settings.psd1` 中调整，随后重新运行安装器以同步 WinSW XML。

服务命令：

```powershell
.\sing-box-service.exe status
.\sing-box-service.exe start
.\sing-box-service.exe stop
.\sing-box-service.exe restart

.\sub-store-service.exe status
.\sub-store-service.exe start
.\sub-store-service.exe stop
.\sub-store-service.exe restart
```

服务启动后的 `poststart.ps1` 会从最终 `config.json` 读取 TUN interface 和 DNS inbound 端口，再设置 Windows forwarding 与防火墙规则，因此修改 YAML 中的 TUN 名称或 DNS 端口时不需要同步修改 PowerShell 配置。WinSW 会把该钩子的输出与错误分别写入 `logs\poststart.out.log` 和 `logs\poststart.err.log`；钩子失败不会把已经启动的 sing-box 主进程改为停止状态。
