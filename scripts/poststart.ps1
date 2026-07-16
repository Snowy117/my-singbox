$ErrorActionPreference = 'Stop'

$tunInterface = 'Meta'
$bridgeInterface = 'vEthernet (Network Bridge)'
$deadline = (Get-Date).AddSeconds(60)

do {
    Start-Sleep -Milliseconds 500
    $tun = Get-NetIPInterface -InterfaceAlias $tunInterface -ErrorAction SilentlyContinue
} while (-not $tun -and (Get-Date) -lt $deadline)

if (-not $tun) {
    Write-Host "[PostStart] Interface '$tunInterface' not found within the timeout period."
    exit 1
}

Set-NetIPInterface -Forwarding Enabled -InterfaceAlias $tunInterface
Write-Host "[PostStart] Enabled IP forwarding on interface '$tunInterface'."

$bridge = Get-NetIPInterface -InterfaceAlias $bridgeInterface -ErrorAction SilentlyContinue
if ($bridge) {
    Set-NetIPInterface -Forwarding Enabled -InterfaceAlias $bridgeInterface
    Write-Host "[PostStart] Enabled IP forwarding on interface '$bridgeInterface'."
} else {
    Write-Host "[PostStart] Interface '$bridgeInterface' not found."
}

