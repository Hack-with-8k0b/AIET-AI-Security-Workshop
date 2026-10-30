$ErrorActionPreference = 'Continue'
$repo = '__REPO__'
$cf = '__CF__'
$state = '__STATE__'
$port = __PORT__
$log = Join-Path $state 'watchdog.log'

function Write-WatchLog([string]$Message) {
    Add-Content -Path $log -Value (('[{0}] {1}' -f (Get-Date -Format o), $Message))
}

function Test-UiUp {
    try {
        $code = (Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/" -f $port) -UseBasicParsing -TimeoutSec 5).StatusCode
        return ($code -ge 200 -and $code -lt 400)
    } catch {
        return $false
    }
}

function Test-PublicTunnel([string]$Url) {
    if (-not $Url) { return $false }
    try {
        $code = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12).StatusCode
        return ($code -ge 200 -and $code -lt 400)
    } catch {
        return $false
    }
}

if (-not (Test-UiUp)) {
    Write-WatchLog 'local UI down; attempting docker compose up -d'
    $dockerDir = Join-Path $repo 'AIGoat\docker'
    $rootEnv = Join-Path $repo '.env'
    $dockerEnv = Join-Path $dockerDir '.env'
    if (Test-Path $rootEnv) { Copy-Item $rootEnv $dockerEnv -Force }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Push-Location $dockerDir
        try { docker compose up -d | Out-Null } catch { Write-WatchLog ("compose failed: {0}" -f $_) } finally { Pop-Location }
    }
    Start-Sleep -Seconds 15
    if (-not (Test-UiUp)) {
        Write-WatchLog 'local UI still down; skip tunnel'
        return
    }
}

$urlFile = Join-Path $state 'tunnel-url.txt'
$existing = $null
if (Test-Path $urlFile) { $existing = (Get-Content $urlFile -Raw).Trim() }
$proc = Get-Process -Name cloudflared -ErrorAction SilentlyContinue
if ($proc -and (Test-PublicTunnel $existing)) {
    Write-WatchLog ("tunnel healthy {0}" -f $existing)
    return
}

Write-WatchLog 'tunnel unhealthy or missing; restarting cloudflared'
Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$err = Join-Path $state 'cloudflared.log'
$out = Join-Path $state 'cloudflared.out.log'
Remove-Item $err, $out -ErrorAction SilentlyContinue
$target = ('http://127.0.0.1:{0}' -f $port)
Start-Process -FilePath $cf -ArgumentList @('tunnel', '--url', $target) `
    -RedirectStandardError $err -RedirectStandardOutput $out -WindowStyle Hidden | Out-Null

$url = $null
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 1
    $text = ''
    if (Test-Path $err) { $text += Get-Content $err -Raw -ErrorAction SilentlyContinue }
    if (Test-Path $out) { $text += Get-Content $out -Raw -ErrorAction SilentlyContinue }
    if ($text -match 'https://[a-z0-9-]+\.trycloudflare\.com') {
        $url = $Matches[0]
        break
    }
}

if ($url) {
    Set-Content -Path $urlFile -Value $url -Encoding UTF8
    Write-WatchLog ("new tunnel {0}" -f $url)
} else {
    Write-WatchLog 'failed to obtain tunnel URL'
}
