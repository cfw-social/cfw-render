import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import type { StatusPayload } from "../status";
import { Panel, type PanelActions } from "./Panel";

const call = (cmd: string, args?: Record<string, unknown>) => {
  invoke(cmd, args).catch((e: unknown) => console.error(cmd, e));
};

const actions: PanelActions = {
  openMain: (section) => call("open_main", { section }),
  startWorker: () => call("start_worker"),
  setPaused: (paused) => call("set_paused", { paused }),
  allowBattery: () => call("set_allow_battery", { allow: true }),
  runNow: () => call("run_now"),
  openLogs: () => call("open_logs"),
};

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
