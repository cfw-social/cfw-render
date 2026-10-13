import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { copy } from "../copy";
import type { SigninEvent } from "../providers/ProvidersScreen";
import { PROVIDERS } from "../providers/registry";
import { Icon } from "../ui/Icon";
import { Button, MARK_URL, ProgressBar } from "../ui/kit";
import { looksLikeBrandKey, setupModel, toolsModel, type SetupEvent, type StepState } from "./model";

const S = copy.setup;
type Stage = "brand" | "ai" | "finish";
const PLAN_ENGINES = ["claude-code", "codex"] as const;

function Steps({ n }: { n: number }) {
  return (
    <div className="flex gap-1.5 px-8 pt-2" aria-hidden="true">
      {[1, 2, 3].map((i) => (
        <span key={i} className={`h-1 flex-1 rounded-full ${i <= n ? "bg-primary" : "bg-secondary"}`} />
      ))}
    </div>
  );
}

function Shell({ step, children, footer }: { step: number | null; children: ReactNode; footer?: ReactNode }) {
  return (
    <div className="flex h-screen flex-col bg-card text-foreground">
      <div data-tauri-drag-region className="flex h-10 shrink-0 items-center justify-center">
        <span data-tauri-drag-region className="text-[13px] font-semibold text-muted-foreground">{S.title}</span>
      </div>
      {step != null && <Steps n={step} />}
      <main className="flex min-h-0 flex-1 flex-col overflow-y-auto px-8 pt-7">{children}</main>
      {footer && <footer className="flex shrink-0 justify-end gap-2 px-8 pt-4 pb-6">{footer}</footer>}
    </div>
  );
}

function Heading({ kicker, title, body }: { kicker?: string; title: string; body?: string }) {
  return (
    <>
      {kicker && <p className="text-xs font-semibold text-accent-foreground">{kicker}</p>}
      <h1 className="mt-1.5 text-[22px] leading-tight font-bold">{title}</h1>
      {body && <p className="mt-2 text-sm leading-relaxed text-subtle">{body}</p>}
    </>
  );
}

function RowIcon({ state }: { state: StepState }) {
  if (state === "done")
    return (
      <span className="flex h-[22px] w-[22px] items-center justify-center rounded-full bg-emerald-100 text-success">
        <Icon name="check" size={13} strokeWidth={3} />
      </span>
    );
  if (state === "failed")
    return (
      <span className="flex h-[22px] w-[22px] items-center justify-center rounded-full bg-failed-bg text-failed">
        <Icon name="x" size={13} strokeWidth={3} />
      </span>
    );
  if (state === "started") return <Icon name="loader-circle" size={22} className="animate-spin text-primary" />;
  return <span className="h-[22px] w-[22px] rounded-full border-[1.5px] border-input" />;
}

function CheckRow({ state, title, sub, pct }: { state: StepState; title: string; sub?: string; pct?: number | null }) {
  return (
    <li className="flex items-start gap-3 py-2.5">
      <span className="mt-px">
        <RowIcon state={state} />
      </span>
      <div className="min-w-0 flex-1">
        <p className={`text-sm ${state === "pending" ? "font-medium text-zinc-500" : "font-semibold"}`}>{title}</p>
        {sub && <p className="mt-0.5 text-xs text-subtle">{sub}</p>}
        {state === "started" && pct != null && (
          <div className="mt-2">
            <ProgressBar pct={pct} label={title} />
          </div>
        )}
      </div>
    </li>
  );
}

