import { create } from "zustand";
import { rpcCall } from "../lib/ipc";
import type { LinkedProject } from "../lib/types";

interface ProjectState {
  active: LinkedProject | null;
  linked: LinkedProject[];
  loading: boolean;
  refresh: () => Promise<void>;
  setActive: (id: string) => Promise<void>;
  addProject: (path: string, name?: string) => Promise<void>;
}

export const useProjectStore = create<ProjectState>((set, get) => ({
  active: null,
  linked: [],
  loading: false,

  refresh: async () => {
    set({ loading: true });
    try {
      const [active, linked] = await Promise.all([
        rpcCall<LinkedProject | null>("projects.getActive"),
        rpcCall<LinkedProject[]>("projects.list"),
      ]);
      set({ active, linked: linked ?? [], loading: false });
    } catch {
      set({ loading: false });
    }
  },

  setActive: async (id: string) => {
    const active = await rpcCall<LinkedProject | null>("projects.setActive", { id });
    set({ active });
    await get().refresh();
  },

  addProject: async (path: string, name?: string) => {
    await rpcCall<LinkedProject>("projects.add", { path, name });
    await get().refresh();
  },
}));
