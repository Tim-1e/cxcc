$script:CxCcSourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$script:AiEnvScriptRoot = $PSScriptRoot
$script:AiHome = if ($env:AI_ENV_HOME) { [Environment]::ExpandEnvironmentVariables($env:AI_ENV_HOME) } else { $HOME }
$script:AiConfigDir = Join-Path $script:AiHome ".ai-env"
$script:AiRegistryPath = Join-Path $script:AiConfigDir "profiles.json"
$script:AiStatePath = Join-Path $script:AiConfigDir "state.json"
$script:AiSecretsPath = Join-Path $script:AiHome ".ai-secrets\secrets.toml"
$script:LegacyAiStateDir = Join-Path $script:AiHome ".ai-state"
$script:ClaudeRouterBaseUrl = "https://claude.example.com"
$script:AiHealthMaxOutputWidth = 120

. (Join-Path $PSScriptRoot "Profiles.ps1")
. (Join-Path $PSScriptRoot "ToolRuntime.ps1")
. (Join-Path $PSScriptRoot "Health.ps1")
. (Join-Path $PSScriptRoot "CodexApp.ps1")
. (Join-Path $PSScriptRoot "Mcp.ps1")
. (Join-Path $PSScriptRoot "Entrypoints.ps1")

Initialize-AiEnvProfiles
