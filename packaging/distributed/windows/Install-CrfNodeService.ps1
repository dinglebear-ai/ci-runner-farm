[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $NodeBinary,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $EnvironmentFile,

    [string] $InstallRoot = "$env:ProgramFiles\CiRunnerFarm",
    [string] $ConfigRoot = "$env:ProgramData\CiRunnerFarm"
)

$ErrorActionPreference = 'Stop'
$serviceName = 'CiRunnerFarmNode'
$allowedKeys = [System.Collections.Generic.HashSet[string]]::new(
    [string[]] @(
        'CRF_CA_CERT', 'CRF_CLIENT_CERT', 'CRF_CLIENT_KEY', 'CRF_COMMAND_LEDGER_CAPACITY',
        'CRF_CONNECT_TIMEOUT_MS', 'CRF_CONTAINER_ADAPTER_PROGRAM',
        'CRF_CONTAINER_ADAPTER_TIMEOUT_MS', 'CRF_CONTROLLER_ADDR',
        'CRF_CONTROLLER_SERVER_NAME', 'CRF_EXECUTION_BACKEND', 'CRF_HEARTBEAT_MS',
        'CRF_IO_TIMEOUT_MS', 'CRF_LOG_DIR', 'CRF_NODE_CPU_MILLIS',
        'CRF_NODE_ID', 'CRF_NODE_MEMORY_BYTES', 'CRF_RUNNER_CACHE_DIR', 'CRF_RUNNER_MANIFEST',
        'CRF_RUNNER_TEMPLATE', 'CRF_RUNTIME_DIR', 'CRF_SERVICE_ERROR_LOG', 'CRF_STATE_DIR'
    ),
    [System.StringComparer]::Ordinal
)
$requiredKeys = @(
    'CRF_CA_CERT', 'CRF_CLIENT_CERT', 'CRF_CLIENT_KEY', 'CRF_CONTROLLER_ADDR',
    'CRF_CONTROLLER_SERVER_NAME', 'CRF_NODE_CPU_MILLIS', 'CRF_NODE_MEMORY_BYTES',
    'CRF_STATE_DIR', 'CRF_SERVICE_ERROR_LOG'
)

function Invoke-Native {
    param([Parameter(Mandatory = $true)][string] $Program, [Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)
    & $Program @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$Program $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Assert-NoInjectedFailure {
    param([Parameter(Mandatory = $true)][string] $Boundary)
    if ($env:CRF_INSTALLER_TEST_FAILURE -eq $Boundary) { throw "Injected installer failure after $Boundary" }
}

function Invoke-RollbackNative {
    param([Parameter(Mandatory = $true)][string] $Program, [Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)
    & $Program @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Rollback command failed ($LASTEXITCODE): $Program $($Arguments -join ' ')" }
}

$environment = [System.Collections.Generic.List[string]]::new()
$values = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $EnvironmentFile))) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
    if ($trimmed -notmatch '^(CRF_[A-Z0-9_]+)=([^\r\n]*)$') { throw "Invalid node environment entry: $trimmed" }
    $key = $Matches[1]
    $value = $Matches[2]
    if (-not $allowedKeys.Contains($key)) { throw "Unknown node environment key: $key" }
    if ($values.ContainsKey($key)) { throw "Duplicate node environment key: $key" }
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Empty node environment value: $key" }
    $values.Add($key, $value)
    $environment.Add("$key=$value")
}
foreach ($key in $requiredKeys) {
    if (-not $values.ContainsKey($key)) { throw "Missing required node environment key: $key" }
}
$backend = if ($values.ContainsKey('CRF_EXECUTION_BACKEND')) { $values['CRF_EXECUTION_BACKEND'] } else { 'native_process' }
switch ($backend) {
    'native_process' {
        foreach ($key in @('CRF_RUNTIME_DIR', 'CRF_LOG_DIR')) {
            if (-not $values.ContainsKey($key)) { throw "Missing required node environment key: $key" }
        }
        $hasTemplate = $values.ContainsKey('CRF_RUNNER_TEMPLATE')
        $hasManifest = $values.ContainsKey('CRF_RUNNER_MANIFEST')
        $hasCache = $values.ContainsKey('CRF_RUNNER_CACHE_DIR')
        if (-not (($hasTemplate -and -not $hasManifest -and -not $hasCache) -or (-not $hasTemplate -and $hasManifest -and $hasCache))) {
            throw 'Native execution requires exactly CRF_RUNNER_TEMPLATE or the CRF_RUNNER_MANIFEST/CRF_RUNNER_CACHE_DIR pair'
        }
    }
    'container' {
        if (-not $values.ContainsKey('CRF_CONTAINER_ADAPTER_PROGRAM')) { throw 'Container execution requires CRF_CONTAINER_ADAPTER_PROGRAM' }
        foreach ($key in @('CRF_RUNTIME_DIR', 'CRF_LOG_DIR', 'CRF_RUNNER_TEMPLATE', 'CRF_RUNNER_MANIFEST', 'CRF_RUNNER_CACHE_DIR')) {
            if ($values.ContainsKey($key)) { throw "Container execution does not accept $key" }
        }
    }
    default { throw "Invalid CRF_EXECUTION_BACKEND: $backend" }
}

