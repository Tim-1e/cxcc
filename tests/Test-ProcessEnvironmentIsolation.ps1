[CmdletBinding()]
param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestProcessEnvironment.ps1")
$outerEnvironment = Save-TestProcessEnvironment
$sentinels = [ordered]@{
  OPENAI_API_KEY = "preexisting-openai"
  ANTHROPIC_AUTH_TOKEN = "preexisting-anthropic"
  CODEX_HOME = "C:\preexisting-codex"
  AI_CLAUDE_LABEL = "preexisting-label"
  CX_TEST_OPENAI_ID = "preexisting-openai-id"
  CX_TEST_SURPLUS_ID = "preexisting-surplus-id"
  CX_TEST_CWD = "C:\preexisting-cwd"
}

try {
  foreach ($entry in $sentinels.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
  }

  & (Join-Path $PSScriptRoot "ai-env-smoke.ps1") -SourceDir $SourceDir
  & (Join-Path $PSScriptRoot "ai-env-health.ps1") -SourceDir $SourceDir
  & (Join-Path $PSScriptRoot "ai-env-mcp.ps1") -SourceDir $SourceDir
  & (Join-Path $PSScriptRoot "codex-all-provider-sessions.ps1") -SourceDir $SourceDir
  & (Join-Path $PSScriptRoot "codex-app-bridge-management.ps1") -SourceDir $SourceDir

  foreach ($entry in $sentinels.GetEnumerator()) {
    $actual = [Environment]::GetEnvironmentVariable($entry.Key, "Process")
    if ($actual -cne $entry.Value) {
      throw "Environment isolation failed for $($entry.Key): expected '$($entry.Value)', got '$actual'"
    }
  }
  Write-Host "PowerShell test environment isolation passed."
} finally {
  Restore-TestProcessEnvironment -Snapshot $outerEnvironment
}
