// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";

const h = vi.hoisted(() => ({
  invoke: vi.fn(),
  listeners: {} as Record<string, (e: { payload: unknown }) => void>,
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => h.invoke(...a) }));
vi.mock("@tauri-apps/api/event", () => ({
  listen: (name: string, cb: (e: { payload: unknown }) => void) => {
    h.listeners[name] = cb;
    return Promise.resolve(() => {});
  },
}));

import { SetupScreen } from "./SetupScreen";

const KEY = "cfw_abcdefgh12345678";
const step = (payload: unknown) => act(async () => h.listeners["setup-step"]({ payload }));

beforeEach(() => {
  h.invoke.mockImplementation((cmd: string) =>
    Promise.resolve(
      cmd === "provider_status" ? false : cmd === "setup_tools_size" ? 180_000_000 : cmd === "get_setup_status" ? { installed: false, adoptable: false } : undefined,
    ),
  );
});
afterEach(() => {
  cleanup();
  h.invoke.mockReset();
});

describe("SetupScreen", () => {
  it("step 1: masks the key and refuses one that isn't a brand key", async () => {
    render(<SetupScreen />);
    const input = screen.getByLabelText("Brand key") as HTMLInputElement;
    expect(input.type).toBe("password");
    expect((screen.getByRole("button", { name: "Continue" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(input, { target: { value: "not a key" } });
    fireEvent.click(screen.getByRole("button", { name: "Continue" }));
    expect(screen.getByRole("alert").textContent).toContain("starts with cfw_");
    expect(h.invoke).not.toHaveBeenCalledWith("setup_install_tools");
    expect(h.invoke).not.toHaveBeenCalledWith("setup_adopt");
  });

  it("step 2 starts the tools download, waits for a sign-in, then step 3 runs setup without re-installing tools", async () => {
    render(<SetupScreen />);
    fireEvent.change(screen.getByLabelText("Brand key"), { target: { value: KEY } });
    fireEvent.click(screen.getByRole("button", { name: "Continue" }));

    expect(await screen.findByRole("heading", { name: "Sign in to an AI" })).toBeTruthy();
    expect(h.invoke).toHaveBeenCalledWith("setup_install_tools");
    expect(screen.getByText(/about 180 MB/)).toBeTruthy();
    const cont = () => screen.getByRole("button", { name: "Continue" }) as HTMLButtonElement;
    expect(cont().disabled).toBe(true);

    // ChatGPT waits for its sign-in tool; Claude can sign in straight away.
    await step({ step: "tools", state: "started", pct: 40 });
    expect(screen.getByText("Getting ready… 40%")).toBeTruthy();
    // a failed "result" during the tools phase is the tools step's own, not the end of setup
    await step({ step: "tools", state: "done" });
    await step({ step: "tools_result", state: "done", message: "Tools installed" });

    fireEvent.click(screen.getAllByRole("button", { name: "Sign in" })[0]);
    expect(h.invoke).toHaveBeenCalledWith("provider_sign_in", { engine: "claude-code" });
    await act(async () => h.listeners["provider-signin"]({ payload: { engine: "claude-code", state: "connected" } }));
    expect(screen.getByText("Signed in")).toBeTruthy();
    expect(cont().disabled).toBe(false);

    fireEvent.click(cont());
    expect(h.invoke).toHaveBeenCalledWith("setup_run", { brandKey: KEY, installTools: false });
    expect(await screen.findByRole("heading", { name: "Getting this Mac ready" })).toBeTruthy();
    await step({ step: "installing", state: "done" });
    await step({ step: "test_render", state: "started", pct: 50 });
    expect(screen.getByRole("progressbar", { name: "Test render" })).toBeTruthy();
    await step({ step: "ready", state: "done" });
    await step({ step: "result", state: "done" });
    expect(await screen.findByRole("heading", { name: "This Mac is ready" })).toBeTruthy();
    expect(screen.getByText("CFW Render stays in your menu bar.")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Open CFW Render" }));
    expect(h.invoke).toHaveBeenCalledWith("open_main", { section: "home" });
  });

  it("step 3 failure explains and offers Try again", async () => {
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "provider_status" ? true : cmd === "get_setup_status" ? { installed: false, adoptable: false } : undefined));
    render(<SetupScreen />);
    fireEvent.change(screen.getByLabelText("Brand key"), { target: { value: KEY } });
    fireEvent.click(screen.getByRole("button", { name: "Continue" }));
    await step({ step: "tools_result", state: "failed", message: "offline" });
    expect(await screen.findByText("Using the tools already on this Mac.")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Continue" }));
    await step({ step: "connecting", state: "failed", message: "CFW didn't accept that key.", action: "Copy it again from CFW." });
    expect(screen.getByRole("alert").textContent).toContain("CFW didn't accept that key. Copy it again from CFW.");
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(h.invoke).toHaveBeenLastCalledWith("setup_run", { brandKey: KEY, installTools: false });
  });

  it("adopts an existing install straight into step 3", async () => {
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_setup_status" ? { installed: false, adoptable: true } : undefined));
    render(<SetupScreen />);
    expect(await screen.findByRole("heading", { name: "Getting this Mac ready" })).toBeTruthy();
    expect(h.invoke).toHaveBeenCalledWith("setup_adopt");
  });
});
