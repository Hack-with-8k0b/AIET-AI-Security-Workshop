#Requires -Version 5.1
<#
.SYNOPSIS
  One-command workshop start: Docker stack + DuckDNS + Cloudflare Tunnel.

.DESCRIPTION
  From the repo root (after filling DUCKDNS_* in .env):

    .\Enable-Access.ps1

  This will:
    1. Ensure / sync .env into AIGoat\docker\.env
    2. Create ollama_models volume if needed
    3. docker compose up --build -d
    4. Wait for http://127.0.0.1:3000
    5. Install DuckDNS updater + Cloudflare quick tunnel
    6. Print the public Cloudflare link

.EXAMPLE
  .\Enable-Access.ps1
  .\Enable-Access.ps1 -SkipCompose
  .\Enable-Access.ps1 -Status
  .\Enable-Access.ps1 -RestartTunnel
  .\Enable-Access.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'RestartTunnel')]
    [switch]$RestartTunnel,

    [string]$Domain,
    [string]$Token,
    [int]$IntervalMinutes = 5,
    [int]$LocalPort = 3000,
    [switch]$SkipFirewall,
    [switch]$SkipCompose
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$stateDir = Join-Path $repoRoot 'remote\state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

function Read-DotEnv([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    Get-Content -Path $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { return }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim().Trim('"').Trim("'")
        $map[$key] = $val
        $map[$key.ToUpperInvariant()] = $val
    }
    return $map
}

function Get-EnvValue($maps, [string[]]$Keys) {
    foreach ($m in $maps) {
        foreach ($k in $Keys) {
            if ($m.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace($m[$k])) {
                return $m[$k]
            }
        }
    }
    return $null
}

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" }
function Write-Ok([string]$Message) { Write-Host "[OK]   $Message" }

function Test-AigoatWantGpu($EnvMaps) {
    # AIGOAT_GPU: auto|gpu|cpu (also 1/0, true/false). Default auto.
    $raw = Get-EnvValue $EnvMaps @('AIGOAT_GPU', 'aigoat_gpu')
    if (-not $raw) { $raw = $env:AIGOAT_GPU }
    if (-not $raw) { $raw = 'auto' }
    $mode = $raw.Trim().ToLowerInvariant()
    switch -Regex ($mode) {
        '^(0|false|no|off|cpu)$' { return $false }
        '^(1|true|yes|on|gpu)$' { return $true }
        default {
            if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $false }
            & nvidia-smi 1>$null 2>$null
            return ($LASTEXITCODE -eq 0)
        }
    }
}

function Get-AigoatComposeArgs([string]$DockerDir, $EnvMaps) {
    $args = @('-f', 'docker-compose.yml')
    $gpuFile = Join-Path $DockerDir 'docker-compose.gpu.yml'
    if ((Test-AigoatWantGpu $EnvMaps) -and (Test-Path $gpuFile)) {
        $args += @('-f', 'docker-compose.gpu.yml')
        Write-Info "AIGOAT_GPU=auto/gpu — enabling NVIDIA overlay for Ollama"
    } else {
        Write-Info "AIGOAT_GPU=cpu (or no NVIDIA) — Ollama will run on CPU"
    }
    return $args
}

function Resolve-Cloudflared {
    $candidates = @(
        (Get-Command cloudflared -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe",
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($candidates) { return $candidates[0] }
    return $null
}

function Install-CloudflaredBinary {
    $existing = Resolve-Cloudflared
    if ($existing) {
        Write-Ok "cloudflared already present: $existing"
        return $existing
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "cloudflared not found and winget is unavailable. Install from https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/"
    }
    Write-Info "Installing cloudflared via winget..."
    winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements | Out-Host
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $path = Resolve-Cloudflared
    if (-not $path) { throw "cloudflared install finished but executable not found on PATH." }
    Write-Ok "cloudflared installed: $path"
    return $path
}

function Open-FirewallPorts([int[]]$Ports) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $tmp = Join-Path $env:TEMP 'aiet-fw.ps1'
    $portCsv = ($Ports -join ',')
    $elevLines = @(
        '$ErrorActionPreference = "Stop"'
        ('$ports = @({0})' -f $portCsv)
        'foreach ($p in $ports) {'
        '  $name = "AIET Workshop TCP $p"'
        '  Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue'
        '  New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p -Profile Any | Out-Null'
        '  Write-Output "OK $p"'
        '}'
    )
    Set-Content -Path $tmp -Value $elevLines -Encoding UTF8
    if (-not $isAdmin) {
        Write-Warning "Not elevated - requesting Administrator approval for firewall rules..."
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp
        )
        if ($p.ExitCode -ne 0) {
            throw "Firewall elevation failed (exit $($p.ExitCode)). Re-run as Administrator or pass -SkipFirewall."
        }
    } else {
        & $tmp
    }
    Write-Ok "Firewall rules added for TCP $($Ports -join ', ')"
}

