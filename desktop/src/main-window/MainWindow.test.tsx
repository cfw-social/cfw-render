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
import { sectionFromId } from "../nav";
import { NOW, payload, workingStatus } from "../panel/fixtures";

beforeEach(() => {
  h.invoke.mockImplementation((cmd: string) =>
    Promise.resolve(cmd === "get_status" ? payload(workingStatus) : cmd === "get_settings" ? { allowBattery: true, startAtLogin: false } : cmd === "chat_brands" ? [{ slug: "brand-a", name: "Brand A" }] : null),
  );
});
afterEach(() => {
  cleanup();
  h.invoke.mockReset();
});

const current = () => screen.getByRole("main").getAttribute("data-section");

describe("main window sidebar", () => {
  it("maps section ids", () => {
    expect(sectionFromId("providers")).toBe("providers");
    expect(sectionFromId("nope")).toBeNull();
    expect(sectionFromId(3)).toBeNull();
  });

  it("routes by navigate event and by clicks", async () => {
    render(<MainWindow clock={() => NOW} />);
    expect(current()).toBe("renders");
    await act(async () => h.listeners.navigate({ payload: "providers" }));
    expect(current()).toBe("providers");
    // The real AI Providers screen is mounted (its heading + the cards).
    expect(screen.getByRole("heading", { name: "AI Providers" })).toBeTruthy();
    await act(async () => h.listeners.navigate({ payload: "bogus" }));
    expect(current()).toBe("providers");
    fireEvent.click(screen.getByText("Chat"));
    expect(current()).toBe("chat");
    expect(screen.getByRole("heading", { name: "Chat" })).toBeTruthy();
    expect(await screen.findByLabelText("Brand")).toBeTruthy();
    fireEvent.click(screen.getByText("Settings"));
    expect(current()).toBe("settings");
    fireEvent.click(screen.getByText("Renders on this Mac"));
    expect(await screen.findByText("R-7KQ4 · Brand A")).toBeTruthy();
    // all four recent entries in the last 24h, not just 3
    for (const c of ["R-OLD", "R-6TT1", "R-6TT2", "R-6TT3"]) expect(screen.getByText(new RegExp(c))).toBeTruthy();
  });
});
