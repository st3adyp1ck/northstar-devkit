@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "DevKit.ps1"
pause
