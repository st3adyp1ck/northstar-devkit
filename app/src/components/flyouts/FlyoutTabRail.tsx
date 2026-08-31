import clsx from "clsx";
import type { FlyoutDockSide } from "./useWidgetFlyout";
import { RailIcon, type IconTheme, type RailIconName } from "./railIcons";
import "./WidgetFlyout.css";

export interface FlyoutTabDef {
  id: string;
  label: string;
  icon: RailIconName;
}

interface FlyoutTabRailProps {
  tabs: FlyoutTabDef[];
  /** Which tab reads "lit", or null when every tray is shut. */
  activeId: string | null;
  /** Dock side of the widget - the rail lives on the opposite (screen-facing) edge. */
  side: FlyoutDockSide;
  /** Glyph style, straight off preferences.iconTheme. */
  iconTheme: IconTheme;
  onSelect: (id: string) => void;
  /** The brand plate at the foot of the rail - the Control Center tray's tab. */
  onBrand: () => void;
  /** True while the Control Center tray is the open one - the plate lights like any other active tab. */
  brandActive?: boolean;
  /** Tooltip/label for the brand plate, e.g. "Open the Control Center tray". */
  brandTitle: string;
}

/**
 * The pull-tabs from the original WPF widget, redrawn in the JARVIS
 * language: a vertical strip of glyph buttons on the sidebar's INNER edge
 * (right edge when docked Left, left edge when docked Right), each with a
 * hairline accent light on the pane-facing side that brightens on hover and
 * breathes while its tray is open - the same living-light-strip vocabulary
 * as .widget-rail, one notch quieter because there are four of them.
 *
 * Two zones, and the split is the whole point of the layout: the tab group
 * takes ALL the leftover height and centres itself inside it, while the
 * DEVKIT plate is a fixed block flush to the foot. Adding a fifth tray
 * re-centres the group automatically and never moves the plate.
 *
 * Sizing (rail width, glyph size, glyph style) is entirely settings-driven -
 * see .widget-app's --rail-width / --rail-icon in WidgetApp.css for why
 * those are divided by --ui-scale before they reach here.
 */
export function FlyoutTabRail({
  tabs,
  activeId,
  side,
  iconTheme,
  onSelect,
  onBrand,
  brandActive = false,
  brandTitle,
}: FlyoutTabRailProps) {
  return (
    <nav
      className={clsx("flyout-rail", side === "Right" ? "flyout-rail--dock-right" : "flyout-rail--dock-left")}
      aria-label="Trays"
    >
      <div className="flyout-rail__tabs">
        {tabs.map((tab) => {
          const active = tab.id === activeId;
          return (
            <button
              key={tab.id}
              type="button"
              className={clsx("flyout-rail__tab", active && "flyout-rail__tab--active")}
              aria-label={tab.label}
              aria-pressed={active}
              title={active ? `Close ${tab.label}` : `Open ${tab.label}`}
              onClick={() => onSelect(tab.id)}
            >
              <RailIcon name={tab.icon} theme={iconTheme} />
              <span className="flyout-rail__light" aria-hidden="true" />
            </button>
          );
        })}
      </div>

      {/* A plate, not a button: full rail width, square, seated on a lit
          seam, with the rose silkscreened over a legend. It should read as
          the bottom section of the instrument's chassis. */}
      <button
        type="button"
        className={clsx("flyout-rail__brand", brandActive && "flyout-rail__brand--active")}
        aria-label={brandTitle}
        aria-pressed={brandActive}
        title={brandTitle}
        onClick={onBrand}
      >
        <span className="flyout-rail__brand-seam" aria-hidden="true" />
        <RailIcon name="devkit" theme={iconTheme} className="flyout-rail__brand-mark" />
        <span className="flyout-rail__brand-label">DEVKIT</span>
      </button>
    </nav>
  );
}
