param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$KamiwazaUrl,

    [string]$ChromePath = "",
    [string]$UserDataDir = "$env:TEMP\kamiwaza-airgap-chrome",
    [string]$ProxyServer = "http://127.0.0.1:9",
    [string[]]$ExtraBypass = @()
)

if ($KamiwazaUrl -notmatch "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
    $KamiwazaUrl = "https://$KamiwazaUrl"
}

$uri = [System.Uri]$KamiwazaUrl
$hostName = $uri.Host

if (-not $ChromePath) {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            $ChromePath = $candidate
            break
        }
    }
}

if (-not $ChromePath) {
    throw "Could not find Chrome or Edge. Pass -ChromePath."
}

New-Item -ItemType Directory -Force -Path $UserDataDir | Out-Null

$bypass = @($hostName, "localhost", "127.0.0.1", "<-loopback>")
if ($hostName -notmatch "^\d+(\.\d+){3}$" -and $hostName -notmatch ":") {
    $bypass += "*.$hostName"
}
$bypass += $ExtraBypass
$bypassList = ($bypass -join ";")

Write-Host "Launching: $ChromePath"
Write-Host "URL:       $KamiwazaUrl"
Write-Host "Proxy:     $ProxyServer"
Write-Host "Bypass:    $bypassList"
Write-Host "Profile:   $UserDataDir"

$args = @(
    "--user-data-dir=$UserDataDir",
    "--disable-extensions",
    "--proxy-server=$ProxyServer",
    "--proxy-bypass-list=$bypassList",
    $KamiwazaUrl
)

Start-Process -FilePath $ChromePath -ArgumentList $args
