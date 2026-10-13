import { describe, expect, it } from "vitest";
import { isWebSection, sectionFromId, sectionFromWebPath, slugFromWebPath } from "./nav";

describe("nav", () => {
  it("maps section ids, including the old chat id", () => {
    expect(sectionFromId("reviews")).toBe("reviews");
    expect(sectionFromId("providers")).toBe("providers");
    expect(sectionFromId("chat")).toBe("assistant");
    expect(sectionFromId("nope")).toBeNull();
    expect(sectionFromId("toString")).toBeNull();
    expect(sectionFromId(3)).toBeNull();
  });

  it("splits website sections from Mac sections", () => {
    expect(isWebSection("posts")).toBe(true);
    expect(isWebSection("renders")).toBe(false);
  });

  it("follows the website's location", () => {
    expect(sectionFromWebPath("/lumen-coffee", "lumen-coffee")).toBe("home");
    expect(sectionFromWebPath("/lumen-coffee/reviews/abc", "lumen-coffee")).toBe("reviews");
    expect(sectionFromWebPath("/lumen-coffee/settings/keys", "lumen-coffee")).toBeNull();
    expect(sectionFromWebPath("/other/posts", "lumen-coffee")).toBeNull();
    expect(slugFromWebPath("/lumen-coffee/posts")).toBe("lumen-coffee");
    expect(slugFromWebPath("/login")).toBeNull();
    expect(slugFromWebPath("/all")).toBeNull();
    expect(slugFromWebPath("/")).toBeNull();
  });
});
