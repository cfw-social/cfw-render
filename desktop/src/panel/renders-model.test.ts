import { describe, expect, it } from "vitest";
import { panelModel, rendersModel } from "./model";
import { NOW, payload, workingStatus } from "./fixtures";

describe("rendersModel", () => {
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
