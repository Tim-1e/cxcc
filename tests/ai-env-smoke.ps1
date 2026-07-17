[CmdletBinding()]
param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestProcessEnvironment.ps1")
$previousProcessEnvironment = Save-TestProcessEnvironment

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-env-smoke-" + [guid]::NewGuid().ToString("N"))
$testHome = Join-Path $tmpRoot "home"
$previousAiEnvHome = $env:AI_ENV_HOME
$previousNonInteractive = $env:AI_ENV_NONINTERACTIVE
$previousCodexConfigPath = $env:AI_CODEX_CONFIG_PATH
$previousCodexAppTokenCommand = $env:AI_CODEX_APP_TOKEN_COMMAND
$env:AI_ENV_HOME = $testHome
$env:AI_ENV_NONINTERACTIVE = "1"

$aiEnvDir = Join-Path $testHome ".ai-env"
$codexDir = Join-Path $testHome ".codex"
$profilesPath = Join-Path $aiEnvDir "profiles.json"
$statePath = Join-Path $aiEnvDir "state.json"
$secretsDir = Join-Path $testHome ".ai-secrets"
$secretsPath = Join-Path $secretsDir "secrets.toml"
$codexConfigPath = Join-Path $codexDir "config.toml"
$codexAuthPath = Join-Path $codexDir "auth.json"
$env:AI_CODEX_CONFIG_PATH = $codexConfigPath
$env:AI_CODEX_APP_TOKEN_COMMAND = Join-Path $SourceDir "templates/codex/codex-app-token.ps1"

try {
  New-Item -ItemType Directory -Force -Path $aiEnvDir, $codexDir, $secretsDir | Out-Null
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/profiles.json") -Destination $profilesPath -Force
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/codex/sub.config.toml") -Destination (Join-Path $codexDir "sub.config.toml") -Force
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/codex/api.config.toml") -Destination (Join-Path $codexDir "api.config.toml") -Force
  @'
model = "gpt-existing"
model_reasoning_effort = "high"

[features]
memories = true

[mcp_servers.keep]
command = "keep-me"
'@ | Set-Content -LiteralPath $codexConfigPath -Encoding UTF8
  '{"auth_mode":"chatgpt","marker":"keep-me"}' | Set-Content -LiteralPath $codexAuthPath -Encoding UTF8
  $codexAuthBefore = Get-FileHash -Algorithm SHA256 -LiteralPath $codexAuthPath
  $sessionDir = Join-Path $codexDir "sessions\2026\06\09"
  New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
  @'
{"timestamp":"2026-06-09T00:00:00.000Z","type":"session_meta","payload":{"id":"stats-smoke","cwd":"C:\\workspace\\cxcc"}}
{"timestamp":"2026-06-09T00:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":700,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200}}}}
'@ | Set-Content -LiteralPath (Join-Path $sessionDir "rollout-2026-06-09T00-00-00-stats-smoke.jsonl") -Encoding UTF8
  Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
  '{"codex":"sub","claude":"sub","updated_at":null}' | Set-Content -LiteralPath $statePath -Encoding UTF8
  @"
[codex.api]
OPENAI_API_KEY = "sk-test-codex"

[codex.cxenvtest]
OPENAI_API_KEY = "sk-test-cxenv"

[codex.surplus]
OPENAI_API_KEY = "sk-test-surplus"

[codex.malformed]
OPENAI_API_KEY = "bad\q"

[claude.api-docker]
  ANTHROPIC_BASE_URL = "https://claude.test"
ANTHROPIC_AUTH_TOKEN = "sk-test-token"

[claude.envtest]
ANTHROPIC_AUTH_TOKEN = "sk-test-envtoken"
"@ | Set-Content -LiteralPath $secretsPath -Encoding UTF8

  . (Join-Path $SourceDir "src/powershell/CxCc/CxCc.ps1")

  $arrayConfigPath = Join-Path $codexDir 'array-table.config.toml'
  @'
