@echo off
setlocal

if /I "%SYMPP_NODE_BRIDGE%"=="0" goto :run_pwsh
where node.exe >nul 2>nul
if errorlevel 1 goto :run_pwsh

node.exe "%~dp0start-sympp-mcp-bridge.js" %*
set "bridge_exit=%ERRORLEVEL%"
if "%bridge_exit%"=="43" goto :run_pwsh
if not "%bridge_exit%"=="42" exit /b %bridge_exit%

call :find_powershell
%SYMPP_POWERSHELL% -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0start-sympp-mcp.ps1" -PrepareRuntimeOnly %*
if errorlevel 1 exit /b %ERRORLEVEL%
node.exe "%~dp0start-sympp-mcp-bridge.js" %*
set "bridge_exit=%ERRORLEVEL%"
if "%bridge_exit%"=="0" exit /b 0
if "%bridge_exit%"=="42" goto :run_pwsh
if "%bridge_exit%"=="43" goto :run_pwsh
>&2 echo Symphony++ Node bridge could not attach after PowerShell prepared the runtime.
%SYMPP_POWERSHELL% -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0start-sympp-mcp.ps1" -CleanupPreparedRuntime
if errorlevel 1 >&2 echo Symphony++ prepared runtime cleanup failed.
exit /b %bridge_exit%

:run_pwsh
call :find_powershell
%SYMPP_POWERSHELL% -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0start-sympp-mcp.ps1" %*
exit /b %ERRORLEVEL%

:find_powershell
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  set "SYMPP_POWERSHELL=powershell.exe"
) else (
  set "SYMPP_POWERSHELL=pwsh.exe"
)
exit /b 0
