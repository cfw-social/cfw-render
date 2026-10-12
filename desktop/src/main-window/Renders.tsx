import { copy } from "../copy";
import { StatusBody, useNow, type PanelActions } from "../panel/Panel";
import { rendersModel } from "../panel/model";
import type { StatusPayload } from "../status";

export function Renders({ payload, actions, clock }: { payload: StatusPayload | null; actions: PanelActions; clock?: () => number }) {
  const m = rendersModel(payload, useNow(clock));
  return (
    <div className="flex flex-col">
      <h1 className="mb-3 text-lg font-semibold">{copy.main.rendersTitle}</h1>
      <StatusBody m={m} actions={actions} />
      {m.done.length === 0 && <p className="mt-3 text-neutral-500">{copy.main.noRecent}</p>}
      <div className="mt-4 text-xs text-neutral-500">{m.lastCheck}</div>
    </div>
  );
}
