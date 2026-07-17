param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$projectPath = Join-Path $SourceDir "src/bridge/CodexProviderBridge/CodexProviderBridge.csproj"
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-provider-bridge-test-" + [guid]::NewGuid().ToString("N"))
$publishDir = Join-Path $tmpRoot "publish"
$stubbornProcess = @()

function Start-TestProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [string[]]$Arguments = @(),
    [string[]]$InputLines = @(),
    [hashtable]$Environment = @{}
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new($Executable)
  foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  [void]$startInfo.Environment.Remove("CODEX_PROVIDER_BRIDGE_ACTIVE")
  foreach ($entry in $Environment.GetEnumerator()) {
    $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
  }
  $process = [Diagnostics.Process]::Start($startInfo)
  foreach ($line in $InputLines) { $process.StandardInput.WriteLine($line) }
  $process.StandardInput.Close()
  if (-not $process.WaitForExit(15000)) {
    $process.Kill($true)
    throw "Process timed out: $Executable"
  }
  $result = [pscustomobject]@{
    ExitCode = $process.ExitCode
    Stdout = $process.StandardOutput.ReadToEnd()
    Stderr = $process.StandardError.ReadToEnd()
  }
  $process.Dispose()
  return $result
}

try {
  New-Item -ItemType Directory -Force -Path $tmpRoot, $publishDir | Out-Null
  & dotnet publish $projectPath -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o $publishDir --nologo
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

  $bridgePath = Join-Path $publishDir "codex-provider-bridge.exe"
  if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) { throw "Bridge executable was not published" }

  $fakeServerPath = Join-Path $tmpRoot "fake-app-server.ps1"
  @'
