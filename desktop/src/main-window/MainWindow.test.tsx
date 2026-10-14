// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";

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

describe("main window", () => {
  it("copies only the selected attempt identity and uses the public guide with offline fallback", async () => {
    const row = { shortCode: "R-FAIL", orderId: "order-1", attemptId: "attempt-old", brand: "Brand A", brandSlug: "brand-a", recipe: "reel", result: "failed", startedAt: "2026-10-11T10:00:00Z", finishedAt: "2026-10-11T10:05:00Z", directorLog: "order-1-123.out", reason: "private failure detail", extra: "not copied" };
    let finish!: () => void;
    const writeText = vi.fn((_text: string) => new Promise<void>((resolve) => { finish = resolve; }));
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    const actions = { openMain: vi.fn(), startWorker: vi.fn(), setPaused: vi.fn(), allowBattery: vi.fn(), runNow: vi.fn(), openLogs: vi.fn() };
    render(<Renders payload={payload({ ...workingStatus, recent: [{ ...row, attemptId: "attempt-new", result: "done", finishedAt: "2026-10-11T11:00:00Z" }, row] })} actions={actions} clock={() => NOW} />);
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
    expect(identity).toEqual({ orderId: "order-1", attemptId: "attempt-old", shortCode: "R-FAIL", brand: "Brand A", brandSlug: "brand-a", recipe: "reel", result: "failed", startedAt: row.startedAt, finishedAt: row.finishedAt, directorLog: row.directorLog });
    await act(async () => finish());
    expect(screen.getByRole("status").textContent).toBe("Copied");
    expect(actions.runNow).not.toHaveBeenCalled();
    expect(actions.startWorker).not.toHaveBeenCalled();
  });

  it("offers selectable instructions when clipboard access fails and leaves unknown identity null", async () => {
    vi.stubGlobal("navigator", { clipboard: { writeText: vi.fn().mockRejectedValue(new Error("denied")) } });
    const actions = { openMain: vi.fn(), startWorker: vi.fn(), setPaused: vi.fn(), allowBattery: vi.fn(), runNow: vi.fn(), openLogs: vi.fn() };
    render(<Renders payload={payload({ ...workingStatus, recent: [{ result: "stopped", finishedAt: "2026-10-11T11:00:00Z" }] })} actions={actions} clock={() => NOW} />);
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

  it("rail footer shows this Mac's state and pauses it", async () => {
    render(<MainWindow clock={() => NOW} />);
    expect(await screen.findByText("Priya's Mac")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Pause this Mac" }));
    expect(h.invoke).toHaveBeenCalledWith("set_paused", { paused: true });
  });
});
