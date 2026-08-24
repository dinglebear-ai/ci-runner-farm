$ErrorActionPreference = 'Stop'

$adapter = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging/distributed/windows/WindowsContainerAdapter.ps1'
$launcher = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging/distributed/windows/crf-container-adapter.cmd'
$entrypoint = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging/distributed/windows/WindowsRunnerEntrypoint.ps1'
$dockerfile = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging/distributed/windows/WindowsRunner.Dockerfile'
$prepare = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging/distributed/windows/Prepare-WindowsRunnerContext.ps1'
if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) {
    throw 'Windows container adapter is missing'
}
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Windows container adapter launcher is missing' }
if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) { throw 'Windows runner entrypoint is missing' }
if (-not (Test-Path -LiteralPath $prepare -PathType Leaf)) { throw 'Windows runner context preparer is missing' }
$dockerfileText = Get-Content -LiteralPath $dockerfile -Raw
if ($dockerfileText -match '(?m)^RUN ') { throw 'Windows image build still requires process-isolated build execution' }
if ($dockerfileText -notmatch '(?m)^COPY actions-runner C:\\actions-runner') { throw 'Prepared runner payload is not copied into the image' }
if ($dockerfileText -notmatch '(?m)^COPY powershell C:\\PowerShell\\7') { throw 'PowerShell 7 is not copied into the image' }
if ($dockerfileText -notmatch '(?m)^ENV PATH=.*C:\\PowerShell\\7') { throw 'PowerShell 7 is not on the image PATH' }

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($adapter, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -ne 0) { throw ($errors | Out-String) }

$root = Join-Path $env:TEMP "crf-windows-adapter-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $log = Join-Path $root 'nerdctl.log'
    $fake = Join-Path $root 'nerdctl.cmd'
@"
@echo off
echo %*>>"$log"
echo %*|findstr /c:" info " >nul && (echo windows& exit /b 0)
echo %*|findstr /c:" create " >nul && (echo 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef& exit /b 0)
echo %*|findstr /c:" cp " >nul && exit /b 0
echo %*|findstr /c:" start " >nul && exit /b 0
echo %*|findstr /c:" inspect " >nul && (echo true^|0^|placement-1& exit /b 0)
echo %*|findstr /c:" rm " >nul && exit /b 0
if "%1"=="info" (echo windows& exit /b 0)
if "%1"=="create" (echo 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef& exit /b 0)
if "%1"=="cp" exit /b 0
if "%1"=="start" exit /b 0
if "%1"=="inspect" (echo true^|0^|placement-1& exit /b 0)
if "%1"=="rm" exit /b 0
exit /b 1
"@ | Set-Content -LiteralPath $fake -Encoding Ascii

    $env:CRF_NERDCTL_PATH = $fake
    Remove-Item Env:CRF_DOCKER_PATH -ErrorAction SilentlyContinue
    $env:CRF_CONTAINER_STATE_DIR = Join-Path $root 'state'
    $env:CRF_RUNNER_IMAGE = 'example.invalid/windows-runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $request = '{"schema_version":1,"payload":{"action":"start","placement_id":"placement-1","command_id":"command-1","pool_id":"windows","runner_name":"runner-1","resources":{"cpu_millis":2500,"memory_bytes":4294967296},"jit_config":"secret-jit"}}'
    $response = $request | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $adapter | ConvertFrom-Json
    if ($response.schema_version -ne 1 -or $response.payload.result -ne 'started') { throw "Unexpected adapter response: $($response | ConvertTo-Json -Compress)" }
    $args = Get-Content -LiteralPath $log -Raw
    if ($args -notmatch 'create .*--isolation=hyperv') { throw "Container was not Hyper-V isolated: $args" }
    if ($args -notmatch '--entrypoint=C:\\actions-runner\\run.cmd') { throw "Runner entrypoint was not selected explicitly: $args" }
    if ($args -notmatch '--namespace=buildkit') { throw "Containerd namespace was not explicit: $args" }
    if ($args -match '--cpus=' -or $args -match '--memory=') { throw "Unsupported Windows HCS resource flags were passed: $args" }
    if ($args -notmatch 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') { throw "Validated local image digest was not used: $args" }
    if ($args -match 'example.invalid/windows-runner@') { throw "Runtime was allowed to resolve the immutable image through a registry: $args" }
    if ($args -match 'secret-jit') { throw 'JIT secret leaked into container runtime argv' }
    if ($args -notmatch '--env-file=') { throw 'JIT was not delivered through a runtime environment file' }
    if ($args -match ' cp ') { throw 'Adapter used unsupported nerdctl cp on Windows' }
    if ((Get-Content -LiteralPath $adapter -Raw) -match 'Docker') { throw 'Adapter still depends on Docker Desktop' }
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
