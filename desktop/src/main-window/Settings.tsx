import { getVersion } from "@tauri-apps/api/app";
import { invoke } from "@tauri-apps/api/core";
import { useEffect, useState } from "react";
import { copy } from "../copy";
import { btn } from "../panel/Panel";

export interface SettingsState { allowBattery: boolean; startAtLogin: boolean }

export function Settings({ workerVersion }: { workerVersion: string | null }) {
  const [s, setS] = useState<SettingsState | null>(null);
  const [appVersion, setAppVersion] = useState<string | null>(null);

  useEffect(() => {
    invoke<SettingsState>("get_settings").then(setS).catch((e: unknown) => console.error("get_settings", e));
    getVersion().then(setAppVersion).catch(() => {});
  }, []);

  const toggle = (key: keyof SettingsState, cmd: string, arg: string) => (on: boolean) => {
    const prev = s;
    setS((cur) => (cur ? { ...cur, [key]: on } : cur));
    invoke(cmd, { [arg]: on }).catch((e: unknown) => {
      console.error(cmd, e);
      setS(prev);
    });
  };

  const row = "flex items-center gap-2";
  return (
    <div className="flex max-w-md flex-col gap-3">
      <h1 className="text-lg font-semibold">{copy.settings.title}</h1>
      <label className={row}>
        <input type="checkbox" disabled={!s} checked={s?.allowBattery ?? false} onChange={(e) => toggle("allowBattery", "set_allow_battery", "allow")(e.target.checked)} />
        {copy.settings.battery}
      </label>
      <label className={row}>
        <input type="checkbox" disabled={!s} checked={s?.startAtLogin ?? false} onChange={(e) => toggle("startAtLogin", "set_start_at_login", "enabled")(e.target.checked)} />
        {copy.settings.startAtLogin}
      </label>
      <div>
        <label className={`${row} text-neutral-400`}>
          <input type="checkbox" disabled checked={false} readOnly />
          {copy.settings.autoUpdate}
        </label>
        <p className="ml-6 text-xs text-neutral-500">{copy.settings.autoUpdateNote}</p>
      </div>
      <div className="flex gap-2">
        <button className={`${btn} disabled:opacity-50`} disabled>{copy.settings.sendLogs}</button>
        <button className={`${btn} disabled:opacity-50`} disabled>{copy.settings.uninstall}</button>
      </div>
      <p className="text-xs text-neutral-500">{copy.settings.comingNote}</p>
      <p className="text-xs text-neutral-500">{copy.settings.version(appVersion, workerVersion)}</p>
    </div>
  );
}
