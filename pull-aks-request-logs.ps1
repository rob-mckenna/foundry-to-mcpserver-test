param(
  [string]$ResourceGroup = "rg-msf-mcp-srv-test",
  [string]$ClusterName = "aks-mcp-msf-test",
  [string]$Namespace = "mcp-server",
  [string]$Deployment = "mcp-server",
  [int]$Tail = 300,
  [switch]$Follow
)

$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = "logs"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$allLogFile = Join-Path $outDir "aks-console-$timestamp.log"
$requestLogFile = Join-Path $outDir "aks-request-lines-$timestamp.log"
$tokenFile = Join-Path $outDir "aks-authorization-values-$timestamp.txt"

Write-Host "Using AKS cluster $ClusterName in $ResourceGroup..."
az aks get-credentials `
  --resource-group $ResourceGroup `
  --name $ClusterName `
  --overwrite-existing | Out-Null

Write-Host "Pulling pod logs from deployment/$Deployment in namespace $Namespace..."
$kubectlArgs = @("logs", "deployment/$Deployment", "-n", $Namespace, "--tail=$Tail", "--timestamps")
if ($Follow) {
  $kubectlArgs += "--follow"
}

& kubectl @kubectlArgs | Tee-Object -FilePath $allLogFile

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
  Write-Warning "Re-run this script, then trigger a Foundry tool call immediately."
}

if (-not $tokens -or $tokens.Count -eq 0) {
  Write-Warning "No Authorization header values were found in this capture window."
}
