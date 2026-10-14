import { describe, expect, it } from "vitest";
import { health, hhmm, panelModel } from "./model";
import { NOW, payload, workingStatus } from "./fixtures";
import type { StatusFile } from "../status";

const withComputer = (c: StatusFile["computer"]): StatusFile => ({ ...workingStatus, computer: { ...workingStatus.computer, ...c } });

describe("panelModel", () => {
  it("worker not running", () => {
    expect(panelModel(payload(workingStatus, { liveness: "NotRunning" }), NOW).banner).toEqual({ kind: "notRunning", text: "Worker not running" });
    expect(panelModel(null, NOW).banner?.kind).toBe("notRunning");
  });

  it("paused by owner", () => {
    const m = panelModel(payload(withComputer({ paused: true, pauseReason: "owner" })), NOW);
    expect(m.banner).toEqual({ kind: "paused", text: "Paused" });
    expect(m.paused).toBe(true);
  });

  it("on battery", () => {
    expect(panelModel(payload(withComputer({ paused: true, pauseReason: "battery", onBattery: true })), NOW).banner).toEqual({ kind: "battery", text: "On battery" });
  });

  it("limited with resetsAt", () => {
    const s: StatusFile = { ...workingStatus, engines: [{ name: "codex", signedIn: true, limit: "limited", resetsAt: "2026-10-11T15:40:00Z" }] };
    const m = panelModel(payload(s), NOW);
    expect(m.banner).toEqual({ kind: "limit", text: `AI limit reached; resumes about ${hhmm(Date.parse("2026-10-11T15:40:00Z"))}` });
  });

  it("update required", () => {
    expect(panelModel(payload(withComputer({ updateRequired: true })), NOW).banner?.text).toBe("Update this computer");
  });

  it("no engine signed in", () => {
    const s: StatusFile = { ...workingStatus, engines: [{ name: "codex", signedIn: false }] };
    const m = panelModel(payload(s, { providerLine: "No AI provider signed in" }), NOW);
    expect(m.noProvider).toBe(true);
    expect(m.providerLine).toBe("No AI provider signed in");
    expect(m.banner).toBeNull();
  });

  it("working status", () => {
    const m = panelModel(payload(workingStatus), NOW);
    expect(m.banner).toBeNull();
    expect(m.providerLine).toBe("AI: ChatGPT limited until 15:40, using Claude");
    expect(m.brandsLine).toBe("Working for: Brand A, Brand C");
    expect(m.now).toEqual([{ title: "R-7KQ4 · Brand A", recipe: "Spotlight reel", stepText: "step 5 of 7 · Render scenes", pct: 62, elapsed: "1:30", code: "R-7KQ4", brand: "Brand A", stepLabel: "Render scenes", step: "step 5 of 7" }]);
    expect(m.next).toEqual([{ title: "R-C1 · Brand C", recipe: "Carousel", code: "R-C1", brand: "Brand C" }]);
    // Newest three by finishedAt; the oldest (R-OLD) drops off.
    expect(m.done.map((d) => [d.mark, d.result, d.title])).toEqual([
      ["–", "stopped", "R-6TT3 · Brand A"],
      ["✗", "failed", "R-6TT2 · Brand C"],
      ["✓", "done", "R-6TT1 · Brand A"],
    ]);
    expect(m.done[0].time).toBe(hhmm(Date.parse("2026-10-11T11:20:00Z")));
    expect(m.lastCheck).toBe("Last check: 8 s ago");
  });

  it("missing optional fields", () => {
    const s: StatusFile = { schema: 1, now: [{ brand: "Brand A" }], recent: [{ shortCode: "R-1", result: "weird" }] };
    const m = panelModel(payload(s), NOW);
    expect(m.brandsLine).toBeNull();
    expect(m.noProvider).toBe(true);
    expect(m.now).toEqual([{ title: "Brand A", recipe: "", stepText: "", pct: null, elapsed: null, code: "", brand: "Brand A", stepLabel: "", step: "" }]);
    expect(m.next).toEqual([]);
    expect(m.done).toEqual([{ mark: "✗", result: "failed", title: "R-1", time: "", code: "R-1", brand: "", identity: { shortCode: "R-1", result: "weird" } }]);
    expect(m.lastCheck).toBe("Last check: never");
  });

  it("health: one state for the menu bar, with a fix when the owner is needed", () => {
    expect(health(panelModel(payload(workingStatus), NOW))).toMatchObject({ kind: "rendering", tone: "ok", callout: null });
    expect(health(panelModel(payload({ ...workingStatus, now: [] }), NOW))).toMatchObject({ kind: "ready", label: "Ready" });
    expect(health(panelModel(null, NOW))).toMatchObject({ kind: "notRunning", tone: "bad" });
    expect(health(panelModel(payload(withComputer({ paused: true, pauseReason: "owner" })), NOW))).toMatchObject({ kind: "paused", callout: null, waiting: 1 });
    const lim: StatusFile = { ...workingStatus, engines: [{ name: "codex", signedIn: true, limit: "limited", resetsAt: "2026-10-11T15:40:00Z" }] };
    const h = health(panelModel(payload(lim), NOW));
    expect(h.kind).toBe("limit");
    expect(h.callout?.body).toContain(hhmm(Date.parse("2026-10-11T15:40:00Z")));
    const none: StatusFile = { ...workingStatus, engines: [{ name: "codex", signedIn: false }] };
    expect(health(panelModel(payload(none), NOW))).toMatchObject({ kind: "noProvider", tone: "warn" });
  });
});
