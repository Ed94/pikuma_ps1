# scripts/launch_pcsx_debug.ps1
#
# One-shot launcher for debug sessions: starts pcsx-redux with the .ps-exe
# loaded, the gdb stub enabled, AND the pcsx_debug_helper Lua plugin loaded
# so external CLI tools (gdb's `shell` command, etc.)
# can read GTE state via http://localhost:8080/api/v1/lua/gte
# (the gdb stub doesn't expose COP2 at all).
#
# usage:
#   .\scripts\launch_pcsx_debug.ps1
#   .\scripts\launch_pcsx_debug.ps1 -ExePath build\hello_gte.ps-exe
#   .\scripts\launch_pcsx_debug.ps1 -HelperZip scripts\pcsx_debug_helper.zip
#
# After launch:
#   - gdb: target remote localhost:3333
#   - web: curl http://localhost:8080/api/v1/lua/gte
#
# Companion: scripts/debug_psyq.ps1 (bare launch — no .ps-exe, no helper).

[CmdletBinding()]
param(
    [string]$PcsxPath = (Join-Path $PSScriptRoot '..\toolchain\pcsx-redux\vsprojects\x64\Release\pcsx-redux.exe'),
    [string]$ExePath  = (Join-Path $PSScriptRoot '..\build\hello_gte.ps-exe'),
    [string]$HelperZip = (Join-Path $PSScriptRoot 'pcsx_debug_helper.zip'),
    [int]   $GdbPort  = 3333,
    [int]   $WebPort  = 8080
)

$ErrorActionPreference = 'Stop'

$gdbInitPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build\gen\hello_gte.gdbinit'))
if (-not (Test-Path -LiteralPath $gdbInitPath -PathType Leaf)) {
    Write-Warning "Generated GDB skip sidecar missing (non-fatal): $gdbInitPath. Run the GTE build to regenerate it; debugger launch will continue without generated skip-over commands."
}

# ── Pre-checks ──
foreach ($p in @($PcsxPath, $ExePath, $HelperZip)) {
    if (-not (Test-Path $p)) {
        Write-Error "Missing: $p"
        exit 1
    }
}

# Kill any existing pcsx-redux so the archive file isn't locked.
Get-Process pcsx-redux -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# ── Launch ──
$absExe  = [System.IO.Path]::GetFullPath($ExePath)
$absZip  = [System.IO.Path]::GetFullPath($HelperZip)

$args = @(
    '-gdb', '-run'
    '-loadexe', "`"$absExe`""
    '-archive', "`"$absZip`""
)

Write-Host "Launching pcsx-redux..." -ForegroundColor Cyan
Write-Host "  ps-exe    : $absExe"
Write-Host "  helper zip: $absZip"
Write-Host "  gdb       : localhost:$GdbPort"
Write-Host "  web       : localhost:$WebPort/api/v1/lua/gte"
Write-Host ""

Start-Process -FilePath $PcsxPath -ArgumentList $args | Out-Null

# ── Wait for both endpoints to come up ──
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    $gdbUp = $false
    $webUp = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.BeginConnect('localhost', $GdbPort, $null, $null) | Out-Null
        Start-Sleep -Milliseconds 100
        $gdbUp = $tcp.Connected
        $tcp.Close()
    } catch { $gdbUp = $false }
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$WebPort/" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
        $webUp = $r.StatusCode -ne 0
    } catch { $webUp = $false }
    if ($gdbUp -and $webUp) { break }
    Start-Sleep -Milliseconds 500
}

# ── Smoke-test the gte handler ──
try {
    $r = Invoke-WebRequest -Uri "http://localhost:$WebPort/api/v1/lua/gte" -UseBasicParsing -TimeoutSec 5
    $firstLine = ([System.Text.Encoding]::UTF8.GetString($r.Content) -split "`n")[0]
    Write-Host "GTE handler OK: $firstLine" -ForegroundColor Green
} catch {
    Write-Warning "GTE handler NOT responding: $_"
    Write-Host "Check the pcsx-redux Lua Console for debug cli messages." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "pcsx-redux running. PIDs:" -ForegroundColor Cyan
Get-Process pcsx-redux | Select-Object Id, ProcessName | Format-Table
