import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useReducer, useRef, useState, type FormEvent } from "react";
import { copy } from "../copy";
import { chatReducer, initialChat, type ChatEvent } from "./reducer";

type Brand = { slug: string; name: string };

const slugify = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64);

export function ChatScreen() {
  const [brands, setBrands] = useState<Brand[]>([]);
  const [slug, setSlug] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [state, dispatch] = useReducer(chatReducer, initialChat);
  const [draft, setDraft] = useState("");
  const slugRef = useRef<string | null>(null);
  slugRef.current = slug;

  useEffect(() => {
    invoke<Brand[]>("chat_brands")
      .then((list) => {
        setBrands(list ?? []);
        if (list?.length) setSlug(list[0].slug);
      })
      .catch(() => {});
    const un = listen<ChatEvent>("chat-event", (e) => {
      if (e.payload.slug === slugRef.current) dispatch(e.payload);
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  const pick = (s: string) => {
    if (state.busy && slug) invoke("chat_cancel", { slug }).catch(() => {});
    setSlug(s);
    dispatch({ kind: "reset" });
  };

  const send = (e: FormEvent) => {
    e.preventDefault();
    const text = draft.trim();
    if (!slug || !text || state.busy) return;
    dispatch({ kind: "user", text });
    setDraft("");
    invoke("chat_send", { slug, text }).catch((err: unknown) => dispatch({ slug, kind: "error", text: String(err) }));
  };

  const remove = () => {
    if (!slug) return;
    invoke<Brand[]>("chat_remove_brand", { slug })
      .then((list) => {
        setBrands(list);
        setSlug(list[0]?.slug ?? null);
        dispatch({ kind: "reset" });
      })
      .catch((err: unknown) => setError(String(err)));
  };

  return (
    <section className="flex h-full flex-col gap-3">
      <header className="flex items-center gap-2">
        <h1 className="mr-auto text-lg font-semibold">{copy.chat.title}</h1>
        {brands.length > 0 && (
          <label className="flex items-center gap-1">
            <span className="sr-only">{copy.chat.brandLabel}</span>
            <select aria-label={copy.chat.brandLabel} value={slug ?? ""} onChange={(e) => pick(e.target.value)} className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-800">
              {brands.map((b) => (
                <option key={b.slug} value={b.slug}>{b.name}</option>
              ))}
            </select>
          </label>
        )}
        <button className="rounded px-2 py-1 hover:bg-neutral-100 dark:hover:bg-neutral-800" onClick={() => setAdding(true)}>{copy.chat.addBrand}</button>
        {slug && <button className="rounded px-2 py-1 text-red-700 hover:bg-neutral-100 dark:hover:bg-neutral-800" onClick={remove}>{copy.chat.remove}</button>}
      </header>
      {error && <p role="alert" className="text-red-700">{error}</p>}
      {adding && (
        <AddBrand
          onCancel={() => setAdding(false)}
          onSaved={(list, s) => {
            setBrands(list);
            setAdding(false);
            setError(null);
            pick(s);
          }}
          onError={setError}
        />
      )}
      {!slug && !adding && <p className="text-neutral-500">{copy.chat.noBrands}</p>}
      {slug && (
        <>
          <ol aria-label="Messages" className="flex flex-1 flex-col gap-2 overflow-y-auto">
            {state.messages.map((m, i) => {
              switch (m.role) {
                case "user":
                  return <li key={i} className="self-end whitespace-pre-wrap rounded-lg bg-blue-600 px-3 py-2 text-white">{m.text}</li>;
                case "assistant":
                  return <li key={i} className="whitespace-pre-wrap">{m.text}</li>;
                case "link":
                  return (
                    <li key={i}>
                      <button className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600" onClick={() => invoke("open_url", { url: m.url }).catch(() => {})}>{m.text}</button>
                    </li>
                  );
                case "error":
                  return <li key={i} role="alert" className="text-red-700">{m.text}</li>;
                default:
                  return <li key={i} className="text-neutral-500">{m.text}</li>;
              }
            })}
          </ol>
          <form onSubmit={send} className="flex gap-2">
            <textarea aria-label={copy.chat.placeholder} placeholder={copy.chat.placeholder} value={draft} onChange={(e) => setDraft(e.target.value)} rows={2} className="flex-1 rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-800" />
            {state.busy ? (
              <button type="button" className="rounded bg-neutral-200 px-3 dark:bg-neutral-700" onClick={() => invoke("chat_cancel", { slug }).catch(() => {})}>{copy.chat.stop}</button>
            ) : (
              <button type="submit" disabled={!draft.trim()} className="rounded bg-blue-600 px-3 text-white disabled:opacity-50">{copy.chat.send}</button>
            )}
          </form>
        </>
      )}
    </section>
  );
}

function AddBrand({ onCancel, onSaved, onError }: { onCancel: () => void; onSaved: (list: Brand[], slug: string) => void; onError: (e: string) => void }) {
  const [name, setName] = useState("");
  const [key, setKey] = useState("");
  const submit = (e: FormEvent) => {
    e.preventDefault();
    const slug = slugify(name);
    invoke<Brand[]>("chat_add_brand", { slug, name: name.trim(), key })
      .then((list) => onSaved(list, slug))
      .catch((err: unknown) => onError(String(err)))
      .finally(() => setKey(""));
  };
  return (
    <form onSubmit={submit} aria-label={copy.chat.addBrand} className="flex flex-col gap-2 rounded border border-neutral-200 p-3 dark:border-neutral-700">
      <label className="flex flex-col">{copy.chat.brandName}<input value={name} onChange={(e) => setName(e.target.value)} className="rounded border px-2 py-1 dark:bg-neutral-800" /></label>
      <label className="flex flex-col">{copy.chat.brandKey}<input type="password" autoComplete="off" value={key} onChange={(e) => setKey(e.target.value)} className="rounded border px-2 py-1 dark:bg-neutral-800" /></label>
      <div className="flex gap-2">
        <button type="submit" disabled={!slugify(name) || !key} className="rounded bg-blue-600 px-3 py-1 text-white disabled:opacity-50">{copy.chat.save}</button>
        <button type="button" onClick={onCancel}>{copy.chat.cancel}</button>
      </div>
    </form>
  );
}
