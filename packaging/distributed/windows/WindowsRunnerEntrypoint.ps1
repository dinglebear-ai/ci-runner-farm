[CmdletBinding()]
param(
    [string] $RunnerRoot = 'C:\actions-runner',
    [string] $JitFile = $(if ($env:CRF_JIT_FILE) { $env:CRF_JIT_FILE } else { 'C:\crf-bootstrap\jit.json' })
)

$ErrorActionPreference = 'Stop'
$run = Join-Path $RunnerRoot 'run.cmd'
if (-not (Test-Path -LiteralPath $run -PathType Leaf)) { throw 'runner_entrypoint_missing' }
if (-not (Test-Path -LiteralPath $JitFile -PathType Leaf)) { throw 'jit_config_missing' }

$jit = [IO.File]::ReadAllText($JitFile)
if ([string]::IsNullOrWhiteSpace($jit) -or [Text.Encoding]::UTF8.GetByteCount($jit) -gt 65536) { throw 'jit_config_invalid' }
Remove-Item -LiteralPath $JitFile -Force
$env:ACTIONS_RUNNER_INPUT_JITCONFIG = $jit
try {
    Push-Location $RunnerRoot
    try { & $run; $exitCode = $LASTEXITCODE } finally { Pop-Location }
} finally {
    Remove-Item Env:ACTIONS_RUNNER_INPUT_JITCONFIG -ErrorAction SilentlyContinue
    $jit = $null
}
if ($exitCode -ne 0) { throw "runner_failed_$exitCode" }
