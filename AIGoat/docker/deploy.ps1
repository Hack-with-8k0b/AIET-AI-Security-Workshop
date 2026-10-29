# AIET workshop deploy helper (Windows PowerShell).
# Usage (from AIGoat\docker):
#   .\deploy.ps1 up
#   .\deploy.ps1 down
#   .\deploy.ps1 status
#   .\deploy.ps1 logs
#   .\deploy.ps1 restart
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

function Ensure-Env {
    if (-not (Test-Path -Path '.env')) {
        if (-not (Test-Path -Path '.env.example')) {
            throw ".env.example not found in $PSScriptRoot"
        }
        Copy-Item '.env.example' '.env'
        Write-Host "[INFO] Created .env from .env.example — set NVIDIA_API_KEY and APP_SECRET_KEY, then re-run."
        exit 2
    }

    $map = @{}
    Get-Content '.env' | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $parts = $_.Split('=', 2)
        if ($parts.Count -eq 2) {
            $map[$parts[0].Trim()] = $parts[1].Trim()
        }
    }

    if (-not $map['NVIDIA_API_KEY']) {
        throw "Set NVIDIA_API_KEY in $PSScriptRoot\.env"
    }
    if (-not $map['APP_SECRET_KEY'] -or $map['APP_SECRET_KEY'] -eq 'aigoat-dev-secret-change-in-production') {
        throw "Set a unique APP_SECRET_KEY in .env (python -c `"import secrets; print(secrets.token_urlsafe(48))`")"
    }
    return $map
}

function Wait-Http([string]$Url, [int]$Tries = 40) {
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                Write-Host "[OK]   $Url"
                return $true
            }
        } catch {
            Start-Sleep -Seconds 3
        }
    }
    Write-Warning "Timed out waiting for $Url"
    return $false
}

function Invoke-Up {
    Assert-Docker
    $envMap = Ensure-Env
    Write-Host "[INFO] Building and starting AI Goat (NVIDIA hosted models, distroless backend)..."
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
    Write-Host "[OK]   Stack stopped"
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
