import { describe, expect, it } from "vitest";
import bundledGuide from "../../../lib/render-debug.md?raw";
import bundledGuideManifest from "../../../config/agent-guides.json?raw";
import { connectionSummary, panelModel, renderItems, rendersModel } from "./model";
import { NOW, payload, workingStatus } from "./fixtures";

describe("connectionSummary", () => {
  const many = Array.from({ length: 14 }, (_, i) => ({ name: `B${i}`, serving: true }));
  it("user scope: all brands with count and key name", () => {
    const c = connectionSummary(payload({ ...workingStatus, brands: many, connection: { scope: "user", keyName: "Vasanth's Mac", keyHint: "cfw_render_vasant…" } }));
    expect(c).toMatchObject({ line: "Connected for all your brands (14)", keyLine: "Key: Vasanth's Mac", allBrands: true });
  });
  it("brand scope: names the one brand, falls back to keyHint", () => {
    const c = connectionSummary(payload({ ...workingStatus, brands: [{ name: "Mr. Growth Guide", serving: true }], connection: { scope: "brand", keyHint: "cfw_render_vasant…" } }));
    expect(c).toMatchObject({ line: "Connected for 1 brand: Mr. Growth Guide", keyLine: "Key: cfw_render_vasant…", allBrands: false });
  });
  it("subset scope counts served brands", () => {
    expect(connectionSummary(payload({ ...workingStatus, connection: { scope: "subset" } }))?.line).toBe("Connected for 2 brands");
  });
  it("older files without connection still summarise brands; no status → null", () => {
    expect(connectionSummary(payload(workingStatus))).toMatchObject({ line: "Connected for 2 brands", keyLine: null, brands: ["Brand A", "Brand C"], allBrands: false });
    expect(connectionSummary(payload(null))).toBeNull();
  });
});

describe("renderItems", () => {
  it("preserves raw attempt identity and cannot reuse a selected row for a later retry", () => {
    const recent = [{ orderId: "o1", attemptId: "a1", directorLog: "o1-1.out", result: "failed", startedAt: "2026-10-11T10:00:01Z", finishedAt: "2026-10-11T11:00:02Z" }];
    const first = renderItems(payload({ ...workingStatus, recent }), NOW).done[0];
    expect(first).toMatchObject({ attemptId: "a1", directorLog: "o1-1.out", startedAt: recent[0].startedAt, finishedAt: recent[0].finishedAt });
    const retry = renderItems(payload({ ...workingStatus, recent: [{ ...recent[0], attemptId: "a2" }] }), NOW).done[0];
    expect(first.key).not.toBe(retry.key);
    const rapidRetry = renderItems(payload({ ...workingStatus, recent: [{ ...recent[0], directorLog: "o1-1-other.out" }] }), NOW).done[0];
    expect(first.key).not.toBe(rapidRetry.key);
  });
  it("next rows: queued vs needs_input with needs and order link", () => {
    const { next } = renderItems(payload({ ...workingStatus, next: [
      { shortCode: "R-C1", brand: "Brand C", recipe: "Carousel" },
      { brand: "Brand A", kind: "reel", status: "needs_input", needs: "Upload a logo", orderId: "o1", brandSlug: "brand-a" },
    ] }), NOW);
    expect(next.map((n) => [n.state, n.title, n.recipe, n.needs])).toEqual([
      ["queued", "R-C1", "Carousel", null],
      ["needs_input", "reel", "reel", "Upload a logo"],
    ]);
    expect(next[1]).toMatchObject({ orderId: "o1", brandSlug: "brand-a" });
  });
  it("done rows: title fallback shortCode → recipe → Render, reason only when not finished", () => {
    const { done } = renderItems(payload({ ...workingStatus, recent: [
      { recipe: "Carousel", result: "failed", reason: "Out of credit", finishedAt: "2026-10-11T11:00:00Z" },
      { result: "done", reason: "ignored", finishedAt: "2026-10-11T10:00:00Z" },
      { shortCode: "R-9", result: "weird", finishedAt: "2026-10-11T09:00:00Z" },
    ] }), NOW);
    expect(done.map((d) => [d.title, d.state, d.reason])).toEqual([
      ["Carousel", "failed", "Out of credit"],
      ["Render", "done", null],
      ["R-9", "failed", null],
    ]);
  });
});
describe("rendersModel", () => {
  it("uses the owner control flag immediately without hiding battery or offline pauses", () => {
    expect(panelModel(payload(workingStatus, { ownerPaused: true }), NOW).paused).toBe(true);
    const stale = { ...workingStatus, computer: { ...workingStatus.computer, paused: true, pauseReason: "owner" } };
    expect(panelModel(payload(stale, { ownerPaused: false }), NOW).paused).toBe(false);
    const battery = { ...stale, computer: { ...stale.computer, pauseReason: "battery" } };
    expect(panelModel(payload(battery, { ownerPaused: false }), NOW).paused).toBe(true);
    expect(panelModel(payload({ ...stale, cfwReach: "unreachable" }, { ownerPaused: true }), NOW)).toMatchObject({ paused: true, banner: { kind: "offline" } });
  });
  it("ships a pinned, read-only debug guide with a matching source checksum", async () => {
    const body = bundledGuide;
    const manifest = JSON.parse(bundledGuideManifest);
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body));
    const sha256 = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
    expect(manifest.schemaVersion).toBe(1);
    expect(manifest.documents).toEqual([{
      path: "lib/render-debug.md",
      source: "src/lib/agent-library/content/render-debug.md",
      url: "https://app.cfw.social/assets/guides/render-debug.md",
      sha256,
    }]);
    expect(body).toContain("Investigate read-only");
    expect(body).toContain("Ask before fixes,\npaid calls or retries");
    expect(body).toContain("Do not download, install or invent a missing helper");
    expect(body).toContain("Null means\nunknown");
  });
  const recent = [
    { shortCode: "R-1", result: "done", finishedAt: "2026-10-11T08:00:00Z" },
    { shortCode: "R-STALE", result: "done", finishedAt: "2026-10-10T11:59:00Z" }, // >24h
    { shortCode: "R-2", result: "failed", finishedAt: "2026-10-11T11:00:00Z" },
    { shortCode: "R-NOTIME", result: "done" },
    { shortCode: "R-3", result: "stopped", finishedAt: "2026-10-10T12:30:00Z" },
    { shortCode: "R-4", result: "done", finishedAt: "2026-10-11T11:30:00Z" },
    { shortCode: "R-5", result: "done", finishedAt: "2026-10-11T09:00:00Z" },
  ];
  const p = payload({ ...workingStatus, recent });

  it("keeps every entry from the last 24h, newest first", () => {
    expect(rendersModel(p, NOW).done.map((d) => d.title)).toEqual(["R-4", "R-2", "R-5", "R-1", "R-3"]);
  });

  it("panel still shows three, unfiltered", () => {
    expect(panelModel(p, NOW).done.map((d) => d.title)).toEqual(["R-4", "R-2", "R-5"]);
  });

  it("shares the rest of the panel model", () => {
    const r = rendersModel(p, NOW), m = panelModel(p, NOW);
    expect({ ...r, done: [] }).toEqual({ ...m, done: [] });
  });
});
