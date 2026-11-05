import { describe, expect, it, vi } from "vitest";
import {
  looksLikeRenderKey,
  looksLikeUserCode,
  parseConnectCode,
  parsePollResult,
  pollConnectOnce,
  requestConnectCode,
  waitForConnectApproval,
} from "./connect";

const CODE = {
  deviceCode: "d".repeat(43),
  userCode: "ABCD-EFGH",
  verifyUrl: "https://app.cfw.social/connect?code=ABCD-EFGH",
  interval: 5,
  expiresIn: 600,
};
const KEY = "cfw_render_abcdefghijklmnop";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("connect shapes", () => {
  it("accepts the short user code and cfw_render_ key shapes", () => {
    expect(looksLikeUserCode("ABCD-EFGH")).toBe(true);
    expect(looksLikeUserCode("abcd-efgh")).toBe(false);
    expect(looksLikeRenderKey(KEY)).toBe(true);
    expect(looksLikeRenderKey("cfw_abcdefghijklmnop")).toBe(false);
  });

  it("parses a code response and refuses a bad verify URL", () => {
    expect(parseConnectCode(CODE)).toEqual(CODE);
    expect(() => parseConnectCode({ ...CODE, verifyUrl: "http://evil/connect?code=ABCD-EFGH" })).toThrow(/start connecting/);
    expect(() => parseConnectCode({ ...CODE, userCode: "nope" })).toThrow(/start connecting/);
  });

  it("parses poll pending/denied/expired/approved", () => {
    expect(parsePollResult({ status: "pending" })).toEqual({ status: "pending" });
    expect(parsePollResult({ status: "denied" })).toEqual({ status: "denied" });
    expect(parsePollResult({ status: "expired" })).toEqual({ status: "expired" });
    expect(parsePollResult({ status: "approved", key: KEY, brandSlug: "acme" })).toEqual({
      status: "approved",
      key: KEY,
      brandSlug: "acme",
    });
    // approved without a valid key is treated as expired (do not leak bad material)
    expect(parsePollResult({ status: "approved", key: "cfw_nope", brandSlug: "acme" })).toEqual({ status: "expired" });
  });
});

describe("requestConnectCode + poll", () => {
  it("POSTs /api/v1/connect/code with optional deviceName", async () => {
    const fetchFn = vi.fn().mockResolvedValue(jsonResponse(CODE));
    const got = await requestConnectCode("https://app.cfw.social/", { deviceName: "Vasanth's Mac", fetch: fetchFn });
    expect(got.userCode).toBe("ABCD-EFGH");
    expect(fetchFn).toHaveBeenCalledWith(
      "https://app.cfw.social/api/v1/connect/code",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ deviceName: "Vasanth's Mac" }),
      }),
    );
  });

  it("polls pending then approved once", async () => {
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ status: "pending" }))
      .mockResolvedValueOnce(jsonResponse({ status: "approved", key: KEY, brandSlug: "acme" }));
    expect(await pollConnectOnce("https://app.cfw.social", "dev", { fetch: fetchFn })).toEqual({ status: "pending" });
    expect(await pollConnectOnce("https://app.cfw.social", "dev", { fetch: fetchFn })).toEqual({
      status: "approved",
      key: KEY,
      brandSlug: "acme",
    });
    expect(fetchFn.mock.calls[0][0]).toBe("https://app.cfw.social/api/v1/connect/poll");
    expect(JSON.parse(fetchFn.mock.calls[0][1].body)).toEqual({ deviceCode: "dev" });
  });

  it("maps denied and expired poll outcomes, including 409", async () => {
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ status: "denied" }))
      .mockResolvedValueOnce(jsonResponse({ status: "expired" }))
      .mockResolvedValueOnce(jsonResponse({ error: "need key" }, 409));
    expect(await pollConnectOnce("https://app.cfw.social", "d", { fetch: fetchFn })).toEqual({ status: "denied" });
    expect(await pollConnectOnce("https://app.cfw.social", "d", { fetch: fetchFn })).toEqual({ status: "expired" });
    expect(await pollConnectOnce("https://app.cfw.social", "d", { fetch: fetchFn })).toEqual({ status: "denied" });
  });
});

describe("waitForConnectApproval", () => {
  it("keeps polling while pending then returns approved", async () => {
    const sleep = vi.fn().mockResolvedValue(undefined);
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ status: "pending" }))
      .mockResolvedValueOnce(jsonResponse({ status: "pending" }))
      .mockResolvedValueOnce(jsonResponse({ status: "approved", key: KEY, brandSlug: "acme" }));
    const result = await waitForConnectApproval("https://app.cfw.social", "dev", {
      intervalSec: 1,
      expiresInSec: 60,
      fetch: fetchFn,
      sleep,
    });
    expect(result).toEqual({ status: "approved", key: KEY, brandSlug: "acme" });
    expect(sleep).toHaveBeenCalledTimes(2);
    expect(fetchFn).toHaveBeenCalledTimes(3);
  });

  it("stops on denied and on expiry budget", async () => {
    const sleep = vi.fn().mockResolvedValue(undefined);
    const denied = await waitForConnectApproval("https://app.cfw.social", "dev", {
      intervalSec: 1,
      expiresInSec: 60,
      fetch: vi.fn().mockResolvedValue(jsonResponse({ status: "denied" })),
      sleep,
    });
    expect(denied).toEqual({ status: "denied" });
    expect(sleep).not.toHaveBeenCalled();

    const expired = await waitForConnectApproval("https://app.cfw.social", "dev", {
      intervalSec: 30,
      expiresInSec: 1,
      fetch: vi.fn().mockResolvedValue(jsonResponse({ status: "pending" })),
      sleep,
    });
    expect(expired).toEqual({ status: "expired" });
  });
});
