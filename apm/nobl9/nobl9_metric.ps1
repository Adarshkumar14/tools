# nobl9_metric.ps1

# --- 1. ENVIRONMENT VARIABLES ---
$requiredVars = @(
  'N9_CLIENT_ID', 'N9_CLIENT_SECRET', 'N9_ORG', 'N9_SLO_PROJECT',
  'N9_SLO_NAME', 'N9_SLO_OBJECTIVE', 'N9_METRIC', 'N9_TIMEFRAME'
)
foreach ($var in $requiredVars) {
  if (-not $env:$var) {
    Write-Error "Missing environment variable: $var"
    exit 1
  }
}

# --- 2. Ensure jq-win64.exe is present ---
$JQ_PATH = Join-Path $PSScriptRoot 'jq-win64.exe'
if (-not (Test-Path $JQ_PATH)) {
  Write-Host "jq not found: downloading jq-win64.exe (official release)..."
  $downloadUrl = "https://github.com/stedolan/jq/releases/latest/download/jq-win64.exe"
  Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $JQ_PATH
}
# Ensure it's on PATH
if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $PSScriptRoot })) {
  $env:PATH = "$PSScriptRoot;$env:PATH"
}

# --- 3. TIME RANGE PARSING ---
$timeframe = $env:N9_TIMEFRAME
if ($timeframe -match '^now-([0-9]+)([smhd])$') {
  $amount = [double]$Matches[1]
  $unit = $Matches[2]
  Switch ($unit) {
    's' { $fromDate = (Get-Date).ToUniversalTime().AddSeconds(-$amount) }
    'm' { $fromDate = (Get-Date).ToUniversalTime().AddMinutes(-$amount) }
    'h' { $fromDate = (Get-Date).ToUniversalTime().AddHours(-$amount) }
    'd' { $fromDate = (Get-Date).ToUniversalTime().AddDays(-$amount) }
    default {
      Write-Error "Unknown timeframe unit: $unit"
      exit 2
    }
  }
  $toDate = (Get-Date).ToUniversalTime()
} else {
  Write-Error "Invalid N9_TIMEFRAME format. Use e.g. now-10m, now-1h, now-2d"
  exit 2
}
$fromUTC = $fromDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
$toUTC = $toDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Host "Time window: $fromUTC -> $toUTC"

# --- 4. GET API TOKEN ---
$bytes = [System.Text.Encoding]::UTF8.GetBytes("$($env:N9_CLIENT_ID):$($env:N9_CLIENT_SECRET)")
$authB64 = [System.Convert]::ToBase64String($bytes)
$tokenResponse = Invoke-RestMethod -Method POST -Uri "https://app.nobl9.com/api/accessToken" `
  -Headers @{
    Accept = "application/json; version=v1alpha"
    Organization = $env:N9_ORG
    Authorization = "Basic $authB64"
  }
if (-not $tokenResponse.access_token) {
  Write-Error "Failed to obtain token"
  exit 3
}
$TOKEN = $tokenResponse.access_token

# --- 5. FETCH SLOs (LIST ENDPOINT, with TIME WINDOW) ---
$apiUrl = "https://app.nobl9.com/api/v2/slos?project=$($env:N9_SLO_PROJECT)&from=$fromUTC&to=$toUTC"
$respFile = New-TemporaryFile
Invoke-WebRequest -UseBasicParsing -Uri $apiUrl `
  -Headers @{
    Accept = "application/json; version=v1alpha"
    Authorization = "Bearer $TOKEN"
    Organization = $env:N9_ORG
  } `
  -OutFile $respFile

# --- 6. EXTRACT DESIRED METRIC USING jq ---
$jqScript = @"
.data[]
| select(.name=="$($env:N9_SLO_NAME)")
| .objectives[]
| select(.name=="$($env:N9_SLO_OBJECTIVE)")
| ."$($env:N9_METRIC)"
"@
$VAL = & $JQ_PATH -r $jqScript $respFile

Remove-Item $respFile

if ($VAL -and $VAL -ne 'null') {
  Write-Host $VAL
} else {
  Write-Error "SLO/objective/metric not found."
  exit 4
}
