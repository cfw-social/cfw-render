import { copy } from "../copy";
import type { Engine } from "../status";
import { hhmm } from "../panel/model";
import type { ProviderAuth, ProviderDef } from "./registry";

export interface ProviderCard {
  engine: string;
  name: string;
  logo: string;
  logoColor: string;
  auth: ProviderAuth;
  connected: boolean;
  signingIn: boolean;
  badge: string;
  /** "Sign in" and/or "API key" (Gemini shows both). */
  badges: string[];
  /** Card shows the key input / Key saved / Remove. */
  acceptsKey: boolean;
  keySaved: boolean;
  /** Out of credit: show Try again. */
  canRetry: boolean;
  stateLine: string;
  position: number;
  isFirst: boolean;
  isLast: boolean;
}

export interface ProvidersModel {
  cards: ProviderCard[];
  connectedCount: number;
  countLine: string;
}

/** Registry order, overridden by `order` (unknown names dropped, missing ones appended). */
export function orderedEngines(registry: readonly ProviderDef[], order: readonly string[]): string[] {
  const known = new Set(registry.map((p) => p.engine));
  const first = order.filter((e, i) => known.has(e) && order.indexOf(e) === i);
  return [...first, ...registry.map((p) => p.engine).filter((e) => !first.includes(e))];
}

export function moveEngine(order: readonly string[], engine: string, delta: -1 | 1): string[] {
  const out = [...order];
  const i = out.indexOf(engine);
  const j = i + delta;
  if (i < 0 || j < 0 || j >= out.length) return out;
  [out[i], out[j]] = [out[j], out[i]];
  return out;
}

export function providersModel(
  registry: readonly ProviderDef[],
  engines: readonly Engine[] | undefined,
  order: readonly string[],
  signingIn: ReadonlySet<string> = new Set(),
  keysSaved: ReadonlySet<string> = new Set(),
): ProvidersModel {
  const byName = new Map((engines ?? []).map((e) => [e.name, e]));
  const defs = new Map(registry.map((p) => [p.engine, p]));
  const names = orderedEngines(registry, order);
  const cards = names.map((engine, i): ProviderCard => {
    const def = defs.get(engine)!;
    const st = byName.get(engine);
    const keySaved = keysSaved.has(engine);
    const connected = st?.signedIn === true || keySaved;
    const credit = st?.limit === "limited" && st.reason === "credit";
    const busy = signingIn.has(engine);
    let stateLine: string;
    if (busy) stateLine = copy.providers.state.signingIn;
    else if (!connected) stateLine = copy.providers.state.notConnected;
    else if (credit) stateLine = copy.providers.outOfCredit;
    else if (st?.limit === "limited") {
      const t = st.resetsAt ? Date.parse(st.resetsAt) : NaN;
      stateLine = copy.providers.state.limited(Number.isNaN(t) ? null : hhmm(t));
    } else stateLine = copy.providers.state.connected;
    return {
      engine,
      name: def.name,
      logo: def.logo,
      logoColor: def.logoColor,
      auth: def.auth,
      connected,
      signingIn: busy,
      badge: copy.providers.badge[def.auth],
      badges:
        def.auth === "signin" && def.alsoApiKey
          ? [copy.providers.badge.signin, copy.providers.badge.api_key]
          : [copy.providers.badge[def.auth]],
      acceptsKey: def.auth === "api_key" || def.alsoApiKey === true,
      keySaved,
      canRetry: connected && credit,
      stateLine,
      position: i + 1,
      isFirst: i === 0,
      isLast: i === names.length - 1,
    };
  });
  const connectedCount = cards.filter((c) => c.connected).length;
  return { cards, connectedCount, countLine: copy.providers.connectedCount(connectedCount) };
}
