import { invoke } from "@tauri-apps/api/core";
import type { PanelActions } from "../panel/Panel";

export const call = (cmd: string, args?: Record<string, unknown>) => {
  invoke(cmd, args).catch((e: unknown) => console.error(cmd, e));
};

export const actions: PanelActions = {
  openMain: (section) => call("open_main", { section }),
  startWorker: () => call("start_worker"),
  setPaused: (paused) => call("set_paused", { paused }),
  allowBattery: () => call("set_allow_battery", { allow: true }),
  runNow: () => call("run_now"),
  openLogs: () => call("open_logs"),
};
