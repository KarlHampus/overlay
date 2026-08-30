@echo off
setlocal
rem Thin wrapper so "overlay ..." works from cmd.exe, PowerShell or Windows Run.
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0overlay.ps1" %*
endlocal
