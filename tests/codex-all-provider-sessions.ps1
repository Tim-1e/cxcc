param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestProcessEnvironment.ps1")
$previousProcessEnvironment = Save-TestProcessEnvironment
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-all-provider-test-" + [guid]::NewGuid().ToString("N"))
$testHome = Join-Path $tmpRoot "home"
$codexHome = Join-Path $testHome ".codex"
$aiEnvHome = Join-Path $testHome ".ai-env"
$previousAiEnvHome = $env:AI_ENV_HOME
$previousNonInteractive = $env:AI_ENV_NONINTERACTIVE
$previousAppServerCli = $env:AI_CODEX_APP_SERVER_CLI
$previousResumeCapture = $env:CX_TEST_RESUME_CAPTURE
$previousOpenAiApiKey = $env:OPENAI_API_KEY
$previousPath = $env:PATH

function Write-TestRollout {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Provider,
    [Parameter(Mandatory = $true)][string]$Preview,
    [Parameter(Mandatory = $true)][string]$Timestamp
  )

  $meta = [ordered]@{
    timestamp = $Timestamp
    type = "session_meta"
    payload = [ordered]@{
      id = $Id
      timestamp = $Timestamp
      cwd = $SourceDir
      originator = "cx-test"
      cli_version = "0.144.1"
      source = "cli"
      model_provider = $Provider
    }
  } | ConvertTo-Json -Depth 8 -Compress
  $message = [ordered]@{
    timestamp = $Timestamp
    type = "response_item"
    payload = [ordered]@{
      type = "message"
      role = "user"
      content = @([ordered]@{ type = "input_text"; text = $Preview })
    }
  } | ConvertTo-Json -Depth 8 -Compress
  [IO.File]::WriteAllText($Path, "$meta`n$message`n", [Text.UTF8Encoding]::new($false))
}

