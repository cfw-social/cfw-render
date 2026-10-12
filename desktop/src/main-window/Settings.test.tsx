// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";

const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
vi.mock("@tauri-apps/api/app", () => ({ getVersion: () => Promise.resolve("0.1.0") }));

import { Settings } from "./Settings";

afterEach(() => {
  cleanup();
  invoke.mockReset();
});

const box = (name: string) => screen.getByRole("checkbox", { name }) as HTMLInputElement;

describe("Settings", () => {
  it("reads checkbox state from get_settings and shows disabled items", async () => {
    invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_settings" ? { allowBattery: true, startAtLogin: false } : null));
    render(<Settings workerVersion="1.0.0" />);
    await waitFor(() => expect(box("Render on battery").checked).toBe(true));
    expect(box("Start at login").checked).toBe(false);
    expect(box("Automatic updates").disabled).toBe(true);
    expect(screen.getByText("Automatic updates arrive with signed releases.")).toBeTruthy();
    expect((screen.getByRole("button", { name: "Send logs to CFW…" }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole("button", { name: "Uninstall CFW Render…" }) as HTMLButtonElement).disabled).toBe(true);
    expect(await screen.findByText("App 0.1.0 · Worker 1.0.0")).toBeTruthy();

    fireEvent.click(box("Start at login"));
    expect(invoke).toHaveBeenCalledWith("set_start_at_login", { enabled: true });
    fireEvent.click(box("Render on battery"));
    expect(invoke).toHaveBeenCalledWith("set_allow_battery", { allow: false });
  });
});
