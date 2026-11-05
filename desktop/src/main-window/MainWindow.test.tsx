// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import type { StatusFile } from "../status";

const h = vi.hoisted(() => ({
  listeners: {} as Record<string, (e: { payload: unknown }) => void>,
  invoke: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: h.invoke }));
vi.mock("@tauri-apps/api/event", () => ({
  listen: (name: string, cb: (e: { payload: unknown }) => void) => {
    h.listeners[name] = cb;
    return Promise.resolve(() => {});
  },
}));
vi.mock("@tauri-apps/api/app", () => ({ getVersion: () => Promise.resolve("0.1.0") }));

import { MainWindow } from "./MainWindow";
import { Renders } from "./Renders";
import { renderDebugInstructions, RENDER_DEBUG_GUIDE_URL } from "./render-debug";
import { NOW, payload, workingStatus } from "../panel/fixtures";

const BRANDS = { signedIn: true, brands: [{ name: "Lumen Coffee", slug: "lumen-coffee", isCurrent: true }, { name: "Atlas Bikes", slug: "atlas-bikes", isCurrent: false }] };

beforeEach(() => {
  localStorage.clear();
  h.invoke.mockImplementation((cmd: string) =>
    Promise.resolve(
      cmd === "get_status"
        ? payload(workingStatus)
        : cmd === "get_settings"
          ? { allowBattery: true, startAtLogin: false }
          : cmd === "web_brands"
            ? BRANDS
            : null,
    ),
  );
});
afterEach(() => {
  cleanup();
  h.invoke.mockReset();
  vi.unstubAllGlobals();
});

const current = () => screen.getByRole("main").getAttribute("data-section");
const location = (url: string) => act(async () => h.listeners["web-location"]({ payload: url }));

// One scale for this file's load wait. 90s expired while the bound suite shared the machine.
const LOAD_WAIT_SCALE = 8;
// The owner's saved brand ("gone-brand") is no longer in the list; "atlas-bikes" is the current one.
const ATLAS_CURRENT = { signedIn: true, brands: BRANDS.brands.map((b) => ({ ...b, isCurrent: b.slug === "atlas-bikes" })) };
const shown = () => h.invoke.mock.calls.filter(([cmd]) => cmd === "web_show").map(([, args]) => args);
/** Every other call answers as usual; `web_brands` waits until the returned function is called. */
const holdBrands = () => {
  let reply!: (w: unknown) => void;
  const pending = new Promise((resolve) => { reply = resolve; });
  h.invoke.mockImplementation((cmd: string) => (cmd === "web_brands" ? pending : Promise.resolve(cmd === "get_status" ? payload(workingStatus) : null)));
  return (w: unknown) => act(async () => reply(w));
};

