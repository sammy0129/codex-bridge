param(
    [string]$Repository = (Split-Path $PSScriptRoot -Parent),
    [string]$Node = '',
    [string]$DataDir = (Join-Path $env:USERPROFILE '.codex-android-bridge')
)
$ErrorActionPreference = 'Stop'
$Repository = (Resolve-Path -LiteralPath $Repository).Path
if (-not $Node) {
    $bundled = Get-ChildItem -Path (Join-Path $Repository '.tools') -Directory -Filter 'node-v24.*-win-x64' -ErrorAction SilentlyContinue | Select-Object -First 1
    $Node = if ($bundled) { Join-Path $bundled.FullName 'node.exe' } else { (Get-Command node -ErrorAction Stop).Source }
}
$env:BRIDGE_DATA_DIR = [IO.Path]::GetFullPath($DataDir)
Set-Location -LiteralPath $Repository
& $Node (Join-Path $Repository 'apps/bridge/dist/cli.js') serve
exit $LASTEXITCODE
