// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";

const h = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: h.invoke }));

import { Renders } from "./Renders";
import { NOW, payload, workingStatus } from "../panel/fixtures";
import type { StatusFile } from "../status";
import type { PanelActions } from "../panel/Panel";

const actions = (): PanelActions => ({ openMain: vi.fn(), startWorker: vi.fn(), setPaused: vi.fn(), allowBattery: vi.fn(), runNow: vi.fn(), openLogs: vi.fn() });
const show = (status: StatusFile, a = actions(), onPayload = vi.fn()) => {
  render(<Renders payload={payload(status)} actions={a} clock={() => NOW} onPayload={onPayload} />);
  return { a, onPayload };
};

afterEach(() => {
  cleanup();
  h.invoke.mockReset();
  vi.unstubAllGlobals();
});

describe("Renders", () => {
  it("account-wide key: shows all brands, no Use all my brands", () => {
    show({ ...workingStatus, connection: { scope: "user", keyName: "Account key" } });
    expect(screen.getByText("Connected for all your brands (2)")).toBeTruthy();
    expect(screen.getByText("Key: Account key")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Use all my brands" })).toBeNull();
  });

  it("brand key: Use all my brands confirms then calls setup_with_account; shows owner-safe error", async () => {
    h.invoke.mockRejectedValue("Sign in to CFW first");
    show({ ...workingStatus, brands: [{ name: "Mr. Growth Guide", serving: true }], connection: { scope: "brand" } });
    expect(screen.getByText("Connected for 1 brand: Mr. Growth Guide")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Use all my brands" }));
    expect(screen.getByText("This Mac will render for every brand on your CFW account using your AI plan.")).toBeTruthy();
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Continue" })));
    expect(h.invoke).toHaveBeenCalledWith("setup_with_account");
    expect(screen.getByRole("alert").textContent).toContain("Sign in to CFW first");
  });

  it("shows only the brand count, no brand chips (Settings lists them)", () => {
    show({ ...workingStatus, brands: Array.from({ length: 11 }, (_, i) => ({ name: `B${i}`, serving: true })), connection: { scope: "subset", keyName: "MacBook Pro" } });
    expect(screen.getByText("Connected for 11 brands")).toBeTruthy();
    expect(screen.getByText("Key: MacBook Pro")).toBeTruthy();
    expect(screen.queryByText("B0")).toBeNull();
    expect(screen.queryByText(/more$/)).toBeNull();
  });

  it("up next shows Waiting and Needs you with the detail", () => {
    show({ ...workingStatus, next: [{ shortCode: "R-C1", brand: "Brand C", recipe: "Carousel" }, { shortCode: "R-N", brand: "Brand A", status: "needs_input", needs: "Pick a voice" }] });
    const next = screen.getByRole("region", { name: "Up next" });
    expect(next.textContent).toContain("Waiting");
    expect(next.textContent).toContain("Needs you");
    expect(next.textContent).toContain("Pick a voice");
  });

  it("empty up next", () => {
    show({ ...workingStatus, next: [] });
    expect(screen.getByText("Nothing waiting.")).toBeTruthy();
  });

  it("failed row shows its reason inline and in the pane; Open in CFW opens the render", () => {
    show({ ...workingStatus, recent: [{ shortCode: "R-F", brand: "Brand C", recipe: "Carousel", result: "failed", reason: "AI ran out of credit", finishedAt: "2026-10-11T11:00:00Z", orderId: "ord_1", brandSlug: "brand-c" }] });
    expect(screen.getByTestId("row-reason").textContent).toBe("AI ran out of credit");
    const row = screen.getByRole("button", { name: /R-F/ });
    fireEvent.click(row);
    expect(row.getAttribute("aria-pressed")).toBe("true");
    const pane = screen.getByRole("complementary", { name: "R-F" });
    expect(pane.textContent).toContain("Why it didn't finish");
    expect(pane.textContent).toContain("AI ran out of credit");
    h.invoke.mockResolvedValue(undefined);
    fireEvent.click(screen.getByRole("button", { name: "Open in CFW" }));
    expect(h.invoke).toHaveBeenCalledWith("open_render_in_browser", { brandSlug: "brand-c", orderId: "ord_1", shortCode: "R-F" });
    fireEvent.keyDown(document, { key: "Escape" });
    expect(screen.queryByRole("complementary")).toBeNull();
  });

  it("stopped row without identity: fallback copy and debug action, no Open in CFW, close button", () => {
    const { a } = show({ ...workingStatus, next: [], recent: [{ recipe: "Carousel", result: "stopped", finishedAt: "2026-10-11T11:00:00Z" }] });
    fireEvent.click(screen.getByRole("button", { name: /Carousel/ }));
    const pane = screen.getByRole("complementary", { name: "Carousel" });
    expect(pane.textContent).toContain("CFW Render didn't record a reason. Copy debug instructions to investigate.");
    expect(within(pane).getByRole("button", { name: "Copy debug instructions" })).toBeTruthy();
    expect(within(pane).queryByRole("button", { name: "View logs" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Open in CFW" })).toBeNull();
    fireEvent.click(screen.getAllByRole("button", { name: "View logs" })[0]);
    expect(a.openLogs).toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    expect(screen.queryByRole("complementary")).toBeNull();
  });

  it("copies only the selected attempt's full identity and local read-only instructions, with pending/success feedback", async () => {
    let finish!: () => void;
    const writeText = vi.fn((_text: string) => new Promise<void>((resolve) => { finish = resolve; }));
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    const row = { shortCode: "R-F", orderId: "ord_1", attemptId: "attempt_1", brand: "Brand C", brandSlug: "brand-c", recipe: "Carousel", result: "failed", startedAt: "2026-10-11T10:00:01Z", finishedAt: "2026-10-11T11:00:02Z", directorLog: "ord_1-1791712801-unique.out", reason: "Not copied" };
    show({ ...workingStatus, recent: [row] });
    fireEvent.click(screen.getByRole("button", { name: /R-F/ }));
    fireEvent.click(screen.getByRole("button", { name: "Copy debug instructions" }));
    expect((screen.getByRole("button", { name: "Copy debug instructions" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Copy debug instructions" }));
    expect(writeText).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("status").textContent).toBe("");
    const text = writeText.mock.calls[0][0];
    expect(JSON.parse(text.split("Render identity (JSON):\n")[1])).toEqual({ orderId: row.orderId, attemptId: row.attemptId, shortCode: row.shortCode, brand: row.brand, brandSlug: row.brandSlug, recipe: row.recipe, result: row.result, startedAt: row.startedAt, finishedAt: row.finishedAt, directorLog: row.directorLog });
    expect(text).toContain("$HOME/CFW Render/app/lib/render-debug.md");
    expect(text).toContain("Ask before fixes, paid calls or retries");
    expect(text).toContain("never substitute the latest retry");
    expect(text).not.toContain("Not copied");
    expect(text).toContain("https://app.cfw.social/assets/guides/render-debug.md");
    await act(async () => finish());
    expect(screen.getByRole("status").textContent).toBe("Copied");
    expect(h.invoke).not.toHaveBeenCalled();
  });

  it("clipboard rejection is visible, retry works, and selecting another attempt clears feedback", async () => {
    const writeText = vi.fn().mockRejectedValueOnce(new Error("Denied")).mockResolvedValue(undefined);
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    const recent = [
      { shortCode: "R-OLD", orderId: "o1", attemptId: "a1", result: "failed", finishedAt: "2026-10-11T10:00:00Z" },
      { shortCode: "R-NEW", orderId: "o1", attemptId: "a2", result: "stopped", finishedAt: "2026-10-11T11:00:00Z" },
    ];
    show({ ...workingStatus, recent });
    fireEvent.click(screen.getByRole("button", { name: /R-OLD/ }));
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Copy debug instructions" })));
    expect(screen.getByRole("status").textContent).toContain("Couldn't copy");
    expect(screen.getByRole("textbox", { name: "Copy debug instructions" })).toBeTruthy();
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Copy debug instructions" })));
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.getByRole("status")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: /R-NEW/ }));
    expect(screen.getByRole("status").textContent).toBe("");
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Copy debug instructions" })));
    const identity = JSON.parse(writeText.mock.calls[2][0].split("Render identity (JSON):\n")[1]);
    expect(identity).toMatchObject({ orderId: "o1", attemptId: "a2", startedAt: null, directorLog: null });
  });

  it("missing clipboard API reports failure without claiming success", async () => {
    vi.stubGlobal("navigator", {});
    show({ ...workingStatus, recent: [{ shortCode: "R-F", result: "failed", finishedAt: "2026-10-11T11:00:00Z" }] });
    fireEvent.click(screen.getByRole("button", { name: /R-F/ }));
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Copy debug instructions" })));
    expect(screen.getByRole("status").textContent).toContain("Couldn't copy");
    expect(screen.getByRole("textbox", { name: "Copy debug instructions" })).toBeTruthy();
  });

  it("keeps the selected attempt across prepends and returns focus to the last selected row", () => {
    const a = actions();
    const status = { ...workingStatus, recent: [
      { shortCode: "R-A", orderId: "order", attemptId: "A", result: "failed" as const, finishedAt: "2026-10-11T11:59:00Z" },
      { shortCode: "R-B", orderId: "order", attemptId: "B", result: "failed" as const, finishedAt: "2026-10-11T11:58:00Z" },
    ] };
    const { rerender } = render(<Renders payload={payload(status)} actions={a} clock={() => NOW} />);
    fireEvent.click(screen.getByRole("button", { name: /R-A/ }));
    fireEvent.click(screen.getByRole("button", { name: /R-B/ }));
    expect(screen.getByRole("complementary", { name: "R-B" })).toBeTruthy();
    rerender(<Renders payload={payload({ ...status, recent: [
      { shortCode: "R-C", orderId: "other", attemptId: "C", result: "done", finishedAt: "2026-10-11T12:00:00Z" }, ...status.recent,
    ] })} actions={a} clock={() => NOW} />);
    expect(screen.getByRole("complementary", { name: "R-B" })).toBeTruthy();
    fireEvent.keyDown(document, { key: "Escape" });
    expect(document.activeElement).toBe(screen.getByRole("button", { name: /R-B/ }));
  });

  it("successful and queued rows retain View logs, not debug instructions", () => {
    show(workingStatus);
    for (const name of [/R-OLD/, /R-C1/]) {
      fireEvent.click(screen.getByRole("button", { name }));
      const pane = within(screen.getByRole("complementary"));
      expect(pane.getByRole("button", { name: "View logs" })).toBeTruthy();
      expect(pane.queryByRole("button", { name: "Copy debug instructions" })).toBeNull();
    }
  });

  it("Refresh runs run_now then get_status, and stays Checking… until the worker has actually checked", async () => {
    const fresh = payload({ ...workingStatus, next: [] });
    let release: () => void = () => {};
    h.invoke.mockImplementation((cmd: string) =>
      cmd === "run_now" ? new Promise<void>((r) => { release = r; }) : Promise.resolve(fresh),
    );
    const onPayload = vi.fn();
    const a = actions();
    const { rerender } = render(<Renders payload={payload(workingStatus)} actions={a} clock={() => NOW} onPayload={onPayload} />);
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    const busy = screen.getByRole("button", { name: "Checking…" }) as HTMLButtonElement;
    expect(busy.disabled).toBe(true);
    await act(async () => release());
    expect(h.invoke.mock.calls.map((c) => c[0])).toEqual(["run_now", "get_status"]);
    expect(onPayload).toHaveBeenCalledWith(fresh);
    // Handed over is not checked: no dead moment where a second click looks needed.
    expect((screen.getByRole("button", { name: "Checking…" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Checking…" }));
    expect(h.invoke.mock.calls.filter((c) => c[0] === "run_now")).toHaveLength(1);
    rerender(<Renders payload={payload({ ...workingStatus, lastCheckAt: "2026-10-11T12:00:30Z" })} actions={a} clock={() => NOW} onPayload={onPayload} />);
    expect(screen.getByRole("button", { name: "Refresh" })).toBeTruthy();
  });

  it("Refresh lets go after 20 s with a note when the worker hasn't answered", async () => {
    vi.useFakeTimers();
    try {
      h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_status" ? payload(workingStatus) : undefined));
      show(workingStatus);
      await act(async () => fireEvent.click(screen.getByRole("button", { name: "Refresh" })));
      expect(screen.getByRole("button", { name: "Checking…" })).toBeTruthy();
      await act(async () => vi.advanceTimersByTime(20_000));
      expect(screen.getByRole("button", { name: "Refresh" })).toBeTruthy();
      expect(screen.getByRole("status").textContent).toContain("updates on its own");
    } finally {
      vi.useRealTimers();
    }
  });

  it("Refresh on a paused Mac doesn't wait for a check that won't come", async () => {
    const pausedStatus = { ...workingStatus, now: [], computer: { ...workingStatus.computer, paused: true, pauseReason: "owner" } };
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "get_status" ? payload(pausedStatus) : undefined));
    show(pausedStatus);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Refresh" })));
    expect(screen.getByRole("button", { name: "Refresh" })).toBeTruthy();
  });

  it("a double-click on Pause this Mac pauses once (the second click would hit Resume)", () => {
    const { a } = show({ ...workingStatus, now: [] });
    const pause = screen.getByRole("button", { name: "Pause this Mac" });
    fireEvent.click(pause);
    fireEvent.click(pause);
    expect(a.setPaused).toHaveBeenCalledTimes(1);
    expect(a.setPaused).toHaveBeenCalledWith(true);
  });

  it("Refresh shows the error", async () => {
    h.invoke.mockRejectedValue("Worker not running");
    show(workingStatus);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Refresh" })));
    expect(screen.getByRole("alert").textContent).toBe("Couldn't check CFW: Worker not running");
  });
});
