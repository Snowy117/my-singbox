$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Import-PowerShellDataFile (Join-Path $root 'settings.psd1')
$config = Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$bridgeInterface = $settings.DnsFirewallInterfaceAlias

$tunInterfaces = @(
    $config.inbounds |
        Where-Object { $_.type -eq 'tun' -and -not [string]::IsNullOrWhiteSpace([string]$_.interface_name) } |
        ForEach-Object interface_name |
        Select-Object -Unique
)
foreach ($tunInterface in $tunInterfaces) {
    $deadline = (Get-Date).AddSeconds($settings.PostStartTunWaitSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $tun = Get-NetIPInterface -InterfaceAlias $tunInterface -ErrorAction SilentlyContinue
    } while (-not $tun -and (Get-Date) -lt $deadline)
    if (-not $tun) { throw "Interface '$tunInterface' was not found before the timeout." }
    foreach ($family in @('IPv4', 'IPv6')) {
        Set-NetIPInterface -Forwarding Enabled -InterfaceAlias $tunInterface -AddressFamily $family
    }
    Write-Host "[PostStart] Enabled IPv4 and IPv6 forwarding on '$tunInterface'."
}

$bridge = Get-NetIPInterface -InterfaceAlias $bridgeInterface -ErrorAction SilentlyContinue
if ($bridge) {
    foreach ($family in @('IPv4', 'IPv6')) {
        Set-NetIPInterface -Forwarding Enabled -InterfaceAlias $bridgeInterface -AddressFamily $family
    }
    Write-Host "[PostStart] Enabled IPv4 and IPv6 forwarding on '$bridgeInterface'."
}

$dnsPorts = @(
    $config.inbounds |
        Where-Object { $settings.DnsInboundTags -contains $_.tag } |
        ForEach-Object listen_port |
        Select-Object -Unique
)
Get-NetFirewallRule -DisplayName 'sing-box DNS*' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
foreach ($port in $dnsPorts) {
    foreach ($protocol in @('TCP', 'UDP')) {
        $ruleName = "sing-box DNS $port ($protocol)"
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
            -Protocol $protocol -LocalPort $port `
            -RemoteAddress $settings.DnsFirewallRemoteAddress `
            -InterfaceAlias $bridgeInterface `
            -Program (Join-Path $root 'runtime\sing-box.exe') | Out-Null
    }
    Write-Host "[PostStart] Allowed TCP and UDP DNS on port $port from '$($settings.DnsFirewallRemoteAddress)' via '$bridgeInterface'."
}

# New-NetRoute -DestinationPrefix "198.18.0.0/15" `
#              -InterfaceAlias "Meta" `
#              -NextHop "0.0.0.0" `
#              -RouteMetric 1 `
#              -AddressFamily IPv4 `
#              -PolicyStore ActiveStore
# New-NetRoute -DestinationPrefix "fd18:1111:1111::/64" `
#              -InterfaceAlias "Meta" `
#              -NextHop "::" `
#              -RouteMetric 1 `
#              -AddressFamily IPv6 `
#              -PolicyStore ActiveStore
# Write-Host "[PostStart] Route created."

