import { copy } from "../copy";
import type { Engine, RecentItem, StatusPayload } from "../status";

export const STALE_MS = 3 * 60 * 1000;

export type BannerKind = "notRunning" | "offline" | "paused" | "battery" | "update" | "limit";
export interface Banner { kind: BannerKind; text: string }
export interface NowRow { title: string; recipe: string; stepText: string; pct: number | null; elapsed: string | null; code: string; brand: string; stepLabel: string; step: string }
export interface SimpleRow { title: string; recipe: string; code: string; brand: string }
export interface DoneRow { mark: string; result: "done" | "failed" | "stopped"; title: string; time: string; code: string; brand: string; identity: RecentItem }

export interface PanelModel {
  providerLine: string;
  noProvider: boolean;
  banner: Banner | null;
  /** When the AI limit lifts (HH:MM), if every provider is limited. */
  limitAt: string | null;
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

export interface ModelOptions {
  /** Max DONE rows (panel: 3). */
  recentLimit?: number;
  /** Only DONE rows finished within this many ms of `now` (undated rows are dropped when set). */
  recentWindowMs?: number;
}

export const DAY_MS = 24 * 60 * 60 * 1000;
/** Main-window "Renders on this Mac": every recent entry from the last 24 h. */
export const rendersModel = (payload: StatusPayload | null, now: number) =>
  panelModel(payload, now, { recentLimit: Infinity, recentWindowMs: DAY_MS });

export function panelModel(payload: StatusPayload | null, now: number, opts: ModelOptions = {}): PanelModel {
  const { recentLimit = 3, recentWindowMs } = opts;
  const s = payload?.status ?? null;
  const engines = (s?.engines ?? []).filter((e) => e.signedIn);
  const noProvider = engines.length === 0;
  const lastCheckMs = ms(s?.lastCheckAt);
  const running = payload ? payload.liveness === "Running" : false;
  const c = s?.computer ?? {};
  const batteryPaused = !!c.paused && c.pauseReason === "battery";
  const ownerPaused = typeof payload?.ownerPaused === "boolean" ? payload.ownerPaused : !!c.paused && c.pauseReason !== "battery";
  const paused = ownerPaused || batteryPaused;

  let banner: Banner | null = null;
  let limitAt: string | null = null;
  if (!s || !running) banner = { kind: "notRunning", text: copy.banner.notRunning };
  // Only the worker's own reach signal: lastError carries update / AI limit /
  // credit text and never means "offline".
  else if (s.cfwReach === "unreachable") banner = { kind: "offline", text: copy.banner.offline };
  else if (ownerPaused) banner = { kind: "paused", text: copy.banner.paused };
  else if (batteryPaused) banner = { kind: "battery", text: copy.banner.battery };
  else if (c.updateRequired) banner = { kind: "update", text: copy.banner.update };
  else if (!noProvider && engines.every((e) => e.limit === "limited")) {
    const resets = engines.map((e) => ms(e.resetsAt)).filter((t): t is number => t != null);
    limitAt = resets.length ? hhmm(Math.min(...resets)) : null;
    banner = { kind: "limit", text: copy.banner.limit(limitAt) };
  }

  const brands = (s?.brands ?? []).filter((b) => b.serving && b.name).map((b) => b.name!);
  const results = ["done", "failed", "stopped"] as const;

  return {
    providerLine: noProvider ? copy.noProvider : (payload?.providerLine ?? fallbackProviderLine(engines)),
    noProvider,
    banner,
    limitAt,
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
        code: n.shortCode ?? "",
        brand: n.brand ?? "",
        stepLabel: n.stepLabel ?? "",
        step: n.step != null && n.steps != null ? copy.stepOf(n.step, n.steps) : "",
      };
    }),
    next: (s?.next ?? []).map((n) => ({ title: title(n.shortCode, n.brand), recipe: n.recipe ?? "", code: n.shortCode ?? "", brand: n.brand ?? "" })),
    // Newest first by finishedAt, whatever order the file lists them in
    // (entries without a time sort last, keeping their file order).
    done: [...(s?.recent ?? [])]
      .map((r, i) => ({ r, i, t: ms(r.finishedAt) }))
      .filter(({ t }) => recentWindowMs == null || (t != null && now - t <= recentWindowMs))
      .sort((a, b) => (b.t ?? -Infinity) - (a.t ?? -Infinity) || a.i - b.i)
      .slice(0, recentLimit)
      .map(({ r }) => {
      const result = (results as readonly string[]).includes(r.result ?? "") ? (r.result as DoneRow["result"]) : "failed";
      const t = ms(r.finishedAt);
      return { mark: copy.marks[result], result, title: title(r.shortCode, r.brand), time: t == null ? "" : hhmm(t), code: r.shortCode ?? "", brand: r.brand ?? "", identity: r };
    }),
    lastCheck: lastCheckMs == null ? copy.lastCheckNever : copy.lastCheck(copy.ago(Math.max(0, Math.floor((now - lastCheckMs) / 1000)))),
  };
}

function fallbackProviderLine(engines: Engine[]) {
  return `AI: ${engines.map(label).join(", ")}`;
}

/** Which key this Mac uses and which brands it serves. Never contains a credential. */
export interface ConnectionSummary {
  line: string;
  keyLine: string | null;
  brands: string[];
  allBrands: boolean;
}

