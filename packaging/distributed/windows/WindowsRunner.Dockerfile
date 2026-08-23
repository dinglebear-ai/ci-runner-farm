# escape=`
FROM mcr.microsoft.com/windows/servercore:ltsc2025@sha256:eeaa17aefe5d949f03b1db17182f5855cf40e757533468cf5b50e07c7c385ada

SHELL ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
ARG RUNNER_URL=https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-win-x64-2.336.0.zip
ARG RUNNER_SHA256=d59123a43003e357b0805b5d0f611d0bd2f65ab67d51bd070dd4e7a0f685c162
RUN $ProgressPreference='SilentlyContinue'; `
    Invoke-WebRequest -UseBasicParsing -Uri $env:RUNNER_URL -OutFile C:\runner.zip; `
    if ((Get-FileHash -Algorithm SHA256 C:\runner.zip).Hash.ToLowerInvariant() -ne $env:RUNNER_SHA256) { throw 'runner digest mismatch' }; `
    New-Item -ItemType Directory C:\actions-runner | Out-Null; `
    Expand-Archive C:\runner.zip C:\actions-runner; `
    Remove-Item C:\runner.zip

COPY WindowsRunnerEntrypoint.ps1 C:\crf\WindowsRunnerEntrypoint.ps1
ENTRYPOINT ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\crf\\WindowsRunnerEntrypoint.ps1"]
