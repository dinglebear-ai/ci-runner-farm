[CmdletBinding()]
param(
    [string] $RunnerRoot = 'C:\actions-runner',
    [string] $JitFile = $(if ($env:CRF_JIT_FILE) { $env:CRF_JIT_FILE } else { 'C:\crf-bootstrap\jit.json' })
)

$ErrorActionPreference = 'Stop'
$run = Join-Path $RunnerRoot 'run.cmd'
if (-not (Test-Path -LiteralPath $run -PathType Leaf)) { throw 'runner_entrypoint_missing' }
if ($env:ACTIONS_RUNNER_INPUT_JITCONFIG) {
    $jit = $env:ACTIONS_RUNNER_INPUT_JITCONFIG
} elseif (Test-Path -LiteralPath $JitFile -PathType Leaf) {
    $jit = [IO.File]::ReadAllText($JitFile)
    Remove-Item -LiteralPath $JitFile -Force
} else {
    throw 'jit_config_missing'
}
if ([string]::IsNullOrWhiteSpace($jit) -or [Text.Encoding]::UTF8.GetByteCount($jit) -gt 65536) { throw 'jit_config_invalid' }
$env:ACTIONS_RUNNER_INPUT_JITCONFIG = $jit
try {
    Push-Location $RunnerRoot
    try { & $run; $exitCode = $LASTEXITCODE } finally { Pop-Location }
} finally {
    Remove-Item Env:ACTIONS_RUNNER_INPUT_JITCONFIG -ErrorAction SilentlyContinue
    $jit = $null
}
if ($exitCode -ne 0) { throw "runner_failed_$exitCode" }
