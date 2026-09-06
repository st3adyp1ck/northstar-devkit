import { describe, expect, it } from "vitest";
import {
  APPEARANCE_CACHE_KEY,
  appearanceProperties,
  applyAnimationsAttribute,
  applyCachedAppearance,
  clampUiScale,
  createAppearanceApplier,
  pickAppearance,
  readCachedAppearance,
  rootAppearance,
  uiScaleProperties,
  writeCachedAppearance,
  type AppearancePrefs,
  type AppearanceRoot,
} from "./appearance";
import { getThemePreset } from "./themes";
import type { DevKitPreferences } from "./types";

/** A CSSStyleDeclaration stand-in that records the inline properties on the root. */
function fakeRoot(): AppearanceRoot & { props: Map<string, string> } {
  const props = new Map<string, string>();
  return {
    props,
    dataset: {},
    style: {
      setProperty: (name, value) => void props.set(name, value),
      removeProperty: (name) => void props.delete(name),
    },
  };
}

/** A minimal Storage - only the two members the cache touches. */
function fakeStorage(initial: Record<string, string> = {}): Storage & { data: Map<string, string> } {
  const data = new Map(Object.entries(initial));
  return {
    data,
    getItem: (key) => data.get(key) ?? null,
    setItem: (key, value) => void data.set(key, value),
    removeItem: (key) => void data.delete(key),
    clear: () => data.clear(),
    key: () => null,
    get length() {
      return data.size;
    },
  };
}

const defaults: AppearancePrefs = {
  appTheme: "northstar",
  accentColor: null,
  fontFamily: null,
  uiScale: 1,
  enableAnimations: true,
  widgetDockMode: null,
  railWidth: null,
  railIconSize: null,
  iconTheme: null,
  flyoutTabOrder: null,
};

describe("clampUiScale / uiScaleProperties", () => {
  it("clamps to the supported range and treats non-finite as 1", () => {
    expect(clampUiScale(0.5)).toBe(0.8);
    expect(clampUiScale(2)).toBe(1.4);
    expect(clampUiScale(1.1)).toBe(1.1);
    expect(clampUiScale(NaN)).toBe(1);
    expect(clampUiScale(Infinity)).toBe(1);
  });

  it("emits zoom and --ui-scale together, and nothing at scale 1", () => {
    expect(uiScaleProperties(1)).toEqual({});
    expect(uiScaleProperties(NaN)).toEqual({});
    expect(uiScaleProperties(1.2)).toEqual({ zoom: "1.2", "--ui-scale": "1.2" });
  });
});

describe("appearanceProperties", () => {
  it("is empty for the stylesheet defaults", () => {
    expect(appearanceProperties(defaults)).toEqual({});
  });

  it("falls back to northstar for an unknown theme id", () => {
    expect(appearanceProperties({ ...defaults, appTheme: "not-a-theme" })).toEqual({});
  });

  it("carries a preset's overrides verbatim", () => {
    const dracula = getThemePreset("dracula").overrides;
    expect(appearanceProperties({ ...defaults, appTheme: "dracula" })).toEqual(dracula);
  });

  it("layers a custom accent ramp over the preset", () => {
    const props = appearanceProperties({ ...defaults, appTheme: "nord", accentColor: "#ff0000" });
    expect(props["--sapphire-500"]).toBe("#ff0000");
    // Untouched preset values survive underneath.
    expect(props["--gm-950"]).toBe(getThemePreset("nord").overrides["--gm-950"]);
  });

  it("ignores an accent that is not a #rrggbb hex", () => {
    expect(appearanceProperties({ ...defaults, accentColor: "red" })).toEqual({});
  });

  it("appends the default stack behind a bare font family and keeps a full stack verbatim", () => {
    expect(appearanceProperties({ ...defaults, fontFamily: "Inter" })["--font-sans"]).toBe(
      'Inter, "Segoe UI Variable", "Segoe UI", system-ui, sans-serif',
    );
    expect(appearanceProperties({ ...defaults, fontFamily: "Inter, sans-serif" })["--font-sans"]).toBe(
      "Inter, sans-serif",
    );
    expect(appearanceProperties({ ...defaults, fontFamily: "   " })).toEqual({});
  });

  it("includes the zoom pair for a non-default scale", () => {
    expect(appearanceProperties({ ...defaults, uiScale: 0.9 })).toEqual({ zoom: "0.9", "--ui-scale": "0.9" });
  });
});

