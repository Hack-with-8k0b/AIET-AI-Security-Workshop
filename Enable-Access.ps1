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
  .\Enable-Access.ps1 -Ensure
  .\Enable-Access.ps1 -RestartTunnel
  .\Enable-Access.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Ensure')]
    [switch]$Ensure,

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

function Resolve-Cloudflared {
    $candidates = New-Object System.Collections.Generic.List[string]
    $cmd = Get-Command cloudflared -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { [void]$candidates.Add([string]$cmd.Source) }
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if ($root -eq $env:LOCALAPPDATA) {
            [void]$candidates.Add((Join-Path $root 'Microsoft\WinGet\Links\cloudflared.exe'))
        } else {
            [void]$candidates.Add((Join-Path $root 'cloudflared\cloudflared.exe'))
        }
    }
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
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
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $updater
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $Minutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    try {
        if ($existingTask) {
            Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
        } else {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'AIET workshop DuckDNS IP updater' | Out-Null
        }
        Write-Ok "Scheduled task '$taskName' (every $Minutes min)"
    } catch {
        Write-Warning "Could not register '$taskName' (need elevation?). DuckDNS updater script is at: $updater"
    }
}

function Stop-CloudflaredProcesses {
    Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Test-LocalUi([int]$Port) {
    try {
        $code = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 5).StatusCode
        return ($code -ge 200 -and $code -lt 400)
    } catch {
        return $false
    }
}

function Test-TunnelUrl([string]$Url) {
    if (-not $Url) { return $false }
    try {
        $code = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12).StatusCode
        return ($code -ge 200 -and $code -lt 400)
    } catch {
        return $false
    }
}

function Sync-WorkshopEnv {
    $rootEnv = Join-Path $repoRoot '.env'
    $rootExample = Join-Path $repoRoot '.env.example'
    $dockerDir = Join-Path $repoRoot 'AIGoat\docker'
    $dockerEnv = Join-Path $dockerDir '.env'
    $dockerExample = Join-Path $dockerDir '.env.example'

    if (-not (Test-Path $rootEnv)) {
        if (-not (Test-Path $rootExample)) { throw "Missing .env.example at repo root." }
        Copy-Item $rootExample $rootEnv
        Write-Info "Created repo-root .env from .env.example"
    }
    New-Item -ItemType Directory -Force -Path $dockerDir | Out-Null
    Copy-Item $rootEnv $dockerEnv -Force
    if (-not (Test-Path $dockerExample) -and (Test-Path (Join-Path $dockerDir '.env.example'))) {
        # keep existing example
    }
    Write-Ok "Synced .env -> AIGoat\docker\.env"
}

function Ensure-ComposeStack([int]$Port) {
    $dockerDir = Join-Path $repoRoot 'AIGoat\docker'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is not installed or not on PATH."
    }
    docker compose version | Out-Null
    Sync-WorkshopEnv
    Write-Info "Ensuring Docker stack is up..."
    Push-Location $dockerDir
    try {
        # docker compose writes progress to stderr; don't treat that as a terminating error
        $prevEa = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & docker compose up -d 2>&1 | ForEach-Object { "$_" } | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "docker compose up -d failed with exit $LASTEXITCODE" }
        $ErrorActionPreference = $prevEa
    } finally {
        Pop-Location
    }
    for ($i = 1; $i -le 60; $i++) {
        if (Test-LocalUi -Port $Port) {
            Write-Ok "Local UI is up on :$Port"
            return
        }
        Start-Sleep -Seconds 5
    }
    Write-Warning "UI not ready yet on :$Port - check: docker compose -f AIGoat\docker\docker-compose.yml logs"
}

