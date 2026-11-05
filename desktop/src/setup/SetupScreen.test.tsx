// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";

const h = vi.hoisted(() => ({
  invoke: vi.fn(),
  listeners: {} as Record<string, (e: { payload: unknown }) => void>,
  fetch: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => h.invoke(...a) }));
vi.mock("@tauri-apps/api/event", () => ({
  listen: (name: string, cb: (e: { payload: unknown }) => void) => {
    h.listeners[name] = cb;
    return Promise.resolve(() => {});
  },
}));

import { SetupScreen } from "./SetupScreen";

const RENDER_KEY = "cfw_render_abcdefghijklmnop";
const CODE = {
  deviceCode: "d".repeat(43),
  userCode: "ABCD-EFGH",
  verifyUrl: "https://app.cfw.social/connect?code=ABCD-EFGH",
  interval: 1,
  expiresIn: 60,
};
const step = (payload: unknown) => act(async () => h.listeners["setup-step"]({ payload }));

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

beforeEach(() => {
  h.fetch.mockReset();
  vi.stubGlobal("fetch", h.fetch);
  h.invoke.mockImplementation((cmd: string) =>
    Promise.resolve(
      cmd === "provider_status"
        ? false
        : cmd === "setup_tools_size"
          ? 180_000_000
          : cmd === "get_setup_status"
            ? { installed: false, adoptable: false }
            : cmd === "connect_api_base"
              ? "https://app.cfw.social"
              : undefined,
    ),
  );
  h.fetch
    .mockResolvedValueOnce(jsonResponse(CODE))
    .mockResolvedValue(jsonResponse({ status: "approved", key: RENDER_KEY, brandSlug: "acme" }));
});
afterEach(() => {
  cleanup();
  h.invoke.mockReset();
  vi.unstubAllGlobals();
});

/** Approval can paint the AI step before the short code is observable (React 18 batching). */
async function approveConnect() {
  await waitFor(() =>
    expect(h.invoke).toHaveBeenCalledWith("connect_store_worker_key", { key: RENDER_KEY, brandSlug: "acme" }),
  );
  expect(await screen.findByRole("heading", { name: "Sign in to an AI" })).toBeTruthy();
}

