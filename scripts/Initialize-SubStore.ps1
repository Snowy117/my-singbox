[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Import-PowerShellDataFile (Join-Path $root 'settings.psd1')
$runtime = Get-Content (Join-Path $root 'local\runtime.json') -Raw | ConvertFrom-Json
$baseUri = "http://$($settings.SubStoreListen):$($settings.SubStoreBackendPort)"

function Invoke-Json([string]$Method, [string]$Path, $Body) {
    $params = @{ Method = $Method; Uri = "$baseUri$Path" }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body = $Body | ConvertTo-Json -Depth 20
    }
    Invoke-RestMethod @params
}

$deadline = (Get-Date).AddSeconds(30)
do {
    try { $existing = (Invoke-Json GET '/api/subs' $null).data; break } catch { Start-Sleep -Seconds 1 }
} while ((Get-Date) -lt $deadline)
if ($null -eq $existing) { throw "Sub-Store is not available at $baseUri" }

Invoke-Json PATCH '/api/settings' @{ defaultTimeout = 30000 } | Out-Null
Write-Host 'Configured Sub-Store request timeout: 30000 ms'

foreach ($subscription in $runtime.subscriptions) {
    if ([string]::IsNullOrWhiteSpace([string]$subscription.url)) {
        throw "Subscription '$($subscription.name)' has no remote URL."
    }
    $body = [ordered]@{
        name = $subscription.name
        displayName = $subscription.name
        source = 'remote'
        url = $subscription.url
        ua = 'clash.meta'
        mergeSources = $null
        ignoreFailedRemoteSub = 'disabled'
        process = @()
    }
    $encodedName = [uri]::EscapeDataString($subscription.name)
    if ($existing.name -contains $subscription.name) {
        Invoke-Json PATCH "/api/sub/$encodedName" $body | Out-Null
        Write-Host "Updated Sub-Store subscription: $($subscription.name)"
    } else {
        Invoke-Json POST '/api/subs' $body | Out-Null
        Write-Host "Created Sub-Store subscription: $($subscription.name)"
    }
}

