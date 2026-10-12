import type { StatusPayload, StatusFile } from "../status";

export const NOW = Date.parse("2026-10-11T12:00:00Z");

export const workingStatus: StatusFile = {
  schema: 1,
  workerVersion: "1.0.0",
  engines: [
    { name: "codex", label: "ChatGPT", signedIn: true, limit: "limited", resetsAt: "2026-10-11T15:40:00Z" },
    { name: "claude-code", label: "Claude", signedIn: true, limit: "ok", resetsAt: null },
  ],
  activeEngine: "claude-code",
  computer: { name: "Priya's Mac", max: 4, running: 1, onBattery: false, paused: false, pauseReason: null, updateRequired: false },
  brands: [
    { id: "b_1", name: "Brand A", serving: true },
    { id: "b_2", name: "Brand B", serving: false },
    { id: "b_3", name: "Brand C", serving: true },
  ],
  now: [{ shortCode: "R-7KQ4", brand: "Brand A", recipe: "Spotlight reel", step: 5, steps: 7, stepLabel: "Render scenes", pct: 62, startedAt: "2026-10-11T11:58:30Z" }],
  next: [{ shortCode: "R-C1", brand: "Brand C", recipe: "Carousel" }],
  recent: [
    { shortCode: "R-OLD", brand: "Brand A", result: "done", finishedAt: "2026-10-11T10:00:00Z" },
    { shortCode: "R-6TT1", brand: "Brand A", result: "done", finishedAt: "2026-10-11T11:00:00Z" },
    { shortCode: "R-6TT2", brand: "Brand C", result: "failed", finishedAt: "2026-10-11T11:10:00Z" },
    { shortCode: "R-6TT3", brand: "Brand A", result: "stopped", finishedAt: "2026-10-11T11:20:00Z" },
  ],
  lastCheckAt: "2026-10-11T11:59:52Z",
  lastError: null,
};

export const payload = (status: StatusFile | null, over: Partial<StatusPayload> = {}): StatusPayload => ({
  status,
  liveness: "Running",
  iconState: "Working",
  tooltip: "",
  providerLine: "AI: ChatGPT limited until 15:40, using Claude",
  ...over,
});
