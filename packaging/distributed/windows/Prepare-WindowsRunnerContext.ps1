[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ContextDirectory,
    [string] $RunnerUrl = 'https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-win-x64-2.336.0.zip',
    [string] $RunnerSha256 = 'd59123a43003e357b0805b5d0f611d0bd2f65ab67d51bd070dd4e7a0f685c162',
    [string] $PowerShellUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/PowerShell-7.6.5-win-x64.zip',
    [string] $PowerShellSha256 = '32eb8f6cdce08f86e987d625a2733e54ac3e289ae7e1621b14c0b5bcec2434ea'
)

$ErrorActionPreference = 'Stop'
if ($RunnerSha256 -notmatch '^[0-9a-f]{64}$') { throw 'invalid runner digest' }
if ($PowerShellSha256 -notmatch '^[0-9a-f]{64}$') { throw 'invalid PowerShell digest' }
$context = [IO.Path]::GetFullPath($ContextDirectory)
New-Item -ItemType Directory -Force -Path $context | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) "crf-runner-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $archive = Join-Path $work 'runner.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $RunnerUrl -OutFile $archive
    $observed = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($observed -cne $RunnerSha256) { throw "runner digest mismatch: $observed" }
    $expanded = Join-Path $work 'actions-runner'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    if (-not (Test-Path -LiteralPath (Join-Path $expanded 'run.cmd') -PathType Leaf)) { throw 'runner archive missing run.cmd' }
    $destination = Join-Path $context 'actions-runner'
    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $expanded -Destination $destination

    $powerShellArchive = Join-Path $work 'powershell.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $PowerShellUrl -OutFile $powerShellArchive
    $observedPowerShell = (Get-FileHash -Algorithm SHA256 -LiteralPath $powerShellArchive).Hash.ToLowerInvariant()
    if ($observedPowerShell -cne $PowerShellSha256) { throw "PowerShell digest mismatch: $observedPowerShell" }
    $powerShellExpanded = Join-Path $work 'powershell'
    Expand-Archive -LiteralPath $powerShellArchive -DestinationPath $powerShellExpanded
    if (-not (Test-Path -LiteralPath (Join-Path $powerShellExpanded 'pwsh.exe') -PathType Leaf)) { throw 'PowerShell archive missing pwsh.exe' }
    $powerShellDestination = Join-Path $context 'powershell'
    Remove-Item -LiteralPath $powerShellDestination -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $powerShellExpanded -Destination $powerShellDestination
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
