// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";

const h = vi.hoisted(() => ({
  listeners: {} as Record<string, (e: { payload: unknown }) => void>,
  invoke: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: h.invoke }));
vi.mock("@tauri-apps/api/event", () => ({
  listen: (name: string, cb: (e: { payload: unknown }) => void) => {
    h.listeners[name] = cb;
    return Promise.resolve(() => {});
  },
}));

import { ChatScreen } from "./ChatScreen";

afterEach(() => {
  cleanup();
  h.invoke.mockReset();
});

describe("ChatScreen", () => {
  it("sends, streams events for the active brand, stops, and opens links", async () => {
    h.invoke.mockImplementation((cmd: string) => Promise.resolve(cmd === "chat_brands" ? [{ slug: "brand-a", name: "Brand A" }] : null));
    render(<ChatScreen />);
    expect(await screen.findByRole("option", { name: "Brand A" })).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Ask about your brand…"), { target: { value: "what's new?" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));
    expect(h.invoke).toHaveBeenCalledWith("chat_send", { slug: "brand-a", text: "what's new?" });
    expect(screen.getByText("what's new?")).toBeTruthy();
    await act(async () => {
      h.listeners["chat-event"]({ payload: { slug: "brand-a", kind: "tool", name: "list_compositions" } });
      h.listeners["chat-event"]({ payload: { slug: "other", kind: "text", text: "not mine" } });
      h.listeners["chat-event"]({ payload: { slug: "brand-a", kind: "text", text: "One draft." } });
      h.listeners["chat-event"]({ payload: { slug: "brand-a", kind: "link", text: "Open c1", url: "https://app.cfw.social/c1" } });
    });
    expect(screen.getByText("Looking at your drafts…")).toBeTruthy();
    expect(screen.getByText("One draft.")).toBeTruthy();
    expect(screen.queryByText("not mine")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Stop" }));
    expect(h.invoke).toHaveBeenCalledWith("chat_cancel", { slug: "brand-a" });
    fireEvent.click(screen.getByRole("button", { name: "Open c1" }));
    expect(h.invoke).toHaveBeenCalledWith("open_url", { url: "https://app.cfw.social/c1" });
    await act(async () => h.listeners["chat-event"]({ payload: { slug: "brand-a", kind: "done" } }));
    expect(screen.getByRole("button", { name: "Send" })).toBeTruthy();
  });

  it("adds a brand with a password-type key field", async () => {
    h.invoke.mockImplementation((cmd: string) =>
      Promise.resolve(cmd === "chat_brands" ? [] : cmd === "chat_add_brand" ? [{ slug: "brand-b", name: "Brand B" }] : null),
    );
    render(<ChatScreen />);
    fireEvent.click(await screen.findByRole("button", { name: "Add a brand" }));
    const key = screen.getByLabelText("Brand key") as HTMLInputElement;
    expect(key.type).toBe("password");
    fireEvent.change(screen.getByLabelText("Brand name"), { target: { value: "Brand B" } });
    fireEvent.change(key, { target: { value: "cfw_secret_123456" } });
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Save" })));
    expect(h.invoke).toHaveBeenCalledWith("chat_add_brand", { slug: "brand-b", name: "Brand B", key: "cfw_secret_123456" });
    expect(await screen.findByRole("option", { name: "Brand B" })).toBeTruthy();
  });
});
