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
});

const current = () => screen.getByRole("main").getAttribute("data-section");
const location = (url: string) => act(async () => h.listeners["web-location"]({ payload: url }));

describe("main window", () => {
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