describe("createAppearanceApplier", () => {
  it("sweeps what it wrote last time that the new set no longer carries", () => {
    const root = fakeRoot();
    const applier = createAppearanceApplier();
    applier.apply(root.style, appearanceProperties({ ...defaults, appTheme: "dracula", uiScale: 1.2 }));
    expect(root.props.get("--gm-950")).toBe(getThemePreset("dracula").overrides["--gm-950"]);
    expect(root.props.get("zoom")).toBe("1.2");

    // Back to the defaults: everything the applier wrote must go.
    applier.apply(root.style, appearanceProperties(defaults));
    expect(root.props.size).toBe(0);
    expect(applier.applied().size).toBe(0);
  });

  it("replaces one theme with another without leaving the first behind", () => {
    // Every preset overrides the same 23 tokens, so a theme-to-theme swap
    // alone cannot tell "swept" from "overwritten". The font and scale
    // properties on the first apply are what the second must take down.
    const root = fakeRoot();
    const applier = createAppearanceApplier();
    applier.apply(root.style, appearanceProperties({ ...defaults, appTheme: "dracula", fontFamily: "Inter", uiScale: 1.2 }));
    expect(root.props.has("--font-sans")).toBe(true);
    expect(root.props.has("zoom")).toBe(true);

    applier.apply(root.style, appearanceProperties({ ...defaults, appTheme: "nord" }));
    expect(root.props.has("--font-sans")).toBe(false);
    expect(root.props.has("zoom")).toBe(false);
    expect(root.props.has("--ui-scale")).toBe(false);
    const nord = getThemePreset("nord").overrides;
    expect(root.props.size).toBe(Object.keys(nord).length);
    for (const [prop, value] of root.props) {
      expect(nord[prop]).toBe(value);
    }
  });

  it("clears an orphaned scale preview it never set", () => {
    const root = fakeRoot();
    // The Settings slider writes the pair directly (previewUiScale)...
    root.style.setProperty("zoom", "1.3");
    root.style.setProperty("--ui-scale", "1.3");
    const applier = createAppearanceApplier();
    // ...and a settings apply at scale 1 must still take it down.
    applier.apply(root.style, appearanceProperties(defaults));
    expect(root.props.has("zoom")).toBe(false);
    expect(root.props.has("--ui-scale")).toBe(false);
  });
});

describe("applyAnimationsAttribute", () => {
  it("stamps off and removes on", () => {
    const root = fakeRoot();
    applyAnimationsAttribute(root, false);
    expect(root.dataset.animations).toBe("off");
    applyAnimationsAttribute(root, true);
    expect("animations" in root.dataset).toBe(false);
  });
});

describe("appearance cache", () => {
  const prefs: AppearancePrefs = {
    appTheme: "tokyo-night",
    accentColor: "#7aa2f7",
    fontFamily: "Inter",
    uiScale: 1.1,
    enableAnimations: false,
    widgetDockMode: "Left",
    railWidth: 52,
    railIconSize: 20,
    iconTheme: "duotone",
    flyoutTabOrder: ["notes", "git"],
  };

  it("round-trips a snapshot", () => {
    const storage = fakeStorage();
    writeCachedAppearance(storage, prefs);
    expect(readCachedAppearance(storage)).toEqual(prefs);
  });

  it("picks exactly the appearance slice of full preferences", () => {
    const full = { ...prefs, confirmDestructive: true, gitFlyoutWidth: 300 } as unknown as DevKitPreferences;
    expect(pickAppearance(full)).toEqual(prefs);
  });

  it("normalises shell values the live path would reject, on both the write and the read", () => {
    const odd = {
      ...prefs,
      widgetDockMode: "Sideways",
      railWidth: "wide",
      railIconSize: NaN,
      iconTheme: "neon",
      flyoutTabOrder: "git",
    } as unknown as DevKitPreferences;
    const picked = pickAppearance(odd);
    expect(picked.widgetDockMode).toBeNull();
    expect(picked.railWidth).toBeNull();
    // pickAppearance only checks typeof === "number", so NaN passes through
    // as NaN here - but nothing reads this in-memory value directly. It is
    // always round-tripped through JSON first (writeCachedAppearance), and
    // JSON.stringify(NaN) serialises to `null`, which is what the consumer
    // (WidgetApp's `?? undefined`, then clampRail) actually sees. Assert
    // that real path below rather than this intermediate value alone.
    expect(picked.railIconSize).toBeNaN();
    expect(picked.iconTheme).toBeNull();
    expect(picked.flyoutTabOrder).toBeNull();

    const storage = fakeStorage();
    writeCachedAppearance(storage, picked);
    expect(readCachedAppearance(storage)?.railIconSize).toBeNull();

    const read = readCachedAppearance(
      fakeStorage({
        [APPEARANCE_CACHE_KEY]: JSON.stringify({
          appTheme: "nord",
          widgetDockMode: "Floating",
          railWidth: 40,
          iconTheme: "solid",
          flyoutTabOrder: ["terminal", 7, null, "files"],
        }),
      }),
    );
    expect(read).toEqual({
      ...defaults,
      appTheme: "nord",
      widgetDockMode: "Floating",
      railWidth: 40,
      iconTheme: "solid",
      flyoutTabOrder: ["terminal", "files"],
    });
  });

  it("is a no-op without storage", () => {
    expect(readCachedAppearance(null)).toBeNull();
    expect(() => writeCachedAppearance(null, prefs)).not.toThrow();
  });

  it("treats a missing, empty, or unparseable entry as uncached", () => {
    expect(readCachedAppearance(fakeStorage())).toBeNull();
    expect(readCachedAppearance(fakeStorage({ [APPEARANCE_CACHE_KEY]: "" }))).toBeNull();
    expect(readCachedAppearance(fakeStorage({ [APPEARANCE_CACHE_KEY]: "{not json" }))).toBeNull();
    expect(readCachedAppearance(fakeStorage({ [APPEARANCE_CACHE_KEY]: "42" }))).toBeNull();
    expect(readCachedAppearance(fakeStorage({ [APPEARANCE_CACHE_KEY]: "null" }))).toBeNull();
  });

  it("defaults every odd or missing field on its own rather than rejecting the entry", () => {
    expect(readCachedAppearance(fakeStorage({ [APPEARANCE_CACHE_KEY]: JSON.stringify({ uiScale: 1.2 }) }))).toEqual({
      ...defaults,
      uiScale: 1.2,
    });
    expect(readCachedAppearance(fakeStorage({ [APPEARANCE_CACHE_KEY]: "{}" }))).toEqual(defaults);
    const partial = readCachedAppearance(
      fakeStorage({
        [APPEARANCE_CACHE_KEY]: JSON.stringify({
          appTheme: "nord",
          accentColor: 7,
          fontFamily: [],
          uiScale: "big",
          enableAnimations: "no",
        }),
      }),
    );
    expect(partial).toEqual({ ...defaults, appTheme: "nord" });
  });

  it("survives a storage that throws", () => {
    const broken = {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("quota");
      },
    } as unknown as Storage;
    expect(readCachedAppearance(broken)).toBeNull();
    expect(() => writeCachedAppearance(broken, prefs)).not.toThrow();
  });
});

