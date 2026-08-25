import { useEffect } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { useProjectStore } from "../stores/useProjectStore";
import "./ProjectPicker.css";

export function ProjectPicker() {
  const { active, linked, refresh, setActive, addProject } = useProjectStore();

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function browse() {
    const dir = await open({ directory: true, multiple: false });
    if (typeof dir === "string") {
      await addProject(dir);
    }
  }

  return (
    <div className="devkit-project-picker">
      <div className="devkit-project-picker__select-wrap">
        <select
          className="devkit-project-picker__select"
          value={active?.id ?? ""}
          onChange={(e) => (e.target.value ? setActive(e.target.value) : undefined)}
        >
          <option value="" disabled>
            {linked.length ? "Select project..." : "No linked projects"}
          </option>
          {linked.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
              {p.Missing ? " (missing)" : ""}
            </option>
          ))}
        </select>
      </div>
      <button type="button" className="devkit-project-picker__browse" onClick={browse} title="Link a project folder">
        +
      </button>
    </div>
  );
}
