// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { Panel, type PanelActions } from "./Panel";
import { NOW, payload, workingStatus } from "./fixtures";
import type { StatusFile } from "../status";

afterEach(cleanup);

const mk = (): PanelActions => ({ openMain: vi.fn(), startWorker: vi.fn(), setPaused: vi.fn(), allowBattery: vi.fn(), runNow: vi.fn(), openLogs: vi.fn() });

describe("Panel", () => {
  it("working: shows what's rendering, what's next, what finished, and wires Pause / Open", () => {
    const actions = mk();
    render(<Panel payload={payload(workingStatus)} actions={actions} clock={() => NOW} />);
    expect(screen.getByText("Rendering")).toBeTruthy();
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.getByText("Spotlight reel")).toBeTruthy();
    expect(screen.getByText("Brand A · R-7KQ4")).toBeTruthy();
    expect(screen.getByText("step 5 of 7")).toBeTruthy();
    expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("62");
    expect(screen.getByText("Carousel")).toBeTruthy();
    // newest three finished, failed ones offer "See why"
    expect(screen.getByText("R-6TT3")).toBeTruthy();
    expect(screen.queryByText("R-OLD")).toBeNull();
    fireEvent.click(screen.getByText("See why"));
    expect(actions.openMain).toHaveBeenCalledWith("renders");
    fireEvent.click(screen.getByText("Open CFW Render"));
    expect(actions.openMain).toHaveBeenCalledTimes(2);
    fireEvent.click(screen.getByText("Pause"));
    expect(actions.setPaused).toHaveBeenCalledWith(true);
  });

  it("not running: says so and offers Start", () => {
    const actions = mk();
    render(<Panel payload={payload(workingStatus, { liveness: "NotRunning" })} actions={actions} clock={() => NOW} />);
    expect(screen.getByRole("alert").textContent).toContain("CFW Render isn't running");
    fireEvent.click(screen.getByRole("button", { name: "Start" }));
    expect(actions.startWorker).toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "Pause" })).toBeNull();
    // the last status is stale, so nothing is shown as rendering or up next
    expect(screen.queryByText("Spotlight reel")).toBeNull();
    expect(screen.queryByRole("progressbar")).toBeNull();
    expect(screen.queryByText("Carousel")).toBeNull();
  });

  it("paused: one Resume button and how many renders wait", () => {
    const actions = mk();
    const s: StatusFile = { ...workingStatus, now: [], computer: { ...workingStatus.computer, paused: true, pauseReason: "owner" } };
    render(<Panel payload={payload(s)} actions={actions} clock={() => NOW} />);
    expect(screen.getAllByText("Paused").length).toBeGreaterThan(0);
    expect(screen.getByText("1 render is waiting for this Mac.")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Resume" }));
    expect(actions.setPaused).toHaveBeenCalledWith(false);
  });

  it("every provider limited: explains and links to AI providers", () => {
    const actions = mk();
    const s: StatusFile = { ...workingStatus, engines: [{ name: "codex", signedIn: true, limit: "limited", resetsAt: "2026-10-11T15:40:00Z" }] };
    render(<Panel payload={payload(s)} actions={actions} clock={() => NOW} />);
    expect(screen.getByText("Needs you")).toBeTruthy();
    expect(screen.getByRole("alert").textContent).toContain("Every AI provider hit its limit");
    fireEvent.click(screen.getByRole("button", { name: "AI providers" }));
    expect(actions.openMain).toHaveBeenCalledWith("providers");
  });

  it("battery: offers Render on battery", () => {
    const actions = mk();
    const s: StatusFile = { ...workingStatus, computer: { ...workingStatus.computer, paused: true, pauseReason: "battery", onBattery: true } };
    render(<Panel payload={payload(s)} actions={actions} clock={() => NOW} />);
    fireEvent.click(screen.getByRole("button", { name: "Render on battery" }));
    expect(actions.allowBattery).toHaveBeenCalled();
  });
});