$nodeBinaryPath = (Resolve-Path -LiteralPath $NodeBinary).Path
Invoke-Native $nodeBinaryPath '--version'
$binaryPath = Join-Path $InstallRoot 'crf-node.exe'
$privateEnvironment = Join-Path $ConfigRoot 'node.env'
$temporaryEnvironment = Join-Path $ConfigRoot ".node.env.$([Guid]::NewGuid().ToString('N')).tmp"
$serviceExisted = $null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)
$installRootExisted = Test-Path -LiteralPath $InstallRoot
$configRootExisted = Test-Path -LiteralPath $ConfigRoot
$originalConfigAcl = if ($configRootExisted) { Get-Acl -LiteralPath $ConfigRoot } else { $null }
$rollbackId = [Guid]::NewGuid().ToString('N')
$binaryBackup = "$binaryPath.$rollbackId.rollback"
$environmentBackup = "$privateEnvironment.$rollbackId.rollback"
$serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
$serviceSnapshot = if ($serviceExisted) { Get-CimInstance Win32_Service -Filter "Name='$serviceName'" } else { $null }
$serviceRegistrySnapshot = if ($serviceExisted) { Get-ItemProperty -LiteralPath $serviceKey } else { $null }
$environmentExisted = $serviceExisted -and ($serviceRegistrySnapshot.PSObject.Properties.Name -contains 'Environment')
$failureActionsExisted = $serviceExisted -and ($serviceRegistrySnapshot.PSObject.Properties.Name -contains 'FailureActions')
$failureFlagExisted = $serviceExisted -and ($serviceRegistrySnapshot.PSObject.Properties.Name -contains 'FailureActionsOnNonCrashFailures')
$binaryMutationStarted = $false
$environmentMutationStarted = $false

