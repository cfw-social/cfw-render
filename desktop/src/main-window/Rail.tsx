import { useEffect, useRef, useState, type ReactNode } from "react";
import { copy } from "../copy";
import type { Health } from "../panel/model";
import type { SectionId } from "../nav";
import { Icon, type IconName } from "../ui/Icon";
import { Dot } from "../ui/kit";

export interface WebBrand { name: string; slug: string; isCurrent: boolean }
export interface WebBrands { signedIn: boolean; brands: WebBrand[] }

const WEB_ITEMS: { id: SectionId; icon: IconName; label: string }[] = [
  { id: "home", icon: "house", label: copy.nav.home },
  { id: "reviews", icon: "clipboard-check", label: copy.nav.reviews },
  { id: "assistant", icon: "message-square", label: copy.nav.assistant },
  { id: "posts", icon: "layout-list", label: copy.nav.posts },
];
const MAC_ITEMS: { id: SectionId; icon: IconName; label: string }[] = [
  { id: "renders", icon: "film", label: copy.nav.renders },
  { id: "providers", icon: "sparkles", label: copy.nav.providers },
  { id: "settings", icon: "settings", label: copy.nav.settings },
];

const initials = (name: string) =>
  name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "")
    .join("") || "?";

function BrandSwitcher({ web, slug, onPick, onAll, onSignIn }: { web: WebBrands | null; slug: string | null; onPick: (slug: string) => void; onAll: () => void; onSignIn: () => void }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => !box.current?.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("mousedown", close);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);

  if (web && !web.signedIn) {
    return (
      <button type="button" onClick={onSignIn} className="mx-3 mt-1 flex items-center gap-2.5 rounded-[6px] px-2 py-1.5 text-left hover:bg-secondary">
        <span className="flex h-7 w-7 items-center justify-center rounded-[7px] bg-accent text-accent-foreground">
          <Icon name="log-in" size={15} />
        </span>
        <span className="text-sm font-semibold">{copy.nav.signIn}</span>
      </button>
    );
  }
  const current = web?.brands.find((b) => b.slug === slug) ?? web?.brands.find((b) => b.isCurrent) ?? web?.brands[0] ?? null;
  return (
    <div ref={box} className="relative mx-3 mt-1">
      <button
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={copy.nav.brandMenu}
        disabled={!web?.brands.length}
        onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center gap-2.5 rounded-[6px] px-2 py-1.5 text-left hover:bg-secondary disabled:hover:bg-transparent"
      >
        <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-[7px] bg-gradient-to-br from-violet-400 to-primary text-[11px] font-semibold text-white">
          {current ? initials(current.name) : <Icon name="loader-circle" size={13} className="animate-spin" />}
        </span>
        <span className="min-w-0 flex-1 truncate text-sm font-semibold">{current?.name ?? copy.web.loading}</span>
        {web && web.brands.length > 1 && <Icon name="chevron-down" size={15} className="text-zinc-500" />}
      </button>
      {open && web && (
        <div role="menu" className="absolute top-full right-0 left-0 z-20 mt-1 rounded-[8px] border border-border bg-card p-1 shadow-lg">
          {web.brands.map((b) => (
            <button
              key={b.slug}
              role="menuitemradio"
              aria-checked={b.slug === current?.slug}
              type="button"
              onClick={() => {
                setOpen(false);
                onPick(b.slug);
              }}
              className="flex w-full items-center gap-2 rounded-[6px] px-2 py-1.5 text-left text-[13px] hover:bg-secondary"
            >
              <span className="min-w-0 flex-1 truncate">{b.name}</span>
              {b.slug === current?.slug && <Icon name="check" size={14} className="text-accent-foreground" />}
            </button>
          ))}
          <div className="my-1 h-px bg-border" />
          <button
            role="menuitem"
            type="button"
            onClick={() => {
              setOpen(false);
              onAll();
            }}
            className="flex w-full items-center gap-2 rounded-[6px] px-2 py-1.5 text-left text-[13px] text-muted-foreground hover:bg-secondary"
          >
            <Icon name="layout-grid" size={14} />
            {copy.nav.allBrands}
          </button>
        </div>
      )}
    </div>
  );
}

/** Left rail, matching the website's: brand switcher, the brand's pages, then This Mac. */
export function Rail({
  section,
  web,
  slug,
  health,
  computerName,
  onSection,
  onPickBrand,
  onAllBrands,
  onSignIn,
  onTogglePause,
}: {
  section: SectionId;
  web: WebBrands | null;
  slug: string | null;
  health: Health;
  computerName: string | null;
  onSection: (s: SectionId) => void;
  onPickBrand: (slug: string) => void;
  onAllBrands: () => void;
  onSignIn: () => void;
  onTogglePause: () => void;
}) {
  const item = (it: { id: SectionId; icon: IconName; label: string }, extra?: ReactNode) => {
    const on = it.id === section;
    return (
      <li key={it.id}>
        <button
          type="button"
          aria-current={on ? "page" : undefined}
          onClick={() => onSection(it.id)}
          className={`flex min-h-[36px] w-full items-center gap-2.5 rounded-[6px] px-3 py-2 text-left text-[13px] ${on ? "bg-accent font-semibold text-accent-foreground" : "font-medium text-muted-foreground hover:bg-secondary"}`}
        >
          <Icon name={it.icon} size={16} />
          <span className="flex-1">{it.label}</span>
          {extra}
        </button>
      </li>
    );
  };
  const providerTrouble = health.kind === "limit" || health.kind === "noProvider";
  const paused = health.kind === "paused" || health.kind === "battery";

  return (
    <aside className="flex h-full w-[208px] shrink-0 flex-col border-r border-border bg-card">
      {/* Room for the window's traffic lights; drag the window from here. */}
      <div data-tauri-drag-region className="h-[46px] shrink-0" />
      <BrandSwitcher web={web} slug={slug} onPick={onPickBrand} onAll={onAllBrands} onSignIn={onSignIn} />
      <nav aria-label="CFW Render" className="mt-3 flex-1 overflow-y-auto border-t border-border px-2 py-3">
        <ul className="flex flex-col gap-0.5">{WEB_ITEMS.map((it) => item(it))}</ul>
        <h2 className="px-3 pt-4 pb-1 text-[11px] font-semibold uppercase tracking-[0.05em] text-faint">{copy.nav.thisMac}</h2>
        <ul className="flex flex-col gap-0.5">
          {MAC_ITEMS.map((it) =>
            item(it, it.id === "providers" && providerTrouble ? <Dot tone="warn" /> : it.id === "renders" && health.tone === "bad" ? <Dot tone="bad" /> : null),
          )}
        </ul>
      </nav>
      <footer className="flex items-center gap-2.5 border-t border-border px-3 py-3">
        <Dot tone={health.tone} />
        <div className="min-w-0 flex-1">
          <p className="truncate text-[13px] font-semibold">{health.label}</p>
          {computerName && <p className="mt-0.5 truncate text-[11px] text-subtle">{computerName}</p>}
        </div>
        {health.kind !== "notRunning" && (
          <button
            type="button"
            onClick={onTogglePause}
            aria-label={paused ? copy.nav.resume : copy.nav.pause}
            title={paused ? copy.nav.resume : copy.nav.pause}
            className="flex h-8 w-8 items-center justify-center rounded-[6px] border border-border bg-white text-muted-foreground hover:bg-secondary"
          >
            <Icon name={paused ? "play" : "pause"} size={14} />
          </button>
        )}
      </footer>
    </aside>
  );
}
