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
function Assert-PortAvailable([int]$Port) {
    $owners = @(
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess
        Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess
    ) | Sort-Object -Unique
    if ($owners.Count) {
        throw "Port $Port is already in use by process ID(s): $($owners -join ', ')."
    }
}
function Assert-DnsPortAvailable([int]$Port) {
    $tcpOwners = @(
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess
    ) | Sort-Object -Unique
    if ($tcpOwners.Count) {
        throw "TCP port $Port is already in use by process ID(s): $($tcpOwners -join ', ')."
    }

    $udpOwners = @(
        Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess
    ) | Sort-Object -Unique
    foreach ($processId in $udpOwners) {
        $serviceNames = @(
            Get-CimInstance Win32_Service -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name
        )
        if ($settings.DnsReuseAddr -and $serviceNames -contains 'SharedAccess') {
            Write-Warning "UDP port $Port is also owned by SharedAccess (PID $processId); continuing with reuse_addr enabled."
            continue
        }
        $ownerDescription = if ($serviceNames.Count) {
            "PID $processId (service: $($serviceNames -join ', '))"
        } else {
            "PID $processId"
        }
        throw "UDP port $Port is already in use by $ownerDescription."
    }
}
function Wait-SingBoxHealthy([int]$Seconds = 90) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $headers = @{ Authorization = "Bearer $($runtime.clash_secret)" }
    do {
        $service = Get-Service -Name 'sing-box' -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            if (-not $settings.ClashApiEnabled) { return }
            try {
                $version = Invoke-RestMethod `
                    -Uri "http://$($settings.ClashApiListen):$($settings.ClashApiPort)/version" `
                    -Headers $headers -TimeoutSec 2
                if ($version.version) { return }
            } catch {
                # The service may still be downloading initial remote rule-sets.
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "sing-box did not become healthy within $Seconds seconds."
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
$runtime = Get-Content (Join-Path $root 'local\runtime.json') -Raw | ConvertFrom-Json

Sync-SubStoreServiceXml
Stop-WinSW $subStoreWrapper 'sub-store' $subStoreInstalled
Copy-Item $stagedNode (Join-Path $root 'runtime\node.exe') -Force
Copy-Item $stagedSubStore (Join-Path $root 'sub-store\sub-store.bundle.js') -Force
Install-WebRoot $frontendRoot (Join-Path $root 'sub-store\frontend')
Copy-Item $winsw $subStoreWrapper -Force
Register-WinSW $subStoreWrapper $subStoreInstalled
Start-WinSW $subStoreWrapper

& (Join-Path $PSScriptRoot 'Initialize-SubStore.ps1')

$singBackup = Join-Path $work 'sing-box-backup'
if (Test-Path $singBackup) { Remove-Item $singBackup -Recurse -Force }
New-Item -ItemType Directory -Force -Path $singBackup | Out-Null
$backupFiles = [ordered]@{
    'sing-box.exe' = (Join-Path $root 'runtime\sing-box.exe')
    'config.json' = (Join-Path $root 'config.json')
    'sing-box-service.exe' = $singWrapper
}
foreach ($entry in $backupFiles.GetEnumerator()) {
    if (Test-Path -LiteralPath $entry.Value -PathType Leaf) {
        Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $singBackup $entry.Key) -Force
    }
}

$singRegisteredDuringInstall = $false
try {
    & (Join-Path $PSScriptRoot 'Update-Config.ps1') -NoRestart -CorePath $stagedSingBox
    Stop-WinSW $singWrapper 'sing-box' $singInstalled
    Assert-DnsPortAvailable $settings.DnsListenPort
    if ($settings.NativeApiEnabled) { Assert-PortAvailable $settings.NativeApiPort }
    if ($settings.ClashApiEnabled) { Assert-PortAvailable $settings.ClashApiPort }
    Assert-PortAvailable $settings.MixedPort

    Copy-Item $stagedSingBox (Join-Path $root 'runtime\sing-box.exe') -Force
    Install-WebRoot $dashboardRoot (Join-Path $root 'ui')
    Copy-Item $winsw $singWrapper -Force
    Register-WinSW $singWrapper $singInstalled
    $singRegisteredDuringInstall = -not $singInstalled
    Start-WinSW $singWrapper
    Wait-SingBoxHealthy
} catch {
    $upgradeError = $_
    Write-Warning "sing-box upgrade failed: $($upgradeError.Exception.Message)"
    if (Test-ServiceInstalled 'sing-box') {
        & $singWrapper stopwait 2>$null
    }
    if ($singRegisteredDuringInstall) {
        & $singWrapper uninstall 2>$null
    }
    foreach ($entry in $backupFiles.GetEnumerator()) {
        $backupPath = Join-Path $singBackup $entry.Key
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Copy-Item -LiteralPath $backupPath -Destination $entry.Value -Force
        } elseif (-not $singInstalled) {
            Remove-Item -LiteralPath $entry.Value -Force -ErrorAction SilentlyContinue
        }
    }
    if ($singInstalled -and
        (Test-Path -LiteralPath (Join-Path $root 'runtime\sing-box.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $root 'config.json') -PathType Leaf)) {
        Start-WinSW $singWrapper
    }
    throw $upgradeError
}

Write-Host 'Installation complete.'
Write-Host "Zashboard: http://$($settings.ClashApiListen):$($settings.ClashApiPort)/ui/"
if ($settings.NativeApiEnabled) {
    Write-Host "sing-box native API (gRPC/gRPC-Web): http://$($settings.NativeApiListen):$($settings.NativeApiPort)/"
}
Write-Host "DNS for local virtual machines: $($settings.DnsListenAddresses -join ', '):$($settings.DnsListenPort) (TCP/UDP)"
Write-Host "Sub-Store: http://$($settings.SubStoreListen):$($settings.SubStoreFrontendPort)/"

