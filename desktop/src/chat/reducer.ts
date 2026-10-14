import { copy } from "../copy";

export type ChatEvent = {
  slug: string;
  kind: "text" | "tool" | "link" | "notice" | "done" | "cancelled" | "error";
  text?: string;
  name?: string;
  url?: string;
  engine?: string;
};

export type Message =
  | { role: "user"; text: string }
  | { role: "assistant"; text: string }
  | { role: "tool"; text: string }
  | { role: "link"; text: string; url: string }
  | { role: "notice"; text: string }
  | { role: "error"; text: string };

export type ChatState = { messages: Message[]; busy: boolean };

export type ChatAction = ChatEvent | { kind: "user"; text: string } | { kind: "reset" };

export const initialChat: ChatState = { messages: [], busy: false };

export const toolLine = (name?: string) => (name && copy.chat.tools[name]) || copy.chat.working;

export function chatReducer(state: ChatState, ev: ChatAction): ChatState {
  const push = (m: Message, busy = state.busy): ChatState => ({ messages: [...state.messages, m], busy });
  switch (ev.kind) {
    case "reset":
      return initialChat;
    case "user":
      return push({ role: "user", text: ev.text }, true);
    case "text": {
      const last = state.messages[state.messages.length - 1];
      const text = ev.text ?? "";
      if (last?.role === "assistant") {
        const sep = last.text && text ? "\n\n" : "";
        return { ...state, messages: [...state.messages.slice(0, -1), { role: "assistant", text: last.text + sep + text }] };
      }
      return push({ role: "assistant", text });
    }
    case "tool":
      return push({ role: "tool", text: toolLine(ev.name) });
    case "link":
      if (!ev.url || state.messages.some((m) => m.role === "link" && m.url === ev.url)) return state;
      return push({ role: "link", text: ev.text ?? ev.url, url: ev.url });
    case "notice":
      return push({ role: "notice", text: ev.text ?? "" });
    case "done":
      return { ...state, busy: false };
    case "cancelled":
      return push({ role: "notice", text: copy.chat.stopped }, false);
    case "error":
      return push({ role: "error", text: ev.text ?? "" }, false);
    default:
      return state;
  }
}
