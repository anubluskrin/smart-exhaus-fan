param(
    [Parameter(Mandatory)]
    [string]$Device
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$backend = Join-Path $root 'backend'
$endpoint = 'http://127.0.0.1:3000'
$worker = $null
$reverseAdded = $false

if (-not (Test-Path (Join-Path $backend '.env'))) {
    throw 'Siapkan backend/.env khusus development terlebih dahulu (lihat README).'
}
if (Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue) {
    throw 'Port 3000 sudah dipakai. Hentikan worker lokal lain sebelum mulai.'
}

try {
    & adb -s $Device reverse --no-rebind tcp:3000 tcp:3000
    if ($LASTEXITCODE -ne 0) { throw 'Gagal menyiapkan adb reverse.' }
    $reverseAdded = $true

    $previousProfile = $env:APP_PROFILE
    $previousPort = $env:PORT
    try {
        $env:APP_PROFILE = 'bazar'
        $env:PORT = '3000'
        $node = (Get-Command node -CommandType Application).Source
        $worker = Start-Process -FilePath $node -ArgumentList 'index.js', '--local' `
            -WorkingDirectory $backend -NoNewWindow -PassThru
    } finally {
        $env:APP_PROFILE = $previousProfile
        $env:PORT = $previousPort
    }

    $ready = $false
    for ($attempt = 0; $attempt -lt 30 -and -not $worker.HasExited; $attempt++) {
        try {
            $ready = (Invoke-RestMethod -Uri "$endpoint/health" -TimeoutSec 1).ok -eq $true
        } catch {
            Start-Sleep -Seconds 1
        }
        if ($ready) { break }
    }
    if (-not $ready) { throw 'Backend belum siap. Periksa log dan konfigurasi backend.' }

    Push-Location (Join-Path $root 'app')
    try {
        & flutter run --debug -d $Device "--dart-define=DEFAULT_BASE_URL=$endpoint" `
            "--dart-define=ADMIN_API_ORIGIN=$endpoint"
        if ($LASTEXITCODE -ne 0) { throw 'Flutter gagal menjalankan aplikasi.' }
    } finally {
        Pop-Location
    }
} finally {
    if ($worker -and -not $worker.HasExited) { Stop-Process -InputObject $worker }
    if ($reverseAdded) { & adb -s $Device reverse --remove tcp:3000 }
}
