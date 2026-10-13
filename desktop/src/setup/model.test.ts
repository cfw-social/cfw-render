import { describe, expect, it } from "vitest";
import { setupModel } from "./model";

describe("setupModel", () => {
  it("starts idle with all steps pending", () => {
    const m = setupModel([]);
    expect(m.phase).toBe("idle");
    expect(m.steps.map((s) => s.step)).toEqual(["checking", "tools", "installing", "connecting", "test_render", "ready"]);
    expect(m.steps.every((s) => s.state === "pending")).toBe(true);
  });
  it("tracks progress, failure with action, and ready", () => {
    let m = setupModel([
      { step: "checking", state: "done" },
      { step: "tools", state: "started", pct: 40 },
    ]);
    expect(m.phase).toBe("running");
    expect(m.steps[1]).toMatchObject({ state: "started", pct: 40 });
    m = setupModel([{ step: "connecting", state: "failed", message: "Key rejected", action: "Paste it again" }, { step: "result", state: "failed", message: "x" }]);
    expect(m).toMatchObject({ phase: "failed", error: "Key rejected", action: "Paste it again" });
    m = setupModel([{ step: "ready", state: "done", message: "Already set up" }, { step: "result", state: "done" }]);
    expect(m).toMatchObject({ phase: "ready", readyMessage: "Already set up" });
    expect(setupModel([{ step: "bogus", state: "done" }]).steps.every((s) => s.state === "pending")).toBe(true);
  });
});
