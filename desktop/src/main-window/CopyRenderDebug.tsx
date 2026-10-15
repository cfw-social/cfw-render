import { useRef, useState } from "react";
import { copy } from "../copy";
import type { RecentItem } from "../status";
import { Button } from "../ui/kit";
import { renderDebugInstructions } from "./render-debug";

export function CopyRenderDebug({ item }: { item: RecentItem }) {
  const [state, setState] = useState<"idle" | "pending" | "copied" | "failed">("idle");
  const pending = useRef(false);
  const text = renderDebugInstructions(item);
  const onCopy = async () => {
    if (pending.current) return;
    pending.current = true;
    setState("pending");
    try {
      await navigator.clipboard.writeText(text);
      setState("copied");
    } catch {
      setState("failed");
    } finally {
      pending.current = false;
    }
  };
  return (
    <div className="col-span-full flex flex-wrap items-center gap-2">
      <Button size="sm" onClick={() => void onCopy()} disabled={state === "pending"} busy={state === "pending"}>
        {copy.action.copyDebug}
      </Button>
      <span role="status" aria-live="polite" className="text-xs text-subtle">
        {state === "copied" ? copy.debug.copied : state === "failed" ? copy.debug.failed : null}
      </span>
      {state === "failed" && <textarea aria-label={copy.action.copyDebug} readOnly value={text} onFocus={(event) => event.currentTarget.select()} className="h-40 w-full rounded-md border border-input p-2 text-xs" />}
    </div>
  );
}
