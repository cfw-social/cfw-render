import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import { actions } from "../main-window/tauri";
import type { StatusPayload } from "../status";
import { Panel } from "./Panel";

export default function PanelWindow() {
  const [payload, setPayload] = useState<StatusPayload | null>(null);
  useEffect(() => {
    invoke<StatusPayload>("get_status").then(setPayload).catch(() => {});
    const un = listen<StatusPayload>("status", (e) => setPayload(e.payload));
    return () => {
      un.then((f) => f());
    };
  }, []);
  return <Panel payload={payload} actions={actions} />;
}
