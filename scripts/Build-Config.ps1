[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$NodesPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\work\config.candidate.json')
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Import-PowerShellDataFile (Join-Path $root 'settings.psd1')
$versions = Import-PowerShellDataFile (Join-Path $root 'versions.psd1')
$runtime = Get-Content (Join-Path $root 'local\runtime.json') -Raw | ConvertFrom-Json
$nodes = Get-Content -LiteralPath $NodesPath -Raw | ConvertFrom-Json

function Invoke-RestMethodWithRetry([string]$Uri) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Warning "Request attempt $attempt failed; retrying in 3 seconds."
            Start-Sleep -Seconds 3
        }
    }
}

$config = Invoke-RestMethodWithRetry $settings.TemplateUrl

function Read-DomainList([string]$Path) {
    $exact = [Collections.Generic.List[string]]::new()
    $suffix = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $value = ($line -replace '#.*$', '').Trim().ToLowerInvariant()
        if (-not $value) { continue }
        if ($value.StartsWith('=') ) { $exact.Add($value.Substring(1)); continue }
        $value = $value -replace '^\+\.', '' -replace '^\*\.', '' -replace '^\.', ''
        $suffix.Add($value)
    }
    return @{ domain = @($exact); domain_suffix = @($suffix) }
}

function New-RouteRule([string]$Outbound, $Domains) {
    if (-not $Domains.domain.Count -and -not $Domains.domain_suffix.Count) { return $null }
    $rule = [ordered]@{ action = 'route'; outbound = $Outbound }
    if ($Domains.domain.Count) { $rule.domain = $Domains.domain }
    if ($Domains.domain_suffix.Count) { $rule.domain_suffix = $Domains.domain_suffix }
    return [pscustomobject]$rule
}

