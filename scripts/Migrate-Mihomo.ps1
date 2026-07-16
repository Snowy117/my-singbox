[CmdletBinding()]
param(
    [string]$MihomoConfig = (Join-Path $PSScriptRoot '..\mihomo.yaml'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\local\runtime.json'),
    [string[]]$ExcludeProviders = @('Weiba')
)

$ErrorActionPreference = 'Stop'
$text = Get-Content -LiteralPath $MihomoConfig -Raw

function Match-One([string]$Pattern, [string]$Label) {
    $match = [regex]::Match($text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success) { throw "Unable to find $Label in $MihomoConfig" }
    return $match.Groups[1].Value
}

$providerSection = Match-One '(?ms)^proxy-providers:[^\S\r\n]*\r?\n(.+?)^#{10,}' 'proxy-providers section'
$subscriptions = @()
$currentProvider = $null
function Add-CurrentProvider {
    if (-not $currentProvider -or -not $currentProvider.url) { return }
    if ($ExcludeProviders -icontains $currentProvider.name) {
        Write-Host "Skipped proxy provider: $($currentProvider.name)"
        return
    }
    $script:subscriptions += $currentProvider
}

foreach ($line in ($providerSection -split '\r?\n')) {
    if ($line -match '^  ([^ <][^:]*):\s*$') {
        Add-CurrentProvider
        $name = $Matches[1].Trim()
        $currentProvider = [ordered]@{ name = $name; url = $null; prefix = "$name>" }
        continue
    }
    if (-not $currentProvider) { continue }
    if ($line -match '^    url:\s*["'']?([^"''\r\n]+?)["'']?\s*$') {
        $currentProvider.url = $Matches[1].Trim()
    } elseif ($line -match '^      additional-prefix:\s*["'']?([^"''\r\n]+?)["'']?\s*$') {
        $currentProvider.prefix = $Matches[1].Trim()
    }
}
Add-CurrentProvider
if ($subscriptions.Count -eq 0) { throw 'No proxy provider subscriptions were found.' }

$mixedUser = Match-One '(?ms)^authentication:\s*\r?\n\s*-\s*["'']?([^"''\r\n]+)' 'mixed authentication'
$mixedParts = $mixedUser.Split(':', 2)
if ($mixedParts.Count -ne 2) { throw 'Mixed authentication must use username:password.' }
$clashSecret = Match-One '(?ms)^external-controller:.*?^secret:\s*["'']?([^"''\r\n]+)' 'Clash API secret'

$pkuBlock = Match-One '(?ms)^  - name:\s*["'']?PKU["'']?\s*(.+?)(?=^  - name:|^# 策略组)' 'PKU outbound'
function Match-Pku([string]$Pattern, [string]$Label) {
    $match = [regex]::Match($pkuBlock, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success) { throw "Unable to find PKU $Label" }
    return $match.Groups[1].Value.Trim()
}
$pkuServer = Match-Pku '^    server:\s*([^\s#]+)' 'server'
$pkuSni = Match-Pku '^    sni:\s*([^\s#]+)' 'SNI'
$pkuHost = Match-Pku '^        Host:\s*([^\s#]+)' 'Host header'
$pkuPath = Match-Pku '^      path:\s*["'']?([^"''\r\n#]+)' 'WebSocket path'

$runtime = [ordered]@{
    mixed_users = @([ordered]@{ username = $mixedParts[0]; password = $mixedParts[1] })
    clash_secret = $clashSecret
    subscriptions = $subscriptions
    custom_outbounds = @([ordered]@{
        type = 'vless'
        tag = 'PKU'
        server = $pkuServer
        server_port = [int](Match-Pku '^    port:\s*(\d+)' 'port')
        uuid = Match-Pku '^    uuid:\s*["'']?([^"''\s#]+)' 'UUID'
        tls = [ordered]@{ enabled = $true; server_name = $pkuSni }
        transport = [ordered]@{
            type = 'ws'
            path = $pkuPath
            headers = [ordered]@{ Host = $pkuHost }
        }
    })
}

$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$runtime | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Migrated $($subscriptions.Count) subscriptions and the PKU outbound to $OutputPath"