model = "top-level"

[[custom.entries]] # valid TOML array table
model = "nested-must-stay"
'@ | Set-Content -LiteralPath $arrayConfigPath -Encoding UTF8
  $env:AI_CODEX_CONFIG_PATH = $arrayConfigPath
  Set-CodexAppConfig -TopLevelValues ([ordered]@{ model = '"updated-top-level"' }) -ProviderBlock $null | Out-Null
  $arrayConfigAfterUpdate = Get-Content -Raw -LiteralPath $arrayConfigPath
  if ($arrayConfigAfterUpdate -notmatch '(?m)^model = "updated-top-level"$' -or $arrayConfigAfterUpdate -notmatch '(?m)^model = "nested-must-stay"$') {
    throw 'Codex App config update rewrote an array-table value'
  }
  $env:AI_CODEX_CONFIG_PATH = $codexConfigPath

  $cxHelp = (& { cx help } 6>&1 | Out-String -Width 4096)
  $cxList = (& { cx list } 6>&1 | Out-String -Width 4096)
  $ccHelp = (& { cc help } 6>&1 | Out-String -Width 4096)
  $ccList = (& { cc list } 6>&1 | Out-String -Width 4096)
  $cxStats = (& { cx stats --days 365 } 6>&1 | Out-String -Width 4096)
  $cxAddApi = (& { cx add-api api:test --base-url https://router.test/v1 --model gpt-test } 6>&1 | Out-String -Width 4096)
  $cxAddSub = (& { cx add-sub sub:test } 6>&1 | Out-String -Width 4096)
  $cxAddSurplus = (& { cx add-api surplus --base-url https://surplus.test/v1 --model gpt-surplus --provider-name Surplus } 6>&1 | Out-String -Width 4096)
  $surplusProfilePath = Join-Path $codexDir 'api-surplus.config.toml'
  @'
model_provider = "api-router"
model = "gpt-surplus"
model_reasoning_effort = "xhigh"
disable_response_storage = true

[model_providers.decoy]
name = "Wrong Provider"
base_url = "https://wrong.test/v1"
env_key = "WRONG_API_KEY"

[model_providers.api-router]
name = "Surplus"
base_url = "https://surplus.test/v1"
env_key = "OPENAI_API_KEY"
'@ | Set-Content -LiteralPath $surplusProfilePath -Encoding UTF8
  $cxAppSurplus = (& { cx app-default surplus } 6>&1 | Out-String -Width 4096)
  $codexAppConfigAfterSurplus = Get-Content -Raw -LiteralPath $codexConfigPath
  $codexExecutable = Get-Command codex -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($codexExecutable) {
    $strictConfigStart = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $codexExecutable.Source, 'app-server', '--strict-config', '--listen', 'stdio://')) { [void]$strictConfigStart.ArgumentList.Add($argument) }
    $strictConfigStart.UseShellExecute = $false
    $strictConfigStart.RedirectStandardInput = $true
    $strictConfigStart.RedirectStandardOutput = $true
    $strictConfigStart.RedirectStandardError = $true
    $strictConfigStart.Environment['CODEX_HOME'] = $codexDir
    $strictConfigProcess = [Diagnostics.Process]::Start($strictConfigStart)
    $strictConfigProcess.StandardInput.Close()
    if (-not $strictConfigProcess.WaitForExit(15000)) {
      $strictConfigProcess.Kill($true)
      throw 'Codex strict-config validation timed out'
    }
    $strictConfigError = $strictConfigProcess.StandardError.ReadToEnd()
    if ($strictConfigProcess.ExitCode -ne 0) { throw "Codex strict-config rejected App config: $strictConfigError" }
  }
  $codexAppRegistryAfterSurplus = Get-Content -Raw -LiteralPath $profilesPath | ConvertFrom-Json
  $codexCliDefaultAfterSurplus = $codexAppRegistryAfterSurplus.defaults.codex
  $codexStateAfterSurplus = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  $codexAppToken = (& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $env:AI_CODEX_APP_TOKEN_COMMAND -SecretId codex.surplus -Key OPENAI_API_KEY | Out-String).Trim()
  $cxAppSurplusAgain = (& { cx app-default surplus } 6>&1 | Out-String -Width 4096)
  $codexAppConfigAfterSecondSwitch = Get-Content -Raw -LiteralPath $codexConfigPath
  $configBeforeActiveRemove = Get-Content -Raw -LiteralPath $codexConfigPath
  $registryBeforeActiveRemove = Get-Content -Raw -LiteralPath $profilesPath
  $activeRemoveError = try { cx remove surplus --delete-config | Out-Null; '' } catch { $_.Exception.Message }
  $configAfterActiveRemove = Get-Content -Raw -LiteralPath $codexConfigPath
  $registryAfterActiveRemove = Get-Content -Raw -LiteralPath $profilesPath
  $cxAppSub = (& { cx app-default sub } 6>&1 | Out-String -Width 4096)
  $codexAppConfigAfterSub = Get-Content -Raw -LiteralPath $codexConfigPath
  $codexAppRegistryAfterSub = Get-Content -Raw -LiteralPath $profilesPath
  $codexAuthAfter = Get-FileHash -Algorithm SHA256 -LiteralPath $codexAuthPath
  $ccAddApi = (& { cc add-api api:test --base-url https://claude.test } 6>&1 | Out-String -Width 4096)
  $ccAddSub = (& { cc add-sub sub:test } 6>&1 | Out-String -Width 4096)
  $cxManagedList = (& { cx list } 6>&1 | Out-String -Width 4096)
  $ccManagedList = (& { cc list } 6>&1 | Out-String -Width 4096)
  $codexApiTestConfig = Join-Path $codexDir "api-api-test.config.toml"
  $codexApiConfigExistsAfterAdd = Test-Path -LiteralPath $codexApiTestConfig
  $cxRemoveApi = (& { cx remove api:test --delete-config } 6>&1 | Out-String -Width 4096)
  $cxRemoveSub = (& { cx remove sub:test --delete-config } 6>&1 | Out-String -Width 4096)
  $ccRemoveApi = (& { cc remove api:test } 6>&1 | Out-String -Width 4096)
  $ccRemoveSub = (& { cc remove sub:test } 6>&1 | Out-String -Width 4096)
  $cxSwitch = (& { cx api } 6>&1 | Out-String -Width 4096)
  $openAiKey = $env:OPENAI_API_KEY
  $ccSwitch = (& { cc api:docker } 6>&1 | Out-String -Width 4096)

  if ($cxHelp -notmatch "cx - switch Codex state") { throw "cx help output missing header" }
  if ($cxHelp -notmatch "Auto-select a cached healthy Codex profile") { throw "cx help output missing auto-select wording" }
  if ($cxHelp -notmatch "cx edit") { throw "cx help output missing edit" }
  if ($cxHelp -notmatch "cx app-default") { throw "cx help output missing app-default" }
  if ($cxHelp -notmatch "cx doctor") { throw "cx help output missing doctor" }
  if ($cxHelp -notmatch "cx next") { throw "cx help output missing next" }
  if ($cxList -notmatch "Codex profiles") { throw "cx list output missing header" }
  if ($cxList -notmatch "Health") { throw "cx list missing Health column" }
  if ($ccHelp -notmatch "cc - switch Claude Code state") { throw "cc help output missing header" }
  if ($ccHelp -notmatch "Auto-select a cached healthy Claude Code profile") { throw "cc help output missing auto-select wording" }
  if ($ccHelp -notmatch "cc edit") { throw "cc help output missing edit" }
  if ($ccHelp -notmatch "cc next") { throw "cc help output missing next" }
  if ($ccList -notmatch "Claude Code profiles") { throw "cc list output missing header" }
  if ($ccList -notmatch "Health") { throw "cc list missing Health column" }
  if ($cxStats -notmatch "Codex local token stats") { throw "cx stats output missing header" }
  if ($cxStats -notmatch "Total:\s+1\.2K \(1200\)") { throw "cx stats did not summarize fixture tokens" }
  if ($cxHelp -notmatch "cx add-api NAME") { throw "cx help output missing add-api" }
  if ($ccHelp -notmatch "cc add-api NAME") { throw "cc help output missing add-api" }
  if ($cxAddApi -notmatch "Added Codex API profile 'api:test'") { throw "cx add-api did not report success" }
  if ($cxAddSub -notmatch "Added Codex subscription profile 'sub:test'") { throw "cx add-sub did not report success" }
  if ($cxAddSurplus -notmatch "Added Codex API profile 'surplus'") { throw "cx add-api surplus did not report success" }
  if ($cxAppSurplus -notmatch "Codex App default = surplus") { throw "cx app-default surplus did not report success" }
  if ($codexAppRegistryAfterSurplus.defaults.codex_app -ne "surplus") { throw "cx app-default did not persist defaults.codex_app" }
  if ($codexAppConfigAfterSurplus -notmatch '(?m)^model_provider = "ai-env-app"$') { throw "cx app-default surplus did not select the managed App provider" }
  if ($codexAppConfigAfterSurplus -notmatch '(?m)^model = "gpt-surplus"$') { throw "cx app-default surplus did not project the profile model" }
  if ($codexAppConfigAfterSurplus -notmatch '(?m)^base_url = "https://surplus\.test/v1"$') { throw "cx app-default surplus did not project the profile base URL" }
  if ($codexAppConfigAfterSurplus -notmatch '(?m)^\[model_providers\.ai-env-app\.auth\]$') { throw "cx app-default surplus did not configure command-backed auth" }
  if ($codexAppConfigAfterSurplus -match '(?m)^\s*(env_key|requires_openai_auth|experimental_bearer_token)\s*=') { throw "cx app-default wrote a forbidden second auth method" }
  if ($codexAppConfigAfterSurplus -match 'sk-test-surplus') { throw "cx app-default leaked the API key into config.toml" }
  if ($codexAppConfigAfterSurplus -notmatch '(?m)^\[mcp_servers\.keep\]$') { throw "cx app-default removed unrelated Codex config" }
  if ($codexAppToken -ne 'sk-test-surplus') { throw "Codex App token helper did not read codex.surplus" }
  if ($codexCliDefaultAfterSurplus -ne 'sub') { throw "cx app-default changed the CLI default" }
  if ($codexStateAfterSurplus.codex -ne 'sub') { throw "cx app-default changed the CLI selected state" }
  if (([regex]::Matches($codexAppConfigAfterSecondSwitch, '(?m)^\[model_providers\.ai-env-app\]$')).Count -ne 1) { throw "cx app-default is not idempotent" }
  if ($codexAppConfigAfterSecondSwitch -cne $codexAppConfigAfterSurplus) { throw "second cx app-default surplus changed config.toml" }
  if ($cxAppSurplusAgain -notmatch "Codex App default = surplus") { throw "second cx app-default surplus did not report success" }
  if ($activeRemoveError -notmatch 'while it is the Codex App default') { throw "cx remove did not protect the active Codex App profile" }
  if ($configAfterActiveRemove -cne $configBeforeActiveRemove -or $registryAfterActiveRemove -cne $registryBeforeActiveRemove) { throw "failed active App profile removal changed state" }
  if ($cxAppSub -notmatch "Codex App default = sub") { throw "cx app-default sub did not report success" }
  if ($codexAppConfigAfterSub -notmatch '(?m)^model_provider = "openai"$') { throw "cx app-default sub did not restore the OpenAI provider" }
  if ($codexAppConfigAfterSub -notmatch '(?m)^model = "gpt-5\.5"$') { throw "cx app-default sub did not restore the subscription profile model" }
  if ($codexAppConfigAfterSub -notmatch '(?m)^model_reasoning_effort = "high"$') { throw "cx app-default sub did not restore the baseline reasoning effort" }
  if ($codexAppConfigAfterSub -match '(?m)^disable_response_storage\s*=') { throw "cx app-default retained an unsupported storage setting" }
  if ($codexAppConfigAfterSub -notmatch '(?m)^\[model_providers\.ai-env-app\]$') { throw "cx app-default sub unexpectedly removed the reusable App provider" }
  if ($codexAuthBefore.Hash -ne $codexAuthAfter.Hash) { throw "cx app-default modified auth.json" }

  cx add-sub app:other | Out-Null
  $configBeforeInvalidAppSwitch = Get-Content -Raw -LiteralPath $codexConfigPath
  $registryBeforeInvalidAppSwitch = Get-Content -Raw -LiteralPath $profilesPath
  $unknownAppError = try { cx app-default missing-profile | Out-Null; '' } catch { $_.Exception.Message }
  $otherHomeError = try { cx app-default app:other | Out-Null; '' } catch { $_.Exception.Message }
  if ($unknownAppError -notmatch "Unknown Codex profile 'missing-profile'") { throw "cx app-default returned the wrong unknown-profile error" }
  if ($otherHomeError -notmatch 'only select profiles that share its CODEX_HOME') { throw "cx app-default did not reject a different CODEX_HOME: $otherHomeError" }
  if ((Get-Content -Raw -LiteralPath $codexConfigPath) -cne $configBeforeInvalidAppSwitch) { throw "failed cx app-default changed config.toml" }
  if ((Get-Content -Raw -LiteralPath $profilesPath) -cne $registryBeforeInvalidAppSwitch) { throw "failed cx app-default changed profiles.json" }
  cx remove app:other --delete-config | Out-Null
  if (($codexAppRegistryAfterSub | ConvertFrom-Json).defaults.codex_app -ne 'sub') { throw "cx app-default sub did not persist defaults.codex_app" }

  $validSurplusProfile = Get-Content -Raw -LiteralPath $surplusProfilePath
  foreach ($invalidBaseUrl in @('http://surplus.test/v1', 'https://user@surplus.test/v1')) {
    $invalidSurplusProfile = $validSurplusProfile -replace 'https://surplus\.test/v1', $invalidBaseUrl
    $invalidSurplusProfile | Set-Content -LiteralPath $surplusProfilePath -Encoding UTF8
    $invalidUrlError = try { cx app-default surplus | Out-Null; '' } catch { $_.Exception.Message }
    if ($invalidUrlError -notmatch 'absolute HTTPS base_url without user info') { throw "cx app-default accepted invalid base_url $invalidBaseUrl" }
    if ((Get-Content -Raw -LiteralPath $codexConfigPath) -cne $configBeforeInvalidAppSwitch) { throw "invalid base_url changed config.toml" }
  }
  $validSurplusProfile | Set-Content -LiteralPath $surplusProfilePath -Encoding UTF8

  $missingTokenStdout = Join-Path $tmpRoot 'missing-token.stdout'
  $missingTokenStderr = Join-Path $tmpRoot 'missing-token.stderr'
  & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $env:AI_CODEX_APP_TOKEN_COMMAND -SecretId codex.missing -Key OPENAI_API_KEY 1> $missingTokenStdout 2> $missingTokenStderr
  $missingTokenExitCode = $LASTEXITCODE
  $missingTokenOutput = if (Test-Path -LiteralPath $missingTokenStdout) { Get-Content -Raw -LiteralPath $missingTokenStdout } else { '' }
  $missingTokenError = if (Test-Path -LiteralPath $missingTokenStderr) { Get-Content -Raw -LiteralPath $missingTokenStderr } else { '' }
  if ($missingTokenExitCode -eq 0) { throw "Codex App token helper accepted a missing secret" }
  if ($missingTokenOutput) { throw "Codex App token helper wrote stdout on failure" }
  if ($missingTokenError -match 'sk-test-surplus') { throw "Codex App token helper leaked a secret on failure" }

  $malformedTokenStdout = Join-Path $tmpRoot 'malformed-token.stdout'
  $malformedTokenStderr = Join-Path $tmpRoot 'malformed-token.stderr'
  & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $env:AI_CODEX_APP_TOKEN_COMMAND -SecretId codex.malformed -Key OPENAI_API_KEY 1> $malformedTokenStdout 2> $malformedTokenStderr
  $malformedTokenExitCode = $LASTEXITCODE
  $malformedTokenOutput = if (Test-Path -LiteralPath $malformedTokenStdout) { Get-Content -Raw -LiteralPath $malformedTokenStdout } else { '' }
  $malformedTokenError = if (Test-Path -LiteralPath $malformedTokenStderr) { Get-Content -Raw -LiteralPath $malformedTokenStderr } else { '' }
  if ($malformedTokenExitCode -eq 0 -or $malformedTokenOutput) { throw "Codex App token helper accepted a malformed secret" }
  if ($malformedTokenError -notmatch 'not a valid quoted TOML string' -or $malformedTokenError -match 'bad\\q') { throw "Codex App token helper exposed parser details" }
  if ($ccAddApi -notmatch "Added Claude Code API profile 'api:test'") { throw "cc add-api did not report success" }
  if ($ccAddSub -notmatch "Added Claude Code subscription profile 'sub:test'") { throw "cc add-sub did not report success" }
  if ($cxManagedList -notmatch "api:test") { throw "cx list did not show added API profile" }
  if ($cxManagedList -notmatch "sub:test") { throw "cx list did not show added sub profile" }
  if ($ccManagedList -notmatch "api:test") { throw "cc list did not show added API profile" }
  if ($ccManagedList -notmatch "sub:test") { throw "cc list did not show added sub profile" }
  if (-not $codexApiConfigExistsAfterAdd) { throw "cx add-api did not write Codex config" }
  if ($cxRemoveApi -notmatch "Removed Codex profile 'api:test'") { throw "cx remove api did not report success" }
  if ($cxRemoveSub -notmatch "Removed Codex profile 'sub:test'") { throw "cx remove sub did not report success" }
  if ($ccRemoveApi -notmatch "Removed Claude Code profile 'api:test'") { throw "cc remove api did not report success" }
  if ($ccRemoveSub -notmatch "Removed Claude Code profile 'sub:test'") { throw "cc remove sub did not report success" }
  if (Test-Path -LiteralPath $codexApiTestConfig) { throw "cx remove --delete-config did not remove Codex config" }
  if ($cxSwitch -notmatch "Secret source: .*secrets\.toml#codex\.api") { throw "cx api did not load TOML secret" }
  if ($cxSwitch -notmatch "API local check: profile file=True; key=True") { throw "cx api switch missing local check" }
  if ($openAiKey -ne "sk-test-codex") { throw "cx api did not set OPENAI_API_KEY from TOML" }
  if ($ccSwitch -notmatch "Secret source: .*secrets\.toml#claude\.api-docker") { throw "cc api:docker did not load TOML secret" }
  if ($ccSwitch -notmatch "API local check: auth=True; url=True") { throw "cc api switch missing local check" }
  if ($env:ANTHROPIC_AUTH_TOKEN -ne "sk-test-token") { throw "cc api:docker did not set ANTHROPIC_AUTH_TOKEN from TOML" }
  if ($env:CODEX_HOME -ne $codexDir) { throw "Unexpected CODEX_HOME: $env:CODEX_HOME" }

  # --- per-profile env (--env): persisted in registry, exported on switch, cleared on switch-away ---
  $ccAddEnv = (& { cc add-api envtest --base-url https://claude.test --env ANTHROPIC_DEFAULT_SONNET_MODEL=glm-test-sonnet --env CLAUDE_CODE_AUTO_COMPACT_WINDOW=987654 } 6>&1 | Out-String -Width 4096)
  $cxAddEnv = (& { cx add-api cxenvtest --base-url https://router.test/v1 --env CODEX_EXTRA_FLAG=on } 6>&1 | Out-String -Width 4096)
  $registryAfterEnv = Get-Content -LiteralPath $profilesPath -Raw
  $ccEnvSwitch = (& { cc envtest } 6>&1 | Out-String -Width 4096)
  $ccEnvSonnet = $env:ANTHROPIC_DEFAULT_SONNET_MODEL
  $ccEnvWindow = $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW
  $ccEnvAway = (& { cc api:docker } 6>&1 | Out-String -Width 4096)
  $ccEnvSonnetAfterAway = $env:ANTHROPIC_DEFAULT_SONNET_MODEL
  $cxEnvSwitch = (& { cx cxenvtest } 6>&1 | Out-String -Width 4096)
  $cxEnvFlag = $env:CODEX_EXTRA_FLAG
  $cxEnvAway = (& { cx api } 6>&1 | Out-String -Width 4096)
  $cxEnvFlagAfterAway = $env:CODEX_EXTRA_FLAG

  if ($ccAddEnv -notmatch "Added Claude Code API profile 'envtest'") { throw "cc add-api --env did not report success" }
  if ($ccAddEnv -notmatch "Env:") { throw "cc add-api did not report Env summary" }
  if ($registryAfterEnv -notmatch "ANTHROPIC_DEFAULT_SONNET_MODEL") { throw "registry did not persist profile env map" }
  if ($ccEnvSonnet -ne "glm-test-sonnet") { throw "cc switch did not export ANTHROPIC_DEFAULT_SONNET_MODEL from profile env" }
  if ($ccEnvWindow -ne "987654") { throw "cc switch did not export CLAUDE_CODE_AUTO_COMPACT_WINDOW from profile env" }
  if ($ccEnvSonnetAfterAway) { throw "cc switch-away did not clear the previous profile env var (leak)" }
  if ($cxEnvFlag -ne "on") { throw "cx switch did not export CODEX_EXTRA_FLAG from profile env" }
  if ($cxEnvFlagAfterAway) { throw "cx switch-away did not clear the previous profile env var (leak)" }

  Write-Host "AI env PowerShell smoke check passed."
} finally {
  if ($null -ne $previousAiEnvHome) {
    $env:AI_ENV_HOME = $previousAiEnvHome
  } else {
    Remove-Item Env:AI_ENV_HOME -ErrorAction SilentlyContinue
  }
  if ($null -ne $previousNonInteractive) {
    $env:AI_ENV_NONINTERACTIVE = $previousNonInteractive
  } else {
    Remove-Item Env:AI_ENV_NONINTERACTIVE -ErrorAction SilentlyContinue
  }
  if ($null -ne $previousCodexConfigPath) {
    $env:AI_CODEX_CONFIG_PATH = $previousCodexConfigPath
  } else {
    Remove-Item Env:AI_CODEX_CONFIG_PATH -ErrorAction SilentlyContinue
  }
  if ($null -ne $previousCodexAppTokenCommand) {
    $env:AI_CODEX_APP_TOKEN_COMMAND = $previousCodexAppTokenCommand
  } else {
    Remove-Item Env:AI_CODEX_APP_TOKEN_COMMAND -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  Restore-TestProcessEnvironment -Snapshot $previousProcessEnvironment
}

# GitHub Actions' PowerShell wrapper exits with the most recent native process
# code. The smoke test intentionally runs failing token-helper probes, so make
# the script's successful outcome explicit after all assertions and cleanup.
exit 0
