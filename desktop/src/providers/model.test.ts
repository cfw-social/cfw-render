import { describe, expect, it } from "vitest";
import { moveEngine, orderedEngines, providersModel } from "./model";
import { PROVIDERS } from "./registry";
import type { Engine } from "../status";

const resets = new Date(2026, 9, 12, 15, 40).toISOString();
const engines: Engine[] = [
  { name: "codex", signedIn: true, limit: "limited", resetsAt: resets },
  { name: "claude-code", signedIn: false, limit: "ok" },
  { name: "gemini", signedIn: true },
];

describe("providersModel", () => {
  it("counts connected, ignores unknown engines, sets badges and lines", () => {
    const m = providersModel(PROVIDERS, engines, []);
    expect(m.cards.map((c) => c.engine)).toEqual(["codex", "claude-code"]);
    expect(m.connectedCount).toBe(1);
    expect(m.countLine).toBe("1 connected");
    expect(m.cards[0]).toMatchObject({ name: "ChatGPT", connected: true, badge: "Sign in", stateLine: "Limit reached, resets 15:40", position: 1, isFirst: true });
    expect(m.cards[1]).toMatchObject({ name: "Claude", connected: false, stateLine: "Not connected", position: 2, isLast: true });
  });

  it("shows Connected and Signing in…", () => {
    const m = providersModel(PROVIDERS, [{ name: "codex", signedIn: true, limit: "ok" }], [], new Set(["claude-code"]));
    expect(m.cards.map((c) => c.stateLine)).toEqual(["Connected", "Signing in…"]);
  });

  it("respects order and API-key badge shape", () => {
    const reg = [...PROVIDERS, { engine: "x", name: "X", auth: "api_key" as const, logo: "X", logoColor: "#000" }];
    const m = providersModel(reg, undefined, ["claude-code", "bogus", "codex"]);
    expect(m.cards.map((c) => [c.engine, c.position, c.badge])).toEqual([
      ["claude-code", 1, "Sign in"],
      ["codex", 2, "Sign in"],
      ["x", 3, "API key"],
    ]);
    expect(m.countLine).toBe("0 connected");
  });

  it("orders and moves", () => {
    expect(orderedEngines(PROVIDERS, ["claude-code", "claude-code"])).toEqual(["claude-code", "codex"]);
    expect(moveEngine(["a", "b"], "b", -1)).toEqual(["b", "a"]);
    expect(moveEngine(["a", "b"], "a", -1)).toEqual(["a", "b"]);
  });
});
