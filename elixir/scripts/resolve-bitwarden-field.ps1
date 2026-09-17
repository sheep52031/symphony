[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $Item,

  [Parameter(Mandatory = $true)]
  [string] $Field,

  [string] $BitwardenCli = "bw",

  [string] $SessionEnvironmentName = "BW_SESSION",

  [string] $PasswordEnvironmentName = "BW_PASSWORD",

  [string] $ForbiddenUserEnvironmentName = "LINEAR_API_KEY"
)

$ErrorActionPreference = "Stop"

try {
  $userScopedFallback = [Environment]::GetEnvironmentVariable($ForbiddenUserEnvironmentName, "User")
  $machineScopedFallback = [Environment]::GetEnvironmentVariable($ForbiddenUserEnvironmentName, "Machine")

  if (-not [string]::IsNullOrWhiteSpace($userScopedFallback) -or
      -not [string]::IsNullOrWhiteSpace($machineScopedFallback)) {
    throw "Remove the ambient Windows User/Machine-scope tracker credential before Bitwarden-backed startup."
  }

  $session = [Environment]::GetEnvironmentVariable($SessionEnvironmentName, "Process")

  if ([string]::IsNullOrWhiteSpace($session)) {
    $password = [Environment]::GetEnvironmentVariable($PasswordEnvironmentName, "Process")

    if ([string]::IsNullOrWhiteSpace($password)) {
      throw "Bitwarden host startup requires a process-scoped BW_SESSION or BW_PASSWORD; refusing an interactive unlock."
    }

    $session = (& $BitwardenCli "unlock" "--passwordenv" $PasswordEnvironmentName "--raw" 2>$null | Out-String).Trim()

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($session)) {
      throw "Bitwarden CLI could not unlock the host vault non-interactively."
    }
  }

  $statusJson = (& $BitwardenCli "status" "--session" $session 2>$null | Out-String)

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($statusJson)) {
    throw "Bitwarden CLI could not validate the supplied host session."
  }

  $status = ($statusJson | ConvertFrom-Json).status

  if ($status -cne "unlocked") {
    throw "Bitwarden host vault session is not unlocked."
  }

  $arguments = @("--session", $session, "get", "item", $Item)
  $rawItem = (& $BitwardenCli @arguments 2>$null | Out-String)

  if ($LASTEXITCODE -ne 0) {
    throw "Bitwarden CLI could not read the configured item. Ensure the host vault session is unlocked."
  }

  $itemObject = $rawItem | ConvertFrom-Json
  $matches = @($itemObject.fields | Where-Object { $_.name -ceq $Field })

  if ($matches.Count -ne 1) {
    throw "Bitwarden item must contain exactly one custom field with the configured name."
  }

  $value = [string] $matches[0].value

  if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains("`n") -or $value.Contains("`r")) {
    throw "Bitwarden custom field must contain one non-empty line."
  }

  [Console]::Out.Write($value)
  exit 0
}
catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
