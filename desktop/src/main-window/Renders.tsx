import { invoke } from "@tauri-apps/api/core";
import { useEffect, useRef, useState } from "react";
import { CopyRenderDebug } from "./CopyRenderDebug";
import { copy } from "../copy";
import { connectionSummary, health, renderItems, rendersModel, type ItemState, type RenderItem } from "../panel/model";
import type { StatusPayload } from "../status";
import { Icon } from "../ui/Icon";
import { Button, Card, Pill, ProgressBar, SectionLabel, type Tone } from "../ui/kit";
import { useClickGuard } from "../ui/useClickGuard";
import { Connection } from "./Connection";
import type { PanelActions } from "../panel/Panel";

const STATE_ICON = { done: "circle-check", failed: "circle-x", stopped: "circle-pause", queued: "hourglass", needs_input: "circle-alert" } as const;
const STATE_ICON_TONE = { done: "text-emerald-600", failed: "text-red-600", stopped: "text-zinc-500", queued: "text-zinc-500", needs_input: "text-amber-600" } as const;
const STATE_TONE: Record<ItemState, Tone> = { done: "ok", failed: "bad", stopped: "idle", queued: "idle", needs_input: "warn" };
const why = (e: unknown) => (typeof e === "string" ? e : e instanceof Error ? e.message : String(e));

function Row({ item, selected, onSelect }: { item: RenderItem; selected: boolean; onSelect: () => void }) {
  const sub = item.state === "needs_input" ? item.needs : item.state === "failed" || item.state === "stopped" ? item.reason : null;
  return (
    <li>
      <button
        type="button"
        aria-pressed={selected}
        onClick={onSelect}
        className={`grid w-full grid-cols-[18px_minmax(0,1fr)_auto] sm:grid-cols-[18px_minmax(0,1.4fr)_minmax(0,1fr)_auto_auto] items-center gap-x-3 px-4 py-3 text-left text-[13px] hover:bg-secondary/60 focus-visible:outline-2 focus-visible:outline-primary ${selected ? "bg-secondary" : ""}`}
      >
        <Icon name={STATE_ICON[item.state]} size={15} className={STATE_ICON_TONE[item.state]} />
        <span className="min-w-0">
          <span className="block truncate font-semibold">{item.title}</span>
          {(item.recipe && item.recipe !== item.title) || (item.code && item.code !== item.title) ? (
            <span className="block truncate text-xs text-subtle">{[item.recipe !== item.title ? item.recipe : "", item.code !== item.title ? item.code : ""].filter(Boolean).join(copy.sep)}</span>
          ) : null}
        </span>
        <span className="hidden truncate text-muted-foreground sm:block">{item.brand}</span>
        <Pill tone={STATE_TONE[item.state]}>{copy.state[item.state]}</Pill>
        <span className="hidden text-right tabular-nums text-subtle sm:block">{item.time}</span>
        {sub && <span className="col-span-2 col-start-2 truncate sm:col-span-4 text-xs text-subtle" data-testid="row-reason">{sub}</span>}
      </button>
    </li>
  );
}

function Detail({ item, actions, onClose }: { item: RenderItem; actions: PanelActions; onClose: () => void }) {
  const D = copy.detail;
  const failed = item.state === "failed" || item.state === "stopped";
  const { brandSlug, orderId } = item;
  const [error, setError] = useState<string | null>(null);
  const pane = useRef<HTMLElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    pane.current?.focus();
    return () => { if (previous?.isConnected) previous.focus(); };
  }, []);
  const field = (label: string, value: string) =>
    value ? (
      <div className="flex justify-between gap-3 text-[13px]">
        <dt className="text-subtle">{label}</dt>
        <dd className="truncate text-right">{value}</dd>
      </div>
    ) : null;
  return (
    <aside
      ref={pane}
      tabIndex={-1}
      role="complementary"
      aria-labelledby="render-detail-title"
      className="flex w-full flex-col gap-4 rounded-[10px] border border-border bg-background p-5 lg:sticky lg:top-[30px] lg:w-[320px] lg:shrink-0"
    >
      <div className="flex items-start gap-2">
        <h2 id="render-detail-title" className="min-w-0 flex-1 truncate text-[15px] font-semibold">{item.title}</h2>
        <Button size="sm" variant="ghost" icon="x" aria-label={D.close} onClick={onClose} />
      </div>
      <div><Pill tone={STATE_TONE[item.state]} dot>{copy.state[item.state]}</Pill></div>
      <dl className="flex flex-col gap-1.5">
        {field(D.brand, item.brand)}
        {field(D.recipe, item.recipe)}
        {field(D.code, item.code)}
        {field(item.list === "done" ? D.finished : D.created, item.time)}
      </dl>
      {failed && (
        <div className="rounded-[8px] border border-failed/30 bg-failed-bg p-3">
          <p className="text-[13px] font-semibold text-failed">{D.whyTitle}</p>
          <p className="mt-1 text-xs whitespace-pre-wrap">{item.reason ?? D.whyFallback}</p>
        </div>
      )}
      {item.state === "needs_input" && item.needs && (
        <div className="rounded-[8px] border border-warn-border bg-warn-bg p-3">
          <p className="text-[13px] font-semibold text-warn-strong">{D.needsTitle}</p>
          <p className="mt-1 text-xs text-warn-strong">{item.needs}</p>
        </div>
      )}
      <div className="flex flex-wrap gap-2">
        {brandSlug && orderId && (
          <Button
            size="sm"
            variant="primary"
            icon="external-link"
            onClick={() =>
              invoke("open_render_in_browser", { brandSlug, orderId, shortCode: item.code || null }).catch((e: unknown) => setError(why(e)))
            }
          >
            {D.openInCfw}
          </Button>
        )}
        {failed ? <CopyRenderDebug item={item.identity} /> : <Button size="sm" onClick={actions.openLogs}>{copy.action.viewLogs}</Button>}
      </div>
      {error && <p role="alert" className="text-xs text-failed">{error}</p>}
    </aside>
  );
}