describe("SetupScreen", () => {
  it("step 1: starts browser-approval connect with no brand-key paste field", async () => {
    render(<SetupScreen />);
    expect(screen.queryByLabelText("Brand key")).toBeNull();
    await waitFor(() => expect(h.fetch.mock.calls.some((c) => String(c[0]).endsWith("/api/v1/connect/code"))).toBe(true));
    await waitFor(() => expect(h.invoke).toHaveBeenCalledWith("open_url", { url: CODE.verifyUrl }));
    await approveConnect();
    // Main path never asks to paste a cfw_ brand key.
    expect(screen.queryByLabelText("Brand key")).toBeNull();
    expect(screen.queryByPlaceholderText("cfw_…")).toBeNull();
  });

  it("step 2 starts the tools download after approval, waits for a sign-in, then step 3 runs setup with the render key", async () => {
    render(<SetupScreen />);
    await approveConnect();

    expect(h.invoke).toHaveBeenCalledWith("setup_install_tools");
    expect(screen.getByText(/about 180 MB/)).toBeTruthy();
    const cont = () => screen.getByRole("button", { name: "Continue" }) as HTMLButtonElement;
    expect(cont().disabled).toBe(true);

    await step({ step: "tools", state: "started", pct: 40 });
    expect(screen.getByText("Getting ready… 40%")).toBeTruthy();
    await step({ step: "tools", state: "done" });
    await step({ step: "tools_result", state: "done", message: "Tools installed" });

    fireEvent.click(screen.getAllByRole("button", { name: "Sign in" })[0]);
    expect(h.invoke).toHaveBeenCalledWith("provider_sign_in", { engine: "claude-code" });
    await act(async () => h.listeners["provider-signin"]({ payload: { engine: "claude-code", state: "connected" } }));
    expect(screen.getByText("Signed in")).toBeTruthy();
    expect(cont().disabled).toBe(false);

    fireEvent.click(cont());
    expect(h.invoke).toHaveBeenCalledWith("setup_run", { brandKey: RENDER_KEY, installTools: false });
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
    h.invoke.mockImplementation((cmd: string) =>
      Promise.resolve(
        cmd === "provider_status"
          ? true
          : cmd === "get_setup_status"
            ? { installed: false, adoptable: false }
            : cmd === "connect_api_base"
              ? "https://app.cfw.social"
              : undefined,
      ),
    );
    render(<SetupScreen />);
    await approveConnect();
    await step({ step: "tools_result", state: "failed", message: "offline" });
    expect(await screen.findByText("Using the tools already on this Mac.")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Continue" }));
    await step({ step: "connecting", state: "failed", message: "CFW didn't accept that key.", action: "Copy it again from CFW." });
    expect(screen.getByRole("alert").textContent).toContain("CFW didn't accept that key. Copy it again from CFW.");
    const retry = screen.getByRole("button", { name: "Try again" }) as HTMLButtonElement;
    expect(retry.disabled).toBe(false);
    const before = h.invoke.mock.calls.filter(([cmd]) => cmd === "setup_run").length;
    fireEvent.click(retry);
    expect(h.invoke.mock.calls.filter(([cmd]) => cmd === "setup_run")).toHaveLength(before + 1);
    expect(h.invoke).toHaveBeenLastCalledWith("setup_run", { brandKey: RENDER_KEY, installTools: false });
  });

  it("follows a setup the main window started (Use all my brands) straight into step 3", async () => {
    h.fetch.mockReset();
    h.fetch.mockResolvedValue(jsonResponse({ status: "pending" }));
    render(<SetupScreen />);
    expect(screen.queryByLabelText("Brand key")).toBeNull();
    await act(async () => h.listeners["setup-external-run"]({ payload: null }));
    expect(await screen.findByRole("heading", { name: "Getting this Mac ready" })).toBeTruthy();
    await step({ step: "connecting", state: "started", message: "Connecting to CFW" });
    expect(screen.getByText("Connecting to CFW")).toBeTruthy();
    expect(h.invoke).not.toHaveBeenCalledWith("setup_run", expect.anything());
  });

  it.each(["failed", "cancelled"])("retries external account setup after %s without asking for a pasted key", async (state) => {
    h.fetch.mockReset();
    h.fetch.mockResolvedValue(jsonResponse({ status: "pending" }));
    render(<SetupScreen />);
    await act(async () => h.listeners["setup-external-run"]({ payload: null }));
    await step({ step: "result", state: "failed", message: state });
    const retry = screen.getByRole("button", { name: "Try again" }) as HTMLButtonElement;
    expect(retry.disabled).toBe(false);
    fireEvent.click(retry);
    expect(h.invoke.mock.calls.filter(([cmd]) => cmd === "setup_with_account")).toHaveLength(1);
    expect(h.invoke).not.toHaveBeenCalledWith("setup_run", expect.anything());
    await step({ step: "result", state: "failed", message: "Still offline" });
    fireEvent.click(screen.getByRole("button", { name: "Back" }));
    expect(h.invoke).toHaveBeenLastCalledWith("open_main", { section: "renders" });
  });

  it("adopts an existing install straight into step 3", async () => {
    h.fetch.mockReset();
    h.invoke.mockImplementation((cmd: string) =>
      Promise.resolve(cmd === "get_setup_status" ? { installed: false, adoptable: true } : undefined),
    );
    render(<SetupScreen />);
    expect(await screen.findByRole("heading", { name: "Getting this Mac ready" })).toBeTruthy();
    expect(h.invoke).toHaveBeenCalledWith("setup_adopt");
    expect(h.invoke).not.toHaveBeenCalledWith("connect_api_base");
  });

  it("shows denied and lets the owner start again", async () => {
    h.fetch.mockReset();
    h.fetch.mockResolvedValueOnce(jsonResponse(CODE)).mockResolvedValue(jsonResponse({ status: "denied" }));
    render(<SetupScreen />);
    expect(await screen.findByRole("alert")).toBeTruthy();
    expect(screen.getByRole("alert").textContent).toMatch(/denied/i);
    expect(screen.queryByLabelText("Brand key")).toBeNull();

    const nextCode = {
      ...CODE,
      userCode: "WXYZ-2345",
      verifyUrl: "https://app.cfw.social/connect?code=WXYZ-2345",
    };
    h.fetch.mockReset();
    h.fetch
      .mockResolvedValueOnce(jsonResponse(nextCode))
      .mockResolvedValue(jsonResponse({ status: "approved", key: RENDER_KEY, brandSlug: "acme" }));
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => expect(h.invoke).toHaveBeenCalledWith("open_url", { url: nextCode.verifyUrl }));
    await waitFor(() =>
      expect(h.invoke).toHaveBeenCalledWith("connect_store_worker_key", { key: RENDER_KEY, brandSlug: "acme" }),
    );
    expect(await screen.findByRole("heading", { name: "Sign in to an AI" })).toBeTruthy();
  });

  it("Back from AI revokes the Keychain key before minting a new connect code", async () => {
    render(<SetupScreen />);
    await approveConnect();
    expect(screen.getByRole("heading", { name: "Sign in to an AI" })).toBeTruthy();

    const nextCode = {
      ...CODE,
      userCode: "BACK-1234",
      verifyUrl: "https://app.cfw.social/connect?code=BACK-1234",
      deviceCode: "e".repeat(43),
    };
    const nextKey = "cfw_render_replacedkey0001";
    h.fetch.mockReset();
    h.fetch
      .mockResolvedValueOnce(jsonResponse(nextCode))
      .mockResolvedValue(jsonResponse({ status: "approved", key: nextKey, brandSlug: "acme" }));
    h.invoke.mockImplementation((cmd: string) =>
      Promise.resolve(
        cmd === "provider_status"
          ? false
          : cmd === "setup_tools_size"
            ? 180_000_000
            : cmd === "get_setup_status"
              ? { installed: false, adoptable: false }
              : cmd === "connect_api_base"
                ? "https://app.cfw.social"
                : cmd === "connect_revoke_worker_key"
                  ? undefined
                  : undefined,
      ),
    );

    fireEvent.click(screen.getByRole("button", { name: "Back" }));
    await waitFor(() => expect(h.invoke).toHaveBeenCalledWith("connect_revoke_worker_key"));
    await waitFor(() => expect(h.invoke).toHaveBeenCalledWith("open_url", { url: nextCode.verifyUrl }));
    await waitFor(() =>
      expect(h.invoke).toHaveBeenCalledWith("connect_store_worker_key", { key: nextKey, brandSlug: "acme" }),
    );
  });
});
