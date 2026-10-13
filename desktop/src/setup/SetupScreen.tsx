import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import { copy } from "../copy";
import { ProvidersScreen } from "../providers";
import type { StatusPayload } from "../status";
import { setupModel, type SetupEvent, type StepState } from "./model";

const S = copy.setup;
const ICON: Record<StepState, string> = { pending: "○", started: "◐", done: "✓", failed: "✕" };

export function SetupScreen() {
  const [key, setKey] = useState("");
  const [tools, setTools] = useState(true);
  const [sizeMb, setSizeMb] = useState<number | null>(null);
  const [payload, setPayload] = useState<StatusPayload | null>(null);
  const [events, setEvents] = useState<SetupEvent[]>([]);
  const [error, setError] = useState<string | null>(null);
  const model = setupModel(events);

  useEffect(() => {
    invoke<StatusPayload>("get_status").then(setPayload).catch(() => {});
    invoke<number | null>("setup_tools_size")
      .then((b) => setSizeMb(b ? Math.round(b / 1_000_000) : null))
      .catch(() => {});
    const unStatus = listen<StatusPayload>("status", (e) => setPayload(e.payload));
    const unStep = listen<SetupEvent>("setup-step", (e) => setEvents((prev) => [...prev, e.payload]));
    invoke<{ installed: boolean; adoptable: boolean }>("get_setup_status")
      .then((st) => {
        if (st?.adoptable) {
          setEvents([{ step: "checking", state: "started" }]);
          invoke("setup_adopt").catch((e) => setError(String(e)));
        }
      })
      .catch(() => {});
    return () => {
      unStatus.then((f) => f());
      unStep.then((f) => f());
    };
  }, []);

  const signedIn = (payload?.status?.engines ?? []).some((e) => e.signedIn);
  const running = model.phase === "running";
  const canConnect = signedIn && key.trim().length > 0 && !running;

  const connect = () => {
    setError(null);
    setEvents([]);
    invoke("setup_run", { brandKey: key.trim(), installTools: tools })
      .then(() => setKey(""))
      .catch((e) => setError(String(e)));
  };
  const paste = () => navigator.clipboard?.readText().then((t) => setKey(t.trim())).catch(() => {});

  if (model.phase === "ready") {
    return (
      <main className="p-6 space-y-4">
        <h1 className="text-lg font-semibold">{S.steps.ready}</h1>
        {model.readyMessage === S.alreadySetUp && <p>{S.alreadySetUp}</p>}
        <p>{S.finish}</p>
        <button className="rounded bg-black px-3 py-1 text-white" onClick={() => invoke("open_url", { url: "https://app.cfw.social" })}>
          {S.openCfw}
        </button>
      </main>
    );
  }

  return (
    <main className="p-6 space-y-4">
      <h1 className="text-lg font-semibold">{S.title}</h1>
      <label className="block space-y-1">
        <span className="text-sm font-medium">{S.keyLabel}</span>
        <div className="flex gap-2">
          <input
            type="password"
            aria-label={S.keyLabel}
            autoComplete="off"
            className="flex-1 rounded border px-2 py-1"
            value={key}
            onChange={(e) => setKey(e.target.value)}
            disabled={running}
          />
          <button type="button" className="rounded border px-2" onClick={paste} disabled={running}>
            {S.paste}
          </button>
        </div>
        <span className="text-xs text-gray-500">{S.keyHint}</span>
      </label>
      <label className="flex items-start gap-2">
        <input type="checkbox" checked={tools} onChange={(e) => setTools(e.target.checked)} disabled={running} />
        <span>
          {S.consent(sizeMb)}
          <span className="block text-xs text-gray-500">{S.toolNames}</span>
        </span>
      </label>
      {!signedIn && (
        <section className="space-y-2">
          <p className="font-medium">{S.signInFirst}</p>
          <ProvidersScreen />
        </section>
      )}
      {events.length > 0 && (
        <ol className="space-y-1">
          {model.steps.map((s) => (
            <li key={s.step} className="flex gap-2">
              <span aria-hidden>{ICON[s.state]}</span>
              <span>
                {S.steps[s.step]}
                {s.state === "started" && s.pct != null ? ` ${s.pct}%` : ""}
              </span>
            </li>
          ))}
        </ol>
      )}
      {(error || model.phase === "failed") && (
        <p role="alert" className="text-red-600">
          {error ?? model.error}
          {model.action ? ` ${model.action}` : ""}
        </p>
      )}
      <div className="flex gap-2">
        <button className="rounded bg-black px-3 py-1 text-white disabled:opacity-40" disabled={!canConnect} onClick={connect}>
          {model.phase === "failed" ? S.tryAgain : S.connect}
        </button>
        {running && (
          <button className="rounded border px-3 py-1" onClick={() => invoke("setup_cancel")}>
            {S.cancel}
          </button>
        )}
      </div>
    </main>
  );
}
