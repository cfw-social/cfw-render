import { invoke } from "@tauri-apps/api/core";
import { useState } from "react";
import { copy } from "../copy";
import type { ConnectionSummary } from "../panel/model";
import { Button } from "../ui/kit";

const why = (e: unknown) => (typeof e === "string" ? e : e instanceof Error ? e.message : String(e));

/**
 * Which key this Mac uses, which brands it serves, and a way to switch to every brand.
 * `showBrands={false}` keeps just the count line (Renders); Settings lists every brand.
 */
export function Connection({ summary, showBrands = true }: { summary: ConnectionSummary; showBrands?: boolean }) {
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const shown = showBrands ? summary.brands : [];
  const C = copy.connection;

  const useAll = () => {
    setBusy(true);
    setError(null);
    invoke("setup_with_account")
      .then(() => setConfirm(false))
      .catch((e: unknown) => setError(C.useAllFailed(why(e))))
      .finally(() => setBusy(false));
  };

  return (
    <div className="flex flex-col gap-1.5" data-testid="connection">
      <p className="text-[13px] font-medium">{summary.line}</p>
      {summary.keyLine && <p className="text-xs text-subtle">{summary.keyLine}</p>}
      {shown.length > 0 && (
        <ul className="flex flex-wrap gap-1.5" aria-label={C.title}>
          {shown.map((b) => (
            <li key={b} className="rounded-full bg-secondary px-2 py-[2px] text-[11px] text-muted-foreground">{b}</li>
          ))}
        </ul>
      )}
      {!summary.allBrands &&
        (confirm ? (
          <div role="group" aria-label={C.useAll} className="mt-1 flex flex-wrap items-center gap-2">
            <p className="text-xs text-muted-foreground">{C.useAllConfirm}</p>
            <Button size="sm" variant="primary" busy={busy} disabled={busy} onClick={useAll}>{C.useAllGo}</Button>
            <Button size="sm" variant="ghost" disabled={busy} onClick={() => setConfirm(false)}>{C.cancel}</Button>
          </div>
        ) : (
          <div className="mt-1">
            <Button size="sm" icon="key-round" onClick={() => setConfirm(true)}>{C.useAll}</Button>
          </div>
        ))}
      {error && <p role="alert" className="text-xs text-failed">{error}</p>}
    </div>
  );
}
