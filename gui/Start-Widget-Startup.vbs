' Northstar DevKit - Windows-startup launcher for the companion widget.
' This is what the "Start with Windows" registry entry points at (see
' Set-DevKitStartupEnabled in DevKit-Widget.ps1), invoked as:
'
'     wscript.exe "<this file>" 45
'
' Why a .vbs under wscript and not a .bat / direct shell path:
'  - A Run-key .bat opens a visible console window at every sign-in;
'    wscript is windowless and WshShell.Run(..., 0, ...) keeps the
'    PowerShell host hidden too.
'  - powershell.exe can fail to initialize (loader error 0xC0000142,
'    "unable to start correctly") when launched while the logon storm is
'    still settling - the same command works seconds later. The argument
'    is a startup delay in seconds, and a fast nonzero exit triggers up
'    to two retries with a backoff, so a transient loader race no longer
'    costs the whole session its widget.
'  - Windows PowerShell 5.1 lives at a path that never changes, unlike
'    Store-packaged pwsh whose version-stamped folder moves on every
'    auto-update. The widget is 5.1-compatible by design and hops off
'    Store pwsh anyway (taskbar identity fix), so launching 5.1 directly
'    is both stable and one process cheaper.
' Run manually (no argument) it starts the widget immediately.
Option Explicit

Dim delaySec: delaySec = 0
If WScript.Arguments.Count > 0 Then delaySec = CLng(WScript.Arguments(0))

Dim sh: Set sh = CreateObject("WScript.Shell")
Dim fso: Set fso = CreateObject("Scripting.FileSystemObject")
Dim here: here = fso.GetParentFolderName(WScript.ScriptFullName)
Dim psh: psh = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
Dim cmd: cmd = """" & psh & """ -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File """ & here & "\DevKit-Widget.ps1"""

If delaySec > 0 Then WScript.Sleep delaySec * 1000

Dim attempt, t0, rc
For attempt = 1 To 3
    t0 = Timer
    rc = sh.Run(cmd, 0, True)          ' 0 = hidden window, True = wait for exit
    If rc = 0 Then Exit For            ' widget ran and exited cleanly
    ' Nonzero after a long run is a real widget failure, not a loader
    ' race - do not restart it behind the user's back. (Timer wraps at
    ' midnight; the rare negative delta just allows one extra retry.)
    If Timer - t0 > 60 Then Exit For
    WScript.Sleep 30000
Next