try {
  $env:AI_ENV_HOME = $testHome
  $env:AI_ENV_NONINTERACTIVE = "1"
  New-Item -ItemType Directory -Force -Path $aiEnvHome, $codexHome | Out-Null
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/profiles.json") -Destination (Join-Path $aiEnvHome "profiles.json")
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/codex/sub.config.toml") -Destination (Join-Path $codexHome "sub.config.toml")
  [IO.File]::WriteAllText((Join-Path $codexHome "config.toml"), "model_provider = `"openai`"`n", [Text.UTF8Encoding]::new($false))

  $sessionDir = Join-Path $codexHome "sessions/2026/07/16"
  New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
  $openAiId = "019f6a00-0000-7000-8000-000000000001"
  $surplusId = "019f6a00-0000-7000-8000-000000000002"
  $fakeBin = Join-Path $tmpRoot "bin"
  New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
  $fakeCodex = @'
if ($args -contains "resume") {
  [IO.File]::WriteAllText($env:CX_TEST_RESUME_CAPTURE, ($args -join "|"), [Text.UTF8Encoding]::new($false))
  exit 0
}
if ($args -contains "app-server" -and $env:OPENAI_API_KEY) {
  throw "Local session listing inherited OPENAI_API_KEY"
}
while (($line = [Console]::In.ReadLine()) -ne $null) {
  $request = $line | ConvertFrom-Json -Depth 50
  if ($request.method -eq "initialize") {
    [Console]::Out.WriteLine(([ordered]@{ id = $request.id; result = [ordered]@{} } | ConvertTo-Json -Compress))
    [Console]::Out.Flush()
    continue
  }
  if ($request.method -eq "thread/list") {
    if ($null -eq $request.params.modelProviders -or @($request.params.modelProviders).Count -ne 0) {
      [Console]::Out.WriteLine(([ordered]@{ id = $request.id; error = [ordered]@{ message = "modelProviders must be []" } } | ConvertTo-Json -Compress))
      [Console]::Out.Flush()
      continue
    }
    $data = @(
      [ordered]@{ id = $env:CX_TEST_OPENAI_ID; modelProvider = "openai"; preview = "openai session"; cwd = $env:CX_TEST_CWD; updatedAt = 1784167200 },
      [ordered]@{ id = $env:CX_TEST_SURPLUS_ID; modelProvider = "api-router"; preview = "surplus session"; cwd = $env:CX_TEST_CWD; updatedAt = 1784170800 }
    )
    [Console]::Out.WriteLine(([ordered]@{ id = $request.id; result = [ordered]@{ data = $data; nextCursor = $null } } | ConvertTo-Json -Depth 10 -Compress))
    [Console]::Out.Flush()
  }
}
'@
  [IO.File]::WriteAllText((Join-Path $fakeBin "codex.ps1"), $fakeCodex, [Text.UTF8Encoding]::new($false))
  $env:CX_TEST_OPENAI_ID = $openAiId
  $env:CX_TEST_SURPLUS_ID = $surplusId
  $env:CX_TEST_CWD = $SourceDir
  $env:PATH = "$fakeBin$([IO.Path]::PathSeparator)$previousPath"
  $env:AI_CODEX_APP_SERVER_CLI = Join-Path $fakeBin "codex.ps1"
  $env:CX_TEST_RESUME_CAPTURE = Join-Path $tmpRoot "resume-args.txt"
  Write-TestRollout -Path (Join-Path $sessionDir "rollout-2026-07-16T10-00-00-$openAiId.jsonl") -Id $openAiId -Provider "openai" -Preview "openai session" -Timestamp "2026-07-16T02:00:00Z"
  Write-TestRollout -Path (Join-Path $sessionDir "rollout-2026-07-16T11-00-00-$surplusId.jsonl") -Id $surplusId -Provider "api-router" -Preview "surplus session" -Timestamp "2026-07-16T03:00:00Z"

  . (Join-Path $SourceDir "src/powershell/CxCc/CxCc.ps1")
  $profile = Get-AiProfileByName -Tool "codex" -Name "sub"
  $env:OPENAI_API_KEY = "must-not-reach-session-list"
  $sessions = @(Get-CodexAllProviderSessions -Profile $profile)
  if ($env:OPENAI_API_KEY -cne "must-not-reach-session-list") { throw "Session listing mutated the caller API key" }
  $sessionIds = @($sessions | ForEach-Object { $_.id })
  if ($openAiId -notin $sessionIds -or $surplusId -notin $sessionIds) {
    throw "All-provider query did not return both test sessions"
  }
  $providers = @($sessions | Where-Object { $_.id -in @($openAiId, $surplusId) } | ForEach-Object { $_.modelProvider } | Sort-Object -Unique)
  if ($providers.Count -ne 2 -or "openai" -notin $providers -or "api-router" -notin $providers) {
    throw "All-provider query lost provider metadata"
  }

  $resumeArguments = @(Get-CodexResumeArguments -Profile $profile -SessionId $surplusId)
  if (($resumeArguments -join "|") -cne "--profile|sub|resume|$surplusId") {
    throw "Resume arguments do not force the current profile: $($resumeArguments -join ' ')"
  }
  Resume-CodexAllProviderSession -Arguments @($surplusId)
  $capturedResumeArguments = Get-Content -LiteralPath $env:CX_TEST_RESUME_CAPTURE -Raw
  if ($capturedResumeArguments -cne "--profile|sub|resume|$surplusId") {
    throw "cx resume did not invoke the expected command: $capturedResumeArguments"
  }

  $help = (& { cx help } 6>&1 | Out-String -Width 4096)
  foreach ($command in @("cx sessions", "cx resume", "cx app-bridge")) {
    if ($help -notmatch [regex]::Escape($command)) { throw "cx help is missing $command" }
  }

  Write-Host "Codex all-provider session tests passed"
} finally {
  if ($null -ne $previousAiEnvHome) { $env:AI_ENV_HOME = $previousAiEnvHome } else { Remove-Item Env:AI_ENV_HOME -ErrorAction SilentlyContinue }
  if ($null -ne $previousNonInteractive) { $env:AI_ENV_NONINTERACTIVE = $previousNonInteractive } else { Remove-Item Env:AI_ENV_NONINTERACTIVE -ErrorAction SilentlyContinue }
  if ($null -ne $previousAppServerCli) { $env:AI_CODEX_APP_SERVER_CLI = $previousAppServerCli } else { Remove-Item Env:AI_CODEX_APP_SERVER_CLI -ErrorAction SilentlyContinue }
  if ($null -ne $previousResumeCapture) { $env:CX_TEST_RESUME_CAPTURE = $previousResumeCapture } else { Remove-Item Env:CX_TEST_RESUME_CAPTURE -ErrorAction SilentlyContinue }
  if ($null -ne $previousOpenAiApiKey) { $env:OPENAI_API_KEY = $previousOpenAiApiKey } else { Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue }
  $env:PATH = $previousPath
  Remove-Item Env:CX_TEST_OPENAI_ID, Env:CX_TEST_SURPLUS_ID, Env:CX_TEST_CWD -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  Restore-TestProcessEnvironment -Snapshot $previousProcessEnvironment
}
