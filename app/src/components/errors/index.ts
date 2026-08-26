/**
 * Error Center public surface.
 *
 * Wiring it into a window is two lines:
 *   1. mount <ErrorCenterHost /> once, inside that window's <ConfirmDialogHost>
 *   2. call openErrorCenter() (or useErrorCenterStore's openCenter) from
 *      whatever control should raise it - a titlebar button, the widget rail
 *
 * useUnseenErrorCount() gives that control a badge number.
 */
export { ErrorCenter, ErrorCenterHost } from "./ErrorCenter";
export {
  useErrorCenterStore,
  openErrorCenter,
  closeErrorCenter,
  toggleErrorCenter,
  useUnseenErrorCount,
  useErrorCount,
} from "./useErrorCenterStore";
export { useErrorFeed, type ErrorFeed } from "./useErrorFeed";
export { entryToText, formatExact, formatRelative } from "./format";
export { copyText } from "./clipboard";