describe("main window", () => {
  it("copies only the selected attempt identity and uses the public guide with offline fallback", async () => {
    // Actual worker serialization after failed A and successful B reuse scratch.
    // This test-only process uses fake engines/network and test-owned cleanup.
    const { execFileSync } = await vi.importActual<{
      execFileSync(file: string, args: string[], options: { encoding: "utf8"; timeout: number }): string;
    }>("node:child_process");
    const output = execFileSync("bash", ["../test/run-tests.sh", "--recent-identity"], { encoding: "utf8", timeout: 90_000 * LOAD_WAIT_SCALE });
    const fixture = output.split("\n").find((line) => line.startsWith("STATUS_FIXTURE="));
    expect(fixture).toBeDefined();
    const status: StatusFile = JSON.parse(fixture!.slice("STATUS_FIXTURE=".length));
    expect(status.recent).toHaveLength(2);
    const [newer, older] = status.recent!;
    expect([newer.attemptId, older.attemptId]).toEqual(["attempt-B", "attempt-A"]);
    expect(older.startedAt).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    expect(older.directorLog).not.toBe(newer.directorLog);
    const row = { ...older, reason: "private failure detail", extra: "not copied" };
    let finish!: () => void;
    const writeText = vi.fn((_text: string) => new Promise<void>((resolve) => { finish = resolve; }));
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    const actions = { openMain: vi.fn(), startWorker: vi.fn(), setPaused: vi.fn(), allowBattery: vi.fn(), runNow: vi.fn(), openLogs: vi.fn() };
    render(<Renders payload={payload({ ...status, recent: [newer, row] })} actions={actions} clock={() => Date.parse(newer.finishedAt!)} />);
    fireEvent.click(screen.getByRole("button", { name: /R-FAIL.*Didn't finish/ }));
    const button = screen.getByRole("button", { name: "Copy debug instructions" });
    fireEvent.click(button);
    expect(button.hasAttribute("disabled")).toBe(true);
    fireEvent.click(button);
    expect(writeText).toHaveBeenCalledTimes(1);
    const text = writeText.mock.calls[0][0];
    expect(text).toContain(RENDER_DEBUG_GUIDE_URL);
    expect(text).toContain("$HOME/CFW Render/app/lib/render-debug.md");
    expect(text).toContain("Ask before fixes, paid calls or retries");
    expect(text).not.toContain(row.reason);
    expect(text).not.toContain("not copied");
    const identity = JSON.parse(text.split("Render identity (JSON):\n")[1]);
    expect(text).not.toContain("attempt-B");
    expect(text).not.toContain(newer.directorLog!);
    expect(identity).toEqual({ orderId: "order-1", attemptId: "attempt-A", shortCode: "R-FAIL", brand: "Brand A", brandSlug: "brand-a", recipe: "reel", result: "failed", startedAt: row.startedAt, finishedAt: row.finishedAt, directorLog: row.directorLog });
    await act(async () => finish());
    expect(screen.getByRole("status").textContent).toBe("Copied");
    expect(actions.runNow).not.toHaveBeenCalled();
    expect(actions.startWorker).not.toHaveBeenCalled();
    // Stage-range alone took 164s under load. Stay above the execFileSync ceiling
    // (90s * scale) so this test is not cut while that script is still allowed to run.
  }, 90_000 * LOAD_WAIT_SCALE + 60_000);

  it("offers selectable instructions when clipboard access fails and leaves unknown identity null", async () => {
    vi.stubGlobal("navigator", { clipboard: { writeText: vi.fn().mockRejectedValue(new Error("denied")) } });
    const actions = { openMain: vi.fn(), startWorker: vi.fn(), setPaused: vi.fn(), allowBattery: vi.fn(), runNow: vi.fn(), openLogs: vi.fn() };
    render(<Renders payload={payload({ ...workingStatus, recent: [{ result: "stopped", finishedAt: "2026-10-11T11:00:00Z" }] })} actions={actions} clock={() => NOW} />);
    fireEvent.click(screen.getByRole("button", { name: /Render.*Stopped/ }));
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Copy debug instructions" })));
    const textarea = screen.getByRole("textbox", { name: "Copy debug instructions" }) as HTMLTextAreaElement;
    expect(textarea.readOnly).toBe(true);
    expect(textarea.value).toContain('"orderId": null');
    expect(textarea.value).toContain('"attemptId": null');
    expect(renderDebugInstructions({})).toContain('"startedAt": null');
    expect(screen.getByRole("status").textContent).toContain("Couldn't copy");
  });
  it("opens on Home showing the website, and Mac pages hide it", async () => {
    render(<MainWindow clock={() => NOW} />);
    expect(current()).toBe("home");
    expect(h.invoke).toHaveBeenCalledWith("web_show", { section: "home", slug: null });
    // asks for the brand list straight away, so the switcher doesn't wait on the website
    expect(await screen.findByText("Lumen Coffee")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "Renders" }));
    expect(current()).toBe("renders");
    expect(h.invoke).toHaveBeenCalledWith("web_hide");
    expect(await screen.findByRole("heading", { name: "Renders on this Mac" })).toBeTruthy();
    expect(screen.getByText("Spotlight reel")).toBeTruthy();

    // once the brand list arrives, pages open for that brand
    fireEvent.click(screen.getByRole("button", { name: "Reviews" }));
    expect(h.invoke).toHaveBeenLastCalledWith("web_show", { section: "reviews", slug: "lumen-coffee" });
    expect(localStorage.getItem("cfw.brand")).toBe("lumen-coffee");
  });

  it("follows the website: brand from the URL, brand list, highlighted page", async () => {
    render(<MainWindow clock={() => NOW} />);
    await location("https://app.cfw.social/lumen-coffee/reviews");
    expect(h.invoke).toHaveBeenCalledWith("web_brands");
    expect(current()).toBe("reviews");
    expect(screen.getByRole("button", { name: "Reviews" }).getAttribute("aria-current")).toBe("page");
    expect(await screen.findByText("Lumen Coffee")).toBeTruthy();

    // switching brand keeps the page and remembers the brand
    fireEvent.click(screen.getByRole("button", { name: "Switch brand" }));
    fireEvent.click(screen.getByRole("menuitemradio", { name: "Atlas Bikes" }));
    expect(h.invoke).toHaveBeenLastCalledWith("web_show", { section: "reviews", slug: "atlas-bikes" });
    expect(localStorage.getItem("cfw.brand")).toBe("atlas-bikes");
  });

  it("signed out of CFW: offers sign-in in the rail (only once the website says so)", async () => {
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "web_brands" ? { signedIn: false, brands: [] } : cmd === "get_status" ? payload(workingStatus) : null));
    render(<MainWindow clock={() => NOW} />);
    await act(async () => {});
    expect(screen.queryByRole("button", { name: "Sign in to CFW" })).toBeNull();
    await location("https://app.cfw.social/login");
    fireEvent.click(screen.getByRole("button", { name: "Sign in to CFW" }));
    expect(h.invoke).toHaveBeenLastCalledWith("web_show", { section: "login", slug: null });
  });

  it("routes the navigate event (old chat id → Assistant) and ignores junk", async () => {
    render(<MainWindow clock={() => NOW} />);
    await act(async () => h.listeners.navigate({ payload: "providers" }));
    expect(current()).toBe("providers");
    expect(screen.getByRole("heading", { name: "AI providers" })).toBeTruthy();
    await act(async () => h.listeners.navigate({ payload: "bogus" }));
    expect(current()).toBe("providers");
    await act(async () => h.listeners.navigate({ payload: "chat" }));
    expect(current()).toBe("assistant");
    fireEvent.click(screen.getByRole("button", { name: "Settings" }));
    expect(current()).toBe("settings");
  });

  it.each(["rail", "renders"] as const)("offline owner pause: %s still offers Resume and clears the local pause", async (surface) => {
    const status = { ...workingStatus, cfwReach: "unreachable" as const, computer: { ...workingStatus.computer, paused: true, pauseReason: "owner" } };
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_status" ? payload(status) : cmd === "web_brands" ? BRANDS : null));
    render(<MainWindow clock={() => NOW} />);
    expect(await screen.findByText("Offline")).toBeTruthy();
    if (surface === "renders") {
      fireEvent.click(screen.getByRole("button", { name: "Renders" }));
      expect(screen.getByRole("alert").textContent).toContain("Can't reach CFW");
    }
    const controls = within(screen.getByRole(surface === "rail" ? "complementary" : "main"));
    expect(controls.queryByRole("button", { name: "Pause this Mac" })).toBeNull();
    fireEvent.click(controls.getByRole("button", { name: "Resume this Mac" }));
    expect(h.invoke).toHaveBeenCalledWith("set_paused", { paused: false });
  });

  it("rail footer shows this Mac's state and pauses it", async () => {
    render(<MainWindow clock={() => NOW} />);
    expect(await screen.findByText("Priya's Mac")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Pause this Mac" }));
    expect(h.invoke).toHaveBeenCalledWith("set_paused", { paused: true });
  });

  it("a saved brand that no longer exists: opens the page again for the current brand, once", async () => {
    localStorage.setItem("cfw.brand", "gone-brand");
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_status" ? payload(workingStatus) : cmd === "web_brands" ? ATLAS_CURRENT : null));
    render(<MainWindow clock={() => NOW} />);
    await act(async () => {});
    expect(shown()).toEqual([{ section: "home", slug: "gone-brand" }, { section: "home", slug: "atlas-bikes" }]);
    expect(localStorage.getItem("cfw.brand")).toBe("atlas-bikes");

    // the reopened page reports its address: the brand is in the list, so nothing opens again
    await location("https://app.cfw.social/atlas-bikes");
    expect(h.invoke.mock.calls.filter(([cmd]) => cmd === "web_brands")).toHaveLength(2);
    expect(shown()).toHaveLength(2);
  });

  it("reopens the section the owner is on, and only once when the dead page reports its address too", async () => {
    localStorage.setItem("cfw.brand", "gone-brand");
    const reply = holdBrands();
    render(<MainWindow clock={() => NOW} />);
    await location("https://app.cfw.social/gone-brand/reviews");
    expect(current()).toBe("reviews");
    // two brand-list requests are waiting (start-up and the page's address), both get the same answer
    await reply(ATLAS_CURRENT);
    expect(shown()).toEqual([{ section: "home", slug: "gone-brand" }, { section: "reviews", slug: "atlas-bikes" }]);
    expect(current()).toBe("reviews");
  });

  it("a saved brand that is still in the list is left alone", async () => {
    localStorage.setItem("cfw.brand", "atlas-bikes");
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_status" ? payload(workingStatus) : cmd === "web_brands" ? ATLAS_CURRENT : null));
    render(<MainWindow clock={() => NOW} />);
    await act(async () => {});
    expect(await screen.findByText("Atlas Bikes")).toBeTruthy();
    expect(shown()).toEqual([{ section: "home", slug: "atlas-bikes" }]);
    expect(localStorage.getItem("cfw.brand")).toBe("atlas-bikes");
  });

  it("a stale brand is replaced quietly while the owner is on a Mac page", async () => {
    localStorage.setItem("cfw.brand", "gone-brand");
    const reply = holdBrands();
    render(<MainWindow clock={() => NOW} />);
    fireEvent.click(screen.getByRole("button", { name: "Renders" }));
    expect(current()).toBe("renders");
    await reply(ATLAS_CURRENT);
    expect(localStorage.getItem("cfw.brand")).toBe("atlas-bikes");
    expect(shown()).toEqual([{ section: "home", slug: "gone-brand" }]);
    expect(current()).toBe("renders");
    // the website view was hidden once, by the click; the reply does not hide it again
    expect(h.invoke.mock.calls.filter(([cmd]) => cmd === "web_hide")).toHaveLength(1);

    // coming back to the website uses the real brand
    fireEvent.click(screen.getByRole("button", { name: "Home" }));
    expect(h.invoke).toHaveBeenLastCalledWith("web_show", { section: "home", slug: "atlas-bikes" });
  });

  it.each(["all", "login"])("a stale brand is replaced without moving the website off its /%s page", async (page) => {
    localStorage.setItem("cfw.brand", "gone-brand");
    const reply = holdBrands();
    render(<MainWindow clock={() => NOW} />);
    await location(`https://app.cfw.social/${page}`);
    await reply(ATLAS_CURRENT);
    expect(localStorage.getItem("cfw.brand")).toBe("atlas-bikes");
    expect(shown()).toEqual([{ section: "home", slug: "gone-brand" }]);
  });

  it.each(["/runs", "/admin/brands", "/privacy", "/help", "/connect", "/c/atlas-bikes"])("a website page that is not a brand (%s) is not mistaken for one", async (path) => {
    localStorage.setItem("cfw.brand", "atlas-bikes");
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_status" ? payload(workingStatus) : cmd === "web_brands" ? ATLAS_CURRENT : null));
    render(<MainWindow clock={() => NOW} />);
    await location("https://app.cfw.social/atlas-bikes/reviews");
    expect(current()).toBe("reviews");
    // a full page load of one of the website's own pages (rail Refresh, a GET form), then the brand list
    const reply = holdBrands();
    await location(`https://app.cfw.social${path}`);
    await reply(ATLAS_CURRENT);
    expect(shown()).toEqual([{ section: "home", slug: "atlas-bikes" }]);
    expect(localStorage.getItem("cfw.brand")).toBe("atlas-bikes");
    expect(current()).toBe("reviews");
  });
});