function Update-DuckDnsNow([string]$DomainName, [string]$TokenValue, [string]$LogPath) {
    $url = "https://www.duckdns.org/update?domains=$DomainName&token=$TokenValue&ip="
    $response = Invoke-RestMethod -Uri $url -Method Get
    $line = "{0}  domains={1}  result={2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $DomainName, $response
    Add-Content -Path $LogPath -Value $line
    if ($response -ne 'OK') { throw "DuckDNS update failed: $response" }
    Write-Ok "DuckDNS updated: $DomainName.duckdns.org"
}

function Install-DuckDnsTask([string]$StateDir, [string]$DomainName, [string]$TokenValue, [int]$Minutes) {
    $updater = Join-Path $StateDir 'Update-DuckDNS.ps1'
    $configPath = Join-Path $StateDir 'duckdns-config.json'
    $logPath = Join-Path $StateDir 'duckdns.log'
    @{
        domains         = @($DomainName)
        token           = $TokenValue
        intervalMinutes = $Minutes
    } | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

    @'
$ErrorActionPreference = "Stop"
$configPath = Join-Path $PSScriptRoot "duckdns-config.json"
$logPath = Join-Path $PSScriptRoot "duckdns.log"
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$domains = ($config.domains -join ",").Trim()
$token = [string]$config.token
$url = "https://www.duckdns.org/update?domains=$domains&token=$token&ip="
$response = Invoke-RestMethod -Uri $url -Method Get
Add-Content -Path $logPath -Value ("{0}  domains={1}  result={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $domains, $response)
if ($response -ne "OK") { throw "DuckDNS update failed: $response" }
'@ | Set-Content -Path $updater -Encoding UTF8

    Update-DuckDnsNow -DomainName $DomainName -TokenValue $TokenValue -LogPath $logPath

    $taskName = 'AIET-DuckDNS'
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $updater
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutes) -RepetitionDuration (New-TimeSpan -Days 9999)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'AIET workshop DuckDNS IP updater' | Out-Null
    Write-Ok "Scheduled task '$taskName' (every $Minutes min)"
}

function Stop-CloudflaredProcesses {
    Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-QuickTunnel([string]$CloudflaredPath, [string]$StateDir, [int]$Port) {
    Stop-CloudflaredProcesses
    $errLog = Join-Path $StateDir 'cloudflared.log'
    $outLog = Join-Path $StateDir 'cloudflared.out.log'
    $urlFile = Join-Path $StateDir 'tunnel-url.txt'
    Remove-Item $errLog, $outLog, $urlFile -ErrorAction SilentlyContinue

    Start-Process -FilePath $CloudflaredPath -ArgumentList @('tunnel', '--url', "http://127.0.0.1:$Port") `
        -RedirectStandardError $errLog -RedirectStandardOutput $outLog -WindowStyle Hidden | Out-Null

    $url = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $text = ''
        if (Test-Path $errLog) { $text += Get-Content $errLog -Raw -ErrorAction SilentlyContinue }
        if (Test-Path $outLog) { $text += Get-Content $outLog -Raw -ErrorAction SilentlyContinue }
        if ($text -match 'https://[a-z0-9-]+\.trycloudflare\.com') {
            $url = $Matches[0]
            break
        }
    }
    if (-not $url) { throw "cloudflared started but no trycloudflare URL appeared. See $errLog" }
    Set-Content -Path $urlFile -Value $url -Encoding UTF8
    return $url
}

function Install-CloudflaredTask([string]$CloudflaredPath, [string]$StateDir, [int]$Port) {
    $wrapper = Join-Path $StateDir 'Start-Cloudflared.ps1'
    $wrapperLines = @(
        '$ErrorActionPreference = "Stop"'
        ('$cf = "{0}"' -f ($CloudflaredPath -replace '"', '`"'))
        ('$state = "{0}"' -f ($StateDir -replace '"', '`"'))
        ('$port = {0}' -f $Port)
        'Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue'
        '$err = Join-Path $state "cloudflared.log"'
        '$out = Join-Path $state "cloudflared.out.log"'
        'Remove-Item $err, $out -ErrorAction SilentlyContinue'
        '$target = "http://127.0.0.1:$port"'
        'Start-Process -FilePath $cf -ArgumentList @("tunnel","--url",$target) -RedirectStandardError $err -RedirectStandardOutput $out -WindowStyle Hidden | Out-Null'
        'Start-Sleep -Seconds 8'
        '$text = ((Get-Content $err, $out -Raw -ErrorAction SilentlyContinue) -join [Environment]::NewLine)'
        'if ($text -match "https://[a-z0-9-]+\.trycloudflare\.com") {'
        '  Set-Content -Path (Join-Path $state "tunnel-url.txt") -Value $Matches[0]'
        '}'
    )
    Set-Content -Path $wrapper -Value $wrapperLines -Encoding UTF8

    $taskName = 'AIET-Cloudflared'
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $wrapper
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'AIET workshop Cloudflare quick tunnel' | Out-Null
    Write-Ok "Scheduled task '$taskName' (at logon)"
}

