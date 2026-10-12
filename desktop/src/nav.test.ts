import { describe, expect, it } from "vitest";
import { NAV_ITEMS } from "./nav";

describe("sidebar", () => {
  it("lists the four sections in order", () => {
    expect(NAV_ITEMS).toEqual(["Chat", "Renders on this Mac", "AI Providers", "Settings"]);
  });
});
