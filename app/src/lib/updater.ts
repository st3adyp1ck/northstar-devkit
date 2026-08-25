/**
 * Thin, typed wrappers around @tauri-apps/plugin-updater and
 * @tauri-apps/plugin-process - the only place in the app that touches
 * those plugin APIs directly. Endpoint/pubkey config lives entirely in
 * src-tauri/tauri.conf.json's plugins.updater block; nothing here needs
 * to know it.
 *
 * Neither function swallows errors - both reject on failure (network,
 * signature verification, disk, relaunch) and let the caller (see
 * stores/useUpdaterStore.ts) decide how to surface that. Never call
 * these directly from a component; go through useUpdateCheck.ts /
 * useUpdaterStore.ts so there's one shared state machine for the whole
 * app instead of each caller racing its own check/install.
 */
import { check, type DownloadEvent, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";

export type { Update };

export interface UpdateDownloadProgress {
  /** Cumulative bytes downloaded so far. */
  downloaded: number;
  /** Total bytes to download, or null if the response had no Content-Length. */
  total: number | null;
}

/**
 * Checks the configured updater endpoint for a newer release. Resolves
 * to `null` when the running build is already current (per the plugin's
 * own contract - see the `.d.ts`'s note on the deprecated `available`
 * field). Rejects on any check failure (offline, malformed latest.json,
 * bad signature) rather than mapping it to `null` - a failed check is
 * not the same thing as "no update," and callers need to tell them apart
 * to show an error instead of silently doing nothing.
 */
export async function checkForUpdate(): Promise<Update | null> {
  return check();
}

/**
 * Downloads and installs `update`, reporting cumulative byte progress
 * via `onProgress` as the plugin's own Started/Progress/Finished events
 * arrive, then relaunches the app so the installed build takes effect.
 * Rejects (without relaunching) if the download or install step fails.
 *
 * If `relaunch()` itself succeeds, the process exits and this promise
 * never settles from the caller's point of view - that's expected, not
 * a bug to work around.
 */
export async function installAndRelaunch(update: Update, onProgress?: (progress: UpdateDownloadProgress) => void): Promise<void> {
  let downloaded = 0;
  let total: number | null = null;

  await update.downloadAndInstall((event: DownloadEvent) => {
    switch (event.event) {
      case "Started":
        total = event.data.contentLength ?? null;
        downloaded = 0;
        onProgress?.({ downloaded, total });
        break;
      case "Progress":
        downloaded += event.data.chunkLength;
        onProgress?.({ downloaded, total });
        break;
      case "Finished":
        onProgress?.({ downloaded: total ?? downloaded, total });
        break;
    }
  });

  await relaunch();
}
