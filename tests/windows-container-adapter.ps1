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
if ($dockerfileText -notmatch '(?m)^ENTRYPOINT .*WindowsRunnerEntrypoint.ps1') { throw 'Windows runner safety entrypoint is not configured' }

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
if "%CRF_FAKE_MODE%"=="invalid-id" echo %*|findstr /c:" create " >nul && (echo invalid-id& exit /b 0)
if "%CRF_FAKE_MODE%"=="start-fail" echo %*|findstr /c:" start " >nul && exit /b 1
if "%CRF_FAKE_MODE%"=="create-recover" echo %*|findstr /c:" create " >nul && exit /b 1
if "%CRF_FAKE_MODE%"=="create-recover" echo %*|findstr /c:" inspect " >nul && (echo 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef^|true^|%CRF_FAKE_PLACEMENT%^|%CRF_FAKE_COMMAND%& exit /b 0)
if "%CRF_FAKE_MODE%"=="inspect-absent" echo %*|findstr /c:" inspect " >nul && exit /b 1
if "%CRF_FAKE_MODE%"=="inspect-absent" echo %*|findstr /c:" ps " >nul && exit /b 0
if "%CRF_FAKE_MODE%"=="inspect-outage" echo %*|findstr /c:" inspect " >nul && exit /b 1
if "%CRF_FAKE_MODE%"=="inspect-outage" echo %*|findstr /c:" ps " >nul && (echo crf-dist-present& exit /b 0)
if "%CRF_FAKE_MODE%"=="terminal-success" echo %*|findstr /c:" inspect " >nul && (echo false^|0^|%CRF_FAKE_PLACEMENT%& exit /b 0)
if "%CRF_FAKE_MODE%"=="terminal-failure" echo %*|findstr /c:" inspect " >nul && (echo false^|7^|%CRF_FAKE_PLACEMENT%& exit /b 0)
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
    if ($args -match '--entrypoint=') { throw "Adapter bypassed the image safety entrypoint: $args" }
    if ($args -notmatch '--namespace=buildkit') { throw "Containerd namespace was not explicit: $args" }
    if ($args -notmatch 'create .*--cpus=2\.5 --memory=4294967296') { throw "Exact Windows container resource limits were not applied: $args" }
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

    # Keep the adapter grammar identical to crf-protocol::valid_identifier.
    $env:CRF_FAKE_MODE = ''
    $colonRequest = '{"schema_version":1,"payload":{"action":"start","placement_id":"placement:2","command_id":"command:2","pool_id":"windows:x64","runner_name":"runner:2","resources":{"cpu_millis":1,"memory_bytes":1},"jit_config":"secret-jit"}}'
    $colonResponse = $colonRequest | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $adapter | ConvertFrom-Json
    if ($colonResponse.payload.result -ne 'started') { throw 'Protocol-valid colon identifiers were rejected' }
    $colonArgs = Get-Content -LiteralPath $log -Raw
    if ($colonArgs -notmatch 'create .*--cpus=0\.001 --memory=1') { throw 'Minimum positive resource limits were not preserved exactly' }

    function Get-StatePath([string] $PlacementId) {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $key = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($PlacementId)))).Replace('-', '').ToLowerInvariant() } finally { $hash.Dispose() }
        return Join-Path $env:CRF_CONTAINER_STATE_DIR "$key.json"
    }
    function Invoke-Adapter([string] $Json) {
        return $Json | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $adapter | ConvertFrom-Json
    }

    $env:CRF_FAKE_MODE = 'invalid-id'
    $invalidId = Invoke-Adapter '{"schema_version":1,"payload":{"action":"start","placement_id":"invalid-id-case","command_id":"command-3","pool_id":"windows","runner_name":"runner-3","resources":{"cpu_millis":1000,"memory_bytes":1024},"jit_config":"secret-jit"}}'
    if ($invalidId.payload.detail_code -ne 'invalid_container_id') { throw 'Invalid runtime container ID was not rejected' }
    if (Test-Path -LiteralPath (Get-StatePath 'invalid-id-case')) { throw 'Invalid container ID left durable adapter state' }
    if ((Get-Content -LiteralPath $log -Raw) -notmatch 'rm -f crf-dist-') { throw 'Invalid container ID did not trigger deterministic-name cleanup' }

    $env:CRF_FAKE_MODE = 'start-fail'
    $startFailed = Invoke-Adapter '{"schema_version":1,"payload":{"action":"start","placement_id":"start-fail-case","command_id":"command-4","pool_id":"windows","runner_name":"runner-4","resources":{"cpu_millis":1000,"memory_bytes":1024},"jit_config":"secret-jit"}}'
    if ($startFailed.payload.detail_code -ne 'adapter_failed') { throw 'Runtime start failure was not contained' }
    if (Test-Path -LiteralPath (Get-StatePath 'start-fail-case')) { throw 'Runtime start failure left durable adapter state' }

    # Simulate a process loss after create succeeded but before adapter state
    # was published. The replayed create collides, then exact labels prove the
    # deterministic container belongs to this placement and command.
    Clear-Content -LiteralPath $log
    $env:CRF_FAKE_MODE = 'create-recover'
    $env:CRF_FAKE_PLACEMENT = 'create-recover-case'
    $env:CRF_FAKE_COMMAND = 'command-7'
    $recovered = Invoke-Adapter '{"schema_version":1,"payload":{"action":"start","placement_id":"create-recover-case","command_id":"command-7","pool_id":"windows","runner_name":"runner-7","resources":{"cpu_millis":1000,"memory_bytes":1024},"jit_config":"secret-jit"}}'
    if ($recovered.payload.result -ne 'started') { throw 'Create-before-state crash was not recovered' }
    if ($recovered.payload.id -ne '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef') { throw 'Recovered container identity was not preserved' }
    $recoveryArgs = Get-Content -LiteralPath $log -Raw
    if ($recoveryArgs -notmatch 'inspect .*crf-dist-') { throw 'Create collision did not inspect the deterministic container name' }
    if ($recoveryArgs -match 'start 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef') { throw 'Already-running recovered container was started twice' }

    $env:CRF_FAKE_MODE = ''
    $stateWritePath = Get-StatePath 'state-write-fail-case'
    New-Item -ItemType Directory -Path $stateWritePath | Out-Null
    $stateWriteFailed = Invoke-Adapter '{"schema_version":1,"payload":{"action":"start","placement_id":"state-write-fail-case","command_id":"command-6","pool_id":"windows","runner_name":"runner-6","resources":{"cpu_millis":1000,"memory_bytes":1024},"jit_config":"secret-jit"}}'
    if ($stateWriteFailed.payload.detail_code -ne 'container_state_cleanup_failed') { throw 'Partial state cleanup failure was not reported distinctly' }
    if ((Get-Content -LiteralPath $log -Raw) -notmatch 'rm -f 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef') { throw 'State persistence failure did not clean up the exact created container' }
    Remove-Item -LiteralPath $stateWritePath -Recurse -Force

    $lifecyclePlacement = 'lifecycle-case'
    $lifecycleStart = '{"schema_version":1,"payload":{"action":"start","placement_id":"lifecycle-case","command_id":"command-5","pool_id":"windows","runner_name":"runner-5","resources":{"cpu_millis":1000,"memory_bytes":1024},"jit_config":"secret-jit"}}'
    $lifecycleInspect = '{"schema_version":1,"payload":{"action":"inspect","placement_id":"lifecycle-case"}}'
    foreach ($case in @(
        @{ Mode = 'terminal-success'; Result = 'terminal'; Failure = $false },
        @{ Mode = 'terminal-failure'; Result = 'terminal'; Failure = $true },
        @{ Mode = 'inspect-absent'; Result = 'absent'; Failure = $false },
        @{ Mode = 'inspect-outage'; Result = 'rejected'; Failure = $false }
    )) {
        $env:CRF_FAKE_MODE = ''
        if ((Invoke-Adapter $lifecycleStart).payload.result -ne 'started') { throw "Failed to prepare lifecycle case $($case.Mode)" }
        $env:CRF_FAKE_MODE = $case.Mode
        $env:CRF_FAKE_PLACEMENT = $lifecyclePlacement
        $observed = Invoke-Adapter $lifecycleInspect
        if ($observed.payload.result -ne $case.Result) { throw "Unexpected $($case.Mode) result: $($observed | ConvertTo-Json -Compress)" }
        if ($case.Failure -and $observed.payload.outcome.failed.detail_code -ne 'container_exit_nonzero') { throw 'Nonzero terminal outcome lost its detail code' }
        if ($case.Mode -eq 'inspect-outage' -and $observed.payload.detail_code -ne 'adapter_failed') { throw 'Runtime outage was mistaken for absence' }
    }

    $env:CRF_FAKE_MODE = ''
    if ((Invoke-Adapter $lifecycleStart).payload.result -ne 'started') { throw 'Failed to prepare ownership case' }
    $wrongOwner = Invoke-Adapter '{"schema_version":1,"payload":{"action":"inspect","placement_id":"lifecycle-case","expected_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
    if ($wrongOwner.payload.detail_code -ne 'ownership_mismatch') { throw 'Mismatched runtime ownership was not rejected' }

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
    Remove-Item Env:CRF_FAKE_MODE, Env:CRF_FAKE_PLACEMENT, Env:CRF_FAKE_COMMAND -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: Windows Hyper-V container adapter contract'
