/** Main-window sections. The first four show app.cfw.social itself (embedded); the rest are this Mac. */
export const WEB_SECTIONS = ["home", "reviews", "assistant", "posts"] as const;
export const MAC_SECTIONS = ["renders", "providers", "settings"] as const;
export type WebSection = (typeof WEB_SECTIONS)[number];
export type MacSection = (typeof MAC_SECTIONS)[number];
export type SectionId = WebSection | MacSection;

export const DEFAULT_SECTION: SectionId = "home";

/** Older ids still sent by `open_main(section)` callers. */
const ALIASES: Record<string, SectionId> = { chat: "assistant" };

export function sectionFromId(id: unknown): SectionId | null {
  if (typeof id !== "string") return null;
  if ((WEB_SECTIONS as readonly string[]).includes(id) || (MAC_SECTIONS as readonly string[]).includes(id)) return id as SectionId;
  return Object.hasOwn(ALIASES, id) ? ALIASES[id] : null;
}

export const isWebSection = (s: SectionId): s is WebSection => (WEB_SECTIONS as readonly string[]).includes(s);

/** Which rail item a website path belongs to (`/<slug>/reviews/x` → reviews). Null when it isn't one of ours. */
export function sectionFromWebPath(path: string, slug: string | null): WebSection | null {
  const parts = path.split("/").filter(Boolean);
  if (!slug || parts[0] !== slug) return null;
  if (parts.length === 1) return "home";
  return (WEB_SECTIONS as readonly string[]).includes(parts[1]) ? (parts[1] as WebSection) : null;
}

/** The brand slug a website path is under, if it looks like one (not /login, /all, /api, …). */
const NOT_BRANDS = new Set(["login", "signup", "all", "api", "onboarding", "settings", "compose", "invite", "auth"]);
export function slugFromWebPath(path: string): string | null {
  const first = path.split("/").filter(Boolean)[0];
  return first && !NOT_BRANDS.has(first) && /^[a-z0-9][a-z0-9-]{0,62}$/.test(first) ? first : null;
}
