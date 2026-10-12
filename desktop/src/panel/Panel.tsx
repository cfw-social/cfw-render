import { useEffect, useState } from "react";
import { copy } from "../copy";
import type { StatusPayload } from "../status";
import { panelModel, type BannerKind, type PanelModel } from "./model";

export interface PanelActions {
  openMain(section: string): void;
  startWorker(): void;
  setPaused(paused: boolean): void;
  allowBattery(): void;
  runNow(): void;
  openLogs(): void;
}

export const btn = "rounded-md px-2 py-1 text-xs font-medium bg-neutral-200 hover:bg-neutral-300 dark:bg-neutral-700 dark:hover:bg-neutral-600";
const heading = "mt-3 mb-1 text-[11px] font-semibold uppercase tracking-wide text-neutral-500";

/** Ticks once a second so elapsed times stay live. */
export function useNow(clock?: () => number) {
  const [now, setNow] = useState(() => (clock ?? Date.now)());
  useEffect(() => {
    const id = setInterval(() => setNow((clock ?? Date.now)()), 1000);
    return () => clearInterval(id);
  }, [clock]);
  return now;
}

export function Panel({ payload, actions, clock }: { payload: StatusPayload | null; actions: PanelActions; clock?: () => number }) {
  const m = panelModel(payload, useNow(clock));
  return (
    <div className="flex h-screen flex-col bg-white p-3 font-sans text-sm text-neutral-900 dark:bg-neutral-900 dark:text-neutral-100">
      <StatusBody m={m} actions={actions} />
      <div className="mt-2 text-xs text-neutral-500">{m.lastCheck}</div>
      <div className="mt-2 flex gap-2">
        <button className={btn} onClick={() => actions.setPaused(!m.paused)}>{m.paused ? copy.action.resume : copy.action.pause}</button>
        <button className={btn} onClick={actions.runNow}>{copy.action.runNow}</button>
        <button className={btn} onClick={() => actions.openMain("renders")}>{copy.action.open}</button>
        <button className={btn} onClick={actions.openLogs}>{copy.action.viewLogs}</button>
      </div>
    </div>
  );
}

/** Provider line, banner, brands and NOW/NEXT/DONE — shared by the panel and the main window. */
export function StatusBody({ m, actions }: { m: PanelModel; actions: Pick<PanelActions, "openMain" | "startWorker" | "setPaused" | "allowBattery"> }) {

  const bannerAction: Record<BannerKind, [string, () => void] | null> = {
    notRunning: [copy.action.start, actions.startWorker],
    paused: [copy.action.resume, () => actions.setPaused(false)],
    battery: [copy.action.renderOnBattery, actions.allowBattery],
    update: null,
    limit: null,
  };
  const ba = m.banner ? bannerAction[m.banner.kind] : null;

  return (
    <>
      <div className="text-xs text-neutral-600 dark:text-neutral-300">
        {m.noProvider ? (
          <button className="underline" onClick={() => actions.openMain("providers")}>{m.providerLine}</button>
        ) : (
          m.providerLine
        )}
      </div>
      {m.banner && (
        <div role="alert" className="mt-2 flex items-center justify-between rounded-md bg-amber-100 px-2 py-1.5 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100">
          <span>{m.banner.text}</span>
          {ba && <button className={btn} onClick={ba[1]}>{ba[0]}</button>}
        </div>
      )}
      {m.brandsLine && <div className="mt-2">{m.brandsLine}</div>}
      <div className="flex-1 overflow-y-auto">
        {m.now.length > 0 && (
          <section>
            <h2 className={heading}>{copy.section.now}</h2>
            {m.now.map((r, i) => (
              <div key={i} className="mb-2">
                <div className="flex justify-between font-medium"><span>{r.title}</span>{r.elapsed && <span className="tabular-nums text-neutral-500">{r.elapsed}</span>}</div>
                {r.recipe && <div>{r.recipe}</div>}
                {r.stepText && <div className="text-xs text-neutral-500">{r.stepText}</div>}
                {r.pct != null && (
                  <div className="mt-1 h-1.5 rounded bg-neutral-200 dark:bg-neutral-700" role="progressbar" aria-valuenow={r.pct} aria-valuemin={0} aria-valuemax={100}>
                    <div className="h-1.5 rounded bg-blue-500" style={{ width: `${r.pct}%` }} />
                  </div>
                )}
              </div>
            ))}
          </section>
        )}
        {m.next.length > 0 && (
          <section>
            <h2 className={heading}>{copy.section.next}</h2>
            {m.next.map((r, i) => (
              <div key={i}>{[r.title, r.recipe].filter(Boolean).join(copy.sep)}</div>
            ))}
          </section>
        )}
        {m.done.length > 0 && (
          <section>
            <h2 className={heading}>{copy.section.done}</h2>
            {m.done.map((r, i) => (
              <div key={i} className="flex justify-between">
                <span>{r.mark} {r.title}</span>
                <span className="tabular-nums text-neutral-500">{r.time}</span>
              </div>
            ))}
          </section>
        )}
      </div>
    </>
  );
}
