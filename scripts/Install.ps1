[CmdletBinding()]
param(
    [switch]$SkipMigration
)

# Run from an elevated PowerShell 7 terminal.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$versions = Import-PowerShellDataFile (Join-Path $root 'versions.psd1')
$settings = Import-PowerShellDataFile (Join-Path $root 'settings.psd1')
$work = Join-Path $root 'work\install'
New-Item -ItemType Directory -Force -Path $work, (Join-Path $root 'runtime'), (Join-Path $root 'data'), (Join-Path $root 'logs'), (Join-Path $root 'sub-store\data') | Out-Null

function Download([string]$Uri, [string]$Path) {
    Write-Host "Downloading $Uri"
    $partial = "$Path.download"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial
            Move-Item -LiteralPath $partial -Destination $Path -Force
            return
        } catch {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if ($attempt -eq 3) { throw }
            Write-Warning "Download attempt $attempt failed; retrying in 3 seconds."
            Start-Sleep -Seconds 3
        }
    }
}
function Expand-Clean([string]$Archive, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
}
function Find-WebRoot([string]$Archive, [string]$StagingPath) {
    Expand-Clean $Archive $StagingPath
    $indexes = @(Get-ChildItem -LiteralPath $StagingPath -Recurse -File -Filter index.html)
    if ($indexes.Count -ne 1) { throw "Expected one index.html in $Archive; found $($indexes.Count)." }
    return $indexes[0].Directory.FullName
}
function Install-WebRoot([string]$Source, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}
function Test-ServiceInstalled([string]$Name) {
    return $null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)
}
function Stop-WinSW([string]$Wrapper, [string]$Name, [bool]$Installed) {
    if (-not $Installed) { return }
    if ((Get-Service -Name $Name).Status -eq 'Stopped') { return }
    & $Wrapper stopwait
    if ($LASTEXITCODE -ne 0) { throw "WinSW stopwait failed for $Wrapper with exit code $LASTEXITCODE" }
}
function Register-WinSW([string]$Wrapper, [bool]$Installed) {
    if ($Installed) { return }
    & $Wrapper install
    if ($LASTEXITCODE -ne 0) { throw "WinSW install failed for $Wrapper with exit code $LASTEXITCODE" }
}
function Start-WinSW([string]$Wrapper) {
    & $Wrapper start
    if ($LASTEXITCODE -ne 0) { throw "WinSW start failed for $Wrapper with exit code $LASTEXITCODE" }
}
function Sync-SubStoreServiceXml {
    $path = Join-Path $root 'sub-store-service.xml'
    [xml]$xml = Get-Content -LiteralPath $path -Raw
    $values = @{
        SUB_STORE_BACKEND_API_HOST = $settings.SubStoreListen
        SUB_STORE_BACKEND_API_PORT = [string]$settings.SubStoreBackendPort
        SUB_STORE_FRONTEND_HOST = $settings.SubStoreListen
        SUB_STORE_FRONTEND_PORT = [string]$settings.SubStoreFrontendPort
        SUB_STORE_FRONTEND_BACKEND_PATH = '/'
        SUB_STORE_CORS_ALLOWED_ORIGINS = "http://$($settings.SubStoreListen):$($settings.SubStoreFrontendPort),http://localhost:$($settings.SubStoreFrontendPort)"
    }
    foreach ($envNode in $xml.service.env) {
        if ($values.ContainsKey($envNode.name)) { $envNode.value = $values[$envNode.name] }
    }
    $xml.Save($path)
}

$singWrapper = Join-Path $root 'sing-box-service.exe'
$subStoreWrapper = Join-Path $root 'sub-store-service.exe'
$singInstalled = Test-ServiceInstalled 'sing-box'
$subStoreInstalled = Test-ServiceInstalled 'sub-store'