export function connectionSummary(payload: StatusPayload | null): ConnectionSummary | null {
  const s = payload?.status;
  if (!s) return null;
  const brands = (s.brands ?? []).filter((b) => b.serving && b.name).map((b) => b.name as string);
  const c = s.connection;
  const key = c?.keyName || c?.keyHint || null;
  const line = c?.scope === "user" ? copy.connection.all(brands.length)
    : brands.length === 1 ? copy.connection.one(brands[0])
    : brands.length > 1 ? copy.connection.some(brands.length) : copy.connection.none;
  return { line, keyLine: key ? copy.connection.key(key) : null, brands, allBrands: c?.scope === "user" };
}

export type ItemState = "done" | "failed" | "stopped" | "queued" | "needs_input";
export interface RenderItem {
  key: string;
  list: "next" | "done";
  state: ItemState;
  title: string;
  brand: string;
  recipe: string;
  code: string;
  time: string;
  reason: string | null;
  needs: string | null;
  orderId: string | null;
  brandSlug: string | null;
  attemptId: string | null;
  directorLog: string | null;
  startedAt: string | null;
  finishedAt: string | null;
  identity: RecentItem;
}

const itemTitle = (code?: string | null, recipe?: string | null) => code || recipe || copy.render;
const at = (iso?: string | null) => {
  const t = ms(iso);
  return t == null ? "" : hhmm(t);
};

/** Keep the original recent identity separate from presentation fallbacks. */
export function renderItems(payload: StatusPayload | null, now: number): { next: RenderItem[]; done: RenderItem[] } {
  const s = payload?.status;
  const next: RenderItem[] = (s?.next ?? []).map((n, i) => ({
    key: `next-${n.orderId ?? n.shortCode ?? ""}-${i}`,
    list: "next",
    state: n.status === "needs_input" ? "needs_input" : "queued",
    title: itemTitle(n.shortCode, n.recipe || n.kind),
    brand: n.brand ?? "", recipe: n.recipe || n.kind || "", code: n.shortCode ?? "",
    time: at(n.createdAt), reason: null, needs: n.needs ?? null,
    orderId: n.orderId ?? null, brandSlug: n.brandSlug ?? null,
    attemptId: null, directorLog: null, startedAt: null, finishedAt: null, identity: {},
  }));
  const duplicateKeys = new Map<string, number>();
  const done: RenderItem[] = [...(s?.recent ?? [])]
    .map((r, i) => ({ r, i, t: ms(r.finishedAt) }))
    .filter(({ t }) => t != null && now - t <= DAY_MS)
    .sort((a, b) => (b.t ?? 0) - (a.t ?? 0) || a.i - b.i)
    .map(({ r }) => {
      const identityKey = JSON.stringify([r.orderId, r.shortCode, r.attemptId, r.directorLog, r.startedAt, r.finishedAt]);
      const occurrence = duplicateKeys.get(identityKey) ?? 0;
      duplicateKeys.set(identityKey, occurrence + 1);
      const state: ItemState = r.result === "done" || r.result === "stopped" ? r.result : "failed";
      return {
        key: `done-${identityKey}-${occurrence}`,
        list: "done", state, title: itemTitle(r.shortCode, r.recipe || r.kind),
        brand: r.brand ?? "", recipe: r.recipe || r.kind || "", code: r.shortCode ?? "",
        time: at(r.finishedAt), reason: state === "done" ? null : r.reason || null, needs: null,
        orderId: r.orderId ?? null, brandSlug: r.brandSlug ?? null,
        attemptId: r.attemptId ?? null, directorLog: r.directorLog ?? null,
        startedAt: r.startedAt ?? null, finishedAt: r.finishedAt ?? null, identity: r,
      };
    });
  return { next, done };
}

/** One line of overall state for the menu bar, the rail footer and Renders. */
export type HealthKind = "rendering" | "ready" | "paused" | "notRunning" | "offline" | "battery" | "update" | "limit" | "noProvider";
export interface Health {
  kind: HealthKind;
  tone: "ok" | "warn" | "idle" | "bad";
  label: string;
  /** What's wrong and what to do; null when nothing needs the owner. */
  callout: { title: string; body: string } | null;
  waiting: number;
}

export function health(m: PanelModel): Health {
  const waiting = m.next.length;
  const kind: HealthKind = m.banner
    ? m.banner.kind
    : m.noProvider
      ? "noProvider"
      : m.now.length > 0
        ? "rendering"
        : "ready";
  switch (kind) {
    case "rendering":
      return { kind, tone: "ok", label: copy.health.rendering, callout: null, waiting };
    case "ready":
      return { kind, tone: "ok", label: copy.health.ready, callout: null, waiting };
    case "paused":
      return { kind, tone: "idle", label: copy.health.paused, callout: null, waiting };
    case "notRunning":
      return { kind, tone: "bad", label: copy.health.notRunning, callout: copy.callout.notRunning, waiting };
    case "offline":
      return { kind, tone: "warn", label: copy.health.offline, callout: copy.callout.offline, waiting };
    case "battery":
      return { kind, tone: "warn", label: copy.health.paused, callout: copy.callout.battery, waiting };
    case "update":
      return { kind, tone: "warn", label: copy.health.attention, callout: copy.callout.update, waiting };
    case "noProvider":
      return { kind, tone: "warn", label: copy.health.attention, callout: copy.callout.noProvider, waiting };
    case "limit": {
      return { kind, tone: "warn", label: copy.health.attention, callout: copy.callout.limit(m.limitAt), waiting };
    }
  }
}