describe("applyCachedAppearance", () => {
  it("paints the snapshot and the animations attribute before settings exist", () => {
    const root = fakeRoot();
    const storage = fakeStorage();
    writeCachedAppearance(storage, { ...defaults, appTheme: "monokai", uiScale: 1.2, enableAnimations: false });
    const applier = createAppearanceApplier();

    const applied = applyCachedAppearance(root, storage, applier);

    expect(applied?.appTheme).toBe("monokai");
    expect(root.props.get("--gm-950")).toBe(getThemePreset("monokai").overrides["--gm-950"]);
    expect(root.props.get("zoom")).toBe("1.2");
    expect(root.dataset.animations).toBe("off");
  });

  it("does nothing without a snapshot", () => {
    const root = fakeRoot();
    expect(applyCachedAppearance(root, fakeStorage(), createAppearanceApplier())).toBeNull();
    expect(root.props.size).toBe(0);
    expect("animations" in root.dataset).toBe(false);
  });

  it("is fully undone by the first real apply when settings disagree", () => {
    // The stale-cache case: the snapshot says dracula, settings.json says
    // northstar. The hook's apply goes through the SAME applier, so the
    // boot-painted properties are swept rather than left underneath.
    const root = fakeRoot();
    const storage = fakeStorage();
    writeCachedAppearance(storage, { ...defaults, appTheme: "dracula" });
    const applier = createAppearanceApplier();
    applyCachedAppearance(root, storage, applier);
    expect(root.props.size).toBeGreaterThan(0);

    applier.apply(root.style, appearanceProperties(defaults));
    expect(root.props.size).toBe(0);
  });

  it("defaults to the window's shared applier, the one useApplyAppearance writes through", () => {
    // The invariant the whole fix rests on: main.tsx passes no applier, so
    // boot must land in `rootAppearance` - otherwise the hook's first apply
    // would not know what boot painted and a stale snapshot would survive.
    const root = fakeRoot();
    const storage = fakeStorage();
    writeCachedAppearance(storage, { ...defaults, appTheme: "dracula", uiScale: 1.2 });
    const cached = applyCachedAppearance(root, storage);
    expect(cached).not.toBeNull();
    expect(rootAppearance.applied()).toEqual(new Set(Object.keys(appearanceProperties(cached!))));

    rootAppearance.apply(root.style, appearanceProperties(defaults));
    expect(root.props.size).toBe(0);
    expect(rootAppearance.applied().size).toBe(0);
  });
});
