export interface SetupEvent {
  step: string;
  state: "started" | "done" | "failed";
  message?: string;
  action?: string;
  pct?: number;
}
export type StepState = "pending" | "started" | "done" | "failed";
export interface StepView { step: string; state: StepState; message?: string; action?: string; pct?: number }
export interface SetupModel {
  steps: StepView[];
  phase: "idle" | "running" | "ready" | "failed";
  error?: string;
  action?: string;
  readyMessage?: string;
}

export const STEPS = ["checking", "tools", "installing", "connecting", "test_render", "ready"] as const;

/** Pure fold of `setup-step` events into the step list + overall phase. */
export function setupModel(events: SetupEvent[]): SetupModel {
  const steps: StepView[] = STEPS.map((step) => ({ step, state: "pending" }));
  const m: SetupModel = { steps, phase: events.length ? "running" : "idle" };
  for (const ev of events) {
    if (ev.step === "result") {
      m.phase = ev.state === "done" ? "ready" : "failed";
      if (ev.state === "failed") m.error = m.error ?? ev.message;
      continue;
    }
    const s = steps.find((x) => x.step === ev.step);
    if (!s) continue;
    s.state = ev.state;
    s.message = ev.message;
    s.action = ev.action;
    s.pct = ev.pct;
    if (ev.state === "failed") {
      m.phase = "failed";
      m.error = ev.message;
      m.action = ev.action;
    }
    if (ev.step === "ready" && ev.state === "done") {
      m.phase = "ready";
      m.readyMessage = ev.message;
    }
  }
  return m;
}

/** Same shape check as the app's Rust side (`setup::valid_key`); CFW does the real check. */
export const looksLikeBrandKey = (k: string) => /^cfw_[A-Za-z0-9_]{8,200}$/.test(k.trim());

export interface ToolsModel { state: "idle" | StepState; pct: number | null; message?: string }

/** Pure fold of the tools-only install (`setup_install_tools`): `tools` progress, then one `tools_result`. */
export function toolsModel(events: SetupEvent[]): ToolsModel {
  let m: ToolsModel = { state: "idle", pct: null };
  for (const ev of events) {
    if (ev.step === "tools") m = { state: ev.state, pct: ev.pct ?? m.pct, message: ev.message };
    if (ev.step === "tools_result") m = { state: ev.state === "done" ? "done" : "failed", pct: m.pct, message: ev.message };
  }
  return m;
}
