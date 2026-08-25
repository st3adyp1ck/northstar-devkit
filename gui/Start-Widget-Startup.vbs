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
'    is a startup delay in seconds.
'  - Windows PowerShell 5.1 lives at a path that never changes, unlike
'    Store-packaged pwsh whose version-stamped folder moves on every
'    auto-update. The widget is 5.1-compatible by design and hops off
'    Store pwsh anyway (taskbar identity fix), so launching 5.1 directly
'    is both stable and one process cheaper.
'
' Launch/retry handshake (the 60s Timer approach it replaced was structurally
' defeated: sh.Run(cmd, 0, True) blocks until the process EXITS, and a process
' stuck behind the loader-error MessageBox never exits until dismissed - so by
' the time Run returned, the retry window was always considered expired):
'  1. Delete the pid file (%LOCALAPPDATA%\NorthstarDevKit\widget.pid) and
'     snapshot the currently-running widget PIDs via WMI.
'  2. Launch NON-blocking (sh.Run cmd, 0, False) - a hard-error dialog must
'     never block this launcher.
'  3. Poll up to 30s for the pid file, which the widget writes itself once
'     its window is fully up -> success.
'  4. On timeout, terminate only widget processes that are NOT in the
'     pre-launch snapshot (clears the instance stuck behind the loader-error
'     dialog so the retry is clean), back off 30s, retry. Max 3 attempts.
' Run manually (no argument) it starts the widget immediately.
Option Explicit

Dim delaySec: delaySec = 0
If WScript.Arguments.Count > 0 Then delaySec = CLng(WScript.Arguments(0))

Dim sh: Set sh = CreateObject("WScript.Shell")
Dim fso: Set fso = CreateObject("Scripting.FileSystemObject")
Dim here: here = fso.GetParentFolderName(WScript.ScriptFullName)
Dim psh: psh = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
Dim cmd: cmd = """" & psh & """ -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File """ & here & "\DevKit-Widget.ps1"""
Dim pidFile: pidFile = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\NorthstarDevKit\widget.pid"

' Returns a Dictionary of ProcessId -> True for every powershell/pwsh whose
' command line mentions DevKit-Widget.ps1. WMI failure (service down, access
' denied) degrades to an empty snapshot - never fatal to the launcher.
Function SnapshotWidgetPids()
    Dim pids: Set pids = CreateObject("Scripting.Dictionary")
    On Error Resume Next
    Dim wmi: Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number = 0 Then
        Dim procs: Set procs = wmi.ExecQuery( _
            "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe' OR Name='pwsh.exe'")
        If Err.Number = 0 Then
            Dim p
            For Each p In procs
                If Not IsNull(p.CommandLine) Then
                    If InStr(1, p.CommandLine, "DevKit-Widget.ps1", vbTextCompare) > 0 Then
                        pids(CStr(p.ProcessId)) = True
                    End If
                End If
            Next
        End If
    End If
    On Error GoTo 0
    Set SnapshotWidgetPids = pids
End Function

' Terminates widget processes that are NOT in the given pre-launch snapshot -
' i.e. only the instances this launch attempt (or a stuck previous attempt)
' started, so a healthy already-running widget is never touched.
Sub KillNewWidgetPids(before)
    Dim now: Set now = SnapshotWidgetPids()
    Dim pid
    On Error Resume Next
    Dim wmi: Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number = 0 Then
        For Each pid In now.Keys
            If Not before.Exists(pid) Then
                Dim p: Set p = wmi.Get("Win32_Process.Handle='" & pid & "'")
                If Err.Number = 0 Then p.Terminate
                Err.Clear
            End If
        Next
    End If
    On Error GoTo 0
End Sub

If delaySec > 0 Then WScript.Sleep delaySec * 1000

Dim attempt, waited, beforePids
For attempt = 1 To 3
    ' Stale pid file from a previous session must not read as success.
    If fso.FileExists(pidFile) Then fso.DeleteFile pidFile, True
    Set beforePids = SnapshotWidgetPids()
    sh.Run cmd, 0, False                 ' 0 = hidden window, False = do NOT wait
    waited = 0
    Do While waited < 30
        WScript.Sleep 2000
        waited = waited + 2
        If fso.FileExists(pidFile) Then WScript.Quit 0   ' widget wrote its pid - window is up
    Loop
    ' No handshake: the launch died or is stuck behind a loader-error dialog.
    ' Clean up only what this attempt started, back off, and try again.
    KillNewWidgetPids beforePids
    If attempt < 3 Then WScript.Sleep 30000
Next
