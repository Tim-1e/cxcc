function Show-CxHelp {
  @"
cx - switch Codex state for this PowerShell session

Usage:
  cx                 Auto-select a cached healthy Codex profile (default fallback)
  cx sub             Use a named subscription profile
  cx sub:work        Use another subscription profile, if registered
  cx api             Use the default API profile
  cx api:docker      Use a named API profile
  cx list            List registry profiles and cached health
  cx status          Print current saved/process state; --fresh/--refresh re-probes selected profile
  cx stats           Summarize local rollout token usage
  cx add-api NAME    Register a Codex API profile that shares ~/.codex by default
                     Options: --base-url URL --env-key NAME --provider-name NAME
                              --model MODEL --home PATH --env KEY=VALUE
                     Prompts for missing base-url/env-key and the secret in a terminal.
  cx add-sub NAME    Register an isolated Codex subscription CODEX_HOME
  cx remove NAME     Remove a Codex profile registration
  cx probe-model NAME [MODEL]  Set/clear health-probe model override
  cx default [NAME]  Show/set the default (primary) profile
  cx app-default [NAME]  Show/set the Codex App provider profile
  cx sessions [--archived] [--json]  List local sessions from every provider
  cx resume [SESSION_ID]  Resume a local session with the currently selected profile
  cx app-bridge install|status|remove  Make Codex App list sessions from every provider
  cx edit            Open the profile registry (profiles.json) in EDITOR
  cx health          Probe & report profile health table (🟢🟡🔴, parallel); --fresh/--refresh re-probes
  cx doctor          Run codex doctor full diagnostic (slow, on-demand)
  cx health-clear    Clear the health probe cache
  cx next            Cycle to the next enabled profile
  cx help            Show this help

Config:
  Registry: ~/.ai-env/profiles.json
  State:    ~/.ai-env/state.json
  Secrets:  ~/.ai-secrets/secrets.toml

After switching, run Codex separately:
  codex
  codex exec "your task"

Notes:
  cx does not launch Codex. The PowerShell codex shim injects --profile for runtime commands.
  Codex App has no --profile selector; app-default projects the selected profile into base config.toml.
  Session discovery is provider-neutral. cx resume chooses history first, then consumes with the current cx profile.
  app-bridge changes only App thread/list requests; restart Codex App after install/remove.
  After a Codex App update, close the App and rerun cx app-bridge install to refresh the pinned CLI.
  Other unprofiled app-server consumers of the same CODEX_HOME (for example an IDE integration) see the same base provider.
  Subscription uses codex login cached under the selected CODEX_HOME.
  API mode does not run codex login --with-api-key; it loads OPENAI_API_KEY only for this shell.
  Multiple API profiles can share ~/.codex. Multiple subscription accounts need separate home values.
  Add commands only write profile metadata and Codex config. Put real tokens in secrets.toml.
  Without probe_model, Codex probes use runtime/global config.toml model, then a cheap fallback.
  Legacy ~/.ai-secrets/*.ps1 files are still accepted as a fallback.
"@ | Write-Host
}

function Show-CcHelp {
  @"
cc - switch Claude Code state for this PowerShell session

Usage:
  cc                 Auto-select a cached healthy Claude Code profile (default fallback)
  cc sub             Clear Anthropic API env and use local Claude subscription login
  cc sub:work        Use another subscription profile, if registered
  cc api             Use the default API profile
  cc api:docker      Use a named API profile
  cc list            List registry profiles and cached health
  cc status          Print current saved/process state; --fresh/--refresh re-probes selected profile
  cc add-api NAME    Register a Claude Code API profile
                     Options: --base-url URL --env-key NAME --env KEY=VALUE (repeatable)
                     Prompts for missing base-url and the secret in a terminal.
  cc add-sub NAME    Register a Claude Code subscription label
  cc remove NAME     Remove a Claude Code profile registration
  cc probe-model NAME [MODEL]  Set/clear health-probe model override
  cc default [NAME]  Show/set the default (primary) profile
  cc edit            Open the profile registry (profiles.json) in EDITOR
  cc health          Probe & report profile health table (🟢🟡🔴, parallel); --fresh/--refresh re-probes
  cc health-clear    Clear the health probe cache
  cc next            Cycle to the next enabled profile
  cc help            Show this help

Config:
  Registry: ~/.ai-env/profiles.json
  State:    ~/.ai-env/state.json
  Secrets:  ~/.ai-secrets/secrets.toml

After switching, run Claude Code separately:
  claude

Notes:
  cc does not launch Claude Code. Claude reads the environment variables set in this shell.
  A Claude API profile can define base_url; otherwise https://claude.example.com is used.
  --env adds non-secret per-profile vars (e.g. ANTHROPIC_DEFAULT_SONNET_MODEL,
    CLAUDE_CODE_AUTO_COMPACT_WINDOW) stored in the registry; exported on switch and
    cleared when switching to another profile so values do not leak.
  Add commands only write profile metadata. Put real tokens in secrets.toml.
  Without probe_model, Claude probes use ANTHROPIC_MODEL, ANTHROPIC_DEFAULT_HAIKU_MODEL, then a cheap fallback.
  Legacy ~/.ai-secrets/*.ps1 files are still accepted as a fallback.
"@ | Write-Host
}

function cx {
  $remaining = @($args)

  if ($remaining.Count -gt 0) {
    switch (($remaining[0] ?? "").ToString().ToLowerInvariant()) {
      { $_ -in @("help", "-h", "--help", "/?") } { Show-CxHelp; return }
      "list" { Show-CodexList; return }
      "status" { Show-CodexStatus -Fresh:(Test-AiFreshFlag ($remaining | Select-Object -Skip 1)); return }
      "doctor" { Show-CodexDoctor; return }
      "edit" { Edit-AiRegistry; return }
      "health" { Show-AiHealth -Tool "codex" -Fresh:(Test-AiFreshFlag ($remaining | Select-Object -Skip 1)); return }
      "stats" { Show-CodexStats -Arguments @($remaining | Select-Object -Skip 1); return }
      "add-api" { Add-CodexApiProfile -Arguments @($remaining | Select-Object -Skip 1); return }
      "add-sub" { Add-CodexSubProfile -Arguments @($remaining | Select-Object -Skip 1); return }
      "remove" { Remove-CodexProfile -Arguments @($remaining | Select-Object -Skip 1); return }
      "probe-model" { Set-AiProfileProbeModel -Tool "codex" -Arguments @($remaining | Select-Object -Skip 1); return }
      "default" { Set-AiDefaultProfile -Tool "codex" -Arguments @($remaining | Select-Object -Skip 1); return }
      "app-default" { Set-CodexAppDefaultProfile -Arguments @($remaining | Select-Object -Skip 1); return }
      "app-bridge" { Invoke-CodexAppBridgeCommand -Arguments @($remaining | Select-Object -Skip 1); return }
      "sessions" { Show-CodexAllProviderSessions -Arguments @($remaining | Select-Object -Skip 1); return }
      "resume" { Resume-CodexAllProviderSession -Arguments @($remaining | Select-Object -Skip 1); return }
      "health-clear" { Clear-AiHealthCache; Write-Host "health cache cleared"; return }
      "next" { $remaining = @((Get-AiNextProfileName -Tool "codex")) }
    }
  }

  if ($remaining.Count -gt 0) {
    $profile = Get-AiProfileByName -Tool "codex" -Name ([string]$remaining[0])
    if (-not $profile) {
      throw "Unknown cx profile '$($remaining[0])'. Add it to $script:AiRegistryPath or run 'cx help'."
    }
    $remaining = @($remaining | Select-Object -Skip 1)
  } else {
    $autoName = Get-AiHealthyProfileName -Tool "codex"
    $profile = Get-AiProfileByName -Tool "codex" -Name $autoName
    if ($profile) {
      $ah = Get-AiProfileHealthCached -Tool "codex" -Profile $profile
      Write-Host ("auto-select: $autoName " + (Format-AiHealthCell $ah)) -ForegroundColor DarkGray
    }
  }

  if ($remaining.Count -gt 0) {
    throw "cx only switches state and does not forward arguments. Run 'codex $($remaining -join ' ')' separately after switching."
  }

  Save-AiSelectedProfile -Tool "codex" -Name (Get-AiProfileName -Profile $profile)
  $secretSource = Set-CodexProfileEnvironment -Profile $profile
  Write-CodexSwitchStatus -Profile $profile -SecretSource $secretSource
}

function cc {
  $remaining = @($args)

  if ($remaining.Count -gt 0) {
    switch (($remaining[0] ?? "").ToString().ToLowerInvariant()) {
      { $_ -in @("help", "-h", "--help", "/?") } { Show-CcHelp; return }
      "list" { Show-ClaudeList; return }
      "status" { Show-ClaudeStatus -Fresh:(Test-AiFreshFlag ($remaining | Select-Object -Skip 1)); return }
      "edit" { Edit-AiRegistry; return }
      "health" { Show-AiHealth -Tool "claude" -Fresh:(Test-AiFreshFlag ($remaining | Select-Object -Skip 1)); return }
      "add-api" { Add-ClaudeApiProfile -Arguments @($remaining | Select-Object -Skip 1); return }
      "add-sub" { Add-ClaudeSubProfile -Arguments @($remaining | Select-Object -Skip 1); return }
      "remove" { Remove-ClaudeProfile -Arguments @($remaining | Select-Object -Skip 1); return }
      "probe-model" { Set-AiProfileProbeModel -Tool "claude" -Arguments @($remaining | Select-Object -Skip 1); return }
      "default" { Set-AiDefaultProfile -Tool "claude" -Arguments @($remaining | Select-Object -Skip 1); return }
      "health-clear" { Clear-AiHealthCache; Write-Host "health cache cleared"; return }
      "next" { $remaining = @((Get-AiNextProfileName -Tool "claude")) }
    }
  }

  if ($remaining.Count -gt 0) {
    $profile = Get-AiProfileByName -Tool "claude" -Name ([string]$remaining[0])
    if (-not $profile) {
      throw "Unknown cc profile '$($remaining[0])'. Add it to $script:AiRegistryPath or run 'cc help'."
    }
    $remaining = @($remaining | Select-Object -Skip 1)
  } else {
    $autoName = Get-AiHealthyProfileName -Tool "claude"
    $profile = Get-AiProfileByName -Tool "claude" -Name $autoName
    if ($profile) {
      $ah = Get-AiProfileHealthCached -Tool "claude" -Profile $profile
      Write-Host ("auto-select: $autoName " + (Format-AiHealthCell $ah)) -ForegroundColor DarkGray
    }
  }

  if ($remaining.Count -gt 0) {
    throw "cc only switches state and does not forward arguments. Run 'claude $($remaining -join ' ')' separately after switching."
  }

  Save-AiSelectedProfile -Tool "claude" -Name (Get-AiProfileName -Profile $profile)
  $secretSource = Set-ClaudeProfileEnvironment -Profile $profile
  Write-ClaudeSwitchStatus -Profile $profile -SecretSource $secretSource
}

function Test-CodexArgsHaveExplicitProfile {
  param([string[]]$Arguments)

  foreach ($arg in $Arguments) {
    if ($arg -eq "--profile" -or $arg -eq "-p" -or $arg -like "--profile=*") {
      return $true
    }
  }

  return $false
}

function Get-CodexFirstToken {
  param([string[]]$Arguments)

  $optionsWithValue = @(
    "-c", "--config", "-i", "--image", "-m", "--model", "-p", "--profile",
    "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval",
    "--remote", "--remote-auth-token-env", "--local-provider"
  )

  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $arg = $Arguments[$i]
    if ($arg -eq "--") {
      return $null
    }
    if ($optionsWithValue -contains $arg) {
      $i++
      continue
    }
    if ($arg.StartsWith("-")) {
      continue
    }
    return $arg
  }

  return $null
}

function Test-CodexShouldInjectProfile {
  param([string[]]$Arguments)

  if (Test-CodexArgsHaveExplicitProfile -Arguments $Arguments) {
    return $false
  }

  $first = Get-CodexFirstToken -Arguments $Arguments
  if (-not $first) {
    return $true
  }

  $knownNoProfile = @(
    "login", "logout", "doctor", "app", "completion", "update", "features", "help",
    "cloud", "app-server", "remote-control", "mcp-server", "exec-server", "mcp",
    "plugin", "sandbox", "debug", "apply", "archive", "unarchive"
  )
  if ($knownNoProfile -contains $first) {
    return $false
  }

  return $true
}

function codex {
  $arguments = @($args)
  $codexCommand = Get-CodexExternalCommand
  $saved = Get-AiSavedProfileName -Tool "codex"
  $profile = Get-AiProfileByName -Tool "codex" -Name ($env:AI_CODEX_LABEL ?? $saved)
  if (-not $profile) {
    $profile = Get-AiProfileByName -Tool "codex" -Name (Get-AiDefaultProfileName -Tool "codex")
  }

  Set-CodexProfileEnvironment -Profile $profile | Out-Null

  $profilePath = Get-CodexProfilePath -Profile $profile
  if ((Test-Path -LiteralPath $profilePath) -and (Test-CodexShouldInjectProfile -Arguments $arguments)) {
    $arguments = @("--profile", (Get-CodexRuntimeProfileName -Profile $profile)) + $arguments
  }

  & $codexCommand @arguments
}

function Initialize-AiEnvProfiles {
  $codexSaved = Get-AiSavedProfileName -Tool "codex"
  $codexProfile = Get-AiProfileByName -Tool "codex" -Name $codexSaved
  if ($codexProfile) {
    try {
      Set-CodexProfileEnvironment -Profile $codexProfile | Out-Null
    } catch {
      Write-Warning "Could not initialize saved Codex profile '$codexSaved'. $($_.Exception.Message)"
    }
  }

  $claudeSaved = Get-AiSavedProfileName -Tool "claude"
  $claudeProfile = Get-AiProfileByName -Tool "claude" -Name $claudeSaved
  if ($claudeProfile) {
    try {
      Set-ClaudeProfileEnvironment -Profile $claudeProfile | Out-Null
    } catch {
      Write-Warning "Could not initialize saved Claude Code profile '$claudeSaved'. $($_.Exception.Message)"
    }
  }
}