function Get-TunnelUrl([string]$StateDir) {
    $urlFile = Join-Path $StateDir 'tunnel-url.txt'
    if (-not (Test-Path $urlFile)) { return $null }
    $url = (Get-Content $urlFile -Raw -ErrorAction SilentlyContinue)
    if (-not $url) { return $null }
    return $url.Trim()
}

function Write-AccessBanner([string]$TunnelUrl, [string]$DomainName, [int]$Port) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  ACCESS THE WORKSHOP HERE (Cloudflare Tunnel)"
    Write-Host "============================================================"
    if ($TunnelUrl) {
        Write-Host ""
        Write-Host "  $TunnelUrl"
        Write-Host ""
        Write-Host "  Open this link in a browser to use the site."
    } else {
        Write-Host ""
        Write-Host "  (no tunnel URL yet - run: .\Enable-Access.ps1 -RestartTunnel)"
        Write-Host ""
    }
    Write-Host "============================================================"
    Write-Host "  Local only : http://127.0.0.1:$Port"
    if ($DomainName) {
        Write-Host "  DuckDNS    : http://$DomainName.duckdns.org:$Port  (needs port-forward)"
    }
    Write-Host "  Saved URL  : remote\state\tunnel-url.txt"
    Write-Host "============================================================"
    Write-Host ""
}

# --- resolve DuckDNS credentials ---
$envMaps = @(
    (Read-DotEnv (Join-Path $repoRoot '.env')),
    (Read-DotEnv (Join-Path $repoRoot 'AIGoat\docker\.env'))
)
if (-not $Domain) { $Domain = Get-EnvValue $envMaps @('DUCKDNS_DOMAIN', 'duckdns_domain') }
if (-not $Token) { $Token = Get-EnvValue $envMaps @('DUCKDNS_TOKEN', 'duckdns_token') }
if ($Domain) { $Domain = $Domain.Trim() -replace '\.duckdns\.org$', '' }

# --- actions ---
if ($Uninstall) {
    foreach ($name in @('AIET-DuckDNS', 'AIET-Cloudflared')) {
        Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
        Write-Ok "Removed task $name"
    }
    Stop-CloudflaredProcesses
    Write-Ok "Stopped cloudflared"
    return
}

