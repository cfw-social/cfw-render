// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { Panel, type PanelActions } from "./Panel";
import { NOW, payload, workingStatus } from "./fixtures";

afterEach(cleanup);

describe("Panel", () => {
  it("renders a working status and wires buttons", () => {
    const actions: PanelActions = { openMain: vi.fn(), startWorker: vi.fn(), setPaused: vi.fn(), allowBattery: vi.fn(), runNow: vi.fn(), openLogs: vi.fn() };
    render(<Panel payload={payload(workingStatus)} actions={actions} clock={() => NOW} />);
    expect(screen.getByText("AI: ChatGPT limited until 15:40, using Claude")).toBeTruthy();
    expect(screen.getByText("Working for: Brand A, Brand C")).toBeTruthy();
    expect(screen.getByText("R-7KQ4 · Brand A")).toBeTruthy();
    expect(screen.getByText("step 5 of 7 · Render scenes")).toBeTruthy();
    expect(screen.getByText("1:30")).toBeTruthy();
    expect(screen.getByText("R-C1 · Brand C · Carousel")).toBeTruthy();
    expect(screen.getByText("Last check: 8 s ago")).toBeTruthy();
    expect(screen.queryByRole("alert")).toBeNull();
    fireEvent.click(screen.getByText("Open"));
    expect(actions.openMain).toHaveBeenCalledWith("renders");
    fireEvent.click(screen.getByText("Pause"));
    expect(actions.setPaused).toHaveBeenCalledWith(true);
  });
});
