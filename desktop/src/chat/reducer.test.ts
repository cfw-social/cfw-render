import { describe, expect, it } from "vitest";
import { chatReducer, initialChat, type ChatAction } from "./reducer";

const run = (evs: ChatAction[]) => evs.reduce(chatReducer, initialChat);

describe("chatReducer", () => {
  it("streams a turn into bubbles, tool lines and links", () => {
    const s = run([
      { kind: "user", text: "hi" },
      { slug: "a", kind: "tool", name: "list_runs" },
      { slug: "a", kind: "tool", name: "mystery_tool" },
      { slug: "a", kind: "text", text: "One" },
      { slug: "a", kind: "text", text: "Two" },
      { slug: "a", kind: "link", text: "Open r9", url: "https://app.cfw.social/a/runs/r9" },
      { slug: "a", kind: "link", text: "Open r9", url: "https://app.cfw.social/a/runs/r9" },
    ]);
    expect(s.busy).toBe(true);
    expect(s.messages).toEqual([
      { role: "user", text: "hi" },
      { role: "tool", text: "Checking recent runs…" },
      { role: "tool", text: "Working…" },
      { role: "assistant", text: "One\n\nTwo" },
      { role: "link", text: "Open r9", url: "https://app.cfw.social/a/runs/r9" },
    ]);
    expect(chatReducer(s, { slug: "a", kind: "done" }).busy).toBe(false);
  });

  it("shows failover notice, cancel and errors", () => {
    const s = run([
      { kind: "user", text: "hi" },
      { slug: "a", kind: "notice", text: "ChatGPT reached its limit; continuing with Claude." },
      { slug: "a", kind: "cancelled" },
    ]);
    expect(s.messages.slice(1)).toEqual([
      { role: "notice", text: "ChatGPT reached its limit; continuing with Claude." },
      { role: "notice", text: "Stopped." },
    ]);
    expect(s.busy).toBe(false);
    const e = chatReducer(run([{ kind: "user", text: "x" }]), { slug: "a", kind: "error", text: "boom" });
    expect(e).toEqual({ busy: false, messages: [{ role: "user", text: "x" }, { role: "error", text: "boom" }] });
    expect(chatReducer(e, { kind: "reset" })).toEqual(initialChat);
  });
});
