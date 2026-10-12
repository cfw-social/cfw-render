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
    expect(screen.getByText("Not connected")).toBeTruthy();
    expect(screen.getByText("Sign out")).toBeTruthy();

    fireEvent.click(screen.getByText("Sign in", { selector: "button" }));
    expect(invoke).toHaveBeenCalledWith("provider_sign_in", { engine: "claude-code" });
    expect(await screen.findByText("Signing in…")).toBeTruthy();

    fireEvent.click(screen.getByLabelText("Move up: Claude"));
    expect(invoke).toHaveBeenCalledWith("set_engine_order", { order: ["claude-code", "codex"] });
  });
});
