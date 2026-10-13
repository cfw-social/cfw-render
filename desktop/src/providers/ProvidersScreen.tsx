import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useMemo, useState } from "react";
import { copy } from "../copy";
import type { StatusPayload } from "../status";
import { Icon } from "../ui/Icon";
import { Button, Card, Pill, SectionLabel, type Tone } from "../ui/kit";
import { moveEngine, orderedEngines, providersModel, type ProviderCard } from "./model";
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
  const [editing, setEditing] = useState<string | null>(null);

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
        setEditing(null);
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

  const tone = (c: ProviderCard): Tone =>
    c.signingIn ? "info" : !c.connected ? "idle" : c.canRetry ? "bad" : c.stateLine === P.state.connected ? "ok" : "warn";

  const row = (c: ProviderCard) => (
    <li key={c.engine} data-testid={`provider-${c.engine}`} className="px-4 py-3">
      <div className="flex items-center gap-3">
        <span className="w-4 text-right text-xs tabular-nums text-subtle">{c.position}</span>
        <span
          aria-hidden
          className="flex h-8 w-8 shrink-0 items-center justify-center rounded-[7px] text-[11px] font-bold text-white"
          style={{ background: c.logoColor }}
        >
          {c.logo}
        </span>
        <div className="min-w-0 flex-1">
          <p className="flex items-center gap-1.5 text-[13px] font-semibold">
            {c.name}
            {c.connected && <span role="img" aria-label={P.state.connected} className="inline-block h-[7px] w-[7px] rounded-full bg-emerald-500" />}
          </p>
          <p className="mt-0.5 text-xs text-subtle">
            {P.how(c.badges.length > 1 ? "both" : c.auth)}
            {c.acceptsKey && !c.keySaved && (
              <>
                {" · "}
                <button type="button" onClick={() => getKey(c.engine)} className="rounded font-medium text-accent-foreground hover:underline">
                  {P.keyAction.get}
                </button>
              </>
            )}
          </p>
        </div>
        <Pill tone={tone(c)}>{c.canRetry ? P.pill.credit : c.keySaved && c.stateLine === P.state.connected ? P.keySaved : c.stateLine}</Pill>
        <div className="flex w-[168px] shrink-0 items-center justify-end gap-1.5">
          {c.canRetry && (
            <Button size="sm" onClick={() => tryAgain(c.engine)}>{P.keyAction.tryAgain}</Button>
          )}
          {c.signingIn ? (
            <Button size="sm" variant="ghost" onClick={() => cancel(c.engine)}>{P.action.cancel}</Button>
          ) : c.keySaved ? (
            <Button size="sm" variant="ghost" onClick={() => removeKey(c.engine)}>{P.keyAction.remove}</Button>
          ) : c.auth === "api_key" ? (
            editing !== c.engine && <Button size="sm" icon="key-round" onClick={() => setEditing(c.engine)}>{P.addKey}</Button>
          ) : c.connected ? (
            <Button size="sm" variant="ghost" onClick={() => signOut(c.engine)}>{P.action.signOut}</Button>
          ) : (
            <>
              {c.acceptsKey && editing !== c.engine && (
                <Button size="sm" variant="ghost" onClick={() => setEditing(c.engine)}>{P.addKey}</Button>
              )}
              <Button size="sm" variant="primary" onClick={() => signIn(c.engine)}>{P.action.signIn}</Button>
            </>
          )}
        </div>
        <div className="flex shrink-0 flex-col">
          <button
            type="button"
            aria-label={`${P.action.up}: ${c.name}`}
            disabled={c.isFirst}
            onClick={() => move(c.engine, -1)}
            className="flex h-4 w-6 items-center justify-center rounded text-zinc-500 hover:bg-secondary disabled:opacity-25"
          >
            <Icon name="arrow-up" size={12} />
          </button>
          <button
            type="button"
            aria-label={`${P.action.down}: ${c.name}`}
            disabled={c.isLast}
            onClick={() => move(c.engine, 1)}
            className="flex h-4 w-6 items-center justify-center rounded text-zinc-500 hover:bg-secondary disabled:opacity-25"
          >
            <Icon name="arrow-down" size={12} />
          </button>
        </div>
      </div>
      {editing === c.engine && !c.keySaved && (
        <form
          className="mt-3 ml-[60px] flex items-center gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            saveKey(c.engine);
          }}
        >
          <input
            type="password"
            autoComplete="off"
            spellCheck={false}
            autoFocus
            aria-label={P.keyLabel(c.name)}
            placeholder={P.keyPlaceholder}
            value={drafts[c.engine] ?? ""}
            onChange={(e) => setDraft(c.engine, e.target.value)}
            className="h-[34px] min-w-0 flex-1 rounded-[8px] border border-input bg-white px-3 font-mono text-[13px] focus:border-primary"
          />
          <Button type="submit" variant="primary" disabled={!drafts[c.engine]}>{P.keyAction.save}</Button>
          <Button variant="ghost" onClick={() => setEditing(null)}>{P.action.cancel}</Button>
        </form>
      )}
    </li>
  );

  const plans = model.cards.filter((c) => c.auth === "signin");
  const keys = model.cards.filter((c) => c.auth === "api_key");
  return (
    <section className="mx-auto flex w-full max-w-[920px] flex-col gap-5 px-8 pt-4 pb-10">
      <header>
        <div className="flex items-baseline gap-3">
          <h1 className="text-xl font-bold">{P.title}</h1>
          <span className="text-[13px] text-subtle">{model.countLine}</span>
        </div>
        <p className="mt-1 text-[13px] text-subtle">{P.orderHint}</p>
      </header>
      {notice && (
        <p role="status" className="rounded-[8px] border border-warn-border bg-warn-bg px-3 py-2 text-[13px] text-warn-strong">
          {notice}
        </p>
      )}
      <div className="flex flex-col gap-2">
        <SectionLabel>{P.groupPlans}</SectionLabel>
        <Card>
          <ul className="divide-y divide-border">{plans.map(row)}</ul>
        </Card>
      </div>
      <div className="flex flex-col gap-2">
        <SectionLabel>{P.groupKeys}</SectionLabel>
        <Card>
          <ul className="divide-y divide-border">{keys.map(row)}</ul>
        </Card>
      </div>
    </section>
  );
}