function Start-QuickTunnel([string]$CloudflaredPath, [string]$StateDir, [int]$Port, [switch]$Force) {
    $urlFile = Join-Path $StateDir 'tunnel-url.txt'
    $existing = Get-TunnelUrl $StateDir
    if (-not $Force -and (Get-Process -Name cloudflared -ErrorAction SilentlyContinue) -and (Test-TunnelUrl $existing)) {
        Write-Ok "Existing Cloudflare tunnel still healthy"
        return $existing
    }

    Stop-CloudflaredProcesses
    $errLog = Join-Path $StateDir 'cloudflared.log'
    $outLog = Join-Path $StateDir 'cloudflared.out.log'
    Remove-Item $errLog, $outLog -ErrorAction SilentlyContinue
    # Keep old tunnel-url.txt until a new URL is confirmed so share links don't go blank mid-restart.

    Start-Process -FilePath $CloudflaredPath -ArgumentList @('tunnel', '--url', "http://127.0.0.1:$Port") `
        -RedirectStandardError $errLog -RedirectStandardOutput $outLog -WindowStyle Hidden | Out-Null

    $url = $null
    for ($i = 0; $i -lt 45; $i++) {
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
    # Watchdog: keep tunnel alive across Docker restarts without forcing a new URL when healthy.
    $template = Join-Path $repoRoot 'remote\templates\Start-Cloudflared.ps1'
    if (-not (Test-Path $template)) { throw "Missing tunnel watchdog template: $template" }
    $wrapper = Join-Path $StateDir 'Start-Cloudflared.ps1'
    $text = Get-Content -Path $template -Raw
    $text = $text.Replace('__REPO__', $repoRoot).Replace('__CF__', $CloudflaredPath).Replace('__STATE__', $StateDir).Replace('__PORT__', [string]$Port)
    Set-Content -Path $wrapper -Value $text -Encoding UTF8

    $taskName = 'AIET-Cloudflared'
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $wrapper
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    try {
        if ($existingTask) {
            Set-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logonTrigger, $repeatTrigger) -Settings $settings -Principal $principal | Out-Null
        } else {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logonTrigger, $repeatTrigger) -Settings $settings -Principal $principal -Description 'AIET workshop Cloudflare tunnel watchdog (logon + every 5 min)' | Out-Null
        }
        Write-Ok "Scheduled task '$taskName' (logon + every 5 min heal)"
    } catch {
        Write-Warning "Could not register '$taskName' (need elevation?). Watchdog script updated at: $wrapper"
        Write-Warning $_.Exception.Message
    }
}

function Get-TunnelUrl([string]$StateDir) {
    $urlFile = Join-Path $StateDir 'tunnel-url.txt'
    if (-not (Test-Path $urlFile)) { return $null }
    $url = (Get-Content $urlFile -Raw -ErrorAction SilentlyContinue)
    if (-not $url) { return $null }
    return $url.Trim()
}

function Update-ShareRedirect([string]$TunnelUrl) {
    if (-not $TunnelUrl) { return }
    $docsDir = Join-Path $repoRoot 'docs'
    New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
    $sharePage = Join-Path $docsDir 'index.html'
    $safe = $TunnelUrl.Replace('&', '&amp;').Replace([string][char]34, '&quot;')
    $jsUrl = $TunnelUrl.Replace('\', '\\').Replace([string][char]34, '\"')
    $html = @(
        '<!DOCTYPE html>'
        '<html lang="en">'
        '<head>'
        '  <meta charset="utf-8" />'
        '  <meta name="viewport" content="width=device-width, initial-scale=1" />'
        '  <title>AIET AI Security Workshop</title>'
        ('  <meta http-equiv="refresh" content="0; url={0}" />' -f $safe)
        ('  <link rel="canonical" href="{0}" />' -f $safe)
        '  <style>'
        '    body { font-family: Georgia, serif; margin: 0; min-height: 100vh; display: grid; place-items: center;'
        '      background: linear-gradient(160deg, #f3efe6, #d9e5df 55%, #c5d4e8); color: #1d2430; }'
        '    main { width: min(34rem, calc(100% - 2rem)); padding: 2rem 1.5rem; }'
        '    a.button { display: inline-block; padding: 0.7rem 1.1rem; background: #1d2430; color: #f7f3ea;'
        '      text-decoration: none; border-radius: 0.35rem; }'
        '    code { word-break: break-all; }'
        '  </style>'
        ('  <script>location.replace("{0}");</script>' -f $jsUrl)
        '</head>'
        '<body>'
        '  <main>'
        '    <h1>AIET AI Security Workshop</h1>'
        '    <p>Redirecting to the live lab...</p>'
        ('    <p><a class="button" href="{0}">Open workshop</a></p>' -f $safe)
        ('    <p>If nothing happens, open:<br /><code>{0}</code></p>' -f $safe)
        '  </main>'
        '</body>'
        '</html>'
    ) -join [Environment]::NewLine
    Set-Content -Path $sharePage -Value $html -Encoding utf8
    Set-Content -Path (Join-Path $stateDir 'share-url.txt') -Value 'https://hack-with-8k0b.github.io/AIET-AI-Security-Workshop/' -Encoding utf8
    Write-Ok "Updated short share page: docs\index.html (push to GitHub to publish)"
}

function Write-AccessBanner([string]$TunnelUrl, [string]$DomainName, [int]$Port) {
    if ($TunnelUrl) { Update-ShareRedirect -TunnelUrl $TunnelUrl }
    $shareUrl = 'https://hack-with-8k0b.github.io/AIET-AI-Security-Workshop/'
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  SHARE THIS SHORT LINK"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "  $shareUrl"
    Write-Host ""
    Write-Host "  (redirects to the live Cloudflare tunnel)"
    Write-Host "============================================================"
    Write-Host "  Tunnel     : $(if ($TunnelUrl) { $TunnelUrl } else { '(none yet - run -RestartTunnel)' })"
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
    if (Test-LocalUi -Port $LocalPort) {
        Write-Host "Local UI :$LocalPort -> up"
    } else {
        Write-Host "Local UI :$LocalPort -> down (run .\Enable-Access.ps1 -Ensure)"
    }
    $url = Get-TunnelUrl $stateDir
    Write-Host ("Tunnel probe: {0}" -f $(if (Test-TunnelUrl $url) { "healthy" } else { "down/stale" }))
    Write-AccessBanner -TunnelUrl $url -DomainName $Domain -Port $LocalPort
    return
}

if ($Ensure) {
    Write-Info "Healing workshop stack (env + compose + tunnel watchdog)..."
    Write-Warning "AIGoat is intentionally vulnerable. Use the Cloudflare Tunnel link for demos only."
    Sync-WorkshopEnv
    $envMaps = @((Read-DotEnv (Join-Path $repoRoot '.env')), (Read-DotEnv (Join-Path $repoRoot 'AIGoat\docker\.env')))
    if (-not $Domain) { $Domain = Get-EnvValue $envMaps @('DUCKDNS_DOMAIN', 'duckdns_domain') }
    if (-not $Token) { $Token = Get-EnvValue $envMaps @('DUCKDNS_TOKEN', 'duckdns_token') }
    if ($Domain) { $Domain = $Domain.Trim() -replace '\.duckdns\.org$', '' }
    Ensure-ComposeStack -Port $LocalPort
    if ($Domain -and $Token) {
        Install-DuckDnsTask -StateDir $stateDir -DomainName $Domain -TokenValue $Token -Minutes $IntervalMinutes
    }
    $cf = Install-CloudflaredBinary
    Install-CloudflaredTask -CloudflaredPath $cf -StateDir $stateDir -Port $LocalPort
    $tunnelUrl = Start-QuickTunnel -CloudflaredPath $cf -StateDir $stateDir -Port $LocalPort
    Write-Host ""
    Write-Host "=== Workshop healed ==="
    Write-AccessBanner -TunnelUrl $tunnelUrl -DomainName $Domain -Port $LocalPort
    Write-Host "Tip: avoid 'docker compose down -v' - that deletes the DB/model volumes."
    return
}

if ($RestartTunnel) {
    $cf = Resolve-Cloudflared
    if (-not $cf) { throw "cloudflared not installed. Run .\Enable-Access.ps1 first." }
    $tunnelUrl = Start-QuickTunnel -CloudflaredPath $cf -StateDir $stateDir -Port $LocalPort -Force
    Write-AccessBanner -TunnelUrl $tunnelUrl -DomainName $Domain -Port $LocalPort
    Write-Host "If the short share link is stale, commit/push docs\index.html"
    return
}

# --- default: start stack + enable public access ---
Write-Info "Repo root: $repoRoot"
Write-Warning "AIGoat is intentionally vulnerable. Use the Cloudflare Tunnel link for demos only."

$rootEnv = Join-Path $repoRoot '.env'
$rootExample = Join-Path $repoRoot '.env.example'
$dockerDir = Join-Path $repoRoot 'AIGoat\docker'

if (-not (Test-Path $rootEnv)) {
    if (-not (Test-Path $rootExample)) { throw "Missing .env.example at repo root." }
    Copy-Item $rootExample $rootEnv
    Write-Host "[INFO] Created .env from .env.example"
    Write-Host "       Edit DUCKDNS_DOMAIN and DUCKDNS_TOKEN, then re-run: .\Enable-Access.ps1"
    notepad $rootEnv
    exit 2
}

Sync-WorkshopEnv

# Re-read after sync
$envMaps = @(
    (Read-DotEnv $rootEnv),
    (Read-DotEnv (Join-Path $dockerDir '.env'))
)
if (-not $Domain) { $Domain = Get-EnvValue $envMaps @('DUCKDNS_DOMAIN', 'duckdns_domain') }
if (-not $Token) { $Token = Get-EnvValue $envMaps @('DUCKDNS_TOKEN', 'duckdns_token') }
if ($Domain) { $Domain = $Domain.Trim() -replace '\.duckdns\.org$', '' }

if (-not $Domain -or -not $Token) {
    throw "Set DUCKDNS_DOMAIN and DUCKDNS_TOKEN in repo-root .env, then re-run."
}

if (-not $SkipCompose) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is not installed or not on PATH."
    }
    docker compose version | Out-Null

    Write-Info "Starting stack (docker compose up --build -d)..."
    Write-Info "First run can take a long time (image build + mistral model pull)."
    Write-Info "Volumes aigoat_db_data + ollama_models persist across compose down (not down -v)."
    Push-Location $dockerDir
    try {
        $prevEa = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & docker compose up --build -d 2>&1 | ForEach-Object { "$_" } | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "docker compose up --build -d failed with exit $LASTEXITCODE" }
        $ErrorActionPreference = $prevEa
    } finally {
        Pop-Location
    }

    Write-Info "Waiting for http://127.0.0.1:$LocalPort ..."
    $ready = $false
    for ($i = 1; $i -le 90; $i++) {
        if (Test-LocalUi -Port $LocalPort) {
            Write-Ok "Local UI is up (HTTP 200)"
            $ready = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) {
        Write-Warning "UI not ready yet after waiting. Continuing with tunnel setup; check: docker compose -f AIGoat\docker\docker-compose.yml logs"
    }
} else {
    if (Test-LocalUi -Port $LocalPort) {
        Write-Ok "Local UI is up on :$LocalPort"
    } else {
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
Write-Host "        .\Enable-Access.ps1 -Ensure         (heal after compose down/up)"
Write-Host "        .\Enable-Access.ps1 -RestartTunnel"
Write-Host "        .\Enable-Access.ps1 -SkipCompose   (tunnel/DNS only)"
Write-Host "        .\Enable-Access.ps1 -Uninstall"
