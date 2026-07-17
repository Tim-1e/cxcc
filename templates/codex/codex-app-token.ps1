[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9:._-]+$')][string]$SecretId,
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')][string]$Key,
  [string]$SecretsPath
)

$ErrorActionPreference = 'Stop'
$homePath = if ($env:AI_ENV_HOME) {
  [Environment]::ExpandEnvironmentVariables($env:AI_ENV_HOME)
} else {
  $HOME
}
$secretsPath = if ($SecretsPath) {
  [Environment]::ExpandEnvironmentVariables($SecretsPath)
} else {
  Join-Path $homePath '.ai-secrets\secrets.toml'
}

if (-not (Test-Path -LiteralPath $secretsPath -PathType Leaf)) {
  throw 'AI secret store is missing.'
}

$currentSection = ''
foreach ($line in Get-Content -LiteralPath $secretsPath) {
  $trimmed = $line.Trim()
  if (-not $trimmed -or $trimmed.StartsWith('#')) {
    continue
  }
  if ($trimmed -match '^\[([^\]]+)\]\s*$') {
    $currentSection = $Matches[1].Trim()
    continue
  }
  if ($currentSection -ne $SecretId) {
    continue
  }
  if ($trimmed -notmatch ('^' + [regex]::Escape($Key) + '\s*=\s*(.+)$')) {
    continue
  }

  $rawValue = $Matches[1].Trim()
  if ($rawValue -match '^("(?:\\.|[^"])*")\s*(?:#.*)?$') {
    try {
      $value = $Matches[1] | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw 'The requested secret is not a valid quoted TOML string.'
    }
  } elseif ($rawValue -match "^'([^']*)'\s*(?:#.*)?$") {
    $value = $Matches[1]
  } else {
    throw 'The requested secret must be a quoted TOML string.'
  }

  if ([string]::IsNullOrWhiteSpace([string]$value)) {
    throw 'The requested secret is empty.'
  }
  [Console]::Out.Write([string]$value)
  exit 0
}

throw 'The requested secret was not found.'
