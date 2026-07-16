$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Import-PowerShellDataFile (Join-Path $root 'settings.psd1')
$tunInterface = $settings.TunInterface
$bridgeInterface = $settings.DnsFirewallInterfaceAlias
$deadline = (Get-Date).AddSeconds(60)

do {
    Start-Sleep -Milliseconds 500
    $tun = Get-NetIPInterface -InterfaceAlias $tunInterface -ErrorAction SilentlyContinue
} while (-not $tun -and (Get-Date) -lt $deadline)

if (-not $tun) {
    Write-Host "[PostStart] Interface '$tunInterface' not found within the timeout period."
    exit 1
}

foreach ($family in @('IPv4', 'IPv6')) {
    Set-NetIPInterface -Forwarding Enabled -InterfaceAlias $tunInterface -AddressFamily $family
}
Write-Host "[PostStart] Enabled IPv4 and IPv6 forwarding on interface '$tunInterface'."

$bridge = Get-NetIPInterface -InterfaceAlias $bridgeInterface -ErrorAction SilentlyContinue
if ($bridge) {
    foreach ($family in @('IPv4', 'IPv6')) {
        Set-NetIPInterface -Forwarding Enabled -InterfaceAlias $bridgeInterface -AddressFamily $family
    }
    Write-Host "[PostStart] Enabled IPv4 and IPv6 forwarding on interface '$bridgeInterface'."
} else {
    Write-Host "[PostStart] Interface '$bridgeInterface' not found."
}

foreach ($protocol in @('TCP', 'UDP')) {
    $ruleName = "sing-box DNS ($protocol)"
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol $protocol -LocalPort $settings.DnsListenPort `
        -RemoteAddress $settings.DnsFirewallRemoteAddress `
        -InterfaceAlias $settings.DnsFirewallInterfaceAlias `
        -Program (Join-Path $root 'runtime\sing-box.exe') | Out-Null
}
Write-Host "[PostStart] Allowed TCP and UDP DNS from '$($settings.DnsFirewallRemoteAddress)' on '$($settings.DnsFirewallInterfaceAlias)'."

