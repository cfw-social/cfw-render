import { copy } from "../copy";
import type { Engine, StatusPayload } from "../status";

export const STALE_MS = 3 * 60 * 1000;

export type BannerKind = "notRunning" | "paused" | "battery" | "update" | "limit";
export interface Banner { kind: BannerKind; text: string }
export interface NowRow { title: string; recipe: string; stepText: string; pct: number | null; elapsed: string | null }
export interface SimpleRow { title: string; recipe: string }
export interface DoneRow { mark: string; result: "done" | "failed" | "stopped"; title: string; time: string }

export interface PanelModel {
  providerLine: string;
  noProvider: boolean;
  banner: Banner | null;
  paused: boolean;
  brandsLine: string | null;
  now: NowRow[];
  next: SimpleRow[];
  done: DoneRow[];
  lastCheck: string;
}

const label = (e: Engine) => e.label || copy.engineFallback[e.name] || e.name;
const ms = (iso?: string | null) => {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : t;
};
export const hhmm = (t: number) => {
  const d = new Date(t);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};
const title = (a?: string | null, b?: string | null) => [a, b].filter(Boolean).join(copy.sep);

export function panelModel(payload: StatusPayload | null, now: number): PanelModel {
  const s = payload?.status ?? null;
  const engines = (s?.engines ?? []).filter((e) => e.signedIn);
  const noProvider = engines.length === 0;
  const lastCheckMs = ms(s?.lastCheckAt);
  const running = payload ? payload.liveness === "Running" : false;
  const c = s?.computer ?? {};
  const paused = !!c.paused;

  let banner: Banner | null = null;
  if (!s || !running) banner = { kind: "notRunning", text: copy.banner.notRunning };
  else if (paused && c.pauseReason === "battery") banner = { kind: "battery", text: copy.banner.battery };
  else if (paused) banner = { kind: "paused", text: copy.banner.paused };
  else if (c.updateRequired) banner = { kind: "update", text: copy.banner.update };
  else if (!noProvider && engines.every((e) => e.limit === "limited")) {
    const resets = engines.map((e) => ms(e.resetsAt)).filter((t): t is number => t != null);
    banner = { kind: "limit", text: copy.banner.limit(resets.length ? hhmm(Math.min(...resets)) : null) };
  }

  const brands = (s?.brands ?? []).filter((b) => b.serving && b.name).map((b) => b.name!);
  const results = ["done", "failed", "stopped"] as const;

  return {
    providerLine: noProvider ? copy.noProvider : (payload?.providerLine ?? fallbackProviderLine(engines)),
    noProvider,
    banner,
    paused,
    brandsLine: brands.length ? copy.workingFor(brands.join(", ")) : null,
    now: (s?.now ?? []).map((n) => {
      const started = ms(n.startedAt);
      return {
        title: title(n.shortCode, n.brand),
        recipe: n.recipe ?? "",
        stepText: copy.step(n.step ?? null, n.steps ?? null, n.stepLabel ?? null),
        pct: typeof n.pct === "number" ? Math.max(0, Math.min(100, n.pct)) : null,
        elapsed: started == null ? null : copy.elapsed(Math.max(0, Math.floor((now - started) / 1000))),
      };
    }),
    next: (s?.next ?? []).map((n) => ({ title: title(n.shortCode, n.brand), recipe: n.recipe ?? "" })),
    done: (s?.recent ?? []).slice(-3).map((r) => {
      const result = (results as readonly string[]).includes(r.result ?? "") ? (r.result as DoneRow["result"]) : "failed";
      const t = ms(r.finishedAt);
      return { mark: copy.marks[result], result, title: title(r.shortCode, r.brand), time: t == null ? "" : hhmm(t) };
    }),
    lastCheck: lastCheckMs == null ? copy.lastCheckNever : copy.lastCheck(copy.ago(Math.max(0, Math.floor((now - lastCheckMs) / 1000)))),
  };
}

function fallbackProviderLine(engines: Engine[]) {
  return `AI: ${engines.map(label).join(", ")}`;
}