if ($Status) {
    foreach ($name in @('AIET-DuckDNS', 'AIET-Cloudflared')) {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($t) { Write-Host ("Task {0}: {1}" -f $name, $t.State) }
    }
    $proc = Get-Process -Name cloudflared -ErrorAction SilentlyContinue
    Write-Host ("cloudflared: {0}" -f $(if ($proc) { "running (pid $($proc.Id -join ','))" } else { 'not running' }))
    try {
        $code = (Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/" -UseBasicParsing -TimeoutSec 5).StatusCode
        Write-Host "Local UI :$LocalPort -> $code"
    } catch {
        Write-Host "Local UI :$LocalPort -> down (run docker compose first)"
    }
    Write-AccessBanner -TunnelUrl (Get-TunnelUrl $stateDir) -DomainName $Domain -Port $LocalPort
    return
}

if ($RestartTunnel) {
    $cf = Resolve-Cloudflared
    if (-not $cf) { throw "cloudflared not installed. Run .\Enable-Access.ps1 first." }
    $tunnelUrl = Start-QuickTunnel -CloudflaredPath $cf -StateDir $stateDir -Port $LocalPort
    Write-AccessBanner -TunnelUrl $tunnelUrl -DomainName $Domain -Port $LocalPort
    return
}

# --- default: start stack + enable public access ---
Write-Info "Repo root: $repoRoot"
Write-Warning "AIGoat is intentionally vulnerable. Use the Cloudflare Tunnel link for demos only."

$rootEnv = Join-Path $repoRoot '.env'
$rootExample = Join-Path $repoRoot '.env.example'
$dockerDir = Join-Path $repoRoot 'AIGoat\docker'
$dockerEnv = Join-Path $dockerDir '.env'

if (-not (Test-Path $rootEnv)) {
    if (-not (Test-Path $rootExample)) { throw "Missing .env.example at repo root." }
    Copy-Item $rootExample $rootEnv
    Write-Host "[INFO] Created .env from .env.example"
    Write-Host "       Edit DUCKDNS_DOMAIN and DUCKDNS_TOKEN, then re-run: .\Enable-Access.ps1"
    notepad $rootEnv
    exit 2
}

# Re-read after possible create
$envMaps = @(
    (Read-DotEnv $rootEnv),
    (Read-DotEnv $dockerEnv)
)
if (-not $Domain) { $Domain = Get-EnvValue $envMaps @('DUCKDNS_DOMAIN', 'duckdns_domain') }
if (-not $Token) { $Token = Get-EnvValue $envMaps @('DUCKDNS_TOKEN', 'duckdns_token') }
if ($Domain) { $Domain = $Domain.Trim() -replace '\.duckdns\.org$', '' }

if (-not $Domain -or -not $Token) {
    throw "Set DUCKDNS_DOMAIN and DUCKDNS_TOKEN in repo-root .env, then re-run."
}

# Keep Compose env in sync with root .env
Copy-Item $rootEnv $dockerEnv -Force
Write-Ok "Synced .env -> AIGoat\docker\.env"

if (-not $SkipCompose) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is not installed or not on PATH."
    }
    docker compose version | Out-Null

    $volNames = docker volume ls --format '{{.Name}}'
    if ($volNames -notcontains 'ollama_models') {
        Write-Info "Creating Docker volume ollama_models..."
        docker volume create ollama_models | Out-Null
    }

    Write-Info "Starting stack (docker compose up --build -d)..."
    Write-Info "First run can take a long time (image build + mistral model pull)."
    Push-Location $dockerDir
    try {
        # Re-read after sync so AIGOAT_GPU from root .env is visible.
        $composeEnvMaps = @(
            (Read-DotEnv $rootEnv),
            (Read-DotEnv $dockerEnv)
        )
        $composeArgs = Get-AigoatComposeArgs -DockerDir $dockerDir -EnvMaps $composeEnvMaps
        Write-Info ("Compose files: " + ($composeArgs -join ' '))
        & docker compose @composeArgs up --build -d
        if ($LASTEXITCODE -ne 0 -and ($composeArgs -contains 'docker-compose.gpu.yml')) {
            Write-Warning "GPU compose failed; falling back to CPU (no NVIDIA reservation)."
            & docker compose -f docker-compose.yml up --build -d
            if ($LASTEXITCODE -ne 0) { throw "docker compose up failed (CPU fallback)." }
        } elseif ($LASTEXITCODE -ne 0) {
            throw "docker compose up failed."
        }
    } finally {
        Pop-Location
    }

    Write-Info "Waiting for http://127.0.0.1:$LocalPort ..."
    $ready = $false
    for ($i = 1; $i -le 90; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/" -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                Write-Ok "Local UI is up (HTTP $($resp.StatusCode))"
                $ready = $true
                break
            }
        } catch {
            Start-Sleep -Seconds 5
        }
    }
    if (-not $ready) {
        Write-Warning "UI not ready yet after waiting. Continuing with tunnel setup; check: docker compose -f AIGoat\docker\docker-compose.yml logs"
    }
} else {
    try {
        $code = (Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/" -UseBasicParsing -TimeoutSec 5).StatusCode
        Write-Ok "Local UI is up on :$LocalPort (HTTP $code)"
    } catch {
        Write-Warning "Nothing responding on http://127.0.0.1:$LocalPort"
    }
}

if (-not $SkipFirewall) {
    Open-FirewallPorts -Ports @($LocalPort, 8000)
}

Install-DuckDnsTask -StateDir $stateDir -DomainName $Domain -TokenValue $Token -Minutes $IntervalMinutes

$cf = Install-CloudflaredBinary
Install-CloudflaredTask -CloudflaredPath $cf -StateDir $stateDir -Port $LocalPort
$tunnelUrl = Start-QuickTunnel -CloudflaredPath $cf -StateDir $stateDir -Port $LocalPort

Write-Host ""
Write-Host "=== Workshop ready ==="
Write-AccessBanner -TunnelUrl $tunnelUrl -DomainName $Domain -Port $LocalPort
Write-Host "Later:  .\Enable-Access.ps1 -Status"
Write-Host "        .\Enable-Access.ps1 -RestartTunnel"
Write-Host "        .\Enable-Access.ps1 -SkipCompose   (tunnel/DNS only)"
Write-Host "        .\Enable-Access.ps1 -Uninstall"
