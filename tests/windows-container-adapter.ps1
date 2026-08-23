$ErrorActionPreference = 'Stop'

$adapter = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging/distributed/windows/WindowsContainerAdapter.ps1'
$launcher = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging/distributed/windows/crf-container-adapter.cmd'
$entrypoint = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging/distributed/windows/WindowsRunnerEntrypoint.ps1'
if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) {
    throw 'Windows container adapter is missing'
}
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Windows container adapter launcher is missing' }
if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) { throw 'Windows runner entrypoint is missing' }

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($adapter, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -ne 0) { throw ($errors | Out-String) }

$root = Join-Path $env:TEMP "crf-windows-adapter-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $log = Join-Path $root 'docker.log'
    $fake = Join-Path $root 'docker.cmd'
    @"
@echo off
echo %*>>"$log"
if "%1"=="info" (echo windows hyperv& exit /b 0)
if "%1"=="create" (echo 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef& exit /b 0)
if "%1"=="cp" exit /b 0
if "%1"=="start" exit /b 0
if "%1"=="inspect" (echo true^|placement-1& exit /b 0)
if "%1"=="rm" exit /b 0
exit /b 1
"@ | Set-Content -LiteralPath $fake -Encoding Ascii

    $env:CRF_DOCKER_PATH = $fake
    $env:CRF_CONTAINER_STATE_DIR = Join-Path $root 'state'
    $env:CRF_RUNNER_IMAGE = 'example.invalid/windows-runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $request = '{"schema_version":1,"payload":{"action":"start","placement_id":"placement-1","command_id":"command-1","pool_id":"windows","runner_name":"runner-1","resources":{"cpu_millis":2500,"memory_bytes":4294967296},"jit_config":"secret-jit"}}'
    $response = $request | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $adapter | ConvertFrom-Json
    if ($response.schema_version -ne 1 -or $response.payload.result -ne 'started') { throw "Unexpected adapter response: $($response | ConvertTo-Json -Compress)" }
    $args = Get-Content -LiteralPath $log -Raw
    if ($args -notmatch 'create .*--isolation=hyperv') { throw "Container was not Hyper-V isolated: $args" }
    if ($args -notmatch '--cpus=2.5' -or $args -notmatch '--memory=4294967296') { throw "Resource limits were not enforced: $args" }
    if ($args -match 'secret-jit') { throw 'JIT secret leaked into Docker argv' }
    $id = $response.payload.id
    $inspect = '{"schema_version":1,"payload":{"action":"inspect","placement_id":"placement-1","expected_id":"' + $id + '"}}' |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $adapter | ConvertFrom-Json
    if ($inspect.payload.result -ne 'running' -or $inspect.payload.id -ne $id) { throw 'Owned running container was not reconciled' }
    $cancel = '{"schema_version":1,"payload":{"action":"cancel","placement_id":"placement-1","expected_id":"' + $id + '"}}' |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $adapter | ConvertFrom-Json
    if ($cancel.payload.result -ne 'cancelled') { throw 'Owned container was not cancelled' }
    $args = Get-Content -LiteralPath $log -Raw
    if ($args -notmatch "rm -f $id") { throw 'Cancellation did not target the exact owned container ID' }

    $runnerRoot = Join-Path $root 'runner'
    New-Item -ItemType Directory -Path $runnerRoot | Out-Null
    $jitFile = Join-Path $root 'jit.json'
    $captured = Join-Path $root 'captured.txt'
    Set-Content -LiteralPath $jitFile -Value 'entrypoint-secret' -NoNewline
    "@echo off`necho %ACTIONS_RUNNER_INPUT_JITCONFIG%>`"$captured`"" | Set-Content -LiteralPath (Join-Path $runnerRoot 'run.cmd') -Encoding Ascii
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entrypoint -RunnerRoot $runnerRoot -JitFile $jitFile
    if ((Get-Content -LiteralPath $captured -Raw).Trim() -ne 'entrypoint-secret') { throw 'Entrypoint did not pass JIT through the runner environment' }
    if (Test-Path -LiteralPath $jitFile) { throw 'Entrypoint left the JIT bootstrap file behind' }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: Windows Hyper-V container adapter contract'
