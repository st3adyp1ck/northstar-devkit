@echo off
rem Northstar DevKit - main entry point.
rem The widget IS the app: this launches it windowlessly through the same
rem startup launcher the "Start with Windows" entry uses (no console window,
rem detached process). If the widget is already running, its single-instance
rem summon event simply brings the existing window to the front.
start "" wscript.exe "%~dp0gui\Start-Widget-Startup.vbs" 0
exit /b 0
