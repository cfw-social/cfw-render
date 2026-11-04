// [WI27] The Server switch as the webview sees it. Rust (`profile.rs`) decides; this only reads.
import { invoke } from "@tauri-apps/api/core";
import { useEffect, useState } from "react";
import { copy } from "./copy";
import type { Health } from "./panel/model";

export type ServerProfile = "production" | "localDev";

export interface ServerView {
  /** What this run uses. */
  active: ServerProfile;
  /** What the next start uses. */
  chosen: ServerProfile;
  /** The active server, e.g. "localhost:3005". */
  server: string | null;
  restartNeeded: boolean;
  error: string | null;
  /** Rust shows the switch only with CFW_RENDER_DEV_TOOLS=1, in a debug build, or in Local dev. */
  switchVisible: boolean;
}

const isProfile = (v: unknown): v is ServerProfile => v === "production" || v === "localDev";

/** A reply that isn't a real view (older app, test stub) counts as "unknown", never as Local dev. */
export function asServerView(v: unknown): ServerView | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  if (!isProfile(o.active)) return null;
  return {
    active: o.active,
    chosen: isProfile(o.chosen) ? o.chosen : o.active,
    server: typeof o.server === "string" ? o.server : null,
    restartNeeded: o.restartNeeded === true,
    error: typeof o.error === "string" ? o.error : null,
    switchVisible: o.switchVisible === true,
  };
}

/** Normal production users never see the Server switch; Local dev always does, to switch back. */
export const showSwitch = (v: ServerView | null) => !!v && (v.switchVisible || v.active === "localDev");

/** The profile is fixed for the app's lifetime, so one read is enough. */
export function useServer(): ServerView | null {
  const [view, setView] = useState<ServerView | null>(null);
  useEffect(() => {
    let live = true;
    invoke<unknown>("get_server_profile")
      .then((v) => live && setView(asServerView(v)))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);
  return view;
}

export const isLocalDev = (v: ServerView | null) => v?.active === "localDev";

/** The badge text while the app runs in Local dev; null in Production. */
export const devBadge = (v: ServerView | null) => (isLocalDev(v) ? copy.server.badge(v?.server ?? null) : null);

/** In Local dev a stopped worker is started from cfw-social, not by this app. */
export function withServer(h: Health, v: ServerView | null): Health {
  return isLocalDev(v) && h.kind === "notRunning" ? { ...h, callout: copy.server.devNotRunning } : h;
}