function Set-JsonProperty($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

$directTag = '🎯 全球直连'
$proxyTag = '🚀 节点选择'
$educationTag = '🎓 北京大学'
$allNodes = @($nodes.outbounds) + @($nodes.endpoints) + @($runtime.custom_outbounds)
$nodeTags = @($allNodes | ForEach-Object { $_.tag })

# Preserve Mihomo provider override `ip-version: ipv6-prefer` when resolving
# proxy server hostnames. System DNS avoids an IPv4-only bootstrap dependency
# when the physical uplink is IPv6-only. IP-literal servers are unaffected.
foreach ($node in @($allNodes | Where-Object { $_.PSObject.Properties['server'] })) {
    Set-JsonProperty $node 'domain_resolver' ([pscustomobject]@{
        server = $settings.ProxyServerDnsServer
        strategy = $settings.DnsStrategy
    })
}

# Add local outbounds before generated subscription nodes.
$config.outbounds = @($config.outbounds) + @($runtime.custom_outbounds) + @($nodes.outbounds)
if (-not $config.PSObject.Properties['endpoints']) { $config | Add-Member -NotePropertyName endpoints -NotePropertyValue @() }
$config.endpoints = @($config.endpoints) + @($nodes.endpoints)

$regionPatterns = [ordered]@{
    '🇭🇰 香港' = '(?i)(香港|港|\bhk\b|hong\s*kong|🇭🇰)'
    '🇹🇼 台湾' = '(?i)(台湾|台灣|台|\btw\b|taiwan|🇹🇼)'
    '🇸🇬 新加坡' = '(?i)(新加坡|狮城|獅城|\bsg\b|singapore|🇸🇬)'
    '🇯🇵 日本' = '(?i)(日本|\bjp\b|japan|🇯🇵)'
    '🇺🇸 美国' = '(?i)(美国|美國|\bus\b|united\s*states|🇺🇸)'
    '🇪🇺 欧洲' = '(?i)(欧洲|歐洲|\beu\b|🇪🇺|🇦🇱|🇦🇩|🇦🇹|🇧🇪|🇧🇬|🇭🇷|🇨🇿|🇩🇰|🇫🇮|🇫🇷|🇩🇪|🇬🇷|🇭🇺|🇮🇸|🇮🇪|🇮🇹|🇱🇺|🇳🇱|🇳🇴|🇵🇱|🇵🇹|🇷🇴|🇪🇸|🇸🇪|🇨🇭|🇬🇧)'
}

$compatibleNeeded = $false
foreach ($entry in $regionPatterns.GetEnumerator()) {
    $matched = @($nodeTags | Where-Object { $_ -match $entry.Value })
    foreach ($outbound in $config.outbounds | Where-Object { $_.tag -like "$($entry.Key)*" -or $_.tag -eq $entry.Key }) {
        if ($outbound.PSObject.Properties['outbounds']) {
            $outbound.outbounds = @($outbound.outbounds) + $matched
            if ($outbound.outbounds.Count -eq 0) {
                $outbound.outbounds = @('COMPATIBLE')
                $compatibleNeeded = $true
            }
        }
    }
}

$customTags = @($runtime.custom_outbounds | ForEach-Object { $_.tag })
$primary = $config.outbounds | Where-Object tag -eq $proxyTag | Select-Object -First 1
if ($primary) { $primary.outbounds = @($customTags) + @($primary.outbounds) }
$speedtest = $config.outbounds | Where-Object tag -eq '🛜 Speedtest' | Select-Object -First 1
if ($speedtest) { $speedtest.outbounds = @($speedtest.outbounds) + $nodeTags }
if ($compatibleNeeded -and -not ($config.outbounds.tag -contains 'COMPATIBLE')) {
    $config.outbounds += [pscustomobject]@{ type = 'direct'; tag = 'COMPATIBLE' }
}

$educationOptions = @($directTag) + $customTags
$config.outbounds = @([pscustomobject]@{
    type = 'selector'; tag = $educationTag; outbounds = $educationOptions
    interrupt_exist_connections = $true
}) + @($config.outbounds)

$mixedTemplate = $config.inbounds | Where-Object type -eq 'mixed' | Select-Object -First 1
if (-not $mixedTemplate) { throw 'The template does not contain a mixed inbound.' }
$config.inbounds = @($config.inbounds | Where-Object type -ne 'mixed')
$mixedInbounds = for ($index = 0; $index -lt $settings.MixedListenAddresses.Count; $index++) {
    $family = if ($index -eq 0) { 'v4' } else { 'v6' }
    $mixed = $mixedTemplate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    Set-JsonProperty $mixed 'tag' "mixed-in-$family"
    Set-JsonProperty $mixed 'listen' $settings.MixedListenAddresses[$index]
    Set-JsonProperty $mixed 'listen_port' $settings.MixedPort
    Set-JsonProperty $mixed 'users' @($runtime.mixed_users)
    $mixed
}
$config.inbounds += @($mixedInbounds)
$tun = $config.inbounds | Where-Object type -eq 'tun' | Select-Object -First 1
Set-JsonProperty $tun 'interface_name' $settings.TunInterface
Set-JsonProperty $tun 'mtu' $settings.TunMtu
Set-JsonProperty $tun 'stack' 'mixed'
Set-JsonProperty $tun 'address' @($settings.TunAddresses)
Set-JsonProperty $tun 'dns_mode' 'hijack'
Set-JsonProperty $tun 'dns_address' @($settings.TunDnsAddresses)
Set-JsonProperty $tun 'auto_route' $true
Set-JsonProperty $tun 'strict_route' $true
Set-JsonProperty $tun 'route_address' @($settings.TunRouteAddresses)
Set-JsonProperty $tun 'route_exclude_address' @($settings.TunRouteExcludeAddresses)
if ($tun.PSObject.Properties['platform']) { $tun.PSObject.Properties.Remove('platform') }

$config.inbounds = @($config.inbounds | Where-Object { $_.tag -notlike 'dns-in*' })
$dnsInboundTags = [Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $settings.DnsListenAddresses.Count; $index++) {
    $family = if ($index -eq 0) { 'v4' } else { 'v6' }
    $tag = "dns-in-$family"
    $dnsInboundTags.Add($tag)
    $config.inbounds += [pscustomobject]@{
        type = 'direct'
        tag = $tag
        listen = $settings.DnsListenAddresses[$index]
        listen_port = $settings.DnsListenPort
        reuse_addr = $settings.DnsReuseAddr
    }
}

if (($settings.ClashApiEnabled -or $settings.NativeApiEnabled) -and
    ([string]::IsNullOrWhiteSpace($runtime.clash_secret) -or $runtime.clash_secret -eq 'CHANGE_ME')) {
    throw 'Set a non-empty clash_secret in local/runtime.json before enabling an API.'
}

if ($settings.ClashApiEnabled) {
    Set-JsonProperty $config.experimental.clash_api 'external_controller' "$($settings.ClashApiListen):$($settings.ClashApiPort)"
    Set-JsonProperty $config.experimental.clash_api 'external_ui' (Join-Path $root 'ui')
    Set-JsonProperty $config.experimental.clash_api 'external_ui_download_url' "https://github.com/Zephyruso/zashboard/releases/download/v$($versions.Zashboard)/dist.zip"
    Set-JsonProperty $config.experimental.clash_api 'secret' $runtime.clash_secret
    Set-JsonProperty $config.experimental.clash_api 'default_mode' 'rule'
    Set-JsonProperty $config.experimental.clash_api 'access_control_allow_origin' @(
        "http://$($settings.ClashApiListen):$($settings.ClashApiPort)",
        "http://localhost:$($settings.ClashApiPort)"
    )
    Set-JsonProperty $config.experimental.clash_api 'access_control_allow_private_network' $false
} else {
    $config.experimental.PSObject.Properties.Remove('clash_api')
}

$existingServices = if ($config.PSObject.Properties['services']) {
    @($config.services | Where-Object { $_.type -ne 'api' -and $_.tag -ne 'native-api' })
} else {
    @()
}
if ($settings.NativeApiEnabled) {
    $existingServices += [pscustomobject]@{
        type = 'api'
        tag = 'native-api'
        listen = $settings.NativeApiListen
        listen_port = $settings.NativeApiPort
        secret = $runtime.clash_secret
        access_control_allow_origin = @($settings.NativeApiAllowedOrigins)
        access_control_allow_private_network = $false
        dashboard = $false
    }
}
$servicesArray = [object[]]@($existingServices)
Set-JsonProperty $config 'services' ([object]$servicesArray)

Set-JsonProperty $config.experimental.cache_file 'path' (Join-Path $root 'data\cache.db')
Set-JsonProperty $config.experimental.cache_file 'store_fakeip' $true
Set-JsonProperty $config.experimental.cache_file 'store_dns' $true
foreach ($legacyCacheField in @('store_rdrc', 'rdrc_timeout')) {
    if ($config.experimental.cache_file.PSObject.Properties[$legacyCacheField]) {
        $config.experimental.cache_file.PSObject.Properties.Remove($legacyCacheField)
    }
}

$manualDirect = Read-DomainList (Join-Path $root 'rules\manual-direct.txt')
$manualProxy = Read-DomainList (Join-Path $root 'rules\manual-proxy.txt')
$wechatDomains = @($settings.WeChatDomains)
$ipv4PreferredDomains = @($settings.Ipv4PreferredDomains + $wechatDomains | Select-Object -Unique)

# sing-box has no DNS fallback/balancer. All original Mihomo upstreams
# are retained, while settings.psd1 selects the active direct and global tags.
$dnsServers = @(
    [pscustomobject]@{ type = 'local'; tag = 'System-DNS' },
    [pscustomobject]@{ type = 'udp'; tag = 'CN-DNS-Bootstrap-114-A'; server = '114.114.114.110'; server_port = 53 },
    [pscustomobject]@{ type = 'udp'; tag = 'CN-DNS-Bootstrap-114-B'; server = '114.114.115.119'; server_port = 53 },
    [pscustomobject]@{
        type = 'tls'; tag = 'CN-DNS-Ali'; server = 'dns.alidns.com'; server_port = 853
        domain_resolver = 'CN-DNS-Bootstrap-114-A'
    },
    [pscustomobject]@{
        type = 'tls'; tag = 'CN-DNS-Tencent'; server = 'dot.pub'; server_port = 853
        domain_resolver = 'CN-DNS-Bootstrap-114-A'
    },
    [pscustomobject]@{
        type = 'tls'; tag = 'CN-DNS-360'; server = 'dot.360.cn'; server_port = 853
        domain_resolver = 'CN-DNS-Bootstrap-114-B'
    },
    [pscustomobject]@{
        type = 'https'; tag = 'Global-DNS-Recipes'; server = 'v.recipes'; server_port = 443
        path = '/dns-query'; domain_resolver = $settings.DirectDnsServer
    },
    [pscustomobject]@{
        type = 'https'; tag = 'Global-DNS-Cloudflare-Gateway'; server = 'iloveyou.cloudflare-gateway.com'; server_port = 443
        path = '/dns-query'; domain_resolver = $settings.DirectDnsServer
    },
    [pscustomobject]@{
        type = 'https'; tag = 'Global-DNS-Google'; server = 'dns.google'; server_port = 443
        path = '/dns-query'; detour = $proxyTag; domain_resolver = $settings.DirectDnsServer
    },
    [pscustomobject]@{
        type = 'fakeip'; tag = 'FakeIP-DNS'
        inet4_range = $settings.FakeIpV4Range; inet6_range = $settings.FakeIpV6Range
    }
)
$hosts = Get-Content (Join-Path $root 'local\dns-hosts.json') -Raw | ConvertFrom-Json -AsHashtable
$config.dns.servers = $dnsServers

$hostsDnsRules = [Collections.Generic.List[object]]::new()
foreach ($entry in $hosts.GetEnumerator()) {
    $domain = $entry.Key.TrimEnd('.').ToLowerInvariant()
    $addressesByType = [ordered]@{ A = @(); AAAA = @() }
    foreach ($address in @($entry.Value)) {
        $parsedAddress = [Net.IPAddress]::Parse($address)
        $recordType = if ($parsedAddress.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 'A' } else { 'AAAA' }
        $addressesByType[$recordType] += $parsedAddress.ToString()
    }
    foreach ($recordType in $addressesByType.Keys) {
        $addresses = @($addressesByType[$recordType])
        if (-not $addresses.Count) { continue }
        $hostsDnsRules.Add([pscustomobject]@{
            action = 'predefined'
            domain = @($domain)
            query_type = @($recordType)
            answer = @($addresses | ForEach-Object { "$domain. IN $recordType $_" })
        })
        $hostsDnsRules.Add([pscustomobject]@{
            action = 'predefined'
            domain_suffix = @($domain)
            query_type = @($recordType)
            answer = @($addresses | ForEach-Object { "*.$domain. IN $recordType $_" })
        })
    }
}

if (-not ($config.route.rule_set.tag -contains 'FakeIP-Filter-SRS')) {
    $config.route.rule_set += [pscustomobject]@{
        tag = 'FakeIP-Filter-SRS'
        type = 'remote'
        format = 'binary'
        url = 'https://github.com/DustinWin/ruleset_geodata/releases/download/sing-box-ruleset-compatible/fakeip-filter.srs'
        http_client = [pscustomobject]@{
            domain_resolver = [pscustomobject]@{
                server = $settings.DirectDnsServer
                strategy = $settings.DnsStrategy
            }
        }
    }
}

# sing-box 1.14 replaces the rule-set download_detour field with an HTTP client.
foreach ($ruleSet in @($config.route.rule_set | Where-Object type -eq 'remote')) {
    if ($ruleSet.PSObject.Properties['download_detour']) {
        $httpClient = if ($ruleSet.download_detour -eq $directTag) {
            [pscustomobject]@{
                domain_resolver = [pscustomobject]@{
                    server = $settings.DirectDnsServer
                    strategy = $settings.DnsStrategy
                }
            }
        } else {
            [pscustomobject]@{ detour = $ruleSet.download_detour }
        }
        Set-JsonProperty $ruleSet 'http_client' $httpClient
        $ruleSet.PSObject.Properties.Remove('download_detour')
    }
}

$educationDnsRule = [pscustomobject]@{
    action = 'route'; domain_suffix = @($settings.EducationDomains); server = 'System-DNS'
}
$config.dns.rules = @($hostsDnsRules) + @(@(
    $educationDnsRule,
    [pscustomobject]@{
        action = 'predefined'; domain_suffix = $ipv4PreferredDomains
        query_type = @('AAAA'); answer = @()
    },
    [pscustomobject]@{
        action = 'route'; domain_suffix = $ipv4PreferredDomains
        server = $settings.DirectDnsServer
        client_subnet = $settings.DnsClientSubnet
    },
    [pscustomobject]@{
        action = 'route'; rule_set = @('GeoSite-Private'); server = $settings.DirectDnsServer
    },
    [pscustomobject]@{
        action = 'route'; rule_set = @('FakeIP-Filter-SRS'); server = $settings.DirectDnsServer
        client_subnet = $settings.DnsClientSubnet
    },
    [pscustomobject]@{
        action = 'route'; query_type = @('A', 'AAAA'); server = 'FakeIP-DNS'
    },
    [pscustomobject]@{
        action = 'route'; clash_mode = 'direct'; server = $settings.DirectDnsServer
        client_subnet = $settings.DnsClientSubnet
    },
    [pscustomobject]@{
        action = 'route'; clash_mode = 'global'; server = $settings.RemoteDnsServer
        client_subnet = $settings.DnsClientSubnet
    },
    [pscustomobject]@{
        action = 'route'; rule_set = @('GeoSite-CN'); server = $settings.DirectDnsServer
        client_subnet = $settings.DnsClientSubnet
    },
    [pscustomobject]@{
        action = 'route'; rule_set = @('GeoLocation-!CN'); server = $settings.RemoteDnsServer
        client_subnet = $settings.DnsClientSubnet
    }
) | Where-Object { $null -ne $_ })
Set-JsonProperty $config.dns 'final' $settings.RemoteDnsServer
Set-JsonProperty $config.dns 'strategy' $settings.DnsStrategy
Set-JsonProperty $config.dns 'cache_capacity' 2048
Set-JsonProperty $config.dns 'reverse_mapping' $true
if ($config.dns.PSObject.Properties['independent_cache']) {
    $config.dns.PSObject.Properties.Remove('independent_cache')
}
Set-JsonProperty $config.route 'default_domain_resolver' ([pscustomobject]@{
    server = $settings.DirectDnsServer
    strategy = $settings.DnsStrategy
})
$priorityRules = @(@(
    [pscustomobject]@{ action = 'sniff'; inbound = 'tun-in' },
    [pscustomobject]@{ action = 'hijack-dns'; inbound = @($dnsInboundTags) },
    [pscustomobject]@{ action = 'hijack-dns'; protocol = 'dns' },
    (New-RouteRule $directTag $manualDirect),
    (New-RouteRule $proxyTag $manualProxy),
    [pscustomobject]@{
        type = 'logical'
        mode = 'and'
        rules = @(
            [pscustomobject]@{ process_name = @($settings.DirectIpv4OnlyProcesses) },
            [pscustomobject]@{ ip_version = 6 }
        )
        action = 'reject'
        method = 'default'
        no_drop = $true
    },
    [pscustomobject]@{
        action = 'route'
        domain_suffix = $wechatDomains
        outbound = $directTag
    },
    [pscustomobject]@{
        action = 'route'
        process_name = @($settings.DirectIpv4OnlyProcesses)
        outbound = $directTag
    },
    [pscustomobject]@{ action = 'route'; domain_suffix = @($settings.EducationDomains); outbound = $educationTag },
    [pscustomobject]@{ action = 'route'; ip_cidr = @($settings.EducationCidrs); outbound = $educationTag }
) | Where-Object { $null -ne $_ })
$remainingRules = @($config.route.rules | Where-Object { $_.action -ne 'sniff' -and $_.action -ne 'hijack-dns' })
$config.route.rules = $priorityRules + $remainingRules

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Built candidate config with $($nodeTags.Count) subscription/custom nodes: $OutputPath"

