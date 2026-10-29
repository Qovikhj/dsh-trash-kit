@echo off
rem Double-click health check for the DSH delete-guard / trash setup.
rem Runs doctor.ps1 (read-only) and keeps the window open so you can read it.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
echo.
echo --- doctor finished. Press any key to close. ---
pause >nul
