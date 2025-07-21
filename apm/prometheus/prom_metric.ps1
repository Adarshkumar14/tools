# avgprom_env.ps1
# Average Prometheus metric from environment variables PROM_URL and PROM_QUERY
# Usage (from PowerShell prompt):
#   $env:PROM_URL = "http://localhost:9090"
#   $env:PROM_QUERY = "up"
#   .\avgprom_env.ps1

# Read env vars or error out
$promUrl   = $env:PROM_URL
$promQuery = $env:PROM_QUERY

if ([string]::IsNullOrWhiteSpace($promUrl) -or [string]::IsNullOrWhiteSpace($promQuery)) {
    Write-Host "Usage: set PROM_URL and PROM_QUERY environment variables before running this script."
    exit 1
}

# Construct the API URL
$apiUrl = "$($promUrl.TrimEnd('/'))/api/v1/query"
try {
    $response = Invoke-WebRequest -Uri $apiUrl -Method GET -Body @{ query = $promQuery } -UseBasicParsing
} catch {
    Write-Error "Failed to reach Prometheus at $promUrl"
    exit 2
}

# Parse JSON
$json = $null
try {
    $json = $response.Content | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse Prometheus response as JSON"
    exit 3
}

if ($json.status -ne 'success') {
    Write-Error "Prometheus returned error: $($json.errorType): $($json.error)"
    exit 4
}

# Extract all sample values (as strings), convert to double
$values = @()
foreach ($item in $json.data.result) {
    if ($item.value.Count -ge 2) {
        $v = $item.value[1] -as [double]
        if ($null -ne $v) { $values += $v }
    }
}

if ($values.Count -eq 0) {
    Write-Error "Query `$PROM_QUERY` returned no samples."
    exit 5
}

# Compute the arithmetic mean
$mean = ($values | Measure-Object -Average).Average
Write-Output $mean
