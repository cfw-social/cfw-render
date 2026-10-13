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
    invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_settings" ? { allowBattery: true, startAtLogin: false } : cmd === "get_support_settings" ? { shareCrashReports: true } : cmd === "get_update_settings" ? { autoUpdate: true, available: false } : null));
    render(<Settings workerVersion="1.0.0" />);
    await waitFor(() => expect(box("Render on battery").checked).toBe(true));
    expect(box("Start at login").checked).toBe(false);
    expect(box("Automatic updates").disabled).toBe(true);
    expect(screen.getByText("Automatic updates arrive with signed releases.")).toBeTruthy();
    expect((screen.getByRole("button", { name: "Send logs to CFW…" }) as HTMLButtonElement).disabled).toBe(false);
    expect((screen.getByRole("button", { name: "Uninstall CFW Render…" }) as HTMLButtonElement).disabled).toBe(false);
    await waitFor(() => expect(box("Share crash reports").checked).toBe(true));
    expect(await screen.findByText("App 0.1.0 · Worker 1.0.0")).toBeTruthy();

    fireEvent.click(box("Start at login"));
    expect(invoke).toHaveBeenCalledWith("set_start_at_login", { enabled: true });
    fireEvent.click(box("Render on battery"));
    expect(invoke).toHaveBeenCalledWith("set_allow_battery", { allow: false });
    fireEvent.click(box("Share crash reports"));
    expect(invoke).toHaveBeenCalledWith("set_share_crash_reports", { enabled: false });
  });

  it("automatic updates: on and switchable once updates are available; the note goes away", async () => {
    invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_settings" ? { allowBattery: false, startAtLogin: true } : cmd === "get_support_settings" ? { shareCrashReports: true } : cmd === "get_update_settings" ? { autoUpdate: true, available: true } : null));
    render(<Settings workerVersion="1.0.0" />);
    await waitFor(() => expect(box("Automatic updates").disabled).toBe(false));
    expect(box("Automatic updates").checked).toBe(true);
    expect(screen.queryByText("Automatic updates arrive with signed releases.")).toBeNull();
    fireEvent.click(box("Automatic updates"));
    expect(invoke).toHaveBeenCalledWith("set_auto_update", { enabled: false });
    expect(box("Automatic updates").checked).toBe(false);
  });

  it("send logs previews the size, confirms, then shows the reference", async () => {
    invoke.mockImplementation((cmd: string) => Promise.resolve(
      cmd === "send_logs_preview" ? { sizeBytes: 2048, path: "/tmp/x" } : cmd === "send_logs" ? { reference: "LOG-AB12" } : cmd === "get_support_settings" ? { shareCrashReports: true } : { allowBattery: false, startAtLogin: false },
    ));
    render(<Settings workerVersion={null} />);
    fireEvent.click(screen.getByRole("button", { name: "Send logs to CFW…" }));
    expect(await screen.findByText(/Send 2\.0 KB of logs/)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByText("Sent. Reference: LOG-AB12. Quote it to CFW support.")).toBeTruthy();
  });

  it("uninstall opens a confirm dialog with the delete-outputs checkbox", async () => {
    invoke.mockResolvedValue({ allowBattery: false, startAtLogin: false, shareCrashReports: true });
    render(<Settings workerVersion={null} />);
    fireEvent.click(screen.getByRole("button", { name: "Uninstall CFW Render…" }));
    expect(screen.getByRole("dialog", { name: "Uninstall CFW Render?" })).toBeTruthy();
    expect(box("Also delete my rendered files").checked).toBe(false);
  });
});
