[CmdletBinding()]
param(
    [string]$MihomoConfig = (Join-Path $PSScriptRoot '..\mihomo.yaml'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\local\runtime.json'),
    [string[]]$ExcludeProviders = @('Weiba'),
    [string]$YqPath
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Resolve-Yq([string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "yq was not found: $ExplicitPath"
        }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    $bundled = Join-Path $root 'runtime\yq.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
    $command = Get-Command yq -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'yq was not found. Run Install.ps1 or pass -YqPath.'
}

$resolvedConfig = (Resolve-Path -LiteralPath $MihomoConfig).Path
$yq = Resolve-Yq $YqPath
$mihomoJson = (& $yq eval -o=json '.' $resolvedConfig | Out-String)
if ($LASTEXITCODE -ne 0) { throw "yq failed to parse $resolvedConfig" }
$mihomo = $mihomoJson | ConvertFrom-Json

$subscriptions = [Collections.Generic.List[object]]::new()
foreach ($providerProperty in @($mihomo.'proxy-providers'.PSObject.Properties)) {
    $name = $providerProperty.Name
    $provider = $providerProperty.Value
    if ($ExcludeProviders -icontains $name) {
        Write-Host "Skipped proxy provider: $name"
        continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$provider.url)) { continue }
    $prefix = [string]$provider.override.'additional-prefix'
    if ([string]::IsNullOrEmpty($prefix)) { $prefix = "$name>" }
    $subscriptions.Add([ordered]@{ name = $name; url = $provider.url; prefix = $prefix })
}
if (-not $subscriptions.Count) { throw 'No proxy provider subscriptions were found.' }

$authentication = [string]@($mihomo.authentication)[0]
if ([string]::IsNullOrWhiteSpace($authentication)) { throw 'No authentication entry was found.' }
$mixedParts = $authentication.Split(':', 2)
if ($mixedParts.Count -ne 2) { throw 'The first authentication entry must use username:password.' }
if ([string]::IsNullOrWhiteSpace([string]$mihomo.secret)) { throw 'The Clash API secret is empty.' }

$customOutbounds = [Collections.Generic.List[object]]::new()
foreach ($proxy in @($mihomo.proxies)) {
    if ($proxy.type -eq 'direct') { continue }
    if ($proxy.type -ne 'vless') {
        Write-Warning "Skipped unsupported local proxy type '$($proxy.type)': $($proxy.name)"
        continue
    }
    $outbound = [ordered]@{
        type = 'vless'
        tag = $proxy.name
        server = $proxy.server
        server_port = [int]$proxy.port
        uuid = $proxy.uuid
    }
    if ($proxy.tls) {
        $serverName = if ($proxy.sni) { $proxy.sni } else { $proxy.server }
        $outbound.tls = [ordered]@{ enabled = $true; server_name = $serverName }
    }
    if ($proxy.network -eq 'ws') {
        $headers = [ordered]@{}
        foreach ($property in @($proxy.'ws-opts'.headers.PSObject.Properties)) {
            $headers[$property.Name] = $property.Value
        }
        $outbound.transport = [ordered]@{
            type = 'ws'
            path = $proxy.'ws-opts'.path
            headers = $headers
        }
    }
    $customOutbounds.Add($outbound)
}

$runtime = [ordered]@{
    mixed_users = @([ordered]@{ username = $mixedParts[0]; password = $mixedParts[1] })
    clash_secret = $mihomo.secret
    subscriptions = @($subscriptions)
    custom_outbounds = @($customOutbounds)
}
$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$runtime | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Migrated $($subscriptions.Count) subscriptions and $($customOutbounds.Count) custom outbounds to $OutputPath"
