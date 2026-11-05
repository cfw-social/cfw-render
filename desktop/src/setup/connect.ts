/** Browser-approval connect: request a short code, poll until approved, never log the key. */

export type ConnectCodeResponse = {
  deviceCode: string;
  userCode: string;
  verifyUrl: string;
  interval: number;
  expiresIn: number;
};

export type PollPending = { status: "pending" | "denied" | "expired" };
export type PollApproved = { status: "approved"; key: string; brandSlug: string };
export type PollResult = PollPending | PollApproved;

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

const USER_CODE_RE = /^[A-Z0-9]{4}-[A-Z0-9]{4}$/;
const RENDER_KEY_RE = /^cfw_render_[A-Za-z0-9_-]{8,200}$/;

export const looksLikeUserCode = (code: string) => USER_CODE_RE.test(code.trim());
export const looksLikeRenderKey = (key: string) => RENDER_KEY_RE.test(key.trim());

function apiRoot(base: string): string {
  return base.replace(/\/+$/, "");
}

function asPositiveInt(v: unknown, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.floor(v) : fallback;
}

export function parseConnectCode(data: unknown): ConnectCodeResponse {
  if (!data || typeof data !== "object") throw new Error("Could not start connecting. Try again.");
  const o = data as Record<string, unknown>;
  const deviceCode = typeof o.deviceCode === "string" ? o.deviceCode.trim() : "";
  const userCode = typeof o.userCode === "string" ? o.userCode.trim() : "";
  const verifyUrl = typeof o.verifyUrl === "string" ? o.verifyUrl.trim() : "";
  if (!deviceCode || deviceCode.length < 16) throw new Error("Could not start connecting. Try again.");
  if (!looksLikeUserCode(userCode)) throw new Error("Could not start connecting. Try again.");
  if (!/^https:\/\//i.test(verifyUrl) || !verifyUrl.includes("/connect?code=")) {
    throw new Error("Could not start connecting. Try again.");
  }
  return {
    deviceCode,
    userCode,
    verifyUrl,
    interval: asPositiveInt(o.interval, 5),
    expiresIn: asPositiveInt(o.expiresIn, 600),
  };
}

export function parsePollResult(data: unknown): PollResult {
  if (!data || typeof data !== "object") return { status: "expired" };
  const o = data as Record<string, unknown>;
  const status = o.status;
  if (status === "pending" || status === "denied" || status === "expired") return { status };
  if (status === "approved") {
    const key = typeof o.key === "string" ? o.key.trim() : "";
    const brandSlug = typeof o.brandSlug === "string" ? o.brandSlug.trim() : "";
    if (!looksLikeRenderKey(key) || !brandSlug) return { status: "expired" };
    return { status: "approved", key, brandSlug };
  }
  return { status: "expired" };
}

/** POST /api/v1/connect/code */
export async function requestConnectCode(
  apiBase: string,
  opts: { deviceName?: string; fetch?: FetchLike } = {},
): Promise<ConnectCodeResponse> {
  const f = opts.fetch ?? fetch;
  const body =
    typeof opts.deviceName === "string" && opts.deviceName.trim()
      ? JSON.stringify({ deviceName: opts.deviceName.trim().slice(0, 60) })
      : "{}";
  const res = await f(`${apiRoot(apiBase)}/api/v1/connect/code`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body,
  });
  if (!res.ok) throw new Error("Could not start connecting. Try again.");
  return parseConnectCode(await res.json());
}

/** POST /api/v1/connect/poll — one attempt. */
export async function pollConnectOnce(
  apiBase: string,
  deviceCode: string,
  opts: { fetch?: FetchLike } = {},
): Promise<PollResult> {
  const f = opts.fetch ?? fetch;
  const res = await f(`${apiRoot(apiBase)}/api/v1/connect/poll`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ deviceCode }),
  });
  // WI17.2.1: Social returns 409 when the owner denies the code → treat as denied.
  if (res.status === 409) return { status: "denied" };
  if (!res.ok) return { status: "expired" };
  return parsePollResult(await res.json());
}

export type WaitConnectOpts = {
  intervalSec: number;
  expiresInSec: number;
  fetch?: FetchLike;
  sleep?: (ms: number) => Promise<void>;
  /** Set `.cancelled = true` to stop early (returns expired). */
  signal?: { cancelled: boolean };
};

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * Poll until approved / denied / expired, or until expiresIn elapses.
 * Never returns the key in thrown errors.
 */
export async function waitForConnectApproval(
  apiBase: string,
  deviceCode: string,
  opts: WaitConnectOpts,
): Promise<PollResult> {
  const sleep = opts.sleep ?? defaultSleep;
  const intervalMs = Math.max(1, opts.intervalSec) * 1000;
  const deadline = Date.now() + Math.max(1, opts.expiresInSec) * 1000;
  // First poll immediately, then every interval.
  for (;;) {
    if (opts.signal?.cancelled) return { status: "expired" };
    const result = await pollConnectOnce(apiBase, deviceCode, { fetch: opts.fetch });
    if (result.status !== "pending") return result;
    if (Date.now() + intervalMs > deadline) return { status: "expired" };
    await sleep(intervalMs);
    if (opts.signal?.cancelled) return { status: "expired" };
  }
}
