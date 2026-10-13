// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => invoke(...a) }));
vi.mock("@tauri-apps/api/event", () => ({ listen: () => Promise.resolve(() => {}) }));

import { SetupScreen } from "./SetupScreen";

afterEach(cleanup);

describe("SetupScreen", () => {
  it("masks the key, checks consent, and blocks Connect with no engine", async () => {
    invoke.mockImplementation((cmd: string) =>
      Promise.resolve(
        cmd === "get_status"
          ? { status: { schema: 1, engines: [{ name: "codex", signedIn: false }] }, liveness: "Running", iconState: "Idle", tooltip: "", providerLine: "" }
          : cmd === "setup_tools_size"
            ? 412_000_000
            : cmd === "get_setup_status"
              ? { installed: false, adoptable: false }
              : undefined,
      ),
    );
    render(<SetupScreen />);
    expect((screen.getByLabelText("Brand key") as HTMLInputElement).type).toBe("password");
    expect(await screen.findByText(/about 412 MB/)).toBeTruthy();
    expect((screen.getByRole("checkbox") as HTMLInputElement).checked).toBe(true);
    expect(screen.getByText("Sign in to ChatGPT or Claude to continue")).toBeTruthy();
    expect((screen.getByRole("button", { name: "Connect" }) as HTMLButtonElement).disabled).toBe(true);
    expect(invoke).not.toHaveBeenCalledWith("setup_adopt");
  });
});
