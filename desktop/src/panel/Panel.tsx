import { copy } from "../copy";
import type { StatusPayload } from "../status";
import { Icon } from "../ui/Icon";
import { Button, MARK_URL, Pill, ProgressBar, SectionLabel } from "../ui/kit";
import { health, panelModel, type DoneRow } from "./model";

export interface PanelActions {
  openMain(section: string): void;
  startWorker(): void;
  setPaused(paused: boolean): void;
  allowBattery(): void;
  runNow(): void;
  openLogs(): void;
}

const RESULT_ICON = { done: "circle-check", failed: "circle-x", stopped: "circle-pause" } as const;
const RESULT_TONE = { done: "text-emerald-600", failed: "text-red-600", stopped: "text-zinc-500" } as const;

function DoneLine({ d, onWhy }: { d: DoneRow; onWhy: () => void }) {
  return (
    <li className="flex items-center gap-2.5 py-1.5 text-[13px]">
      <Icon name={RESULT_ICON[d.result]} size={15} className={RESULT_TONE[d.result]} />
      <span className="sr-only">{copy.result[d.result]}</span>
      <span className="min-w-0 truncate font-medium">{d.code || copy.render}</span>
      <span className="min-w-0 truncate text-subtle">{d.brand}</span>
      {d.result === "failed" ? (
        <button type="button" onClick={onWhy} className="ml-auto shrink-0 rounded text-xs font-medium text-failed hover:underline">
          {copy.action.seeWhy}
        </button>
      ) : (
        <span className="ml-auto shrink-0 text-xs tabular-nums text-subtle">{d.time}</span>
      )}
    </li>
  );
}

/** The menu-bar panel: what this Mac is doing, what needs you, and one obvious next action. */
export function Panel({ payload, actions, clock = Date.now }: { payload: StatusPayload | null; actions: PanelActions; clock?: () => number }) {
  const m = panelModel(payload, clock());
  const h = health(m);
  // When it isn't running, the last status file is stale: don't claim anything is rendering.
  const down = h.kind === "notRunning";
  const now = down ? undefined : m.now[0];

  const fix = (() => {
    switch (h.kind) {
      case "notRunning":
        return <Button size="sm" variant="primary" icon="play" onClick={actions.startWorker}>{copy.action.start}</Button>;
      case "battery":
        return <Button size="sm" variant="primary" onClick={actions.allowBattery}>{copy.action.renderOnBattery}</Button>;
      case "limit":
      case "noProvider":
        return <Button size="sm" variant="primary" onClick={() => actions.openMain("providers")}>{copy.action.providers}</Button>;
      case "update":
        return <Button size="sm" variant="primary" onClick={() => actions.openMain("settings")}>{copy.nav.settings}</Button>;
      default:
        return null;
    }
  })();

  return (
    <div className="flex h-screen flex-col overflow-hidden bg-card text-foreground">
      <header className="flex items-center gap-2.5 border-b border-border px-4 py-3">
        <img src={MARK_URL} alt="" width={22} height={22} className="h-[22px] w-[22px]" />
        <h1 className="flex-1 text-sm font-semibold">{copy.appName}</h1>
        <Pill tone={h.tone} dot>{h.label}</Pill>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {h.callout && (
          <div role="alert" className="mx-4 mt-3 rounded-[8px] border border-warn-border bg-warn-bg p-3">
            <p className="flex items-center gap-2 text-[13px] font-semibold text-warn-strong">
              <Icon name="circle-alert" size={15} />
              {h.callout.title}
            </p>
            <p className="mt-1 text-xs leading-snug text-warn-strong">{h.callout.body}</p>
            {fix && <div className="mt-2.5 flex gap-2">{fix}</div>}
          </div>
        )}

        {h.kind === "paused" ? (
          <section className="px-4 pt-6 pb-5 text-center">
            <div className="mx-auto mb-2.5 flex h-10 w-10 items-center justify-center rounded-full bg-secondary text-muted-foreground">
              <Icon name="circle-pause" size={20} />
            </div>
            <p className="text-sm font-semibold">{copy.pausedTitle}</p>
            <p className="mt-1 text-xs text-subtle">{copy.waitingCount(h.waiting)}</p>
            <Button variant="primary" icon="play" className="mt-3.5" onClick={() => actions.setPaused(false)}>
              {copy.action.resume}
            </Button>
          </section>
        ) : now ? (
          <section className="px-4 py-3" aria-label={copy.section.now}>
            <SectionLabel className="mb-2.5">{copy.section.now}</SectionLabel>
            <div className="flex gap-3">
              <div className="flex h-[60px] w-[44px] shrink-0 items-center justify-center rounded-md bg-gradient-to-b from-violet-300 to-primary text-white">
                <Icon name="film" size={16} />
              </div>
              <div className="min-w-0 flex-1">
                <p className="truncate text-[13px] font-semibold">{now.recipe || now.code || copy.render}</p>
                <p className="mt-0.5 truncate text-xs text-subtle">{[now.brand, now.code].filter(Boolean).join(copy.sep)}</p>
                <div className="mt-2 mb-1.5 flex text-xs text-subtle">
                  <span className="truncate">{now.stepLabel}</span>
                  <span className="ml-auto shrink-0 tabular-nums">{now.step || now.elapsed}</span>
                </div>
                {now.pct != null && <ProgressBar pct={now.pct} label={copy.section.now} />}
              </div>
            </div>
          </section>
        ) : h.kind === "rendering" || h.kind === "ready" ? (
          <section className="px-4 py-5 text-center">
            <p className="text-sm font-semibold">{copy.idle.title}</p>
            <p className="mt-1 text-xs text-subtle">{copy.idle.body}</p>
          </section>
        ) : null}

        {m.next.length > 0 && h.kind !== "paused" && !down && (
          <section className="border-t border-border px-4 py-3" aria-label={copy.section.next}>
            <SectionLabel className="mb-1">{copy.section.next}</SectionLabel>
            <ul>
              {m.next.slice(0, 3).map((n, i) => (
                <li key={`${n.code}-${i}`} className="flex items-center gap-2.5 py-1.5 text-[13px]">
                  <Icon name={h.kind === "rendering" || h.kind === "ready" ? "image" : "hourglass"} size={15} className="text-zinc-500" />
                  <span className="min-w-0 truncate font-medium">{n.recipe || n.code || copy.render}</span>
                  <span className="ml-auto shrink-0 truncate text-xs text-subtle">{n.brand}</span>
                </li>
              ))}
            </ul>
          </section>
        )}

        {m.done.length > 0 && (
          <section className="border-t border-border px-4 py-3" aria-label={copy.section.done}>
            <SectionLabel className="mb-1">{copy.section.done}</SectionLabel>
            <ul>
              {m.done.map((d, i) => (
                <DoneLine key={`${d.code}-${i}`} d={d} onWhy={() => actions.openMain("renders")} />
              ))}
            </ul>
          </section>
        )}
      </div>

      <footer className="flex items-center gap-2 border-t border-border bg-[#fcfcfc] px-4 py-3">
        {h.kind !== "paused" && h.kind !== "notRunning" && (
          <Button icon="pause" className="flex-1" onClick={() => actions.setPaused(true)}>{copy.action.pause}</Button>
        )}
        <Button variant="primary" className="flex-1" onClick={() => actions.openMain("renders")}>{copy.action.open}</Button>
      </footer>
    </div>
  );
}
