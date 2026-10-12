import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import { copy } from "../copy";
import { SECTION_IDS, sectionFromId, type SectionId } from "../nav";
import type { StatusPayload } from "../status";
import { ProvidersScreen } from "../providers";
import { Renders } from "./Renders";
import { Settings } from "./Settings";
import { actions } from "./tauri";

export function MainWindow({ initial = "renders", clock }: { initial?: SectionId; clock?: () => number }) {
  const [section, setSection] = useState<SectionId>(initial);
  const [payload, setPayload] = useState<StatusPayload | null>(null);

  useEffect(() => {
    invoke<StatusPayload>("get_status").then(setPayload).catch(() => {});
    const unStatus = listen<StatusPayload>("status", (e) => setPayload(e.payload));
    const unNav = listen<string>("navigate", (e) => {
      const s = sectionFromId(e.payload);
      if (s) setSection(s);
    });
    return () => {
      unStatus.then((f) => f());
      unNav.then((f) => f());
    };
  }, []);

  return (
    <div className="flex h-screen font-sans text-sm text-neutral-900 dark:bg-neutral-900 dark:text-neutral-100">
      <nav className="w-56 border-r border-neutral-200 bg-neutral-50 p-4 dark:border-neutral-700 dark:bg-neutral-800">
        <ul className="space-y-1">
          {(Object.keys(SECTION_IDS) as SectionId[]).map((id) => (
            <li key={id}>
              <button
                aria-current={section === id ? "page" : undefined}
                className={`w-full rounded-md px-2 py-1 text-left ${section === id ? "bg-neutral-200 font-medium dark:bg-neutral-700" : "hover:bg-neutral-100 dark:hover:bg-neutral-700/50"}`}
                onClick={() => setSection(id)}
              >
                {SECTION_IDS[id]}
              </button>
            </li>
          ))}
        </ul>
      </nav>
      <main className="flex flex-1 flex-col overflow-y-auto p-6" data-section={section}>
        {section === "chat" && <p>{copy.main.chatPlaceholder}</p>}
        {section === "providers" && <ProvidersScreen />}
        {section === "renders" && <Renders payload={payload} actions={{ ...actions, openMain: (s) => { const id = sectionFromId(s); if (id) setSection(id); } }} clock={clock} />}
        {section === "settings" && <Settings workerVersion={payload?.status?.workerVersion ?? null} />}
      </main>
    </div>
  );
}
