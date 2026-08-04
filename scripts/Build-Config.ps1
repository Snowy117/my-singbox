[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$NodesPath,
    [string]$TemplatePath = (Join-Path $PSScriptRoot '..\config.yaml'),
    [string]$RuntimePath = (Join-Path $PSScriptRoot '..\local\runtime.json'),
    [string]$YqPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\work\config.candidate.json')
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Resolve-Tool([string]$ExplicitPath, [string]$BundledPath, [string]$CommandName) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "$CommandName was not found: $ExplicitPath"
        }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    if (Test-Path -LiteralPath $BundledPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $BundledPath).Path
    }
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "$CommandName was not found. Run scripts/Install.ps1 or pass -YqPath."
}

function Get-UniqueStrings([object[]]$Values) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $Values) {
        $text = [string]$value
        if ($seen.Add($text)) { $text }
    }
}

function Assert-UniqueTags([object[]]$Items, [string]$Kind) {
    $duplicates = @(
        $Items |
            Where-Object { $_.PSObject.Properties['tag'] } |
            Group-Object tag |
            Where-Object Count -gt 1 |
            ForEach-Object Name
    )
    if ($duplicates.Count) {
        throw "Duplicate $Kind tag(s): $($duplicates -join ', ')"
    }
}

$resolvedTemplate = (Resolve-Path -LiteralPath $TemplatePath).Path
$resolvedRuntime = (Resolve-Path -LiteralPath $RuntimePath).Path
$resolvedNodes = (Resolve-Path -LiteralPath $NodesPath).Path
$yq = Resolve-Tool $YqPath (Join-Path $root 'runtime\yq.exe') 'yq'

$templateJson = (& $yq eval -o=json '.' $resolvedTemplate | Out-String)
if ($LASTEXITCODE -ne 0) { throw "yq failed to convert $resolvedTemplate" }
$config = $templateJson | ConvertFrom-Json
$runtime = Get-Content -LiteralPath $resolvedRuntime -Raw | ConvertFrom-Json
$nodes = Get-Content -LiteralPath $resolvedNodes -Raw | ConvertFrom-Json

$subscriptionOutbounds = @($nodes.outbounds)
$subscriptionEndpoints = @($nodes.endpoints)
$customOutbounds = @($runtime.custom_outbounds)
$insertedOutbounds = @($customOutbounds) + @($subscriptionOutbounds)
$allNodeItems = @($insertedOutbounds) + @($subscriptionEndpoints)
$allNodeTags = @($allNodeItems | ForEach-Object tag)
$subscriptionTags = @($subscriptionOutbounds | ForEach-Object tag) + @($subscriptionEndpoints | ForEach-Object tag)
$customTags = @($customOutbounds | ForEach-Object tag)

