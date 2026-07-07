[CmdletBinding()]
param(
  [string]$ApiApplicationId = "7d019514-b7a5-4501-9baa-099a4e0a627c",
  [string[]]$RequiredRoles = @("mcp-srv-001"),
  [string]$FoundryProjectEndpoint = "",
  [string]$FoundryProjectResourceId = "",
  [string]$ConnectionName = "",
  [string]$ExpectedTargetSseUrl = ""
)

# Required permissions to run this validator:
# 1) Azure management-plane read access on the Foundry project scope (or parent scope):
#    - Microsoft.CognitiveServices/accounts/projects/read
#    - Microsoft.CognitiveServices/accounts/projects/connections/read (when -ConnectionName is used)
#    - Microsoft.Resources/subscriptions/resources/read
#    Built-in role guidance: Reader is typically sufficient for these checks.
#
# 2) Microsoft Entra ID / Microsoft Graph read access:
#    - ability to read Applications and Service Principals (az ad app/sp show)
#    - ability to read app role assignments on service principals
#    Typical setup: Directory Readers role + delegated Graph read scopes allowed by tenant policy.
#
# 3) Azure CLI signed into the intended tenant/subscription:
#    - az login
#    - az account set --subscription <id> (if needed)
#
$ErrorActionPreference = "Stop"

$RequiredRoles = @(
  $RequiredRoles |
  ForEach-Object { $_ -split "," } |
  ForEach-Object { $_.Trim() } |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
  param(
    [string]$Check,
    [string]$Status,
    [string]$Details
  )

  $results.Add([pscustomobject]@{
      Check   = $Check
      Status  = $Status
      Details = $Details
    }) | Out-Null
}

function Get-AzJson {
  param(
    [Parameter(Mandatory = $true)][string[]]$Args
  )

  $output = az @Args
  if ($LASTEXITCODE -ne 0) {
    throw "az command failed: az $($Args -join ' ')"
  }

  if ([string]::IsNullOrWhiteSpace($output)) {
    return $null
  }

  return $output | ConvertFrom-Json
}

function Get-AzTsv {
  param(
    [Parameter(Mandatory = $true)][string[]]$Args
  )

  $output = az @Args
  if ($LASTEXITCODE -ne 0) {
    throw "az command failed: az $($Args -join ' ')"
  }
  return "$output".Trim()
}

function Resolve-FoundryProjectResourceIdFromEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Endpoint
  )

  $uri = [Uri]$Endpoint
  $accountName = $uri.Host.Split(".")[0]
  $segments = $uri.AbsolutePath.Trim("/").Split("/")
  if ($segments.Length -lt 3 -or $segments[0] -ne "api" -or $segments[1] -ne "projects") {
    throw "FoundryProjectEndpoint format is invalid. Expected https://<account>.services.ai.azure.com/api/projects/<project>"
  }
  $projectName = $segments[2]

  $id = Get-AzTsv -Args @(
    "resource", "list",
    "--resource-type", "Microsoft.CognitiveServices/accounts/projects",
    "--query", "[?name=='$accountName/$projectName'].id | [0]",
    "-o", "tsv"
  )

  if ([string]::IsNullOrWhiteSpace($id)) {
    throw "Could not resolve project resource ID for endpoint: $Endpoint"
  }

  return $id
}

Write-Host "Validating Entra ID + Foundry MCP configuration..." -ForegroundColor Cyan

# 1) Basic context
$accountContext = Get-AzJson -Args @("account", "show", "-o", "json")
Add-Result -Check "Azure CLI context" -Status "PASS" -Details "Signed in as $($accountContext.user.name) on tenant $($accountContext.tenantId)"

# 2) API app registration and service principal
$apiApp = Get-AzJson -Args @("ad", "app", "show", "--id", $ApiApplicationId, "-o", "json")
if ($null -eq $apiApp) {
  throw "App registration not found for application ID: $ApiApplicationId"
}
Add-Result -Check "API app registration exists" -Status "PASS" -Details "displayName=$($apiApp.displayName), appId=$ApiApplicationId"

