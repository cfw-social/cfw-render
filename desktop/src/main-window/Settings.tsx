import { getVersion } from "@tauri-apps/api/app";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import { copy } from "../copy";
import { Button, Card, SectionLabel } from "../ui/kit";
import { Toggle } from "../ui/Toggle";

export interface SettingsState { allowBattery: boolean; startAtLogin: boolean }
export interface SupportSettings { shareCrashReports: boolean }
export interface UpdateSettings { autoUpdate: boolean; available: boolean }
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
  const [upd, setUpd] = useState<UpdateSettings | null>(null);
  const [appVersion, setAppVersion] = useState<string | null>(null);
  const [logs, setLogs] = useState<LogsUi>({ k: "idle" });
  const [un, setUn] = useState<{ open: boolean; deleteOutputs: boolean; running: boolean; message: string | null }>(
    { open: false, deleteOutputs: false, running: false, message: null },
  );

  useEffect(() => {
    invoke<SettingsState>("get_settings").then(setS).catch((e: unknown) => console.error("get_settings", e));
    invoke<SupportSettings>("get_support_settings").then(setSupport).catch((e: unknown) => console.error("get_support_settings", e));
    invoke<UpdateSettings>("get_update_settings").then(setUpd).catch((e: unknown) => console.error("get_update_settings", e));
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

  const toggleAutoUpdate = (on: boolean) => {
    const prev = upd;
    setUpd((cur) => (cur ? { ...cur, autoUpdate: on } : cur));
    invoke("set_auto_update", { enabled: on }).catch((e: unknown) => {
      console.error("set_auto_update", e);
      setUpd(prev);
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

  const busy = logs.k === "preparing" || logs.k === "sending";
  const S = copy.settings;
  return (
    <div className="mx-auto flex w-full max-w-[640px] flex-col gap-6 px-8 pt-4 pb-10">
      <h1 className="text-xl font-bold">{S.title}</h1>

      <section className="flex flex-col gap-2">
        <SectionLabel>{S.groupMac}</SectionLabel>
        <Card className="divide-y divide-border">
          <Toggle label={S.battery} note={S.batteryNote} disabled={!s} checked={s?.allowBattery ?? false} onChange={toggle("allowBattery", "set_allow_battery", "allow")} />
          <Toggle label={S.startAtLogin} note={S.startAtLoginNote} disabled={!s} checked={s?.startAtLogin ?? false} onChange={toggle("startAtLogin", "set_start_at_login", "enabled")} />
        </Card>
      </section>

      <section className="flex flex-col gap-2">
        <SectionLabel>{S.groupUpdates}</SectionLabel>
        <Card className="divide-y divide-border">
          <Toggle
            label={S.autoUpdate}
            note={upd?.available ? undefined : S.autoUpdateNote}
            disabled={!upd?.available}
            checked={upd?.available ? upd.autoUpdate : false}
            onChange={toggleAutoUpdate}
          />
          <Toggle label={S.shareCrashReports} note={S.shareCrashReportsNote} disabled={!support} checked={support?.shareCrashReports ?? true} onChange={toggleShare} />
        </Card>
      </section>

      <section className="flex flex-col gap-2">
        <SectionLabel>{S.groupHelp}</SectionLabel>
        <Card className="divide-y divide-border">
          <div className="flex items-center gap-4 px-4 py-3">
            <div className="min-w-0 flex-1">
              <p className="text-[13px] font-medium">{S.sendLogs.replace("…", "")}</p>
              <p className="mt-0.5 text-xs text-subtle">{S.sendLogsNote}</p>
            </div>
            <Button size="sm" disabled={busy || un.running} busy={busy} onClick={startLogs}>{S.sendLogs}</Button>
          </div>
          {logs.k !== "idle" && (
            <div className="px-4 py-3 text-xs" aria-live="polite">
              {logs.k === "preparing" && <p className="text-subtle">{copy.support.logsPreparing}</p>}
              {logs.k === "sending" && <p className="text-subtle">{copy.support.logsSending}</p>}
              {logs.k === "confirm" && (
                <div role="dialog" aria-label={S.sendLogs} className="flex flex-col gap-2.5">
                  <p className="text-[13px]">{copy.support.logsConfirm(fmtSize(logs.sizeBytes))}</p>
                  <div className="flex gap-2">
                    <Button size="sm" variant="primary" onClick={sendLogs}>{copy.support.logsSend}</Button>
                    <Button size="sm" variant="ghost" onClick={() => setLogs({ k: "idle" })}>{copy.support.cancel}</Button>
                  </div>
                </div>
              )}
              {logs.k === "sent" && <p className="font-medium text-success">{copy.support.logsSent(logs.reference)}</p>}
              {logs.k === "failed" && <p role="alert" className="text-failed">{copy.support.logsFailed(logs.why)}</p>}
            </div>
          )}
          <div className="flex items-center gap-4 px-4 py-3">
            <div className="min-w-0 flex-1">
              <p className="text-[13px] font-medium">{S.uninstall.replace("…", "")}</p>
              <p className="mt-0.5 text-xs text-subtle">{S.uninstallNote}</p>
            </div>
            <Button size="sm" variant="danger" disabled={un.running} onClick={() => setUn((u) => ({ ...u, open: true, message: null }))}>{S.uninstall}</Button>
          </div>
          {un.open && (
            <div role="dialog" aria-label={copy.support.uninstallTitle} className="flex flex-col gap-2.5 bg-failed-bg/40 px-4 py-3 text-[13px]">
              <p className="font-semibold">{copy.support.uninstallTitle}</p>
              <p className="text-xs text-muted-foreground">{copy.support.uninstallBody}</p>
              <label className="flex items-center gap-2 text-xs">
                <input type="checkbox" className="accent-primary" disabled={un.running} checked={un.deleteOutputs} onChange={(e) => setUn((u) => ({ ...u, deleteOutputs: e.target.checked }))} />
                {copy.support.uninstallDeleteOutputs}
              </label>
              {un.message && <p className="text-xs" aria-live="polite">{un.message}</p>}
              <div className="flex gap-2">
                <Button size="sm" variant="danger" busy={un.running} disabled={un.running} onClick={() => void runUninstall()}>{copy.support.uninstallConfirm}</Button>
                <Button size="sm" variant="ghost" disabled={un.running} onClick={() => setUn((u) => ({ ...u, open: false }))}>{copy.support.cancel}</Button>
              </div>
            </div>
          )}
        </Card>
      </section>

      <p className="text-xs text-subtle">{S.version(appVersion, workerVersion)}</p>
    </div>
  );
}
