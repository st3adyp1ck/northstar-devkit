; DevKit NSIS installer hooks (registered via bundle.windows.nsis.installerHooks).
;
; POSTUNINSTALL only. The app's mandatory-elevation gate (src/elevation.rs)
; redirects every launch through the 'NorthstarDevKit-Admin' scheduled task
; created by tools/system/Set-DevKitAdminMode.ps1. At POSTUNINSTALL time the
; install dir - and therefore the script itself - is already gone, so the
; cleanup is inlined here instead of calling Set-DevKitAdminMode.ps1 -Off.
;
; Everything is best-effort: a leftover task points at a deleted exe (the
; gate re-runs setup on reinstall), and a leftover shortcut is inert. One
; known gap, accepted deliberately: if Start-with-Windows had been MOVED
; onto the task's logon trigger, uninstalling removes that autostart instead
; of restoring the Run-key value (the marker that remembered it is deleted
; with the app-data folder by the standard uninstaller).

!macro NSIS_HOOK_POSTUNINSTALL
  ; Remove the elevation scheduled task. 'schtasks /delete' from the user's
  ; filtered token succeeds for tasks in their own task library; if it does
  ; not, the stale task is harmless (see header).
  nsExec::ExecToStack 'schtasks /delete /tn "NorthstarDevKit-Admin" /f'
  Pop $0
  Pop $0
  DetailPrint "Removed NorthstarDevKit-Admin elevation task (if present)"

  ; The hidden WSH launcher and the state marker live in the app-data folder.
  Delete "$LOCALAPPDATA\NorthstarDevKit\DevKit-Admin.vbs"
  Delete "$LOCALAPPDATA\NorthstarDevKit\admin-mode.json"

  ; The 'DevKit (Admin)' shortcuts the setup script wrote next to the stock
  ; NSIS shortcuts ($SMPROGRAMS matches [Environment]::GetFolderPath('Programs')).
  Delete "$DESKTOP\DevKit (Admin).lnk"
  Delete "$SMPROGRAMS\DevKit (Admin).lnk"
!macroend
