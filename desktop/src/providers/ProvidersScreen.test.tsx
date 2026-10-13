// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => invoke(...a) }));
vi.mock("@tauri-apps/api/event", () => ({ listen: () => Promise.resolve(() => {}) }));

import { ProvidersScreen } from "./ProvidersScreen";

afterEach(cleanup);

describe("ProvidersScreen", () => {
  it("renders cards and wires sign-in and reorder", async () => {
    invoke.mockImplementation((cmd: string) =>
      Promise.resolve(
        cmd === "get_status"
          ? {
              status: { schema: 1, engines: [{ name: "codex", signedIn: true, limit: "ok" }, { name: "claude-code", signedIn: false }] },
              liveness: "Running",
              iconState: "Idle",
              tooltip: "",
              providerLine: "",
            }
          : undefined,
      ),
    );
    render(<ProvidersScreen />);
    expect(screen.getByText("AI Providers")).toBeTruthy();
    expect(await screen.findByText("1 connected")).toBeTruthy();
    expect(screen.getByText("Connected")).toBeTruthy();
    expect(screen.getAllByText("Not connected").length).toBe(7);
    expect(screen.getByText("Sign out")).toBeTruthy();

    fireEvent.click(screen.getAllByText("Sign in", { selector: "button" })[0]);
    expect(invoke).toHaveBeenCalledWith("provider_sign_in", { engine: "claude-code" });
    expect(await screen.findByText("Signing in…")).toBeTruthy();

    fireEvent.click(screen.getByLabelText("Move up: Claude"));
    expect(invoke).toHaveBeenCalledWith("set_engine_order", {
      order: ["claude-code", "codex", "gemini", "zai", "moonshot", "minimax", "xai", "openrouter"],
    });
  });

  it("saves a key and never shows it again", async () => {
    const KEY = "sk-secret-0123456789abcdef";
    invoke.mockReset();
    invoke.mockImplementation((cmd: string) =>
      Promise.resolve(
        cmd === "get_status"
          ? { status: { schema: 1, engines: [] }, liveness: "Running", iconState: "Idle", tooltip: "", providerLine: "" }
          : cmd === "provider_key_present"
            ? false
            : undefined,
      ),
    );
    render(<ProvidersScreen />);
    const input = screen.getByLabelText("OpenRouter API key") as HTMLInputElement;
    expect(input.type).toBe("password");
    fireEvent.change(input, { target: { value: KEY } });
    const card = screen.getByTestId("provider-openrouter");
    fireEvent.click(card.querySelector("button[type=submit]")!);
    expect(invoke).toHaveBeenCalledWith("provider_key_save", { engine: "openrouter", key: KEY });
    expect(await screen.findByText("Key saved")).toBeTruthy();
    expect(await screen.findByText("1 connected")).toBeTruthy();
    expect(document.body.innerHTML).not.toContain(KEY);
    expect(screen.queryByLabelText("OpenRouter API key")).toBeNull();
    expect(card.querySelector("[aria-label=Connected]")).toBeTruthy();

    fireEvent.click(screen.getAllByText("Get a key", { selector: "button" })[0]);
    expect(invoke).toHaveBeenCalledWith("open_provider_key_url", { engine: "gemini" });
  });
});