/** First-run setup: brand key, then an AI sign-in (tools download meanwhile), then install + test render. */
export function SetupScreen() {
  const [stage, setStage] = useState<Stage>("brand");
  const [key, setKey] = useState("");
  const [keyError, setKeyError] = useState(false);
  const [signedIn, setSignedIn] = useState<Record<string, boolean>>({});
  const [signingIn, setSigningIn] = useState<string | null>(null);
  const [aiNotice, setAiNotice] = useState<string | null>(null);
  const [toolEvents, setToolEvents] = useState<SetupEvent[]>([]);
  const [runEvents, setRunEvents] = useState<SetupEvent[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [sizeMb, setSizeMb] = useState<number | null>(null);
  const phase = useRef<"tools" | "run" | null>(null);
  const toolsStarted = useRef(false);

  const tools = toolsModel(toolEvents);
  const run = setupModel(runEvents);

  const checkSignedIn = () => {
    for (const engine of PLAN_ENGINES) {
      invoke<boolean>("provider_status", { engine })
        .then((ok) => setSignedIn((s) => ({ ...s, [engine]: !!ok })))
        .catch(() => {});
    }
  };

  useEffect(() => {
    checkSignedIn();
    invoke<number | null>("setup_tools_size")
      .then((b) => setSizeMb(b ? Math.round(b / 1_000_000) : null))
      .catch(() => {});
    const subs = [
      listen<SetupEvent>("setup-step", (e) => {
        const ev = e.payload;
        if (phase.current === "tools") {
          // The tools step reports its own end; a "result" here is only the tools failing.
          if (ev.step === "result") return;
          setToolEvents((p) => [...p, ev]);
          if (ev.step === "tools_result") {
            phase.current = null;
            checkSignedIn();
          }
        } else setRunEvents((p) => [...p, ev]);
      }),
      listen<SigninEvent>("provider-signin", ({ payload: ev }) => {
        if (ev.state === "waiting") return setSigningIn(ev.engine);
        setSigningIn(null);
        if (ev.state === "connected") {
          setAiNotice(null);
          setSignedIn((s) => ({ ...s, [ev.engine]: true }));
        } else setAiNotice(ev.message ?? copy.providers.event[ev.state]);
      }),
    ];
    invoke<{ installed: boolean; adoptable: boolean }>("get_setup_status")
      .then((st) => {
        if (st?.adoptable) {
          phase.current = "run";
          setStage("finish");
          invoke("setup_adopt").catch((e: unknown) => setError(String(e)));
        }
      })
      .catch(() => {});
    return () => subs.forEach((p) => p.then((f) => f()));
  }, []);

  const startTools = () => {
    if (toolsStarted.current) return;
    toolsStarted.current = true;
    phase.current = "tools";
    invoke("setup_install_tools").catch(() => setToolEvents((p) => [...p, { step: "tools_result", state: "failed" }]));
  };

  const toBrandNext = () => {
    if (!looksLikeBrandKey(key)) return setKeyError(true);
    setKeyError(false);
    setStage("ai");
    startTools();
  };
  const paste = () =>
    navigator.clipboard
      ?.readText()
      .then((t) => {
        setKey(t.trim());
        setKeyError(false);
      })
      .catch(() => {});

  const runSetup = () => {
    setError(null);
    setRunEvents([]);
    phase.current = "run";
    setStage("finish");
    invoke("setup_run", { brandKey: key.trim(), installTools: false })
      .then(() => setKey(""))
      .catch((e: unknown) => setError(String(e)));
  };
  const signIn = (engine: string) => {
    setAiNotice(null);
    setSigningIn(engine);
    invoke("provider_sign_in", { engine }).catch((e: unknown) => {
      setSigningIn(null);
      setAiNotice(String(e));
    });
  };

  // ---------- Done ----------
  if (run.phase === "ready") {
    return (
      <Shell
        step={null}
        footer={
          <Button size="lg" variant="primary" onClick={() => invoke("open_main", { section: "home" }).catch(() => {})}>{S.done.open}</Button>
        }
      >
        <div className="flex flex-col items-center pt-8 text-center">
          <span className="flex h-14 w-14 items-center justify-center rounded-full bg-emerald-100 text-success">
            <Icon name="check" size={28} strokeWidth={2.5} />
          </span>
          <h1 className="mt-4 text-[22px] font-bold">{S.done.title}</h1>
          <p className="mt-2 max-w-[320px] text-sm leading-relaxed text-subtle">
            {run.readyMessage && /already/i.test(run.readyMessage) ? S.done.already : S.done.body}
          </p>
          <div className="mt-7 flex items-center gap-3 rounded-[10px] border border-border bg-background p-3.5 text-left">
            <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[8px] border border-border bg-white">
              <img src={MARK_URL} alt="" width={22} height={22} />
            </span>
            <p className="text-[13px] leading-snug">
              <span className="font-semibold">{S.done.tipTitle}</span>
              <br />
              <span className="text-subtle">{S.done.tipBody}</span>
            </p>
          </div>
        </div>
      </Shell>
    );
  }

  // ---------- Step 3: install + test ----------
  if (stage === "finish") {
    const failed = run.phase === "failed" || !!error;
    const row = (step: string) => run.steps.find((s) => s.step === step);
    const toolsRow: StepState = tools.state === "failed" ? "done" : tools.state === "idle" ? "done" : tools.state;
    return (
      <Shell
        step={3}
        footer={
          failed ? (
            <>
              <Button size="lg" variant="ghost" onClick={() => setStage(key ? "ai" : "brand")}>{S.back}</Button>
              <Button size="lg" variant="primary" icon="refresh-cw" onClick={runSetup} disabled={!key.trim()}>{S.tryAgain}</Button>
            </>
          ) : (
            <Button size="lg" variant="ghost" onClick={() => invoke("setup_cancel").catch(() => {})}>{S.cancel}</Button>
          )
        }
      >
        <Heading kicker={S.stepOf(3)} title={S.ready.title} body={S.ready.body} />
        <ul className="mt-5">
          <CheckRow state="done" title={S.rows.brand} />
          <CheckRow state="done" title={S.rows.ai} sub={PROVIDERS.find((p) => signedIn[p.engine])?.name} />
          <CheckRow state={toolsRow} title={S.rows.tools} sub={tools.state === "failed" ? S.toolsFallback : undefined} />
          {(["installing", "connecting", "test_render"] as const).map((s) => {
            const r = row(s);
            return <CheckRow key={s} state={r?.state ?? "pending"} title={S.rows[s]} pct={r?.pct ?? null} />;
          })}
        </ul>
        {failed && (
          <div role="alert" className="mt-3 rounded-[8px] border border-failed-bg bg-failed-bg p-3 text-[13px] text-failed">
            <p className="font-semibold">{S.failedTitle}</p>
            <p className="mt-1">
              {error ?? run.error}
              {run.action ? ` ${run.action}` : ""}
            </p>
          </div>
        )}
      </Shell>
    );
  }

  // ---------- Step 2: AI sign-in ----------
  if (stage === "ai") {
    const anySignedIn = PLAN_ENGINES.some((e) => signedIn[e]);
    const preparing = tools.state === "started" || (toolsStarted.current && tools.state === "idle");
    return (
      <Shell
        step={2}
        footer={
          <>
            <Button size="lg" variant="ghost" onClick={() => setStage("brand")}>{S.back}</Button>
            <Button size="lg" variant="primary" disabled={!anySignedIn} onClick={runSetup}>{S.continue}</Button>
          </>
        }
      >
        <Heading kicker={S.stepOf(2)} title={S.ai.title} body={S.ai.body} />
        <div className="mt-5 grid grid-cols-2 gap-2.5">
          {PLAN_ENGINES.map((engine) => {
            const p = PROVIDERS.find((d) => d.engine === engine);
            if (!p) return null;
            const on = !!signedIn[engine];
            // ChatGPT's sign-in tool arrives with the video tools; Claude's is the owner's own install.
            const waitForTools = engine === "codex" && preparing;
            return (
              <div key={engine} className={`flex flex-col gap-2.5 rounded-[10px] border p-3.5 ${on ? "border-primary ring-1 ring-primary" : "border-border"}`}>
                <div className="flex items-center gap-2.5">
                  <span aria-hidden className="flex h-[30px] w-[30px] items-center justify-center rounded-[7px] text-xs font-bold text-white" style={{ background: p.logoColor }}>
                    {p.logo}
                  </span>
                  <div>
                    <p className="text-sm font-semibold">{p.name}</p>
                    <p className="text-xs text-subtle">{S.ai.plan[engine]}</p>
                  </div>
                </div>
                {on ? (
                  <span className="inline-flex items-center gap-1 self-start rounded-full bg-success-bg px-2 py-[3px] text-[11px] font-semibold text-success">
                    <Icon name="check" size={11} strokeWidth={3} />
                    {S.ai.signedIn}
                  </span>
                ) : waitForTools ? (
                  <span className="text-xs text-subtle">{S.ai.preparing(tools.pct)}</span>
                ) : (
                  <Button size="sm" className="self-start" busy={signingIn === engine} disabled={!!signingIn} onClick={() => signIn(engine)}>
                    {S.ai.signIn}
                  </Button>
                )}
              </div>
            );
          })}
        </div>
        {aiNotice && <p role="status" className="mt-3 text-[13px] text-warn-strong">{aiNotice}</p>}
        <p className="mt-4 text-xs text-subtle">
          {tools.state === "failed" ? S.toolsFallback : sizeMb ? S.toolsNote(sizeMb) : null}
        </p>
      </Shell>
    );
  }

  // ---------- Step 1: brand key ----------
  return (
    <Shell step={1} footer={<Button size="lg" variant="primary" onClick={toBrandNext} disabled={!key.trim()}>{S.continue}</Button>}>
      <Heading kicker={S.stepOf(1)} title={S.brand.title} body={S.brand.body} />
      <form
        className="mt-6"
        onSubmit={(e) => {
          e.preventDefault();
          toBrandNext();
        }}
      >
        <label htmlFor="brand-key" className="block text-[13px] font-semibold">{S.brand.keyLabel}</label>
        <div className="mt-1.5 flex gap-2">
          <input
            id="brand-key"
            type="password"
            autoComplete="off"
            spellCheck={false}
            autoFocus
            placeholder={S.brand.placeholder}
            aria-invalid={keyError || undefined}
            aria-describedby={keyError ? "brand-key-error" : undefined}
            value={key}
            onChange={(e) => {
              setKey(e.target.value);
              setKeyError(false);
            }}
            className={`h-[38px] min-w-0 flex-1 rounded-[8px] border bg-white px-3 font-mono text-[13px] ${keyError ? "border-destructive" : "border-input focus:border-primary"}`}
          />
          <Button size="lg" icon="clipboard-paste" onClick={paste}>{S.brand.paste}</Button>
        </div>
        {keyError && (
          <p id="brand-key-error" role="alert" className="mt-2 text-xs text-destructive">{S.brand.bad}</p>
        )}
      </form>
      <p className="mt-4 text-xs text-subtle">
        {S.brand.where}{" "}
        <button type="button" className="inline-flex items-center gap-1 rounded font-medium text-accent-foreground hover:underline" onClick={() => invoke("open_url", { url: "https://app.cfw.social" }).catch(() => {})}>
          {S.brand.whereLink}
          <Icon name="external-link" size={12} />
        </button>
      </p>
    </Shell>
  );
}
