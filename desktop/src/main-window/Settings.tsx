import { getVersion } from "@tauri-apps/api/app";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import { copy } from "../copy";
import { btn } from "../panel/Panel";

export interface SettingsState { allowBattery: boolean; startAtLogin: boolean }
export interface SupportSettings { shareCrashReports: boolean }
interface UninstallStep { step: string; state: string; message: string }

type LogsUi =
  | { k: "idle" }
  | { k: "preparing" }
  | { k: "confirm"; sizeBytes: number }
  | { k: "sending" }
  | { k: "sent"; reference: string }
  | { k: "failed"; why: string };

const fmtSize = (n: number) => (n < 1024 ? `${n} B` : n < 1024 * 1024 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(1)} MB`);
const why = (e: unknown) => (typeof e === "string" ? e : e instanceof Error ? e.message : String(e));

export function Settings({ workerVersion }: { workerVersion: string | null }) {
  const [s, setS] = useState<SettingsState | null>(null);
  const [support, setSupport] = useState<SupportSettings | null>(null);
  const [appVersion, setAppVersion] = useState<string | null>(null);
  const [logs, setLogs] = useState<LogsUi>({ k: "idle" });
  const [un, setUn] = useState<{ open: boolean; deleteOutputs: boolean; running: boolean; message: string | null }>(
    { open: false, deleteOutputs: false, running: false, message: null },
  );

  useEffect(() => {
    invoke<SettingsState>("get_settings").then(setS).catch((e: unknown) => console.error("get_settings", e));
    invoke<SupportSettings>("get_support_settings").then(setSupport).catch((e: unknown) => console.error("get_support_settings", e));
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

  const toggleShare = (on: boolean) => {
    const prev = support;
    setSupport({ shareCrashReports: on });
    invoke("set_share_crash_reports", { enabled: on }).catch((e: unknown) => {
      console.error("set_share_crash_reports", e);
      setSupport(prev);
    });
  };

  const startLogs = () => {
    setLogs({ k: "preparing" });
    invoke<{ sizeBytes: number; path: string }>("send_logs_preview")
      .then((p) => setLogs({ k: "confirm", sizeBytes: p.sizeBytes }))
      .catch((e: unknown) => setLogs({ k: "failed", why: why(e) }));
  };
  const sendLogs = () => {
    setLogs({ k: "sending" });
    invoke<{ reference: string }>("send_logs")
      .then((r) => setLogs({ k: "sent", reference: r.reference }))
      .catch((e: unknown) => setLogs({ k: "failed", why: why(e) }));
  };

  const runUninstall = async () => {
    setUn((u) => ({ ...u, running: true, message: copy.support.uninstallWorking }));
    const off = await listen<UninstallStep>("uninstall-step", (ev) => setUn((u) => ({ ...u, message: ev.payload.message })));
    try {
      await invoke("uninstall", { deleteOutputs: un.deleteOutputs });
    } catch (e: unknown) {
      setUn((u) => ({ ...u, running: false, message: copy.support.uninstallFailed(why(e)) }));
    } finally {
      off();
    }
  };

  const row = "flex items-center gap-2";
  const busy = logs.k === "preparing" || logs.k === "sending";
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
        <label className={row}>
          <input type="checkbox" disabled={!support} checked={support?.shareCrashReports ?? true} onChange={(e) => toggleShare(e.target.checked)} />
          {copy.settings.shareCrashReports}
        </label>
        <p className="ml-6 text-xs text-neutral-500">{copy.settings.shareCrashReportsNote}</p>
      </div>
      <div>
        <label className={`${row} text-neutral-400`}>
          <input type="checkbox" disabled checked={false} readOnly />
          {copy.settings.autoUpdate}
        </label>
        <p className="ml-6 text-xs text-neutral-500">{copy.settings.autoUpdateNote}</p>
      </div>
      <div className="flex gap-2">
        <button className={`${btn} disabled:opacity-50`} disabled={busy || un.running} onClick={startLogs}>{copy.settings.sendLogs}</button>
        <button className={`${btn} disabled:opacity-50`} disabled={un.running} onClick={() => setUn((u) => ({ ...u, open: true, message: null }))}>{copy.settings.uninstall}</button>
      </div>
      {logs.k === "preparing" && <p className="text-xs">{copy.support.logsPreparing}</p>}
      {logs.k === "sending" && <p className="text-xs">{copy.support.logsSending}</p>}
      {logs.k === "confirm" && (
        <div role="dialog" className="flex flex-col gap-2 rounded border border-neutral-700 p-2 text-xs">
          <p>{copy.support.logsConfirm(fmtSize(logs.sizeBytes))}</p>
          <div className="flex gap-2">
            <button className={btn} onClick={sendLogs}>{copy.support.logsSend}</button>
            <button className={btn} onClick={() => setLogs({ k: "idle" })}>{copy.support.cancel}</button>
          </div>
        </div>
      )}
      {logs.k === "sent" && <p className="text-xs">{copy.support.logsSent(logs.reference)}</p>}
      {logs.k === "failed" && <p className="text-xs text-red-400">{copy.support.logsFailed(logs.why)}</p>}
      {un.open && (
        <div role="dialog" aria-label={copy.support.uninstallTitle} className="flex flex-col gap-2 rounded border border-neutral-700 p-2 text-xs">
          <p className="font-semibold">{copy.support.uninstallTitle}</p>
          <p>{copy.support.uninstallBody}</p>
          <label className={row}>
            <input type="checkbox" disabled={un.running} checked={un.deleteOutputs} onChange={(e) => setUn((u) => ({ ...u, deleteOutputs: e.target.checked }))} />
            {copy.support.uninstallDeleteOutputs}
          </label>
          {un.message && <p>{un.message}</p>}
          <div className="flex gap-2">
            <button className={`${btn} disabled:opacity-50`} disabled={un.running} onClick={() => void runUninstall()}>{copy.support.uninstallConfirm}</button>
            <button className={`${btn} disabled:opacity-50`} disabled={un.running} onClick={() => setUn((u) => ({ ...u, open: false }))}>{copy.support.cancel}</button>
          </div>
        </div>
      )}
      <p className="text-xs text-neutral-500">{copy.settings.version(appVersion, workerVersion)}</p>
    </div>
  );
}
