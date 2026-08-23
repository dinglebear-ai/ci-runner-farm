[CmdletBinding()]
param([string] $OutputDirectory = 'build/distributed')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    cargo build --locked --release -p crf-node
    if ($LASTEXITCODE -ne 0) { throw 'crf-node release build failed' }
    $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
    $stage = Join-Path $root "build/windows-stage/ci-runner-farm-node-$version-windows-x86_64"
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'target/release/crf-node.exe') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/distributed/windows/crf-container-adapter.cmd') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/distributed/windows/WindowsContainerAdapter.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/distributed/windows/WindowsRunnerEntrypoint.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/distributed/windows/WindowsRunner.Dockerfile') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/distributed/windows/Prepare-WindowsRunnerContext.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/distributed/windows/Install-CrfNodeService.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/distributed/windows/node-env.example') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'docs/distributed-runner-farm/runner-manifest.example.json') -Destination $stage
    New-Item -ItemType Directory -Force -Path (Join-Path $root $OutputDirectory) | Out-Null
    $archive = Join-Path $root "$OutputDirectory/ci-runner-farm-node-$version-windows-x86_64.zip"
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $stage -DestinationPath $archive
    Write-Output $archive
} finally {
    Pop-Location
}
