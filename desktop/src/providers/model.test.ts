import { describe, expect, it } from "vitest";
import { moveEngine, orderedEngines, providersModel } from "./model";
import { PROVIDERS } from "./registry";
import type { Engine } from "../status";

const TWO = PROVIDERS.slice(0, 2);

const resets = new Date(2026, 9, 12, 15, 40).toISOString();
const engines: Engine[] = [
  { name: "codex", signedIn: true, limit: "limited", resetsAt: resets },
  { name: "claude-code", signedIn: false, limit: "ok" },
  { name: "gemini", signedIn: true },
];

describe("providersModel", () => {
  it("counts connected, ignores unknown engines, sets badges and lines", () => {
    const m = providersModel(TWO, engines, []);
    expect(m.cards.map((c) => c.engine)).toEqual(["codex", "claude-code"]);
    expect(m.connectedCount).toBe(1);
    expect(m.countLine).toBe("1 connected");
    expect(m.cards[0]).toMatchObject({ name: "ChatGPT", connected: true, badge: "Sign in", stateLine: "Limit reached, resets 15:40", position: 1, isFirst: true });
    expect(m.cards[1]).toMatchObject({ name: "Claude", connected: false, stateLine: "Not connected", position: 2, isLast: true });
  });

  it("shows Connected and Signing in…", () => {
    const m = providersModel(TWO, [{ name: "codex", signedIn: true, limit: "ok" }], [], new Set(["claude-code"]));
    expect(m.cards.map((c) => c.stateLine)).toEqual(["Connected", "Signing in…"]);
  });

  it("respects order and API-key badge shape", () => {
    const reg = [...TWO, { engine: "x", name: "X", auth: "api_key" as const, logo: "X", logoColor: "#000" }];
    const m = providersModel(reg, undefined, ["claude-code", "bogus", "codex"]);
    expect(m.cards.map((c) => [c.engine, c.position, c.badge])).toEqual([
      ["claude-code", 1, "Sign in"],
      ["codex", 2, "Sign in"],
      ["x", 3, "API key"],
    ]);
    expect(m.countLine).toBe("0 connected");
  });

  it("orders and moves", () => {
    expect(orderedEngines(TWO, ["claude-code", "claude-code"])).toEqual(["claude-code", "codex"]);
    expect(moveEngine(["a", "b"], "b", -1)).toEqual(["b", "a"]);
    expect(moveEngine(["a", "b"], "a", -1)).toEqual(["a", "b"]);
  });

  it("has all 8 providers with badges, Gemini both, credit line and Try again", () => {
    const st: Engine[] = [
      { name: "codex", signedIn: true },
      { name: "gemini", signedIn: false },
      { name: "xai", signedIn: true, limit: "limited", reason: "credit" },
      { name: "zai", signedIn: true, limit: "limited", resetsAt: resets },
    ];
    const m = providersModel(PROVIDERS, st, [], new Set(), new Set(["openrouter"]));
    expect(m.cards.map((c) => c.engine)).toEqual(["codex", "claude-code", "gemini", "zai", "moonshot", "minimax", "xai", "openrouter"]);
    const by = Object.fromEntries(m.cards.map((c) => [c.engine, c]));
    expect(by.codex.badges).toEqual(["Sign in"]);
    expect(by.gemini.badges).toEqual(["Sign in", "API key"]);
    expect(by.gemini.acceptsKey).toBe(true);
    expect(by.moonshot).toMatchObject({ badges: ["API key"], acceptsKey: true, connected: false, stateLine: "Not connected" });
    expect(by.xai).toMatchObject({ stateLine: "Out of credit; add funds, then click Try again", canRetry: true });
    expect(by.zai).toMatchObject({ stateLine: "Limit reached, resets 15:40", canRetry: false });
    expect(by.openrouter).toMatchObject({ connected: true, keySaved: true, stateLine: "Connected" });
    expect(m.connectedCount).toBe(4);
    expect(m.countLine).toBe("4 connected");
  });
});
