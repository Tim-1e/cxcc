$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot "install.ps1"
$requiredFiles = @(
  $installer,
  (Join-Path $repoRoot "load.ps1"),
  (Join-Path $repoRoot "load.sh")
)
foreach ($requiredFile in $requiredFiles) {
  if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
    throw "Required installer file is missing: $requiredFile"
  }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("cxcc-installer-" + [guid]::NewGuid().ToString("N"))
$testHome = Join-Path $tempRoot "home"
$installRoot = Join-Path $testHome ".local\share\cxcc"
$unrelatedCwd = Join-Path $tempRoot "unrelated cwd"
$savedAiEnvHome = $env:AI_ENV_HOME

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function New-TestArchive {
  param([Parameter(Mandatory = $true)][string]$Version)

  $payload = Join-Path $tempRoot ("payload-" + $Version)
  $archive = Join-Path $tempRoot ("cxcc-" + $Version + ".zip")
  New-Item -ItemType Directory -Force -Path $payload | Out-Null
  Copy-Item -LiteralPath (Join-Path $repoRoot "src") -Destination (Join-Path $payload "src") -Recurse
  Copy-Item -LiteralPath (Join-Path $repoRoot "templates") -Destination (Join-Path $payload "templates") -Recurse
  Copy-Item -LiteralPath (Join-Path $repoRoot "load.ps1") -Destination $payload
  Copy-Item -LiteralPath (Join-Path $repoRoot "load.sh") -Destination $payload
  $bridgeDirectory = Join-Path $payload "bin\win-x64"
  New-Item -ItemType Directory -Force -Path $bridgeDirectory | Out-Null
  [IO.File]::WriteAllText((Join-Path $bridgeDirectory "codex-provider-bridge.exe"), "prebuilt-$Version", [Text.UTF8Encoding]::new($false))
  [IO.File]::AppendAllText((Join-Path $payload "src\powershell\CxCc\Entrypoints.ps1"), "`n`$global:CXCC_TEST_PAYLOAD_VERSION = `"$Version`"`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $payload "VERSION"), $Version, [Text.UTF8Encoding]::new($false))
  Compress-Archive -Path (Join-Path $payload "*") -DestinationPath $archive
  return [pscustomobject]@{
    Path = $archive
    Sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Read-Current {
  $currentPath = Join-Path $installRoot "current.json"
  return (Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json)
}

function Assert-Current {
  param([string]$Version, [AllowNull()][string]$Previous)

  $current = Read-Current
  Assert-True ($current.schema -eq 1) "current.json schema is not 1."
  Assert-True ($current.version -ceq $Version) "Expected current version $Version, got $($current.version)."
  if ($null -eq $Previous) {
    Assert-True ($null -eq $current.previous) "Expected no previous version, got $($current.previous)."
  } else {
    Assert-True ($current.previous -ceq $Previous) "Expected previous version $Previous, got $($current.previous)."
  }
}

function Assert-LoaderWorks {
  param([Parameter(Mandatory = $true)][string]$ExpectedVersion)
  Push-Location -LiteralPath $unrelatedCwd
  try {
    . (Join-Path $installRoot "load.ps1")
    foreach ($commandName in @("cx", "cc", "mcp")) {
      $command = Get-Command $commandName -CommandType Function -ErrorAction SilentlyContinue
      Assert-True ($null -ne $command) "Installed loader did not define $commandName."
    }
    $bridgeBinary = Get-CodexAppBridgeBinaryPath
    Assert-True ($bridgeBinary -and (Test-Path -LiteralPath $bridgeBinary -PathType Leaf)) "Installed loader did not resolve the prebuilt Bridge."
    Assert-True ($global:CXCC_TEST_PAYLOAD_VERSION -ceq $ExpectedVersion) "Installed loader ran $global:CXCC_TEST_PAYLOAD_VERSION, expected $ExpectedVersion."
    & cx help *> $null
  } finally {
    Pop-Location
  }
}

function Assert-StatePreserved {
  foreach ($path in $script:sentinelPaths) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "User state file was removed: $path"
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Assert-True ($actual -ceq $script:sentinelHashes[$path]) "User state file changed: $path"
  }
}

