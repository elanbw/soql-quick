$ErrorActionPreference = "Stop"
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $projectDir

if (-not (Test-Path ".env")) {
  throw "Missing .env. Copy .env.example to .env and configure the Salesforce External Client App first."
}

Get-Content ".env" | ForEach-Object {
  if ($_ -match '^\s*([^#][^=]*)=(.*)$') {
    [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), "Process")
  }
}

if (-not $env:SALESFORCE_CLIENT_ID) { throw "SALESFORCE_CLIENT_ID is required." }
npm ci
npm run check
npm run build
Write-Host "Installers are under src-tauri\target\release\bundle\."