$apiServicePrincipalObjectId = Get-AzTsv -Args @("ad", "sp", "show", "--id", $ApiApplicationId, "--query", "id", "-o", "tsv")
if ([string]::IsNullOrWhiteSpace($apiServicePrincipalObjectId)) {
  throw "Service principal not found for application ID: $ApiApplicationId"
}
Add-Result -Check "API service principal exists" -Status "PASS" -Details "objectId=$apiServicePrincipalObjectId"

# 3) Required app roles
$roleValueToId = @{}
foreach ($role in $apiApp.appRoles) {
  if ($null -ne $role.value -and "$($role.value)".Length -gt 0) {
    $roleValueToId[$role.value] = $role.id
  }
}

foreach ($requiredRole in $RequiredRoles) {
  $roleDef = $apiApp.appRoles | Where-Object { $_.value -eq $requiredRole } | Select-Object -First 1
  if ($null -eq $roleDef) {
    Add-Result -Check "Required role '$requiredRole' exists" -Status "FAIL" -Details "Missing from app registration appRoles."
    continue
  }

  if (-not $roleDef.isEnabled) {
    Add-Result -Check "Required role '$requiredRole' enabled" -Status "FAIL" -Details "Role exists but is disabled."
  }
  else {
    Add-Result -Check "Required role '$requiredRole' enabled" -Status "PASS" -Details "Role is enabled."
  }

  if ($roleDef.allowedMemberTypes -notcontains "Application") {
    Add-Result -Check "Required role '$requiredRole' allows Application members" -Status "FAIL" -Details "allowedMemberTypes=$($roleDef.allowedMemberTypes -join ',')"
  }
  else {
    Add-Result -Check "Required role '$requiredRole' allows Application members" -Status "PASS" -Details "allowedMemberTypes includes Application."
  }
}

# 4) Resolve Foundry project identity if provided
$projectResourceId = $FoundryProjectResourceId
if ([string]::IsNullOrWhiteSpace($projectResourceId) -and -not [string]::IsNullOrWhiteSpace($FoundryProjectEndpoint)) {
  $projectResourceId = Resolve-FoundryProjectResourceIdFromEndpoint -Endpoint $FoundryProjectEndpoint
  Add-Result -Check "Foundry project resolved from endpoint" -Status "PASS" -Details "resourceId=$projectResourceId"
}

$projectMiPrincipalId = ""
if (-not [string]::IsNullOrWhiteSpace($projectResourceId)) {
  $projectMiPrincipalId = Get-AzTsv -Args @("resource", "show", "--ids", $projectResourceId, "--query", "identity.principalId", "-o", "tsv")
  if ([string]::IsNullOrWhiteSpace($projectMiPrincipalId)) {
    Add-Result -Check "Foundry project managed identity principal" -Status "FAIL" -Details "No system-assigned identity principalId on project."
  }
  else {
    Add-Result -Check "Foundry project managed identity principal" -Status "PASS" -Details "principalId=$projectMiPrincipalId"
  }
}
else {
  Add-Result -Check "Foundry project managed identity principal" -Status "WARN" -Details "Skipped (provide FoundryProjectEndpoint or FoundryProjectResourceId)."
}

