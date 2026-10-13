import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useMemo, useState } from "react";
import { copy } from "../copy";
import type { StatusPayload } from "../status";
import { moveEngine, orderedEngines, providersModel } from "./model";
import { PROVIDERS } from "./registry";

export interface SigninEvent {
  engine: string;
  state: "waiting" | "connected" | "timeout" | "cancelled" | "failed";
  message?: string;
}

const P = copy.providers;

/** AI Providers screen. Self-contained: reads `get_status`, listens to `status` + `provider-signin`. */
export function ProvidersScreen() {
  const [payload, setPayload] = useState<StatusPayload | null>(null);
  const [order, setOrder] = useState<string[] | null>(null);
  const [signingIn, setSigningIn] = useState<Set<string>>(new Set());
  const [notice, setNotice] = useState<string | null>(null);
  const [keysSaved, setKeysSaved] = useState<Set<string>>(new Set());
  const [drafts, setDrafts] = useState<Record<string, string>>({});

  useEffect(() => {
    for (const p of PROVIDERS.filter((d) => d.auth === "api_key" || d.alsoApiKey)) {
      invoke<boolean>("provider_key_present", { engine: p.engine })
        .then((ok) => ok && setKeysSaved((s) => new Set(s).add(p.engine)))
        .catch(() => {});
    }
  }, []);

  useEffect(() => {
    invoke<StatusPayload>("get_status").then(setPayload).catch(() => {});
    const unStatus = listen<StatusPayload>("status", (e) => setPayload(e.payload));
    const unSignin = listen<SigninEvent>("provider-signin", ({ payload: ev }) => {
      setSigningIn((prev) => {
        const next = new Set(prev);
        if (ev.state === "waiting") next.add(ev.engine);
        else next.delete(ev.engine);
        return next;
      });
      if (ev.state === "timeout" || ev.state === "cancelled" || ev.state === "failed") {
        setNotice(ev.message ?? P.event[ev.state]);
      } else setNotice(null);
      if (ev.state === "connected") invoke<StatusPayload>("get_status").then(setPayload).catch(() => {});
    });
    return () => {
      unStatus.then((f) => f());
      unSignin.then((f) => f());
    };
  }, []);

  const engines = payload?.status?.engines;
  // Until the owner reorders, the worker's reported engine order is the current order.
  const effectiveOrder = order ?? orderedEngines(PROVIDERS, (engines ?? []).map((e) => e.name));
  const model = useMemo(
    () => providersModel(PROVIDERS, engines, effectiveOrder, signingIn, keysSaved),
    [engines, effectiveOrder, signingIn, keysSaved],
  );

  const move = (engine: string, delta: -1 | 1) => {
    const next = moveEngine(effectiveOrder, engine, delta);
    setOrder(next);
    invoke("set_engine_order", { order: next }).catch((e: unknown) => setNotice(String(e)));
  };
  const signIn = (engine: string) => {
    setSigningIn((s) => new Set(s).add(engine));
    invoke("provider_sign_in", { engine }).catch((e: unknown) => {
      setSigningIn((s) => {
        const n = new Set(s);
        n.delete(engine);
        return n;
      });
      setNotice(String(e));
    });
  };
  const cancel = (engine: string) => invoke("provider_sign_in_cancel", { engine }).catch(() => {});
  const signOut = (engine: string) =>
    invoke("provider_sign_out", { engine })
      .then(() => invoke<StatusPayload>("get_status").then(setPayload))
      .catch((e: unknown) => setNotice(String(e)));

  const setDraft = (engine: string, v: string) => setDrafts((d) => ({ ...d, [engine]: v }));
  const saveKey = (engine: string) => {
    const key = (drafts[engine] ?? "").trim();
    invoke("provider_key_save", { engine, key })
      .then(() => {
        setDraft(engine, "");
        setKeysSaved((s) => new Set(s).add(engine));
        setNotice(null);
      })
      .catch((e: unknown) => setNotice(String(e)));
  };
  const removeKey = (engine: string) =>
    invoke("provider_key_remove", { engine })
      .then(() =>
        setKeysSaved((s) => {
          const n = new Set(s);
          n.delete(engine);
          return n;
        }),
      )
      .catch((e: unknown) => setNotice(String(e)));
  const getKey = (engine: string) => invoke("open_provider_key_url", { engine }).catch((e: unknown) => setNotice(String(e)));
  const tryAgain = (engine: string) =>
    invoke("provider_clear_limit", { engine })
      .then(() => invoke<StatusPayload>("get_status").then(setPayload))
      .catch((e: unknown) => setNotice(String(e)));

  return (
    <section className="p-6">
      <header className="mb-4 flex items-baseline gap-3">
        <h1 className="text-xl font-semibold">{P.title}</h1>
        <span className="text-sm text-neutral-500">{model.countLine}</span>
      </header>
      <p className="mb-4 text-sm text-neutral-500">{P.orderHint}</p>
      {notice && (
        <p role="status" className="mb-4 text-sm text-amber-700">
          {notice}
        </p>
      )}
      <ul className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        {model.cards.map((c) => (
          <li key={c.engine} data-testid={`provider-${c.engine}`} className="rounded-lg border border-neutral-200 p-4">
            <div className="flex items-center gap-3">
              <span className="w-5 text-xs text-neutral-400">{c.position}</span>
              <span
                aria-hidden
                className="flex h-9 w-9 items-center justify-center rounded-md text-xs font-bold text-white"
                style={{ background: c.logoColor }}
              >
                {c.logo}
              </span>
              <span className="font-medium">{c.name}</span>
              {c.connected && <span aria-label={P.state.connected} className="h-2 w-2 rounded-full bg-green-500" />}
              <span className="ml-auto flex gap-1">
                {c.badges.map((b) => (
                  <span key={b} className="rounded bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600">
                    {b}
                  </span>
                ))}
              </span>
            </div>
            <p className="mt-2 text-sm text-neutral-600">{c.stateLine}</p>
            {c.canRetry && (
              <button type="button" onClick={() => tryAgain(c.engine)} className="mt-2 rounded border px-3 py-1 text-sm">
                {P.keyAction.tryAgain}
              </button>
            )}
            {c.acceptsKey &&
              (c.keySaved ? (
                <div className="mt-3 flex items-center gap-2 text-sm">
                  <span className="text-green-700">{P.keySaved}</span>
                  <button type="button" onClick={() => removeKey(c.engine)} className="rounded border px-3 py-1">
                    {P.keyAction.remove}
                  </button>
                </div>
              ) : (
                <form
                  className="mt-3 flex items-center gap-2 text-sm"
                  onSubmit={(e) => {
                    e.preventDefault();
                    saveKey(c.engine);
                  }}
                >
                  <input
                    type="password"
                    autoComplete="off"
                    spellCheck={false}
                    aria-label={P.keyLabel(c.name)}
                    placeholder={P.keyPlaceholder}
                    value={drafts[c.engine] ?? ""}
                    onChange={(e) => setDraft(c.engine, e.target.value)}
                    className="min-w-0 flex-1 rounded border px-2 py-1"
                  />
                  <button type="submit" disabled={!drafts[c.engine]} className="rounded border px-3 py-1 disabled:opacity-40">
                    {P.keyAction.save}
                  </button>
                  <button type="button" onClick={() => getKey(c.engine)} className="text-blue-700 underline">
                    {P.keyAction.get}
                  </button>
                </form>
              ))}
            <div className="mt-3 flex gap-2">
              {c.signingIn ? (
                <button type="button" onClick={() => cancel(c.engine)} className="rounded border px-3 py-1 text-sm">
                  {P.action.cancel}
                </button>
              ) : c.auth === "api_key" ? null : c.connected && !c.acceptsKey ? (
                <button type="button" onClick={() => signOut(c.engine)} className="rounded border px-3 py-1 text-sm">
                  {P.action.signOut}
                </button>
              ) : c.connected && c.keySaved ? null : (
                <button
                  type="button"
                  onClick={() => signIn(c.engine)}
                  className="rounded bg-neutral-900 px-3 py-1 text-sm text-white"
                >
                  {P.action.signIn}
                </button>
              )}
              <button
                type="button"
                aria-label={`${P.action.up}: ${c.name}`}
                disabled={c.isFirst}
                onClick={() => move(c.engine, -1)}
                className="ml-auto rounded border px-2 text-sm disabled:opacity-30"
              >
                ↑
              </button>
              <button
                type="button"
                aria-label={`${P.action.down}: ${c.name}`}
                disabled={c.isLast}
                onClick={() => move(c.engine, 1)}
                className="rounded border px-2 text-sm disabled:opacity-30"
              >
                ↓
              </button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
