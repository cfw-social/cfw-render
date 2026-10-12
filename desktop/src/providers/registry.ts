// Provider registry. M3-08 adds providers by appending entries here (D107: list order = default order).
export type ProviderAuth = "signin" | "api_key";

export interface ProviderDef {
  engine: string;
  name: string;
  auth: ProviderAuth;
  /** Where to get a key; API-key providers only. */
  keyUrl?: string;
  /** Initials shown as the logo. */
  logo: string;
  logoColor: string;
}

export const PROVIDERS: readonly ProviderDef[] = [
  { engine: "codex", name: "ChatGPT", auth: "signin", logo: "GPT", logoColor: "#10a37f" },
  { engine: "claude-code", name: "Claude", auth: "signin", logo: "C", logoColor: "#d97757" },
];
