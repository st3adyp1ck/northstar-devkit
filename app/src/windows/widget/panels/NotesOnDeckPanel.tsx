import { useState, type CSSProperties } from "react";
import clsx from "clsx";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useProjectStore } from "../../../stores/useProjectStore";
import { rpcCall, RpcClientError } from "../../../lib/ipc";
import { asArray } from "../../../lib/arrays";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import { Button } from "../../../components/primitives/Button";
import type { ProjectNote, OnDeckItem, OnDeckStatus } from "../../../lib/types";
import "./NotesOnDeckPanel.css";

/** Small fixed palette drawn from tokens.css's signal colors - one pick per new note, round-robin. */
const NOTE_COLORS = [
  "var(--signal-amber)",
  "var(--signal-green)",
  "var(--signal-cyan)",
  "var(--signal-violet)",
  "var(--signal-sand)",
  "var(--signal-red)",
];

/** Click advances a status; wraps done -> notStarted so the control is always live. */
const NEXT_STATUS: Record<OnDeckStatus, OnDeckStatus> = {
  notStarted: "inProgress",
  inProgress: "done",
  done: "notStarted",
};

const SECTIONS: { status: OnDeckStatus; label: string; tone: "neutral" | "accent" | "success" }[] = [
  { status: "notStarted", label: "Not Started", tone: "neutral" },
  { status: "inProgress", label: "In Progress", tone: "accent" },
  { status: "done", label: "Done", tone: "success" },
];

function statusDotColors(status: OnDeckStatus): CSSProperties {
  const color =
    status === "done" ? "var(--signal-green)" : status === "inProgress" ? "var(--sapphire-400)" : "var(--text-tertiary)";
  return { "--dot-color": color, "--dot-fill": status === "done" ? color : "transparent" } as CSSProperties;
}

/**
 * Notes + On-Deck flyout. Notes is a flat list of small colored sticky
 * cards persisted whole via notes.save (there is no notes.add/remove RPC -
 * every mutation reads the current list, edits it client-side, and saves
 * the full replacement). On Deck groups items into three sections by
 * Status, matching Group-DevKitOnDeckItems' order (notStarted, inProgress,
 * done) - the server already returns items pre-grouped/stable, and
 * bucketing by iteration order here preserves that.
 */
