@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "WiFi-Optimize.ps1"
pause
