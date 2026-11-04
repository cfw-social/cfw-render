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

  it("never takes a page the website owns for a brand", () => {
    expect(slugFromWebPath("/runs")).toBeNull();
    expect(slugFromWebPath("/admin/brands")).toBeNull();
    expect(slugFromWebPath("/c/atlas-bikes")).toBeNull();
    expect(slugFromWebPath("/privacy")).toBeNull();
    expect(slugFromWebPath("/connect")).toBeNull();
    // the names cfw-social reserves in src/proxy.ts RESERVED_SLUGS that a slug could be spelled like
    const reserved = [
      "login", "register", "signup", "forgot-password", "reset-password", "logout", "invite", "auth", "oauth",
      "icons", "images", "public", "compose", "compositions", "settings", "onboarding", "templates",
      "posts", "agents", "workspaces", "recipes", "analytics", "repurpose", "inbox", "reviews",
      "api", "admin", "a", "c", "s", "upload", "unauthorized", "all", "runs", "connect",
      "account", "help", "pricing", "legal", "blog", "docs", "privacy", "terms",
    ];
    for (const name of reserved) expect(slugFromWebPath(`/${name}/x`), name).toBeNull();
    // dotted and "_" names can't be a slug at all
    for (const name of ["_next", "_dev", "favicon.ico", "sw.js", "install.md", ".well-known"]) expect(slugFromWebPath(`/${name}`), name).toBeNull();
    // real brands, and a brand's own pages with a reserved word further along, still count
    expect(slugFromWebPath("/atlas-bikes")).toBe("atlas-bikes");
    expect(slugFromWebPath("/lumen-coffee/runs")).toBe("lumen-coffee");
  });
});
