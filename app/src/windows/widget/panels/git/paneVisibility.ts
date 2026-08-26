import { useEffect, useState, type RefObject } from "react";

/** FlyoutPaneStack's pane element - it carries the aria-hidden we read. */
const PANE_SELECTOR = ".widget-flyout__pane";

/**
 * True while this subtree is genuinely on screen.
 *
 * FlyoutPaneStack keeps every tray that has ever been opened mounted (a tray
 * holds live things - a ConPTY session, a scrolled log, an unsent draft), so
 * a panel inside a SHUT tray keeps polling forever unless it asks. That is
 * expensive here: git.overview with the graph is a git log spawn + parse
 * (250-420ms measured) and github.prs/issues each spawn the gh CLI (~620ms).
 *
 * The pane's `aria-hidden` is the signal, not geometry: an inactive pane is
 * hidden with `visibility` and keeps its full-size box on purpose (xterm
 * measures itself off it), so IntersectionObserver would happily report a
 * shut tray as visible.
 *
 * No pane ancestor at all - the floating widget renders these panels inline
 * in the column - means "always visible".
 */
export function useOnScreen(ref: RefObject<HTMLElement | null>): boolean {
  const [visible, setVisible] = useState(true);

  useEffect(() => {
    const pane = ref.current?.closest(PANE_SELECTOR);
    if (!(pane instanceof HTMLElement)) {
      setVisible(true);
      return;
    }
    const read = () => setVisible(pane.getAttribute("aria-hidden") !== "true");
    read();
    const observer = new MutationObserver(read);
    observer.observe(pane, { attributes: true, attributeFilter: ["aria-hidden"] });
    return () => observer.disconnect();
  }, [ref]);

  return visible;
}
