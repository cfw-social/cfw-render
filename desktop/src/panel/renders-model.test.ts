import { describe, expect, it } from "vitest";
import bundledGuide from "../../../lib/render-debug.md?raw";
import bundledGuideManifest from "../../../config/agent-guides.json?raw";
import { panelModel, rendersModel } from "./model";
import { NOW, payload, workingStatus } from "./fixtures";

describe("rendersModel", () => {
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
