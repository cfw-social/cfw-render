import { copy } from "../copy";
import { health, rendersModel, type DoneRow } from "../panel/model";
import type { StatusPayload } from "../status";
import { Icon } from "../ui/Icon";
import { Button, Card, Pill, ProgressBar, SectionLabel } from "../ui/kit";
import type { PanelActions } from "../panel/Panel";

const RESULT_ICON = { done: "circle-check", failed: "circle-x", stopped: "circle-pause" } as const;
const RESULT_TONE = { done: "text-emerald-600", failed: "text-red-600", stopped: "text-zinc-500" } as const;

function Row({ icon, iconClass, title, brand, detail, detailClass, right }: { icon: Parameters<typeof Icon>[0]["name"]; iconClass?: string; title: string; brand: string; detail?: string; detailClass?: string; right?: string }) {
  return (
    <li className="grid grid-cols-[18px_minmax(0,1.4fr)_minmax(0,1fr)_minmax(0,1fr)_auto] items-center gap-3 px-4 py-3 text-[13px]">
      <Icon name={icon} size={15} className={iconClass ?? "text-zinc-500"} />
      <span className="truncate font-semibold">{title}</span>
      <span className="truncate text-muted-foreground">{brand}</span>
      <span className={`truncate ${detailClass ?? "text-muted-foreground"}`}>{detail}</span>
      <span className="text-right tabular-nums text-subtle">{right}</span>
    </li>
  );
}

/** "Renders on this Mac": what's rendering now, what's waiting, what finished in the last 24 hours. */
export function Renders({ payload, actions, clock = Date.now }: { payload: StatusPayload | null; actions: PanelActions; clock?: () => number }) {
  const m = rendersModel(payload, clock());
  const h = health(m);
  const brands = (payload?.status?.brands ?? []).filter((b) => b.serving && b.name).map((b) => b.name as string);
  const now = h.kind === "notRunning" ? undefined : m.now[0];
  const paused = h.kind === "paused" || h.kind === "battery";

  return (
    <div className="mx-auto flex w-full max-w-[920px] flex-col gap-5 px-8 pt-4 pb-10">
      <header className="flex items-start gap-4">
        <div className="min-w-0 flex-1">
          <h1 className="text-xl font-bold">{copy.main.rendersTitle}</h1>
          {brands.length > 0 && <p className="mt-1 text-[13px] text-subtle">{copy.main.rendersFor(brands.join(", "))}</p>}
        </div>
        {h.kind !== "notRunning" &&
          (paused ? (
            <Button variant="primary" icon="play" onClick={() => actions.setPaused(false)}>{copy.nav.resume}</Button>
          ) : (
            <Button icon="pause" onClick={() => actions.setPaused(true)}>{copy.action.pauseMac}</Button>
          ))}
      </header>

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
        {m.next.length ? (
          <Card>
            <ul className="divide-y divide-border">
              {m.next.map((n, i) => (
                <Row key={`${n.code}-${i}`} icon="hourglass" title={n.recipe || n.code || copy.render} brand={n.brand} detail={n.code} />
              ))}
            </ul>
          </Card>
        ) : (
          <p className="text-[13px] text-subtle">{copy.main.noNext}</p>
        )}
      </section>

      <section className="flex flex-col gap-2" aria-label={copy.section.done}>
        <SectionLabel>{copy.section.done}</SectionLabel>
        {m.done.length ? (
          <Card>
            <ul className="divide-y divide-border">
              {m.done.map((d: DoneRow, i) => (
                <Row
                  key={`${d.code}-${i}`}
                  icon={RESULT_ICON[d.result]}
                  iconClass={RESULT_TONE[d.result]}
                  title={d.code || copy.render}
                  brand={d.brand}
                  detail={copy.result[d.result]}
                  detailClass={d.result === "failed" ? "font-medium text-failed" : undefined}
                  right={d.time}
                />
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
  );
}
