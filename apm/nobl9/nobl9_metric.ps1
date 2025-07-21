 # Enable strict error handling
$ErrorActionPreference = "Stop"

# --- 1. ENVIRONMENT VARIABLES VALIDATION ---
$requiredVars = @(
  "N9_CLIENT_ID", "N9_CLIENT_SECRET", "N9_ORG",
  "N9_SLO_PROJECT", "N9_SLO_NAME", "N9_SLO_OBJECTIVE",
  "N9_METRIC", "N9_TIMEFRAME"
)

# --- 2. Ensure jq.exe is installed on Windows ---
if (-not (Get-Command "jq.exe" -ErrorAction SilentlyContinue)) {
  $jqDir = "$env:USERPROFILE\.local\bin"
  $jqPath = Join-Path $jqDir "jq.exe"
  $url = "https://github.com/jqlang/jq/releases/latest/download/jq-win64.exe"

  if (-not (Test-Path $jqDir)) {
    New-Item -ItemType Directory -Path $jqDir -Force | Out-Null
  }

  Invoke-WebRequest -Uri $url -OutFile $jqPath -UseBasicParsing

  if (-not (Test-Path $jqPath)) {
    Write-Error "Failed to download jq.exe"
    exit 10
  }

  # Add jq.exe to PATH for this session
  $env:PATH = "$jqDir;$env:PATH"
}

# --- 3. TIME WINDOW PROCESSING ---
$timeframe = $env:N9_TIMEFRAME
if ($timeframe -match "^now-([0-9]+)([smhd])$") {
  $amount = [int]$matches[1]
  $unit = $matches[2]
} else {
  Write-Error "Invalid N9_TIMEFRAME format. Use e.g. now-10m, now-1h, now-2d"
  exit 2
}

switch ($unit) {
  's' { $fromTime = (Get-Date).ToUniversalTime().AddSeconds(-$amount) }
  'm' { $fromTime = (Get-Date).ToUniversalTime().AddMinutes(-$amount) }
  'h' { $fromTime = (Get-Date).ToUniversalTime().AddHours(-$amount) }
  'd' { $fromTime = (Get-Date).ToUniversalTime().AddDays(-$amount) }
  default {
    Write-Error "Invalid unit in N9_TIMEFRAME: $unit"
    exit 2
  }
}

$toTime = (Get-Date).ToUniversalTime()
$fromStr = $fromTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
$toStr = $toTime.ToString("yyyy-MM-ddTHH:mm:ssZ")

# --- 4. GET API TOKEN ---
$authString = "$($env:N9_CLIENT_ID):$($env:N9_CLIENT_SECRET)"
$authBytes = [System.Text.Encoding]::UTF8.GetBytes($authString)
$authBase64 = [Convert]::ToBase64String($authBytes)

$tokenResp = Invoke-RestMethod -Uri "https://app.nobl9.com/api/accessToken" `
  -Method POST `
  -Headers @{
    "Accept" = "application/json; version=v1alpha"
    "Organization" = $env:N9_ORG
    "Authorization" = "Basic $authBase64"
  }

$token = $tokenResp.access_token
if (-not $token -or $token -eq "null") {
  Write-Error "Failed to obtain token"
  exit 3
}

# --- 5. FETCH SLO DATA ---
$apiUrl = "https://app.nobl9.com/api/v2/slos?project=$($env:N9_SLO_PROJECT)&from=$fromStr&to=$toStr"
$resp = Invoke-RestMethod -Uri $apiUrl `
  -Method GET `
  -Headers @{
    "Accept" = "application/json; version=v1alpha"
    "Authorization" = "Bearer $token"
    "Organization" = $env:N9_ORG
  } -ErrorAction Stop

# --- 6. EXTRACT DESIRED METRIC USING JQ ---
# Convert response to JSON and pass to jq
$jsonFile = "$env:TEMP\slo_response.json"
$resp | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 -FilePath $jsonFile

$val = & jq.exe -r --arg slo "$env:N9_SLO_NAME" --arg obj "$env:N9_SLO_OBJECTIVE" --arg met "$env:N9_METRIC" `
  '.data[] | select(.name == $slo) | .objectives[] | select(.name == $obj) | .[$met]' `
  $jsonFile

if ($val -and $val -ne "null") {
  Write-Output $val
} else {
  Write-Error "SLO/objective/metric not found."
  exit 4
}