New-Item -ItemType Directory -Force -Path $testHome, $unrelatedCwd | Out-Null
$sentinelPaths = @(
  (Join-Path $testHome ".ai-env\profiles.json"),
  (Join-Path $testHome ".ai-secrets\secrets.toml"),
  (Join-Path $testHome ".codex\config.toml"),
  (Join-Path $testHome ".claude\settings.json")
)
foreach ($path in $sentinelPaths) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
}
Copy-Item -LiteralPath (Join-Path $repoRoot "templates\profiles.json") -Destination $sentinelPaths[0]
[IO.File]::WriteAllText($sentinelPaths[1], "# sentinel secret store`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($sentinelPaths[2], "model = `"sentinel`"`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($sentinelPaths[3], "{`"sentinel`":true}`n", [Text.UTF8Encoding]::new($false))
$sentinelHashes = @{}
foreach ($path in $sentinelPaths) {
  $sentinelHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

try {
  $env:AI_ENV_HOME = $testHome
  $v1 = New-TestArchive -Version "v0.1.0"
  $v2 = New-TestArchive -Version "v0.2.0"

  $recoveryRoot = Join-Path $tempRoot "recovery\cxcc"
  $invalidPayloadFailed = $false
  try {
    & $installer -Version "v9.9.9" -ArtifactPath $v1.Path -Sha256 $v1.Sha256 -InstallRoot $recoveryRoot
  } catch {
    $invalidPayloadFailed = $true
  }
  Assert-True $invalidPayloadFailed "An artifact with a mismatched VERSION was accepted."
  & $installer -Version "v0.1.0" -ArtifactPath $v1.Path -Sha256 $v1.Sha256 -InstallRoot $recoveryRoot
  $recoveredCurrent = Get-Content -LiteralPath (Join-Path $recoveryRoot "current.json") -Raw | ConvertFrom-Json
  Assert-True ($recoveredCurrent.version -ceq "v0.1.0") "A failed first install prevented a valid retry."
  & $installer -Uninstall -InstallRoot $recoveryRoot

  & $installer -Version "v0.1.0" -ArtifactPath $v1.Path -Sha256 $v1.Sha256 -InstallRoot $installRoot
  Assert-True (Test-Path -LiteralPath (Join-Path $installRoot "versions\v0.1.0") -PathType Container) "Clean install did not create v0.1.0."
  Assert-True (Test-Path -LiteralPath (Join-Path $installRoot "load.ps1") -PathType Leaf) "Clean install did not create load.ps1."
  Assert-True (Test-Path -LiteralPath (Join-Path $installRoot "load.sh") -PathType Leaf) "Clean install did not create load.sh."
  Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot ".cxcc-root") -Raw).Trim() -ceq "cxcc-install-root-v1") "Clean install did not create the cxcc root marker."
  Assert-Current -Version "v0.1.0" -Previous $null
  Assert-StatePreserved
  Assert-LoaderWorks -ExpectedVersion "v0.1.0"
  $rootLoaderHashes = @{}
  foreach ($loaderName in @("load.ps1", "load.sh")) {
    $loaderPath = Join-Path $installRoot $loaderName
    $rootLoaderHashes[$loaderName] = (Get-FileHash -LiteralPath $loaderPath -Algorithm SHA256).Hash
  }

  $pointerBeforeRepeat = (Get-FileHash -LiteralPath (Join-Path $installRoot "current.json") -Algorithm SHA256).Hash
  & $installer -Version "v0.1.0" -ArtifactPath $v1.Path -Sha256 $v1.Sha256 -InstallRoot $installRoot
  $versionsAfterRepeat = @(Get-ChildItem -LiteralPath (Join-Path $installRoot "versions") -Directory)
  Assert-True ($versionsAfterRepeat.Count -eq 1) "Repeat install created an extra version directory."
  Assert-True (((Get-FileHash -LiteralPath (Join-Path $installRoot "current.json") -Algorithm SHA256).Hash) -ceq $pointerBeforeRepeat) "Repeat install changed current.json."
  Assert-StatePreserved

  $pointerBeforeFailure = [IO.File]::ReadAllBytes((Join-Path $installRoot "current.json"))
  $checksumFailed = $false
  try {
    & $installer -Version "v0.2.0" -ArtifactPath $v2.Path -Sha256 ("0" * 64) -InstallRoot $installRoot
  } catch {
    $checksumFailed = $true
  }
  Assert-True $checksumFailed "A mismatched SHA-256 was accepted."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "versions\v0.2.0"))) "Failed checksum left a final v0.2.0 directory."
  Assert-True ([Linq.Enumerable]::SequenceEqual($pointerBeforeFailure, [IO.File]::ReadAllBytes((Join-Path $installRoot "current.json")))) "Failed checksum changed current.json."
  Assert-LoaderWorks -ExpectedVersion "v0.1.0"
  Assert-StatePreserved

  $unsafeVersionFailed = $false
  try {
    & $installer -Version "../escape" -ArtifactPath $v2.Path -Sha256 $v2.Sha256 -InstallRoot $installRoot
  } catch {
    $unsafeVersionFailed = $true
  }
  Assert-True $unsafeVersionFailed "An unsafe version was accepted."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "escape"))) "Unsafe version escaped the versions directory."

  & $installer -Version "v0.2.0" -ArtifactPath $v2.Path -Sha256 $v2.Sha256 -InstallRoot $installRoot
  Assert-Current -Version "v0.2.0" -Previous "v0.1.0"
  Assert-True (Test-Path -LiteralPath (Join-Path $installRoot "versions\v0.1.0") -PathType Container) "Upgrade removed v0.1.0."
  Assert-True (Test-Path -LiteralPath (Join-Path $installRoot "versions\v0.2.0") -PathType Container) "Upgrade did not install v0.2.0."
  Assert-LoaderWorks -ExpectedVersion "v0.2.0"
  foreach ($loaderName in $rootLoaderHashes.Keys) {
    Assert-True (((Get-FileHash -LiteralPath (Join-Path $installRoot $loaderName) -Algorithm SHA256).Hash) -ceq $rootLoaderHashes[$loaderName]) "Upgrade replaced stable root loader $loaderName."
  }
  Assert-StatePreserved

  & $installer -Rollback -InstallRoot $installRoot
  Assert-Current -Version "v0.1.0" -Previous "v0.2.0"
  Assert-LoaderWorks -ExpectedVersion "v0.1.0"
  Assert-StatePreserved

  $unrecognizedRoot = Join-Path $tempRoot "unrecognized\cxcc"
  New-Item -ItemType Directory -Force -Path $unrecognizedRoot | Out-Null
  $unrecognizedSentinel = Join-Path $unrecognizedRoot "keep.txt"
  [IO.File]::WriteAllText($unrecognizedSentinel, "keep", [Text.UTF8Encoding]::new($false))
  $unsafeUninstallFailed = $false
  try {
    & $installer -Uninstall -InstallRoot $unrecognizedRoot
  } catch {
    $unsafeUninstallFailed = $true
  }
  Assert-True $unsafeUninstallFailed "Uninstall accepted an unrecognized cxcc root."
  Assert-True (Test-Path -LiteralPath $unrecognizedSentinel -PathType Leaf) "Rejected uninstall removed unrelated data."

  & $installer -Uninstall -InstallRoot $installRoot
  Assert-True (-not (Test-Path -LiteralPath $installRoot)) "Uninstall did not remove the cxcc install root."
  Assert-StatePreserved

  Write-Host "cxcc PowerShell installer lifecycle tests passed."
} finally {
  if ($null -eq $savedAiEnvHome) {
    Remove-Item -LiteralPath Env:\AI_ENV_HOME -ErrorAction SilentlyContinue
  } else {
    $env:AI_ENV_HOME = $savedAiEnvHome
  }
  Remove-Variable -Name CXCC_TEST_PAYLOAD_VERSION -Scope Global -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