$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Error.WriteLine("ARGS=" + ($args | ConvertTo-Json -Compress))
while ($null -ne ($line = [Console]::In.ReadLine())) {
  [Console]::Out.WriteLine($line)
  [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServerPath -Encoding UTF8

  $settingsPath = Join-Path $publishDir "codex-provider-bridge.json"
  [ordered]@{
    realCodexPath = (Get-Process -Id $PID).Path
    realCodexSha256 = (Get-FileHash -LiteralPath (Get-Process -Id $PID).Path -Algorithm SHA256).Hash
    realCodexPrefixArgs = @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $fakeServerPath)
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

  $listNull = '{"id":"list-null","method":"thread/list","params":{"modelProviders":null,"archived":false}}'
  $listFiltered = '{"id":"list-filtered","method":"thread/list","params":{"modelProviders":["openai"],"archived":true}}'
  $resume = '{"id":"resume","method":"thread/resume","params":{"threadId":"abc","modelProvider":"ai-env-app"}}'
  $invalid = 'not-json'
  $nonStringMethod = '{"id":"weird","method":7,"params":{}}'
  $unicodeResume = '{"id":"unicode","method":"thread/resume","params":{"threadId":"跨-provider-✓"}}'
  $result = Start-TestProcess -Executable $bridgePath -Arguments @("alpha", "with space") -InputLines @($listNull, $listFiltered, $resume, $invalid, $nonStringMethod, $unicodeResume)
  if ($result.ExitCode -ne 0) { throw "Bridge failed: $($result.Stderr)" }

  $lines = @($result.Stdout -split '\r?\n' | Where-Object { $_ -ne "" })
  if ($lines.Count -ne 6) { throw "Expected six stdout lines, got $($lines.Count): $($result.Stdout)" }
  foreach ($index in 0, 1) {
    $message = $lines[$index] | ConvertFrom-Json -Depth 20
    if ($message.method -ne "thread/list") { throw "List request method changed" }
    if ($null -eq $message.params.modelProviders -or @($message.params.modelProviders).Count -ne 0) {
      throw "thread/list modelProviders was not replaced with an empty array"
    }
  }
  if ($lines[2] -cne $resume) { throw "thread/resume was modified by the bridge" }
  if ($lines[3] -cne $invalid) { throw "Malformed non-JSON input was not forwarded unchanged" }
  if ($lines[4] -cne $nonStringMethod) { throw "JSON with a non-string method was not forwarded unchanged" }
  if ($lines[5] -cne $unicodeResume) { throw "UTF-8 input was not forwarded unchanged" }
  if ($result.Stderr -notmatch 'ARGS=\["alpha","with space"\]') { throw "Child arguments or stderr were not forwarded" }

  $activeRecursiveResult = Start-TestProcess -Executable $bridgePath -Environment @{ CODEX_PROVIDER_BRIDGE_ACTIVE = "1" }
  if ($activeRecursiveResult.ExitCode -ne 2) { throw "Recursive bridge launch exited $($activeRecursiveResult.ExitCode), expected 2" }
  if ($activeRecursiveResult.Stdout) { throw "Recursive bridge launch wrote to stdout" }
  if ($activeRecursiveResult.Stderr -notmatch 'recursive') { throw "Recursive bridge error is not actionable" }

  $stubbornServerPath = Join-Path $tmpRoot "stubborn-app-server.ps1"
  $stubbornPidPath = Join-Path $tmpRoot "stubborn-app-server.pid"
  @'
param([string]$PidPath)
$startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$startInfo.ArgumentList.Add("-NoLogo")
$startInfo.ArgumentList.Add("-NoProfile")
$startInfo.ArgumentList.Add("-NonInteractive")
$startInfo.ArgumentList.Add("-Command")
$startInfo.ArgumentList.Add("while (`$true) { Start-Sleep -Milliseconds 200 }")
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$grandchild = [Diagnostics.Process]::Start($startInfo)
"$PID,$($grandchild.Id)" | Set-Content -LiteralPath $PidPath -Encoding ascii
while ($true) { Start-Sleep -Milliseconds 200 }
'@ | Set-Content -LiteralPath $stubbornServerPath -Encoding UTF8
  [ordered]@{
    realCodexPath = (Get-Process -Id $PID).Path
    realCodexSha256 = (Get-FileHash -LiteralPath (Get-Process -Id $PID).Path -Algorithm SHA256).Hash
    realCodexPrefixArgs = @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $stubbornServerPath, $stubbornPidPath)
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

  $stubbornStartInfo = [Diagnostics.ProcessStartInfo]::new($bridgePath)
  $stubbornStartInfo.UseShellExecute = $false
  $stubbornStartInfo.RedirectStandardInput = $true
  $stubbornStartInfo.RedirectStandardOutput = $true
  $stubbornStartInfo.RedirectStandardError = $true
  [void]$stubbornStartInfo.Environment.Remove("CODEX_PROVIDER_BRIDGE_ACTIVE")
  $stubbornBridge = [Diagnostics.Process]::Start($stubbornStartInfo)
  try {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $stubbornPidPath) -and [DateTime]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $stubbornPidPath)) { throw "Stubborn downstream did not start" }
    $stubbornPids = @((Get-Content -LiteralPath $stubbornPidPath -Raw).Trim() -split ',' | ForEach-Object { [int]$_ })
    if ($stubbornPids.Count -ne 2) { throw "Stubborn downstream did not report child and grandchild PIDs" }
    $stubbornProcess = @(Get-Process -Id $stubbornPids -ErrorAction Stop)
    if ($stubbornProcess.Count -ne 2) { throw "Stubborn downstream process tree was incomplete" }
    foreach ($item in $stubbornProcess) { [void]$item.Handle }
    $stubbornBridge.Kill()
    if (-not $stubbornBridge.WaitForExit(5000)) { throw "Bridge did not terminate" }
    $exitDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
      $survivingProcesses = @($stubbornProcess | Where-Object { -not $_.HasExited })
      if ($survivingProcesses.Count -gt 0) { Start-Sleep -Milliseconds 100 }
    } while ($survivingProcesses.Count -gt 0 -and [DateTime]::UtcNow -lt $exitDeadline)
    if ($survivingProcesses.Count -gt 0) { throw "Downstream process tree survived bridge termination" }
  } finally {
    if (-not $stubbornBridge.HasExited) { $stubbornBridge.Kill($true) }
    $stubbornBridge.Dispose()
  }

  $missingDir = Join-Path $tmpRoot "missing-settings"
  New-Item -ItemType Directory -Force -Path $missingDir | Out-Null
  $missingBridge = Join-Path $missingDir "codex-provider-bridge.exe"
  Copy-Item -LiteralPath $bridgePath -Destination $missingBridge
  $missingResult = Start-TestProcess -Executable $missingBridge
  if ($missingResult.ExitCode -eq 0 -or $missingResult.Stdout) { throw "Bridge accepted missing settings" }
  if ($missingResult.Stderr -notmatch 'settings') { throw "Missing-settings error is not actionable" }

  [ordered]@{
    realCodexPath = (Get-Process -Id $PID).Path
    realCodexSha256 = ('0' * 64)
    realCodexPrefixArgs = @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $fakeServerPath)
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
  $hashMismatchResult = Start-TestProcess -Executable $bridgePath
  if ($hashMismatchResult.ExitCode -eq 0 -or $hashMismatchResult.Stdout) { throw "Bridge accepted a downstream hash mismatch" }
  if ($hashMismatchResult.Stderr -notmatch 'hash') { throw "Hash-mismatch error is not actionable" }

  [ordered]@{
    realCodexPath = $bridgePath
    realCodexSha256 = (Get-FileHash -LiteralPath $bridgePath -Algorithm SHA256).Hash
    realCodexPrefixArgs = @()
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
  $recursiveResult = Start-TestProcess -Executable $bridgePath
  if ($recursiveResult.ExitCode -eq 0 -or $recursiveResult.Stdout) { throw "Bridge accepted a recursive downstream path" }
  if ($recursiveResult.Stderr -notmatch 'itself|recursive') { throw "Recursion error is not actionable" }

  Write-Host "Codex provider bridge tests passed"
} finally {
  foreach ($process in @($stubbornProcess)) {
    if ($null -ne $process -and -not $process.HasExited) {
      $process.Kill($true)
      $process.WaitForExit()
    }
    if ($null -ne $process) { $process.Dispose() }
  }
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
