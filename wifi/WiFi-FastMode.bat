@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "WiFi-FastMode.ps1"
pause