# 5) App role assignments for Foundry MI -> API SP
if (-not [string]::IsNullOrWhiteSpace($projectMiPrincipalId)) {
  $assignments = Get-AzJson -Args @(
    "rest", "--method", "get",
    "--url", "https://graph.microsoft.com/v1.0/servicePrincipals/$projectMiPrincipalId/appRoleAssignments",
    "-o", "json"
  )

  foreach ($requiredRole in $RequiredRoles) {
    $requiredRoleId = $roleValueToId[$requiredRole]
    if ([string]::IsNullOrWhiteSpace("$requiredRoleId")) {
      Add-Result -Check "Foundry MI assignment for role '$requiredRole'" -Status "FAIL" -Details "Role ID not found (role missing in app registration)."
      continue
    }

    $match = $assignments.value | Where-Object {
      $_.resourceId -eq $apiServicePrincipalObjectId -and $_.appRoleId -eq $requiredRoleId
    } | Select-Object -First 1

    if ($null -eq $match) {
      Add-Result -Check "Foundry MI assignment for role '$requiredRole'" -Status "FAIL" -Details "No appRoleAssignment found on Foundry MI SP."
    }
    else {
      Add-Result -Check "Foundry MI assignment for role '$requiredRole'" -Status "PASS" -Details "Assignment exists (assignmentId=$($match.id))."
    }
  }
}

# 6) Optional connection validation
if (-not [string]::IsNullOrWhiteSpace($ConnectionName) -and -not [string]::IsNullOrWhiteSpace($projectResourceId)) {
  $connApiVersion = "2025-06-01"
  $connections = Get-AzJson -Args @(
    "rest", "--method", "get",
    "--url", "https://management.azure.com$projectResourceId/connections?api-version=$connApiVersion",
    "-o", "json"
  )

  $conn = $connections.value | Where-Object { $_.name -eq $ConnectionName } | Select-Object -First 1
  if ($null -eq $conn) {
    Add-Result -Check "Foundry connection '$ConnectionName' exists" -Status "FAIL" -Details "Connection not found under project."
  }
  else {
    Add-Result -Check "Foundry connection '$ConnectionName' exists" -Status "PASS" -Details "target=$($conn.properties.target)"

    if ($conn.properties.authType -eq "ProjectManagedIdentity") {
      Add-Result -Check "Connection '$ConnectionName' authType" -Status "PASS" -Details "authType=ProjectManagedIdentity"
    }
    else {
      Add-Result -Check "Connection '$ConnectionName' authType" -Status "FAIL" -Details "authType=$($conn.properties.authType)"
    }

    $expectedAudience = "api://$ApiApplicationId"
    if ($conn.properties.audience -eq $expectedAudience) {
      Add-Result -Check "Connection '$ConnectionName' audience" -Status "PASS" -Details "audience=$($conn.properties.audience)"
    }
    else {
      Add-Result -Check "Connection '$ConnectionName' audience" -Status "WARN" -Details "expected=$expectedAudience actual=$($conn.properties.audience)"
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedTargetSseUrl)) {
      if ($conn.properties.target -eq $ExpectedTargetSseUrl) {
        Add-Result -Check "Connection '$ConnectionName' target URL" -Status "PASS" -Details "target matches expected URL."
      }
      else {
        Add-Result -Check "Connection '$ConnectionName' target URL" -Status "WARN" -Details "expected=$ExpectedTargetSseUrl actual=$($conn.properties.target)"
      }
    }
  }
}
elseif (-not [string]::IsNullOrWhiteSpace($ConnectionName)) {
  Add-Result -Check "Foundry connection '$ConnectionName' exists" -Status "WARN" -Details "Skipped (provide FoundryProjectEndpoint or FoundryProjectResourceId)."
}

Write-Host ""
Write-Host "Validation results" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$failCount = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host ""
if ($failCount -eq 0) {
  if ($warnCount -eq 0) {
    Write-Host "PASS: Configuration checks indicate Foundry should be able to mint tokens that include the expected app role(s)." -ForegroundColor Green
  }
  else {
    Write-Host "PASS with WARNINGS: Core role assignment checks passed, but review warning items." -ForegroundColor Yellow
  }
  Write-Host "Note: token caching in Foundry/runtime can delay observation of new role assignments."
  exit 0
}
else {
  Write-Host "FAIL: One or more required configuration checks did not pass." -ForegroundColor Red
  Write-Host "Fix failed checks, then rerun this script."
  exit 1
}
