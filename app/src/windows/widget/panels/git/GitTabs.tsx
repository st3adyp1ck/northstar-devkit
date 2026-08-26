import { useCallback, useRef, type KeyboardEvent } from "react";
import clsx from "clsx";
import { playSound } from "../../../../lib/sounds";
import "./GitTabs.css";

export interface GitTabDef<Id extends string> {
  id: Id;
  label: string;
  /**
   * The tab's badge, already rendered as text by the caller. null draws no
   * badge at all, which is the honest state for "we do not know the count
   * yet" - a 0 there would claim the tab is empty.
   */
  badge: string | null;
  /** Badge tone: something is waiting in there, or that tab's own query failed. */
  tone?: "live" | "error";
}

interface GitTabsProps<Id extends string> {
  tabs: GitTabDef<Id>[];
  active: Id;
  onChange: (id: Id) => void;
  /** Prefix for the generated ids; must match what the panels use for aria-labelledby. */
  idPrefix: string;
  label: string;
}

export const tabId = (prefix: string, id: string) => `${prefix}-tab-${id}`;
export const panelId = (prefix: string, id: string) => `${prefix}-panel-${id}`;

/**
 * The Graph / Pull requests / Issues switch.
 *
 * Full ARIA tabs pattern - roving tabindex (exactly one tab is in the tab
 * order, arrows move within), arrow/Home/End navigation, aria-selected and
 * aria-controls wired to real panel ids. Two details worth naming:
 *
 * AUTOMATIC ACTIVATION (arrowing selects, not just focuses) is the right
 * choice here specifically because switching costs nothing: all three
 * panels' data is already in hand - the polls live above this component and
 * keep running whichever tab is up - so arrowing through cannot fire a
 * request. Manual activation exists for tabs whose panels are expensive to
 * build, which is the opposite of this case.
 *
 * The badge is inside the tab's accessible name on purpose ("Pull requests,
 * 3"), because the count is the reason to go there.
 */
export function GitTabs<Id extends string>({ tabs, active, onChange, idPrefix, label }: GitTabsProps<Id>) {
  const refs = useRef(new Map<Id, HTMLButtonElement>());

  const select = useCallback(
    (id: Id) => {
      if (id === active) return;
      onChange(id);
      playSound("click");
    },
    [active, onChange],
  );

  function onKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    const index = tabs.findIndex((tab) => tab.id === active);
    if (index < 0) return;
    let next = -1;
    if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
    else if (event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabs.length - 1;
    if (next < 0) return;
    event.preventDefault();
    const target = tabs[next];
    select(target.id);
    refs.current.get(target.id)?.focus();
  }

  return (
    <div className="git-tabs" role="tablist" aria-label={label}>
      {tabs.map((tab) => {
        const selected = tab.id === active;
        const badge = tab.badge;
        return (
          <button
            key={tab.id}
            ref={(node) => {
              if (node) refs.current.set(tab.id, node);
              else refs.current.delete(tab.id);
            }}
            type="button"
            role="tab"
            id={tabId(idPrefix, tab.id)}
            aria-controls={panelId(idPrefix, tab.id)}
            aria-selected={selected}
            // Roving tabindex: Tab lands on the tablist once, arrows do the rest.
            tabIndex={selected ? 0 : -1}
            className={clsx("git-tab", selected && "git-tab--active")}
            onClick={() => select(tab.id)}
            onKeyDown={onKeyDown}
          >
            <span className="git-tab__label">{tab.label}</span>
            {badge !== null && (
              <span
                className={clsx(
                  "git-tab__count",
                  tab.tone === "live" && "git-tab__count--live",
                  tab.tone === "error" && "git-tab__count--error",
                )}
              >
                {badge}
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
}
