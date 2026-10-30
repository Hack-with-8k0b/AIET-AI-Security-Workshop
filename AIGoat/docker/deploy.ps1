# AIET workshop deploy helper (Windows PowerShell) — Ollama local stack.
# Usage (from AIGoat\docker):
#   .\deploy.ps1 up
#   .\deploy.ps1 down
#   .\deploy.ps1 status
#   .\deploy.ps1 logs
#   .\deploy.ps1 restart
#
# For DuckDNS + Cloudflare Tunnel from the repo root, use:
#   .\Enable-Access.ps1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'down', 'status', 'logs', 'restart')]
    [string]$Action = 'up',

    [int]$LogTail = 100
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is not installed or not on PATH."
    }
    docker compose version | Out-Null
}

function Read-DotEnv([string]$Path) {
    $map = @{}
    if (-not (Test-Path -Path $Path)) { return $map }
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $parts = $_.Split('=', 2)
        if ($parts.Count -eq 2) {
            $map[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    return $map
}

function Ensure-Env {
    if (-not (Test-Path -Path '.env')) {
        if (-not (Test-Path -Path '.env.example')) {
            throw ".env.example not found in $PSScriptRoot"
        }
        Copy-Item '.env.example' '.env'
        Write-Host "[INFO] Created .env from .env.example — set DUCKDNS_* if you need remote access via ..\..\Enable-Access.ps1"
    }

    $map = Read-DotEnv '.env'
    if (-not $map['APP_SECRET_KEY']) {
        Add-Content -Path '.env' -Value 'APP_SECRET_KEY=aiet-workshop-local-secret'
        $map['APP_SECRET_KEY'] = 'aiet-workshop-local-secret'
        Write-Host "[INFO] Wrote default APP_SECRET_KEY into .env"
    }

    $provider = if ($map['LLM_PROVIDER']) { $map['LLM_PROVIDER'].ToLowerInvariant() } else { 'ollama' }
    if ($provider -in @('nvidia', 'openai-compatible', 'openai_compatible')) {
        if (-not $map['NVIDIA_API_KEY']) {
            throw "LLM_PROVIDER=$provider requires NVIDIA_API_KEY in $PSScriptRoot\.env"
        }
    }
    return $map
}

function Ensure-OllamaVolume {
    $names = docker volume ls --format '{{.Name}}'
    if ($names -notcontains 'ollama_models') {
        Write-Host "[INFO] Creating external Docker volume ollama_models..."
        docker volume create ollama_models | Out-Null
    }
}

function Wait-Http([string]$Url, [int]$Tries = 60) {
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                Write-Host "[OK]   $Url"
                return $true
            }
        } catch {
            Start-Sleep -Seconds 5
        }
    }
    Write-Warning "Timed out waiting for $Url"
    return $false
}

function Invoke-Up {
    Assert-Docker
    $envMap = Ensure-Env
    Ensure-OllamaVolume
    Write-Host "[INFO] Building and starting AI Goat (Ollama + local embeddings)..."
    Write-Host "[INFO] First run may take a long time (image build + mistral model pull)."
    docker compose up --build -d
    Write-Host "[INFO] Waiting for UI..."
    Wait-Http 'http://127.0.0.1:3000/' | Out-Null
    Wait-Http 'http://127.0.0.1:3000/api/products/' | Out-Null
    docker compose ps
    $bind = if ($envMap['HOST_BIND']) { $envMap['HOST_BIND'] } else { '0.0.0.0' }
    Write-Host ""
    Write-Host "App:  http://127.0.0.1:3000"
    Write-Host "Bind: ${bind}:3000"
}

function Invoke-Down {
    Assert-Docker
    docker compose down --remove-orphans
    Write-Host "[OK]   Stack stopped (ollama_models volume kept)"
}

function Invoke-Status {
    Assert-Docker
    docker compose ps -a
    Write-Host ""
    foreach ($pair in @(
        @{ Name = 'ui'; Url = 'http://127.0.0.1:3000/' },
        @{ Name = 'api'; Url = 'http://127.0.0.1:3000/api/products/' }
    )) {
        try {
            $code = (Invoke-WebRequest -Uri $pair.Url -UseBasicParsing -TimeoutSec 5).StatusCode
            Write-Host ("{0}: {1}" -f $pair.Name, $code)
        } catch {
            Write-Host ("{0}: down" -f $pair.Name)
        }
    }
}

function Invoke-Logs {
    Assert-Docker
    docker compose logs --tail $LogTail -f backend
}

switch ($Action) {
    'up' { Invoke-Up }
    'down' { Invoke-Down }
    'status' { Invoke-Status }
    'logs' { Invoke-Logs }
    'restart' { Invoke-Down; Invoke-Up }
}