export function NotesOnDeckPanel() {
  const active = useProjectStore((s) => s.active);
  const [tab, setTab] = useState<"notes" | "ondeck">("notes");
  const params = active ? { projectPath: active.path } : undefined;
  const {
    data: notes,
    isLoading: notesLoading,
    refetch: refetchNotes,
  } = usePolledRpc<ProjectNote[]>("notes.get", params, 10000, !!active);
  const {
    data: items,
    isLoading: itemsLoading,
    refetch: refetchItems,
  } = usePolledRpc<OnDeckItem[]>("ondeck.get", params, 10000, !!active);
  const [noteDraft, setNoteDraft] = useState("");
  const [itemDraft, setItemDraft] = useState("");
  const [error, setError] = useState<string | null>(null);

  // Wire-shape guard: a 1-element PS list can arrive as a bare object (see
  // lib/arrays.ts). Normalize once and use these everywhere - especially in
  // the read-modify-write notes.save payloads, where spreading a bare
  // object would corrupt the saved list.
  const noteList = asArray(notes);
  const itemList = asArray(items);

  function describeError(err: unknown, fallback: string): string {
    return err instanceof RpcClientError ? err.message : fallback;
  }

  async function addNote() {
    if (!active || !noteDraft.trim()) return;
    const current = noteList;
    const text = noteDraft.trim();
    const newNote: ProjectNote = {
      Id: crypto.randomUUID(),
      Text: text,
      Color: NOTE_COLORS[current.length % NOTE_COLORS.length],
      UpdatedAt: new Date().toISOString(),
    };
    setNoteDraft("");
    setError(null);
    try {
      await rpcCall("notes.save", { projectPath: active.path, notes: [...current, newNote] });
      refetchNotes();
    } catch (err) {
      setError(describeError(err, "Could not save note."));
      setNoteDraft(text); // restore the draft so the typed text isn't lost
    }
  }

  async function deleteNote(id: string) {
    if (!active) return;
    setError(null);
    try {
      await rpcCall("notes.save", { projectPath: active.path, notes: noteList.filter((n) => n.Id !== id) });
      refetchNotes();
    } catch (err) {
      setError(describeError(err, "Could not delete note."));
    }
  }

  async function addOnDeck() {
    if (!active || !itemDraft.trim()) return;
    const text = itemDraft.trim();
    setItemDraft("");
    setError(null);
    try {
      await rpcCall("ondeck.add", { projectPath: active.path, text });
      refetchItems();
    } catch (err) {
      setError(describeError(err, "Could not add item."));
      setItemDraft(text); // restore the draft so the typed text isn't lost
    }
  }

  async function cycleStatus(item: OnDeckItem) {
    if (!active) return;
    setError(null);
    try {
      await rpcCall("ondeck.setStatus", { projectPath: active.path, id: item.Id, status: NEXT_STATUS[item.Status] });
      refetchItems();
    } catch (err) {
      setError(describeError(err, "Could not update item status."));
    }
  }

  async function removeItem(id: string) {
    if (!active) return;
    setError(null);
    try {
      await rpcCall("ondeck.remove", { projectPath: active.path, id });
      refetchItems();
    } catch (err) {
      setError(describeError(err, "Could not remove item."));
    }
  }

  async function clearDone() {
    if (!active) return;
    setError(null);
    try {
      await rpcCall("ondeck.clearDone", { projectPath: active.path });
      refetchItems();
    } catch (err) {
      setError(describeError(err, "Could not clear done items."));
    }
  }

  if (!active) return null;

  const grouped: Record<OnDeckStatus, OnDeckItem[]> = { notStarted: [], inProgress: [], done: [] };
  for (const item of itemList) {
    (grouped[item.Status] ?? grouped.notStarted).push(item);
  }

  return (
    <GlassPanel>
      <div className="panel-tabs">
        <button type="button" className={clsx("panel-tab", tab === "notes" && "panel-tab--active")} onClick={() => setTab("notes")}>
          Notes <Badge tone={tab === "notes" ? "accent" : "neutral"}>{noteList.length}</Badge>
        </button>
        <button type="button" className={clsx("panel-tab", tab === "ondeck" && "panel-tab--active")} onClick={() => setTab("ondeck")}>
          On Deck <Badge tone={tab === "ondeck" ? "accent" : "neutral"}>{itemList.length}</Badge>
        </button>
      </div>

      {error && <div className="panel-empty panel-empty--danger">{error}</div>}

      {tab === "notes" && (
        <div>
          <div className="notes-panel__input-row">
            <input
              value={noteDraft}
              onChange={(e) => setNoteDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && addNote()}
              placeholder="New note..."
              className="notes-panel__input"
            />
            <Button size="sm" variant="primary" onClick={addNote} disabled={!noteDraft.trim()}>
              Add
            </Button>
          </div>
          {notesLoading && !notes ? (
            <div className="panel-empty">Loading notes...</div>
          ) : noteList.length === 0 ? (
            <div className="panel-empty">No notes yet.</div>
          ) : (
            <div className="notes-panel__list">
              {noteList.map((n) => (
                <div key={n.Id} className="notes-panel__note" style={{ "--note-color": n.Color } as CSSProperties}>
                  <span className="notes-panel__note-text">{n.Text}</span>
                  <button
                    className="notes-panel__icon-btn"
                    onClick={() => deleteNote(n.Id)}
                    aria-label={`Delete note: ${n.Text}`}
                    title="Delete note"
                  >
                    ×
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {tab === "ondeck" && (
        <div>
          <div className="notes-panel__input-row">
            <input
              value={itemDraft}
              onChange={(e) => setItemDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && addOnDeck()}
              placeholder="New item..."
              className="notes-panel__input"
            />
            <Button size="sm" variant="primary" onClick={addOnDeck} disabled={!itemDraft.trim()}>
              Add
            </Button>
          </div>
          {itemsLoading && !items ? (
            <div className="panel-empty">Loading on-deck items...</div>
          ) : itemList.length === 0 ? (
            <div className="panel-empty">Nothing on deck.</div>
          ) : (
            <div className="notes-panel__sections">
              {SECTIONS.map(({ status, label, tone }) => {
                const sectionItems = grouped[status];
                if (sectionItems.length === 0) return null;
                return (
                  <div key={status}>
                    <div className="notes-panel__section-head">
                      <span className="notes-panel__section-label">{label}</span>
                      <Badge tone={tone}>{sectionItems.length}</Badge>
                      {status === "done" && (
                        <Button size="sm" variant="ghost" onClick={clearDone} className="notes-panel__clear-done">
                          Clear Done
                        </Button>
                      )}
                    </div>
                    <div className="notes-panel__items">
                      {sectionItems.map((item) => (
                        <div key={item.Id} className="notes-panel__item">
                          <button
                            className="notes-panel__status-dot"
                            style={statusDotColors(item.Status)}
                            onClick={() => cycleStatus(item)}
                            aria-label={`Advance status of: ${item.Text}`}
                            title={`Status: ${item.Status} (click to advance)`}
                          />
                          <span className={clsx("notes-panel__item-text", item.Status === "done" && "notes-panel__item-text--done")}>
                            {item.Text}
                          </span>
                          <button
                            className="notes-panel__icon-btn"
                            onClick={() => removeItem(item.Id)}
                            aria-label={`Remove item: ${item.Text}`}
                            title="Remove item"
                          >
                            ×
                          </button>
                        </div>
                      ))}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </GlassPanel>
  );
}
