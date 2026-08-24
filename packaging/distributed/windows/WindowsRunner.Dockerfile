# escape=`
FROM mcr.microsoft.com/windows/servercore:ltsc2025@sha256:eeaa17aefe5d949f03b1db17182f5855cf40e757533468cf5b50e07c7c385ada

COPY actions-runner C:\actions-runner
COPY powershell C:\PowerShell\7
COPY WindowsRunnerEntrypoint.ps1 C:\crf\WindowsRunnerEntrypoint.ps1
ENV PATH="C:\PowerShell\7;C:\Windows\system32;C:\Windows"
ENTRYPOINT ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\crf\\WindowsRunnerEntrypoint.ps1"]
