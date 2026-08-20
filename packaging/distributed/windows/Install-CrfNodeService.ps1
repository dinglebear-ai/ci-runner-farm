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
$environment = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $EnvironmentFile))) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
    if ($trimmed -notmatch '^(CRF_[A-Z0-9_]+)=([^\r\n]*)$') {
        throw "Invalid node environment entry: $trimmed"
    }
    if (-not $seen.Add($Matches[1])) {
        throw "Duplicate node environment key: $($Matches[1])"
    }
    $environment.Add("$($Matches[1])=$($Matches[2])")
}
if ($environment.Count -eq 0) { throw 'Node environment file is empty' }

$binaryPath = Join-Path $InstallRoot 'crf-node.exe'
$privateEnvironment = Join-Path $ConfigRoot 'node.env'
if ($PSCmdlet.ShouldProcess($serviceName, 'Install Windows node service without starting it')) {
    New-Item -ItemType Directory -Force -Path $InstallRoot, $ConfigRoot | Out-Null
    Copy-Item -LiteralPath $NodeBinary -Destination $binaryPath -Force
    Copy-Item -LiteralPath $EnvironmentFile -Destination $privateEnvironment -Force
    & icacls.exe $ConfigRoot /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'LOCAL SERVICE:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to secure the node configuration directory' }

    $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        & sc.exe create $serviceName 'binPath=' "\`"$binaryPath\`" --windows-service" 'start=' 'demand' 'obj=' 'NT AUTHORITY\LocalService' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the Windows node service' }
    } else {
        & sc.exe config $serviceName 'binPath=' "\`"$binaryPath\`" --windows-service" 'start=' 'demand' 'obj=' 'NT AUTHORITY\LocalService' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to update the Windows node service' }
    }
    & sc.exe description $serviceName 'Distributed CI Runner Farm portable node' | Out-Null
    & sc.exe failure $serviceName 'reset=86400' 'actions=restart/5000/restart/15000/restart/60000' | Out-Null

    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    New-ItemProperty -Path $serviceKey -Name Environment -PropertyType MultiString -Value $environment.ToArray() -Force | Out-Null
}

Write-Host "Installed $serviceName with Manual startup. To change configuration, edit $privateEnvironment and rerun this installer before starting it explicitly."
