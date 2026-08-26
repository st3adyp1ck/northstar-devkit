/**
 * Copy-to-clipboard for the Error Center's detail view.
 *
 * NOT @tauri-apps/plugin-clipboard-manager: that plugin is neither a
 * dependency in app/package.json nor granted in
 * src-tauri/capabilities/default.json, and adding either is another agent's
 * file this round. The browser API is enough - WebView2 exposes
 * navigator.clipboard for the app's own custom-protocol origin - with the
 * legacy execCommand path behind it for the case where it doesn't (a
 * non-secure origin, a permission denial), and a silent false if neither
 * works so a copy button can never throw into the dialog.
 */
export async function copyText(text: string): Promise<boolean> {
  try {
    if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // fall through to the legacy path
  }
  return copyViaTextarea(text);
}

function copyViaTextarea(text: string): boolean {
  try {
    const textarea = document.createElement("textarea");
    textarea.value = text;
    // Off-screen rather than display:none - a hidden element can't be selected.
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.top = "-1000px";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);
    textarea.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(textarea);
    return ok;
  } catch {
    return false;
  }
}
