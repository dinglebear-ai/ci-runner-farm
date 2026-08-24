$ErrorActionPreference = 'Stop'

function Write-Response([hashtable] $Payload) {
    @{ schema_version = 1; payload = $Payload } | ConvertTo-Json -Compress -Depth 8
}

function Reject([string] $Code) {
    Write-Response @{ result = 'rejected'; detail_code = $Code }
    exit 0
}

function Valid-Identifier([string] $Value) {
    return $null -ne $Value -and $Value -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
}

function Invoke-Runtime([string[]] $Arguments, [switch] $Capture) {
    $namespaceArgument = "--namespace=$script:Namespace"
    if ($Capture) { $output = & $script:Runtime $namespaceArgument @Arguments 2>$null | Out-String } else { & $script:Runtime $namespaceArgument @Arguments 2>$null | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw 'container_runtime_failed' }
    if ($Capture) { return $output.Trim() }
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 131072) { Reject 'request_too_large' }
    $envelope = $raw | ConvertFrom-Json
    if ($envelope.schema_version -ne 1) { Reject 'invalid_request' }
    $request = $envelope.payload
    if (-not (Valid-Identifier $request.placement_id)) { Reject 'invalid_request' }

    $script:Runtime = if ($env:CRF_NERDCTL_PATH) { $env:CRF_NERDCTL_PATH } else { 'C:\Program Files\nerdctl\nerdctl.exe' }
    $script:Namespace = if ($env:CRF_CONTAINERD_NAMESPACE) { $env:CRF_CONTAINERD_NAMESPACE } else { 'buildkit' }
    if (-not (Valid-Identifier $script:Namespace)) { Reject 'invalid_runtime_namespace' }
    if (-not (Test-Path -LiteralPath $script:Runtime -PathType Leaf)) { Reject 'missing_runtime_dependency' }
    $stateRoot = if ($env:CRF_CONTAINER_STATE_DIR) { $env:CRF_CONTAINER_STATE_DIR } else { 'C:\ProgramData\CiRunnerFarm\container-adapter' }
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$request.placement_id)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $name = "crf-dist-$($key.Substring(0,20))"
    $statePath = Join-Path $stateRoot "$key.json"

    switch ([string]$request.action) {
        'start' {
            foreach ($value in @($request.command_id, $request.pool_id, $request.runner_name)) { if (-not (Valid-Identifier $value)) { Reject 'invalid_request' } }
            if ([uint64]$request.resources.cpu_millis -eq 0 -or [uint64]$request.resources.memory_bytes -eq 0) { Reject 'invalid_request' }
            if ($env:CRF_RUNNER_IMAGE -notmatch '@(sha256:[0-9a-f]{64})$') { Reject 'immutable_image_required' }
            # nerdctl treats a name@digest reference as a registry lookup even when the
            # content is already present in containerd. Use the validated digest as the
            # local content-store reference so an offline node never falls back to pull.
            $imageRuntimeReference = $Matches[1]
            $probe = Invoke-Runtime @('info', '--format', '{{.OSType}}') -Capture
            if ($probe -notmatch 'windows') { Reject 'hyperv_isolation_unavailable' }
            $jit = Join-Path $stateRoot ".$key.jit.env.tmp"
            try {
                [IO.File]::WriteAllText($jit, "ACTIONS_RUNNER_INPUT_JITCONFIG=$([string]$request.jit_config)", [Text.UTF8Encoding]::new($false))
                $id = Invoke-Runtime @(
                    'create', "--name=$name", '--isolation=hyperv', '--entrypoint=C:\actions-runner\run.cmd',
                    "--label=io.dinglebear.ci-runner-farm.placement-id=$($request.placement_id)",
                    "--label=io.dinglebear.ci-runner-farm.command-id=$($request.command_id)",
                    "--env-file=$jit", $imageRuntimeReference
                ) -Capture
            } finally { Remove-Item -LiteralPath $jit -Force -ErrorAction SilentlyContinue }
            if ($id -notmatch '^[0-9a-f]{64}$') { Reject 'invalid_container_id' }
            try {
                Invoke-Runtime @('start', $id)
            } catch {
                try { Invoke-Runtime @('rm', '-f', $id) } catch { }
                throw
            }
            @{ schema_version = 1; placement_id = $request.placement_id; container_id = $id; container_name = $name } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $statePath -Encoding UTF8
            Write-Response @{ result = 'started'; id = $id }
        }
        'inspect' {
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Write-Response @{ result = 'absent' }; exit 0 }
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($request.expected_id -and $request.expected_id -cne $state.container_id) { Reject 'ownership_mismatch' }
            $observed = Invoke-Runtime @('inspect', '--format', '{{.State.Running}}|{{.State.ExitCode}}|{{index .Config.Labels "io.dinglebear.ci-runner-farm.placement-id"}}', $state.container_id) -Capture
            $parts = $observed -split '\|', 3
            if ($parts.Count -ne 3 -or $parts[2] -cne [string]$request.placement_id) { Reject 'ownership_mismatch' }
            if ($parts[0] -ceq 'true') { Write-Response @{ result = 'running'; id = $state.container_id }; exit 0 }
            Invoke-Runtime @('rm', '-f', [string]$state.container_id)
            Remove-Item -LiteralPath $statePath -Force
            if ($parts[1] -ceq '0') {
                Write-Response @{ result = 'terminal'; outcome = 'succeeded' }
            } else {
                Write-Response @{ result = 'terminal'; outcome = @{ failed = @{ detail_code = 'container_exit_nonzero' } } }
            }
        }
        'cancel' {
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Write-Response @{ result = 'absent' }; exit 0 }
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($request.expected_id -and $request.expected_id -cne $state.container_id) { Reject 'ownership_mismatch' }
            $observed = Invoke-Runtime @('inspect', '--format', '{{.State.Running}}|{{.State.ExitCode}}|{{index .Config.Labels "io.dinglebear.ci-runner-farm.placement-id"}}', $state.container_id) -Capture
            $parts = $observed -split '\|', 3
            if ($parts.Count -ne 3 -or $parts[2] -cne [string]$request.placement_id) { Reject 'ownership_mismatch' }
            Invoke-Runtime @('rm', '-f', [string]$state.container_id)
            Remove-Item -LiteralPath $statePath -Force
            Write-Response @{ result = 'cancelled' }
        }
        default { Reject 'unsupported_action' }
    }
} catch {
    Reject 'adapter_failed'
}
