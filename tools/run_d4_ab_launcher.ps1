# run_d4_ab_launcher.ps1  --  ASCII only, no BOM needed.
# Reads the real script as UTF-8 (it contains Chinese comments and may have
# lost its BOM) and runs it in this process.
param(
    [string]$Which = "both"
)
$ErrorActionPreference = "Stop"
$target = (Join-Path (Split-Path -Parent $PSScriptRoot) "tools\run_d4_ab.ps1")
$src = [System.IO.File]::ReadAllText($target, [System.Text.UTF8Encoding]::new($false))
& ([scriptblock]::Create($src)) -Which $Which
