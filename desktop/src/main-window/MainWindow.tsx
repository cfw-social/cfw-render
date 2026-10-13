import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useCallback, useEffect, useRef, useState } from "react";
import { copy } from "../copy";
import { DEFAULT_SECTION, isWebSection, sectionFromId, sectionFromWebPath, slugFromWebPath, type SectionId } from "../nav";
import { health, panelModel } from "../panel/model";
import { ProvidersScreen } from "../providers";
import type { StatusPayload } from "../status";
import { Icon } from "../ui/Icon";
import { Button } from "../ui/kit";
import { Rail, type WebBrands } from "./Rail";
import { Renders } from "./Renders";
import { Settings } from "./Settings";
import { actions } from "./tauri";

const BRAND_KEY = "cfw.brand";
const readSlug = () => {
  try {
    return localStorage.getItem(BRAND_KEY);
  } catch {
    return null;
  }
};
const saveSlug = (s: string) => {
  try {
    localStorage.setItem(BRAND_KEY, s);
  } catch {
    /* private storage off: the website's own redirect still picks a brand */
  }
};

/** Shown behind the embedded website while it loads, or when it can't be opened. */
function WebPlaceholder({ failed, onRetry }: { failed: boolean; onRetry: () => void }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
      {failed ? (
        <>
          <Icon name="circle-alert" size={22} className="text-warn" />
          <p className="text-sm font-semibold">{copy.web.failed}</p>
          <Button variant="primary" icon="refresh-cw" onClick={onRetry}>{copy.web.retry}</Button>
        </>
      ) : (
        <>
          <Icon name="loader-circle" size={22} className="animate-spin text-primary" />
          <p className="text-[13px] text-subtle">{copy.web.loading}</p>
        </>
      )}
    </div>
  );
}

export function MainWindow({ clock = Date.now }: { clock?: () => number } = {}) {
  const [section, setSection] = useState<SectionId>(DEFAULT_SECTION);
  const [payload, setPayload] = useState<StatusPayload | null>(null);
  const [web, setWeb] = useState<WebBrands | null>(null);
  const [slug, setSlug] = useState<string | null>(readSlug);
  const [webFailed, setWebFailed] = useState(false);
  const slugRef = useRef(slug);
  slugRef.current = slug;
  const sectionRef = useRef(section);
  sectionRef.current = section;

  /** `trustSignedOut`: only the website landing on /login proves the owner is signed out; an early
   *  check can run before the embedded view has its cookies. */
  const refreshBrands = useCallback((trustSignedOut = true) => {
    invoke<WebBrands>("web_brands")
      .then((w) => {
        if (!w || (!w.signedIn && !trustSignedOut)) return;
        setWeb(w);
        const cur = slugRef.current;
        if (w.signedIn && w.brands.length && !w.brands.some((b) => b.slug === cur)) {
          const pick = (w.brands.find((b) => b.isCurrent) ?? w.brands[0]).slug;
          setSlug(pick);
          saveSlug(pick);
        }
      })
      .catch(() => {});
  }, []);

  /** Show a section: website sections drive the embedded view, Mac sections hide it. */
  const go = useCallback((next: SectionId, nextSlug: string | null = slugRef.current, webSection?: string) => {
    setSection(next);
    if (isWebSection(next)) {
      setWebFailed(false);
      invoke("web_show", { section: webSection ?? next, slug: nextSlug }).catch(() => setWebFailed(true));
    } else {
      invoke("web_hide").catch(() => {});
    }
  }, []);

  useEffect(() => {
    invoke<StatusPayload>("get_status").then(setPayload).catch(() => {});
    go(DEFAULT_SECTION);
    refreshBrands(false);
    const subs = [
      listen<StatusPayload>("status", (e) => setPayload(e.payload)),
      listen<unknown>("navigate", (e) => {
        const s = sectionFromId(e.payload);
        if (s) go(s);
      }),
      // Where the website ended up after its own redirects and links.
      listen<string>("web-location", (e) => {
        let path: string;
        try {
          path = new URL(e.payload).pathname;
        } catch {
          return;
        }
        if (path.startsWith("/login") || path.startsWith("/signup")) {
          setWeb({ signedIn: false, brands: [] });
          return;
        }
        const s = slugFromWebPath(path);
        if (s && s !== slugRef.current) {
          setSlug(s);
          saveSlug(s);
        }
        if (s) refreshBrands(true);
        const sec = sectionFromWebPath(path, s);
        if (sec && isWebSection(sectionRef.current)) setSection(sec);
      }),
    ];
    return () => subs.forEach((p) => p.then((f) => f()));
  }, [go, refreshBrands]);

  const m = panelModel(payload, clock());
  const h = health(m);
  const paused = h.kind === "paused" || h.kind === "battery";

  return (
    <div className="flex h-screen overflow-hidden bg-background text-foreground">
      <Rail
        section={section}
        web={web}
        slug={slug}
        health={h}
        computerName={payload?.status?.computer?.name ?? null}
        onSection={(s) => go(s)}
        onPickBrand={(s) => {
          setSlug(s);
          saveSlug(s);
          go(isWebSection(section) ? section : "home", s);
        }}
        onAllBrands={() => go("home", slugRef.current, "all")}
        onSignIn={() => go("home", null, "login")}
        onTogglePause={() => actions.setPaused(!paused)}
      />
      <main data-section={section} className="relative min-w-0 flex-1 overflow-y-auto">
        {/* Mac pages get a drag strip where the title bar would be. */}
        {!isWebSection(section) && <div data-tauri-drag-region className="sticky top-0 z-10 h-[30px] bg-background/90" />}
        {isWebSection(section) && <WebPlaceholder failed={webFailed} onRetry={() => go(section)} />}
        {section === "renders" && <Renders payload={payload} actions={actions} clock={clock} />}
        {section === "providers" && <ProvidersScreen />}
        {section === "settings" && <Settings workerVersion={payload?.status?.workerVersion ?? null} />}
      </main>
    </div>
  );
}
