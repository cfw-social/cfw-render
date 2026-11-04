import { describe, expect, it } from "vitest";
import { asServerView, devBadge, showSwitch, withServer } from "./server";
import type { Health } from "./panel/model";

const dev = { active: "localDev", chosen: "localDev", server: "localhost:3005", restartNeeded: false, error: null, switchVisible: true };
const down: Health = { kind: "notRunning", tone: "bad", label: "Not running", callout: { title: "CFW Render isn't running", body: "x" }, waiting: 0 };

describe("server view", () => {
  it("only a real view counts; anything else is unknown, never Local dev", () => {
    expect(asServerView(dev)).toEqual(dev);
    for (const junk of [null, undefined, "localDev", {}, { active: "staging" }, { allowBattery: true }]) {
      expect(asServerView(junk)).toBeNull();
      expect(devBadge(asServerView(junk))).toBeNull();
    }
  });

  it("the switch shows only with the dev flag or in Local dev", () => {
    const prod = { ...dev, active: "production", chosen: "production", server: "app.cfw.social", switchVisible: false };
    expect(showSwitch(asServerView(prod))).toBe(false);
    expect(showSwitch(asServerView({ ...prod, switchVisible: "yes" }))).toBe(false);
    expect(showSwitch(asServerView({ ...prod, switchVisible: true }))).toBe(true);
    expect(showSwitch(asServerView({ ...dev, switchVisible: false }))).toBe(true);
    expect(showSwitch(null)).toBe(false);
  });

  it("badge and callout change only in Local dev", () => {
    expect(devBadge(asServerView(dev))).toBe("Local dev — localhost:3005");
    expect(devBadge(asServerView({ ...dev, server: null }))).toBe("Local dev — no server");
    expect(devBadge(asServerView({ ...dev, active: "production", server: "app.cfw.social" }))).toBeNull();
    expect(withServer(down, asServerView(dev)).callout?.body).toBe("Start it with pnpm dev:stack in cfw-social.");
    expect(withServer(down, null)).toBe(down);
    const ready: Health = { ...down, kind: "ready", callout: null };
    expect(withServer(ready, asServerView(dev))).toBe(ready);
  });
});