$singArchive = Join-Path $work 'sing-box.zip'
Download "https://github.com/SagerNet/sing-box/releases/download/v$($versions.SingBox)/sing-box-$($versions.SingBox)-windows-amd64.zip" $singArchive
$singExtract = Join-Path $work 'sing-box'
Expand-Clean $singArchive $singExtract
$stagedSingBox = (Get-ChildItem $singExtract -Recurse -File -Filter sing-box.exe | Select-Object -First 1).FullName
if (-not $stagedSingBox) { throw 'sing-box.exe was not found in the downloaded archive.' }

$nodeArchive = Join-Path $work 'node.zip'
Download "https://nodejs.org/dist/v$($versions.Node)/node-v$($versions.Node)-win-x64.zip" $nodeArchive
$nodeExtract = Join-Path $work 'node'
Expand-Clean $nodeArchive $nodeExtract
$stagedNode = (Get-ChildItem $nodeExtract -Recurse -File -Filter node.exe | Select-Object -First 1).FullName
if (-not $stagedNode) { throw 'node.exe was not found in the downloaded archive.' }

$stagedSubStore = Join-Path $work 'sub-store.bundle.js'
Download "https://github.com/sub-store-org/Sub-Store/releases/download/$($versions.SubStore)/sub-store.bundle.js" $stagedSubStore
$frontendArchive = Join-Path $work 'sub-store-frontend.zip'
Download "https://github.com/sub-store-org/Sub-Store-Front-End/releases/download/$($versions.SubStoreFrontend)/dist.zip" $frontendArchive
$frontendRoot = Find-WebRoot $frontendArchive (Join-Path $work 'sub-store-frontend')

$dashboardArchive = Join-Path $work 'zashboard.zip'
Download "https://github.com/Zephyruso/zashboard/releases/download/v$($versions.Zashboard)/dist.zip" $dashboardArchive
$dashboardRoot = Find-WebRoot $dashboardArchive (Join-Path $work 'zashboard')

$winsw = Join-Path $work 'WinSW-x64.exe'
Download "https://github.com/winsw/winsw/releases/download/v$($versions.WinSW)/WinSW-x64.exe" $winsw

if (-not $SkipMigration -and -not (Test-Path (Join-Path $root 'local\runtime.json'))) {
    & (Join-Path $PSScriptRoot 'Migrate-Mihomo.ps1')
}
if (-not (Test-Path (Join-Path $root 'local\runtime.json'))) {
    throw 'Create local/runtime.json from local/runtime.example.json before continuing.'
}

Sync-SubStoreServiceXml
Stop-WinSW $subStoreWrapper 'sub-store' $subStoreInstalled
Copy-Item $stagedNode (Join-Path $root 'runtime\node.exe') -Force
Copy-Item $stagedSubStore (Join-Path $root 'sub-store\sub-store.bundle.js') -Force
Install-WebRoot $frontendRoot (Join-Path $root 'sub-store\frontend')
Copy-Item $winsw $subStoreWrapper -Force
Register-WinSW $subStoreWrapper $subStoreInstalled
Start-WinSW $subStoreWrapper

& (Join-Path $PSScriptRoot 'Initialize-SubStore.ps1')
& (Join-Path $PSScriptRoot 'Update-Config.ps1') -NoRestart -CorePath $stagedSingBox

Stop-WinSW $singWrapper 'sing-box' $singInstalled
Copy-Item $stagedSingBox (Join-Path $root 'runtime\sing-box.exe') -Force
Install-WebRoot $dashboardRoot (Join-Path $root 'ui')
Copy-Item $winsw $singWrapper -Force
Register-WinSW $singWrapper $singInstalled
Start-WinSW $singWrapper

Write-Host 'Installation complete.'
Write-Host "Zashboard: http://$($settings.SingBoxApiListen):$($settings.SingBoxApiPort)/ui/"
Write-Host "Sub-Store: http://$($settings.SubStoreListen):$($settings.SubStoreFrontendPort)/"