if ($allNodeItems.Count -ne $allNodeTags.Count -or
    @($allNodeTags | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count) {
    throw 'Every inserted outbound and endpoint must have a non-empty tag.'
}
Assert-UniqueTags $allNodeItems 'inserted node'

$markerIndexes = @(
    for ($index = 0; $index -lt @($config.outbounds).Count; $index++) {
        if ($config.outbounds[$index].tag -eq '__INSERT_NODES__') { $index }
    }
)
if ($markerIndexes.Count -ne 1) {
    throw 'config.yaml must contain exactly one outbound tagged __INSERT_NODES__.'
}
$markerIndex = $markerIndexes[0]
$before = if ($markerIndex -gt 0) { @($config.outbounds[0..($markerIndex - 1)]) } else { @() }
$after = if ($markerIndex -lt @($config.outbounds).Count - 1) {
    @($config.outbounds[($markerIndex + 1)..(@($config.outbounds).Count - 1)])
} else {
    @()
}
$config.outbounds = @($before) + @($insertedOutbounds) + @($after)

if (-not $config.PSObject.Properties['endpoints']) {
    $config | Add-Member -NotePropertyName endpoints -NotePropertyValue @()
}
$config.endpoints = @($config.endpoints) + @($subscriptionEndpoints)

$regionPatterns = @{
    '__HK_NODES__' = '(?i)(香港|\bHK\b|Hong\s*Kong|🇭🇰)'
    '__TW_NODES__' = '(?i)(台湾|台灣|\bTW\b|Taiwan|🇹🇼)'
    '__SG_NODES__' = '(?i)(新加坡|狮城|獅城|\bSG\b|Singapore|🇸🇬)'
    '__JP_NODES__' = '(?i)(日本|\bJP\b|Japan|🇯🇵)'
    '__US_NODES__' = '(?i)(美国|美國|\bUS\b|United\s*States|America|Los\s*Angeles|Chicago|Ashburn|Seattle|Kansas|🇺🇸|🇺🇲)'
    '__EU_NODES__' = '(?i)(欧洲|歐洲|\bEU\b|🇪🇺|🇦🇱|🇦🇩|🇦🇹|🇧🇾|🇧🇪|🇧🇦|🇧🇬|🇭🇷|🇨🇾|🇨🇿|🇩🇰|🇪🇪|🇫🇮|🇫🇷|🇩🇪|🇬🇷|🇭🇺|🇮🇸|🇮🇪|🇮🇹|🇽🇰|🇱🇻|🇱🇮|🇱🇹|🇱🇺|🇲🇹|🇲🇩|🇲🇨|🇲🇪|🇳🇱|🇲🇰|🇳🇴|🇵🇱|🇵🇹|🇷🇴|🇷🇺|🇸🇲|🇷🇸|🇸🇰|🇸🇮|🇪🇸|🇸🇪|🇨🇭|🇹🇷|🇺🇦|🇬🇧|🇻🇦)'
}
$expansions = @{
    '__ALL_NODES__' = @($allNodeTags)
    '__SUBSCRIPTION_NODES__' = @($subscriptionTags)
    '__CUSTOM_NODES__' = @($customTags)
}
foreach ($entry in $regionPatterns.GetEnumerator()) {
    $expansions[$entry.Key] = @($allNodeTags | Where-Object { $_ -match $entry.Value })
}

foreach ($outbound in @($config.outbounds | Where-Object { $_.PSObject.Properties['outbounds'] })) {
    $expanded = [Collections.Generic.List[string]]::new()
    foreach ($tag in @($outbound.outbounds)) {
        if ($expansions.ContainsKey([string]$tag)) {
            $matches = @($expansions[[string]$tag])
            if (-not $matches.Count) { $matches = @('🟢 直连') }
            foreach ($match in $matches) { $expanded.Add($match) }
        } else {
            $expanded.Add([string]$tag)
        }
    }
    $outbound.outbounds = @(Get-UniqueStrings $expanded)
}

$requiresRuntimeSecret = $false
foreach ($inbound in @($config.inbounds | Where-Object {
    @($_.users | ForEach-Object Username) -contains '__RUNTIME_MIXED_USERS__'
})) {
    $inbound.users = @($runtime.mixed_users | ForEach-Object {
        [pscustomobject]@{ Username = $_.username; Password = $_.password }
    })
}
if ($config.PSObject.Properties['experimental'] -and
    $config.experimental.PSObject.Properties['clash_api'] -and
    $config.experimental.clash_api.secret -eq '__RUNTIME_CLASH_SECRET__') {
    $requiresRuntimeSecret = $true
    $config.experimental.clash_api.secret = $runtime.clash_secret
}
foreach ($service in @($config.services | Where-Object { $_.secret -eq '__RUNTIME_CLASH_SECRET__' })) {
    $requiresRuntimeSecret = $true
    $service.secret = $runtime.clash_secret
}

if ($requiresRuntimeSecret -and
    ([string]::IsNullOrWhiteSpace([string]$runtime.clash_secret) -or $runtime.clash_secret -eq 'CHANGE_ME')) {
    throw 'Set clash_secret in local/runtime.json.'
}
Assert-UniqueTags @($config.outbounds) 'outbound'
Assert-UniqueTags @($config.endpoints) 'endpoint'
Assert-UniqueTags (@($config.outbounds) + @($config.endpoints)) 'outbound/endpoint'

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Built config from $resolvedTemplate with $($insertedOutbounds.Count) inserted outbounds and $($subscriptionEndpoints.Count) endpoints: $OutputPath"