if ($PSCmdlet.ShouldProcess($serviceName, 'Install Windows node service without starting it')) {
    try {
        New-Item -ItemType Directory -Force -Path $InstallRoot, $ConfigRoot | Out-Null
        if (Test-Path -LiteralPath $binaryPath) { Copy-Item -LiteralPath $binaryPath -Destination $binaryBackup }
        if (Test-Path -LiteralPath $privateEnvironment) { Copy-Item -LiteralPath $privateEnvironment -Destination $environmentBackup }
        Invoke-Native "$env:SystemRoot\System32\icacls.exe" $ConfigRoot '/inheritance:r' '/grant:r' 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'LOCAL SERVICE:(OI)(CI)F'
        Assert-NoInjectedFailure 'acl'
        $binaryMutationStarted = $true
        Copy-Item -LiteralPath $NodeBinary -Destination $binaryPath -Force
        Copy-Item -LiteralPath $EnvironmentFile -Destination $temporaryEnvironment -Force
        $environmentMutationStarted = $true
        Move-Item -LiteralPath $temporaryEnvironment -Destination $privateEnvironment -Force
        Assert-NoInjectedFailure 'files'

        $quotedBinaryPath = "`"$binaryPath`" --windows-service"
        if (-not $serviceExisted) {
            # Windows PowerShell 5.1 strips embedded quotes from native argv,
            # making a Program Files binPath invalid. Create the stopped service
            # with a no-space placeholder and set the exact ImagePath through
            # the registry before it can be started.
            Invoke-Native "$env:SystemRoot\System32\sc.exe" 'create' $serviceName 'binPath=' "$env:SystemRoot\System32\cmd.exe" 'start=' 'demand' 'obj=' 'NT AUTHORITY\LocalService'
        } else {
            Invoke-Native "$env:SystemRoot\System32\sc.exe" 'config' $serviceName 'start=' 'demand' 'obj=' 'NT AUTHORITY\LocalService'
        }
        Set-ItemProperty -LiteralPath $serviceKey -Name ImagePath -Value $quotedBinaryPath
        Invoke-Native "$env:SystemRoot\System32\sc.exe" 'description' $serviceName 'Distributed CI Runner Farm portable node'
        Assert-NoInjectedFailure 'service-config'
        # sc.exe requires a space between each option's trailing '=' and its
        # value. Keeping them as separate argv entries works across Windows
        # PowerShell and PowerShell 7; combining them exits with ERROR_INVALID_COMMAND_LINE (1639).
        Invoke-Native "$env:SystemRoot\System32\sc.exe" 'failure' $serviceName 'reset=' '86400' 'actions=' 'restart/5000/restart/15000/restart/60000'
        Assert-NoInjectedFailure 'failure-policy'

        New-ItemProperty -Path $serviceKey -Name Environment -PropertyType MultiString -Value $environment.ToArray() -Force | Out-Null
        Assert-NoInjectedFailure 'registry-environment'
        Remove-Item -LiteralPath $binaryBackup, $environmentBackup -Force -ErrorAction SilentlyContinue
    } catch {
        $installError = $_
        Remove-Item -LiteralPath $temporaryEnvironment -Force -ErrorAction SilentlyContinue
        if ($serviceExisted) {
            if ($binaryMutationStarted) {
                Remove-Item -LiteralPath $binaryPath -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $binaryBackup) { Move-Item -LiteralPath $binaryBackup -Destination $binaryPath -Force }
            } else {
                Remove-Item -LiteralPath $binaryBackup -Force -ErrorAction SilentlyContinue
            }
            if ($environmentMutationStarted) {
                Remove-Item -LiteralPath $privateEnvironment -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $environmentBackup) { Move-Item -LiteralPath $environmentBackup -Destination $privateEnvironment -Force }
            } else {
                Remove-Item -LiteralPath $environmentBackup -Force -ErrorAction SilentlyContinue
            }
            if ($null -ne $originalConfigAcl -and (Test-Path -LiteralPath $ConfigRoot)) { Set-Acl -LiteralPath $ConfigRoot -AclObject $originalConfigAcl }

            $startMode = switch ($serviceSnapshot.StartMode) { 'Auto' { 'auto' } 'Disabled' { 'disabled' } default { 'demand' } }
            Invoke-RollbackNative "$env:SystemRoot\System32\sc.exe" 'config' $serviceName 'start=' $startMode 'obj=' $serviceSnapshot.StartName
            Set-ItemProperty -LiteralPath $serviceKey -Name ImagePath -Value ([string] $serviceRegistrySnapshot.ImagePath)
            Invoke-RollbackNative "$env:SystemRoot\System32\sc.exe" 'description' $serviceName ([string] $serviceSnapshot.Description)
            if ($failureActionsExisted) {
                Set-ItemProperty -LiteralPath $serviceKey -Name FailureActions -Value ([byte[]] $serviceRegistrySnapshot.FailureActions)
            } else {
                Remove-ItemProperty -LiteralPath $serviceKey -Name FailureActions -ErrorAction SilentlyContinue
            }
            if ($failureFlagExisted) {
                Set-ItemProperty -LiteralPath $serviceKey -Name FailureActionsOnNonCrashFailures -Value $serviceRegistrySnapshot.FailureActionsOnNonCrashFailures
            } else {
                Remove-ItemProperty -LiteralPath $serviceKey -Name FailureActionsOnNonCrashFailures -ErrorAction SilentlyContinue
            }
            if ($environmentExisted) {
                New-ItemProperty -LiteralPath $serviceKey -Name Environment -PropertyType MultiString -Value ([string[]] $serviceRegistrySnapshot.Environment) -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $serviceKey -Name Environment -ErrorAction SilentlyContinue
            }
        } else {
            if ($null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
                Invoke-RollbackNative "$env:SystemRoot\System32\sc.exe" 'delete' $serviceName
            }
            Remove-Item -LiteralPath $binaryPath, $privateEnvironment -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $binaryBackup) { Move-Item -LiteralPath $binaryBackup -Destination $binaryPath -Force }
            if (Test-Path -LiteralPath $environmentBackup) { Move-Item -LiteralPath $environmentBackup -Destination $privateEnvironment -Force }
            if ($null -ne $originalConfigAcl -and (Test-Path -LiteralPath $ConfigRoot)) { Set-Acl -LiteralPath $ConfigRoot -AclObject $originalConfigAcl }
            if (-not $installRootExisted) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue }
            if (-not $configRootExisted) { Remove-Item -LiteralPath $ConfigRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
        throw $installError
    }
}

Write-Host "Installed $serviceName with Manual startup. Rerun this installer after changing configuration; start the service explicitly when ready."
