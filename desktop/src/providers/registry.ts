// Provider registry. M3-08 adds providers by appending entries here (D107: list order = default order).
export type ProviderAuth = "signin" | "api_key";

export interface ProviderDef {
  engine: string;
  name: string;
  auth: ProviderAuth;
  /** Where to get a key; API-key providers only. */
  keyUrl?: string;
  /** A sign-in provider that also accepts an API key (Gemini). */
  alsoApiKey?: boolean;
  /** Initials shown as the logo. */
  logo: string;
  logoColor: string;
}

export const PROVIDERS: readonly ProviderDef[] = [
  { engine: "codex", name: "ChatGPT", auth: "signin", logo: "GPT", logoColor: "#10a37f" },
  { engine: "claude-code", name: "Claude", auth: "signin", logo: "C", logoColor: "#d97757" },
  {
    engine: "gemini",
    name: "Gemini",
    auth: "signin",
    alsoApiKey: true,
    keyUrl: "https://aistudio.google.com/apikey",
    logo: "G",
    logoColor: "#4285f4",
  },
  { engine: "zai", name: "Z.AI", auth: "api_key", keyUrl: "https://z.ai/manage-apikey/apikey-list", logo: "Z", logoColor: "#2d2d2d" },
  { engine: "moonshot", name: "Moonshot", auth: "api_key", keyUrl: "https://platform.moonshot.ai/console/api-keys", logo: "M", logoColor: "#16191e" },
  {
    engine: "minimax",
    name: "MiniMax",
    auth: "api_key",
    keyUrl: "https://www.minimax.io/platform/user-center/basic-information/interface-key",
    logo: "MM",
    logoColor: "#e2167e",
  },
  { engine: "xai", name: "xAI", auth: "api_key", keyUrl: "https://console.x.ai", logo: "X", logoColor: "#000000" },
  { engine: "openrouter", name: "OpenRouter", auth: "api_key", keyUrl: "https://openrouter.ai/keys", logo: "OR", logoColor: "#6467f2" },
];
