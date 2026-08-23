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

function Invoke-Docker([string[]] $Arguments, [switch] $Capture) {
    if ($Capture) { $output = & $script:Docker @Arguments 2>$null | Out-String } else { & $script:Docker @Arguments 2>$null | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw 'docker_failed' }
    if ($Capture) { return $output.Trim() }
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 131072) { Reject 'request_too_large' }
    $envelope = $raw | ConvertFrom-Json
    if ($envelope.schema_version -ne 1) { Reject 'invalid_request' }
    $request = $envelope.payload
    if (-not (Valid-Identifier $request.placement_id)) { Reject 'invalid_request' }

    $script:Docker = if ($env:CRF_DOCKER_PATH) { $env:CRF_DOCKER_PATH } else { 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' }
    if (-not (Test-Path -LiteralPath $script:Docker -PathType Leaf)) { Reject 'missing_runtime_dependency' }
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
            if ($env:CRF_RUNNER_IMAGE -notmatch '@sha256:[0-9a-f]{64}$') { Reject 'immutable_image_required' }
            $probe = Invoke-Docker @('info', '--format', '{{.OSType}} {{json .SecurityOptions}}') -Capture
            if ($probe -notmatch 'windows' -or $probe -notmatch 'hyperv') { Reject 'hyperv_isolation_unavailable' }
            $cpu = ([decimal]$request.resources.cpu_millis / 1000).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
            $id = Invoke-Docker @(
                'create', "--name=$name", '--isolation=hyperv', "--cpus=$cpu", "--memory=$([uint64]$request.resources.memory_bytes)",
                "--label=io.dinglebear.ci-runner-farm.placement-id=$($request.placement_id)",
                "--label=io.dinglebear.ci-runner-farm.command-id=$($request.command_id)",
                '--env=CRF_JIT_FILE=C:\crf-bootstrap\jit.json', $env:CRF_RUNNER_IMAGE
            ) -Capture
            if ($id -notmatch '^[0-9a-f]{64}$') { Reject 'invalid_container_id' }
            $jit = Join-Path $stateRoot ".$key.jit.tmp"
            try {
                [IO.File]::WriteAllText($jit, [string]$request.jit_config, [Text.UTF8Encoding]::new($false))
                Invoke-Docker @('cp', $jit, "$id`:/crf-bootstrap/jit.json")
            } finally { Remove-Item -LiteralPath $jit -Force -ErrorAction SilentlyContinue }
            Invoke-Docker @('start', $id)
            @{ schema_version = 1; placement_id = $request.placement_id; container_id = $id; container_name = $name } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $statePath -Encoding UTF8
            Write-Response @{ result = 'started'; id = $id }
        }
        'inspect' {
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Write-Response @{ result = 'absent' }; exit 0 }
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($request.expected_id -and $request.expected_id -cne $state.container_id) { Reject 'ownership_mismatch' }
            $observed = Invoke-Docker @('inspect', '--format', '{{.State.Running}}|{{index .Config.Labels "io.dinglebear.ci-runner-farm.placement-id"}}', $state.container_id) -Capture
            if ($observed -cne "true|$($request.placement_id)") { Reject 'ownership_mismatch' }
            Write-Response @{ result = 'running'; id = $state.container_id }
        }
        'cancel' {
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Write-Response @{ result = 'absent' }; exit 0 }
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($request.expected_id -and $request.expected_id -cne $state.container_id) { Reject 'ownership_mismatch' }
            $observed = Invoke-Docker @('inspect', '--format', '{{.State.Running}}|{{index .Config.Labels "io.dinglebear.ci-runner-farm.placement-id"}}', $state.container_id) -Capture
            if ($observed -notmatch "^[^|]+\|$([regex]::Escape([string]$request.placement_id))$") { Reject 'ownership_mismatch' }
            Invoke-Docker @('rm', '-f', [string]$state.container_id)
            Remove-Item -LiteralPath $statePath -Force
            Write-Response @{ result = 'cancelled' }
        }
        default { Reject 'unsupported_action' }
    }
} catch {
    Reject 'adapter_failed'
}
