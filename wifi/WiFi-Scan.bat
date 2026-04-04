@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "WiFi-Scan.ps1"
pause
