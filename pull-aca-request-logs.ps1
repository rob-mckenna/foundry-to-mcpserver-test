param(
  [string]$ResourceGroup = "rg-msf-mcp-srv-test",
  [string]$ContainerApp = "ca-mcp-donnyjjdtavyg",
  [int]$Tail = 300,
  [switch]$Follow
)

$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = "logs"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$allLogFile = Join-Path $outDir "aca-console-$timestamp.log"
$requestLogFile = Join-Path $outDir "aca-request-lines-$timestamp.log"
$tokenFile = Join-Path $outDir "aca-authorization-values-$timestamp.txt"

Write-Host "Finding active revision..."
$revision = az containerapp revision list `
  --resource-group $ResourceGroup `
  --name $ContainerApp `
  --query "[?properties.active].name | [0]" `
  --output tsv

if ([string]::IsNullOrWhiteSpace($revision)) {
  throw "Could not find an active revision for $ContainerApp in $ResourceGroup."
}

$followValue = if ($Follow) { "true" } else { "false" }

Write-Host "Pulling logs from revision: $revision"
az containerapp logs show `
  --resource-group $ResourceGroup `
  --name $ContainerApp `
  --revision $revision `
  --type console `
  --format text `
  --tail $Tail `
  --follow $followValue | Tee-Object -FilePath $allLogFile

Write-Host "Extracting request and authorization lines..."
Select-String -Path $allLogFile -Pattern "\[REQUEST\]|authorization" -Context 0,3 |
  ForEach-Object { $_.ToString() } |
  Set-Content -Path $requestLogFile

$mcpRequestMatches = Select-String -Path $allLogFile -Pattern '"url"\s*:\s*"/(sse|messages)'

$authMatches = Select-String -Path $allLogFile -Pattern '"authorization"\s*:\s*"([^"]+)"' -AllMatches
$tokens = foreach ($m in $authMatches) {
  foreach ($match in $m.Matches) {
    $match.Groups[1].Value
  }
}

$tokens | Sort-Object -Unique | Set-Content -Path $tokenFile

Write-Host ""
Write-Host "Done."
Write-Host "Full logs:      $allLogFile"
Write-Host "Request lines:  $requestLogFile"
Write-Host "Auth values:    $tokenFile"

if (-not $mcpRequestMatches) {
  Write-Warning "No MCP calls to /sse or /messages were found in the captured logs."
  Write-Warning "The capture appears to contain probes or non-MCP traffic only."
  Write-Warning "Re-run this script, then trigger a Foundry tool call immediately, and run again."
}

if (-not $tokens -or $tokens.Count -eq 0) {
  Write-Warning "No Authorization header values were found in this capture window."
}
