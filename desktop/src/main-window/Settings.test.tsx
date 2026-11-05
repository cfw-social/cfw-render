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
  it("connection lists every brand, never '+N more'", () => {
    invoke.mockResolvedValue(null);
    const brands = Array.from({ length: 14 }, (_, i) => `Brand ${i + 1}`);
    render(<Settings workerVersion={null} connection={{ line: "Connected for all your brands (14)", keyLine: "Key: MacBook Pro (2)", brands, allBrands: true }} />);
    const list = screen.getByRole("list", { name: "Connection" });
    expect(list.querySelectorAll("li").length).toBe(14);
    expect(screen.getByText("Brand 14")).toBeTruthy();
    expect(screen.queryByText(/more$/)).toBeNull();
  });

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

  // A production run with CFW_RENDER_DEV_TOOLS=1 (or a debug build): the switch shows.
  const PROD = { active: "production", chosen: "production", server: "app.cfw.social", restartNeeded: false, error: null, switchVisible: true };
  const LOCAL = { active: "localDev", chosen: "localDev", server: "localhost:3005", restartNeeded: false, error: null, switchVisible: false };

  it("server switch: hidden for a plain production app, so normal users never see it", async () => {
    invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_server_profile" ? { ...PROD, switchVisible: false } : null));
    render(<Settings workerVersion={null} />);
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("get_server_profile"));
    expect(await screen.findByText("App 0.1.0 · Worker not installed")).toBeTruthy();
    expect(screen.queryByRole("radiogroup", { name: "Server" })).toBeNull();
    expect(screen.queryByText("Server")).toBeNull();
    // Production otherwise unchanged.
    expect((screen.getByRole("button", { name: "Uninstall CFW Render…" }) as HTMLButtonElement).disabled).toBe(false);
  });

  it("server switch: shown with the dev-tools flag", async () => {
    invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_server_profile" ? PROD : null));
    render(<Settings workerVersion={null} />);
    expect(await screen.findByRole("radiogroup", { name: "Server" })).toBeTruthy();
  });

  it("server switch: shown when already in Local dev, so it can be switched back", async () => {
    invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_server_profile" ? LOCAL : null));
    render(<Settings workerVersion={null} />);
    expect(await screen.findByRole("radiogroup", { name: "Server" })).toBeTruthy();
    expect((screen.getByRole("radio", { name: "Local dev" }) as HTMLInputElement).checked).toBe(true);
  });

  it("server switch: the Local dev note says AI sign-ins and provider keys are shared with production", async () => {
    invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_server_profile" ? LOCAL : null));
    render(<Settings workerVersion={null} />);
    await screen.findByRole("radiogroup", { name: "Server" });
    expect(screen.getByText(/AI sign-ins and provider keys are shared with production/)).toBeTruthy();
    expect(screen.queryByText(/production setup stays as it is/)).toBeNull();
  });
  const radio =(name: string) => screen.getByRole("radio", { name }) as HTMLInputElement;

  it("server switch: Production by default; Local dev is saved for the next start and offers Restart now", async () => {
    invoke.mockImplementation((cmd: string, args?: { server?: string }) =>
      Promise.resolve(
        cmd === "get_server_profile"
          ? PROD
          : cmd === "set_server_profile"
            ? { ...PROD, chosen: args?.server, restartNeeded: args?.server !== "production" }
            : null,
      ),
    );
    render(<Settings workerVersion={null} />);
    expect(await screen.findByRole("radiogroup", { name: "Server" })).toBeTruthy();
    await waitFor(() => expect(radio("Production").checked).toBe(true));
    expect(radio("Local dev").checked).toBe(false);
    expect(screen.queryByRole("button", { name: "Restart now" })).toBeNull();

    fireEvent.click(radio("Local dev"));
    expect(invoke).toHaveBeenCalledWith("set_server_profile", { server: "localDev" });
    expect(await screen.findByText("Restart CFW Render to switch to Local dev. Nothing changes until then.")).toBeTruthy();
    expect(radio("Local dev").checked).toBe(true);
    // Production stays usable until the restart: nothing switched halfway.
    expect((screen.getByRole("button", { name: "Uninstall CFW Render…" }) as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Restart now" }));
    expect(invoke).toHaveBeenCalledWith("restart_app");

    fireEvent.click(radio("Production"));
    expect(invoke).toHaveBeenCalledWith("set_server_profile", { server: "production" });
    await waitFor(() => expect(screen.queryByRole("button", { name: "Restart now" })).toBeNull());
  });

  it("server switch: a failed save says why and keeps the old choice", async () => {
    invoke.mockImplementation((cmd: string) =>
      cmd === "set_server_profile" ? Promise.reject("disk full") : Promise.resolve(cmd === "get_server_profile" ? PROD : null),
    );
    render(<Settings workerVersion={null} />);
    await waitFor(() => expect(radio("Production").checked).toBe(true));
    fireEvent.click(radio("Local dev"));
    expect((await screen.findByRole("alert")).textContent).toBe("Couldn't save the server choice: disk full");
    expect(radio("Production").checked).toBe(true);
  });

  it("in Local dev, Send logs and Uninstall are off, so the production install is never touched", async () => {
    invoke.mockImplementation((cmd: string) =>
      Promise.resolve(cmd === "get_server_profile" ? { active: "localDev", chosen: "localDev", server: "localhost:3005", restartNeeded: false, error: null } : null),
    );
    render(<Settings workerVersion={null} />);
    await waitFor(() => expect(radio("Local dev").checked).toBe(true));
    expect((screen.getByRole("button", { name: "Send logs to CFW…" }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole("button", { name: "Uninstall CFW Render…" }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getAllByText("Not available in Local dev. It would change the production setup.").length).toBe(2);
  });

  it("uninstall opens a confirm dialog with the delete-outputs checkbox", async () => {
    invoke.mockResolvedValue({ allowBattery: false, startAtLogin: false, shareCrashReports: true });
    render(<Settings workerVersion={null} />);
    fireEvent.click(screen.getByRole("button", { name: "Uninstall CFW Render…" }));
    expect(screen.getByRole("dialog", { name: "Uninstall CFW Render?" })).toBeTruthy();
    expect(box("Also delete my rendered files").checked).toBe(false);
  });
});
