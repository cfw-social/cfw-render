export const NAV_ITEMS = ["Chat", "Renders on this Mac", "AI Providers", "Settings"] as const;
export type NavItem = (typeof NAV_ITEMS)[number];

/** Section ids used by `open_main(section)` / the `navigate` event. */
export const SECTION_IDS = { chat: "Chat", renders: "Renders on this Mac", providers: "AI Providers", settings: "Settings" } as const satisfies Record<string, NavItem>;
export type SectionId = keyof typeof SECTION_IDS;

export function sectionFromId(id: unknown): SectionId | null {
  return typeof id === "string" && Object.hasOwn(SECTION_IDS, id) ? (id as SectionId) : null;
}