/** How long Refresh waits for the worker to finish its check before letting go. */
const CHECK_WAIT_MS = 20_000;

/** "Renders on this Mac": what's rendering now, what's waiting, what finished in the last 24 hours. */
export function Renders({
  payload,
  actions,
  clock = Date.now,
  onPayload,
}: {
  payload: StatusPayload | null;
  actions: PanelActions;
  clock?: () => number;
  /** Receives the fresh status after Refresh. */
  onPayload?: (p: StatusPayload) => void;
}) {
  const t = clock();
  const m = rendersModel(payload, t);
  const h = health(m);
  const conn = connectionSummary(payload);
  const items = renderItems(payload, t);
  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const selected = [...items.next, ...items.done].find((i) => i.key === selectedKey) ?? null;
  const [refreshError, setRefreshError] = useState<string | null>(null);
  // Refresh stays "Checking…" until the worker has actually checked (its lastCheckAt moves on),
  // not just until the request was handed over, so there's never a dead moment to click again.
  const lastCheckAt = payload?.status?.lastCheckAt ?? null;
  const [checking, setChecking] = useState<{ since: string | null } | null>(null);
  const [checkSlow, setCheckSlow] = useState(false);
  const guard = useClickGuard();
  useEffect(() => {
    if (checking && lastCheckAt !== checking.since) setChecking(null);
  }, [checking, lastCheckAt]);
  useEffect(() => {
    if (!checking) return;
    const t = setTimeout(() => {
      setChecking(null);
      setCheckSlow(true);
    }, CHECK_WAIT_MS);
    return () => clearTimeout(t);
  }, [checking]);

  useEffect(() => {
    if (!selected) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setSelectedKey(null);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [selected]);

  const toggle = (k: string) => setSelectedKey((cur) => (cur === k ? null : k));
  const now = h.kind === "notRunning" ? undefined : m.now[0];
  const paused = m.paused;
  const refresh = async () => {
    if (checking) return;
    setRefreshError(null);
    setCheckSlow(false);
    setChecking({ since: lastCheckAt });
    try {
      await invoke("run_now");
      const p = await invoke<StatusPayload>("get_status");
      if (p) onPayload?.(p);
      // A stopped or paused worker doesn't check: nothing to wait for.
      if (!p || p.liveness !== "Running" || paused) setChecking(null);
    } catch (e: unknown) {
      setRefreshError(copy.main.refreshFailed(why(e)));
      setChecking(null);
    }
  };

  return (
    <div className="mx-auto flex w-full max-w-[1280px] flex-col items-start gap-6 px-4 pt-4 pb-10 sm:px-8 lg:flex-row">
    <div className="flex w-full min-w-0 max-w-[920px] flex-1 flex-col gap-5">
      <header className="flex flex-wrap items-start gap-4">
        <div className="min-w-0 flex-1">
          <h1 className="text-xl font-bold">{copy.main.rendersTitle}</h1>
          {conn && <div className="mt-1.5"><Connection summary={conn} showBrands={false} /></div>}
        </div>
        <Button icon="refresh-cw" busy={!!checking} disabled={!!checking} onClick={() => void refresh()}>
          {checking ? copy.main.checking : copy.main.refresh}
        </Button>
        {h.kind !== "notRunning" &&
          (paused ? (
            <Button variant="primary" icon="play" onClick={() => guard(() => actions.setPaused(false))}>{copy.nav.resume}</Button>
          ) : (
            <Button icon="pause" onClick={() => guard(() => actions.setPaused(true))}>{copy.action.pauseMac}</Button>
          ))}
      </header>

      {refreshError && <p role="alert" className="text-[13px] text-failed">{refreshError}</p>}
      {checkSlow && !refreshError && <p role="status" className="text-[13px] text-subtle">{copy.main.checkSlow}</p>}

      {h.callout && (
        <div role="alert" className="flex items-start gap-3 rounded-[10px] border border-warn-border bg-warn-bg p-4">
          <Icon name="circle-alert" size={18} className="mt-px text-warn" />
          <div className="min-w-0 flex-1">
            <p className="text-[13px] font-semibold text-warn-strong">{h.callout.title}</p>
            <p className="mt-0.5 text-xs text-warn-strong">{h.callout.body}</p>
          </div>
          {h.kind === "notRunning" && <Button size="sm" variant="primary" onClick={actions.startWorker}>{copy.action.start}</Button>}
          {h.kind === "battery" && <Button size="sm" variant="primary" onClick={actions.allowBattery}>{copy.action.renderOnBattery}</Button>}
          {(h.kind === "limit" || h.kind === "noProvider") && (
            <Button size="sm" variant="primary" onClick={() => actions.openMain("providers")}>{copy.action.providers}</Button>
          )}
        </div>
      )}

      {now ? (
        <Card className="flex gap-4 p-4">
          <div className="flex h-24 w-[54px] shrink-0 items-center justify-center rounded-md bg-gradient-to-b from-violet-300 to-primary text-white">
            <Icon name="film" size={18} />
          </div>
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              <Pill tone="ok" dot>{copy.health.rendering}</Pill>
              {now.elapsed && <span className="text-xs text-subtle">{copy.main.startedAgo(now.elapsed)}</span>}
            </div>
            <p className="mt-2 truncate text-[15px] font-semibold">{now.recipe || now.code || copy.render}</p>
            <p className="mt-0.5 truncate text-[13px] text-muted-foreground">{[now.brand, now.code].filter(Boolean).join(copy.sep)}</p>
            <div className="mt-3 flex items-center gap-3">
              <div className="flex-1">{now.pct != null && <ProgressBar pct={now.pct} label={copy.section.now} />}</div>
              <span className="shrink-0 text-xs text-subtle">{[now.stepLabel, now.step].filter(Boolean).join(copy.sep)}</span>
            </div>
          </div>
        </Card>
      ) : (
        !h.callout && (
          <Card className="px-4 py-6 text-center">
            <p className="text-sm font-semibold">{paused ? copy.pausedTitle : copy.idle.title}</p>
            <p className="mt-1 text-xs text-subtle">{paused ? copy.waitingCount(h.waiting) : copy.idle.body}</p>
          </Card>
        )
      )}

      <section className="flex flex-col gap-2" aria-label={copy.section.next}>
        <SectionLabel>{copy.section.next}</SectionLabel>
        {items.next.length ? (
          <Card>
            <ul className="divide-y divide-border">
              {items.next.map((n) => (
                <Row key={n.key} item={n} selected={n.key === selectedKey} onSelect={() => toggle(n.key)} />
              ))}
            </ul>
          </Card>
        ) : (
          <p className="text-[13px] text-subtle">{copy.main.noNext}</p>
        )}
      </section>

      <section className="flex flex-col gap-2" aria-label={copy.section.done}>
        <SectionLabel>{copy.section.done}</SectionLabel>
        {items.done.length ? (
          <Card>
            <ul className="divide-y divide-border">
              {items.done.map((d) => (
                <Row key={d.key} item={d} selected={d.key === selectedKey} onSelect={() => toggle(d.key)} />
              ))}
            </ul>
          </Card>
        ) : (
          <p className="text-[13px] text-subtle">{copy.main.noRecent}</p>
        )}
      </section>

      <div className="flex items-center gap-4 text-xs text-subtle">
        <span>{m.lastCheck}</span>
        <button type="button" className="rounded font-medium text-accent-foreground hover:underline" onClick={actions.runNow}>{copy.action.runNow}</button>
        <button type="button" className="rounded font-medium text-accent-foreground hover:underline" onClick={actions.openLogs}>{copy.action.viewLogs}</button>
      </div>
    </div>
    {selected && <Detail key={selected.key} item={selected} actions={actions} onClose={() => setSelectedKey(null)} />}
    </div>
  );
}
