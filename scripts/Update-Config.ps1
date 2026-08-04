[CmdletBinding()]
param(
    [string]$TemplatePath = (Join-Path $PSScriptRoot '..\config.yaml'),
    [string]$CorePath,
    [string]$YqPath,
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Import-PowerShellDataFile (Join-Path $root 'settings.psd1')
$runtimePath = Join-Path $root 'local\runtime.json'
$runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
$work = Join-Path $root 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$allOutbounds = [Collections.Generic.List[object]]::new()
$allEndpoints = [Collections.Generic.List[object]]::new()
$baseUri = "http://$($settings.SubStoreListen):$($settings.SubStoreBackendPort)"
foreach ($subscription in @($runtime.subscriptions)) {
    $name = [uri]::EscapeDataString($subscription.name)
    $uri = "$baseUri/download/$name/sing-box?noCache=true"
    Write-Host "Fetching subscription: $($subscription.name)"
    $produced = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'sing-box' }
    $items = @($produced.outbounds) + @($produced.endpoints)
    $tagMap = @{}
    foreach ($item in $items) {
        if ([string]::IsNullOrWhiteSpace([string]$item.tag)) {
            throw "Subscription '$($subscription.name)' produced an item without a tag."
        }
        $tagMap[$item.tag] = "$($subscription.prefix)$($item.tag)"
    }
    foreach ($item in $items) {
        $item.tag = $tagMap[$item.tag]
        if ($item.PSObject.Properties['detour'] -and $tagMap.ContainsKey($item.detour)) {
            $item.detour = $tagMap[$item.detour]
        }
        if ($item.PSObject.Properties['outbounds']) {
            $item.outbounds = @($item.outbounds | ForEach-Object {
                if ($tagMap.ContainsKey($_)) { $tagMap[$_] } else { $_ }
            })
        }
    }
    foreach ($item in @($produced.outbounds)) { $allOutbounds.Add($item) }
    foreach ($item in @($produced.endpoints)) { $allEndpoints.Add($item) }
}

$nodesPath = Join-Path $work 'nodes.json'
[ordered]@{ outbounds = @($allOutbounds); endpoints = @($allEndpoints) } |
    ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $nodesPath -Encoding utf8NoBOM

$candidate = Join-Path $work 'config.candidate.json'
$buildParams = @{
    NodesPath = $nodesPath
    TemplatePath = $TemplatePath
    RuntimePath = $runtimePath
    OutputPath = $candidate
}
if ($YqPath) { $buildParams.YqPath = $YqPath }
& (Join-Path $PSScriptRoot 'Build-Config.ps1') @buildParams

$core = if ($CorePath) { $CorePath } else { Join-Path $root 'runtime\sing-box.exe' }
if (-not (Test-Path -LiteralPath $core -PathType Leaf)) { throw "sing-box core not found: $core" }
& $core check -D (Join-Path $root 'data') -c $candidate
if ($LASTEXITCODE -ne 0) { throw "sing-box check failed with exit code $LASTEXITCODE" }

$live = Join-Path $root 'config.json'
$backup = Join-Path $work 'config.previous.json'
if (Test-Path -LiteralPath $live -PathType Leaf) { Copy-Item $live $backup -Force }
Move-Item $candidate $live -Force
Write-Host "Installed validated config: $live"

if ($Restart) {
    $wrapper = Join-Path $root 'sing-box-service.exe'
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
        throw "Cannot restart because the WinSW wrapper was not found: $wrapper"
    }
    & $wrapper restart
    if ($LASTEXITCODE -ne 0) {
        $restartExitCode = $LASTEXITCODE
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
            throw "WinSW restart failed with exit code $restartExitCode; no previous config is available."
        }
        Copy-Item -LiteralPath $backup -Destination $live -Force
        & $wrapper restart
        if ($LASTEXITCODE -ne 0) {
            throw "WinSW restart failed with exit code $restartExitCode; rollback was restored but its restart also failed with exit code $LASTEXITCODE."
        }
        throw "WinSW restart failed with exit code $restartExitCode; the previous config was restored and restarted."
    }
}
