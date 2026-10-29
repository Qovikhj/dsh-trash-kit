@echo off
rem The only deletion channel: moves files into the "pending-delete" folder, never deletes.
rem Usage: trash.cmd -Path ".\a.log" -Purpose "old log" -Reason "no longer needed"
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0trash.ps1" %*
exit /b %ERRORLEVEL%