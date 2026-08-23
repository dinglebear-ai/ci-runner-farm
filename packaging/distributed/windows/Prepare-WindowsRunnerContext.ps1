[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ContextDirectory,
    [string] $RunnerUrl = 'https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-win-x64-2.336.0.zip',
    [string] $RunnerSha256 = 'd59123a43003e357b0805b5d0f611d0bd2f65ab67d51bd070dd4e7a0f685c162'
)

$ErrorActionPreference = 'Stop'
if ($RunnerSha256 -notmatch '^[0-9a-f]{64}$') { throw 'invalid runner digest' }
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
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

