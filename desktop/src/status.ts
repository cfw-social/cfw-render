// Mirrors desktop/src-tauri/src/state.rs + lib.rs StatusPayload. Every field but `schema` is optional.
export type Limit = "ok" | "limited" | "unknown";
export type RunResult = "done" | "failed" | "stopped";

export interface Engine {
  name: string;
  label?: string | null;
  auth?: string | null;
  signedIn?: boolean;
  limit?: Limit;
  resetsAt?: string | null;
  /** Why it's limited, e.g. "credit" (out of funds). */
  reason?: string | null;
}
export interface Computer {
  name?: string | null;
  max?: number;
  running?: number;
  onBattery?: boolean;
  paused?: boolean;
  pauseReason?: string | null;
  updateRequired?: boolean;
}
export interface Brand { id?: string; name?: string; serving?: boolean }
export interface NowItem {
  shortCode?: string | null;
  brand?: string | null;
  recipe?: string | null;
  step?: number | null;
  steps?: number | null;
  stepLabel?: string | null;
  pct?: number | null;
  startedAt?: string | null;
}
export interface NextItem { shortCode?: string | null; brand?: string | null; recipe?: string | null }
export interface RecentItem { shortCode?: string | null; brand?: string | null; result?: RunResult | string; finishedAt?: string | null }

export interface StatusFile {
  schema: number;
  workerVersion?: string | null;
  engines?: Engine[];
  activeEngine?: string | null;
  computer?: Computer;
  brands?: Brand[];
  now?: NowItem[];
  next?: NextItem[];
  recent?: RecentItem[];
  lastCheckAt?: string | null;
  lastError?: string | null;
}

export type Liveness = "Running" | "NotRunning";
export type IconState = "Working" | "Idle" | "Attention";

export interface StatusPayload {
  status: StatusFile | null;
  liveness: Liveness;
  iconState: IconState;
  tooltip: string;
  providerLine: string;
}
