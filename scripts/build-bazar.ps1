param(
    [string]$ApiUrl = '',
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
$mode = if ($Release) { 'release' } else { 'debug' }
$origin = ''
if ($ApiUrl.Trim()) {
    $api = $null
    if (-not [Uri]::TryCreate($ApiUrl.Trim(), [UriKind]::Absolute, [ref]$api) -or
        -not $api.IsWellFormedOriginalString() -or
        $api.Scheme -notin @('http', 'https') -or -not $api.Host -or
        $api.UserInfo -or $api.AbsolutePath -ne '/' -or $api.Query -or $api.Fragment -or
        $api.Port -eq 0) {
        throw 'ApiUrl harus berupa origin HTTP/HTTPS tanpa path, kredensial, query, atau fragment.'
    }
    $privateIpv4 = $api.HostNameType -eq [UriHostNameType]::IPv4 -and
        $api.Host -match '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
    if ($api.Scheme -eq 'http' -and $api.Host -notin @('localhost', '[::1]') -and
        -not $privateIpv4) {
        throw 'APK debug hanya menerima HTTP loopback atau IP privat RFC1918. Gunakan HTTPS untuk server publik.'
    }
    $origin = $api.GetLeftPart([UriPartial]::Authority)
}
if ($Release -and -not $origin.StartsWith('https://')) {
    throw 'APK Tim release wajib memakai -ApiUrl HTTPS yang tetap. Untuk IP LAN yang berubah, jalankan tanpa -Release.'
}

$app = Join-Path (Split-Path $PSScriptRoot) 'app'
$output = Join-Path $app "build/outputs/apk-bazar/$mode"
$flutterApk = "build/app/outputs/flutter-apk/app-$mode.apk"
# Debug normally falls back to the current server. A non-empty, invalid origin
# explicitly disables that fallback for the Guest APK.
$guestOrigin = if ($Release) { '' } else { 'disabled' }
$teamOrigin = if ($Release) { $origin } else { '' }
$variants = [ordered]@{ tim = $teamOrigin; pengunjung = $guestOrigin }

Push-Location $app
try {
    foreach ($name in $variants.Keys) {
        $flutterArgs = @('build', 'apk', "--$mode")
        if ($origin) {
            $flutterArgs += "--dart-define=DEFAULT_BASE_URL=$origin"
        }
        if ($variants[$name]) {
            $flutterArgs += "--dart-define=ADMIN_API_ORIGIN=$($variants[$name])"
        }
        & flutter @flutterArgs
        if ($LASTEXITCODE -ne 0) { throw "Build APK $name gagal (exit $LASTEXITCODE)." }

        $null = New-Item -ItemType Directory -Force -Path $output
        Copy-Item -LiteralPath $flutterApk -Destination (Join-Path $output "hembus-$name.apk")
    }
} finally {
    Pop-Location
}

Write-Output "APK siap: $output"
