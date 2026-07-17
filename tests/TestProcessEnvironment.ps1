$ErrorActionPreference = "Stop"

function Save-TestProcessEnvironment {
  $snapshot = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in [Environment]::GetEnvironmentVariables("Process").GetEnumerator()) {
    $snapshot[[string]$entry.Key] = [string]$entry.Value
  }
  return $snapshot
}

function Restore-TestProcessEnvironment {
  param(
    [Parameter(Mandatory = $true)]
    [Collections.Generic.Dictionary[string, string]]$Snapshot
  )

  foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys)) {
    if (-not $Snapshot.ContainsKey([string]$name)) {
      Remove-Item -LiteralPath ("Env:\{0}" -f $name) -ErrorAction Stop
    }
  }
  foreach ($entry in $Snapshot.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
  }
}

if ($MyInvocation.InvocationName -ne ".") {
  $name = "CXCC_TEST_ENVIRONMENT_RESTORE"
  $extraName = "CXCC_TEST_ENVIRONMENT_EXTRA_$([guid]::NewGuid().ToString('N'))"
  $before = [Environment]::GetEnvironmentVariable($name, "Process")
  $snapshot = Save-TestProcessEnvironment
  try {
    [Environment]::SetEnvironmentVariable($name, "changed", "Process")
    [Environment]::SetEnvironmentVariable($extraName, "temporary", "Process")
    Restore-TestProcessEnvironment -Snapshot $snapshot
    if ([Environment]::GetEnvironmentVariable($name, "Process") -cne $before) { throw "Existing environment value was not restored" }
    if ($null -ne [Environment]::GetEnvironmentVariable($extraName, "Process")) { throw "Temporary environment value was not removed" }
    Write-Host "Test process environment restore check passed."
  } finally {
    if ($null -eq $before) {
      Remove-Item -LiteralPath ("Env:\{0}" -f $name) -ErrorAction SilentlyContinue
    } else {
      [Environment]::SetEnvironmentVariable($name, $before, "Process")
    }
    Remove-Item -LiteralPath ("Env:\{0}" -f $extraName) -ErrorAction SilentlyContinue
  }
}
