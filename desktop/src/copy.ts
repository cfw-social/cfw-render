const copy_sep = " · ";
// All owner-facing panel copy. Plain English only.
export const copy = {
  noProvider: "No AI provider signed in",
  workingFor: (names: string) => `Working for: ${names}`,
  banner: {
    notRunning: "Worker not running",
    paused: "Paused",
    battery: "On battery",
    update: "Update this computer",
    limit: (hhmm: string | null) => (hhmm ? `AI limit reached; resumes about ${hhmm}` : "AI limit reached"),
  },
  action: {
    start: "Start",
    resume: "Resume",
    pause: "Pause",
    renderOnBattery: "Render on battery",
    runNow: "Run now",
    open: "Open",
    viewLogs: "View logs",
  },
  section: { now: "Now", next: "Next", done: "Done" },
  step: (step: number | null, steps: number | null, label: string | null) => {
    const base = step != null && steps != null ? `step ${step} of ${steps}` : step != null ? `step ${step}` : "";
    return [base, label].filter(Boolean).join(" · ");
  },
  sep: " · ",
  marks: { done: "✓", failed: "✗", stopped: "–" },
  lastCheck: (ago: string) => `Last check: ${ago}`,
  lastCheckNever: "Last check: never",
  ago: (secs: number) => (secs < 60 ? `${secs} s ago` : secs < 3600 ? `${Math.floor(secs / 60)} min ago` : `${Math.floor(secs / 3600)} h ago`),
  elapsed: (secs: number) => {
    const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60), s = secs % 60;
    const pad = (n: number) => String(n).padStart(2, "0");
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  },
  main: {
    rendersTitle: "Renders on this Mac",
    noRecent: "Nothing finished in the last 24 hours.",
  },
  settings: {
    title: "Settings",
    battery: "Render on battery",
    startAtLogin: "Start at login",
    autoUpdate: "Automatic updates",
    autoUpdateNote: "Automatic updates arrive with signed releases.",
    sendLogs: "Send logs to CFW…",
    uninstall: "Uninstall CFW Render…",
    comingNote: "Coming in a later update.",
    version: (app: string | null, worker: string | null) =>
      `App ${app ?? "unknown"}${copy_sep}Worker ${worker ?? "not installed"}`,
  },
  engineFallback: { codex: "ChatGPT", "claude-code": "Claude" } as Record<string, string>,
  providers: {
    title: "AI Providers",
    connectedCount: (n: number) => `${n} connected`,
    badge: { signin: "Sign in", api_key: "API key" },
    state: {
      connected: "Connected",
      limited: (hhmm: string | null) => (hhmm ? `Limit reached, resets ${hhmm}` : "Limit reached"),
      notConnected: "Not connected",
      signingIn: "Signing in…",
    },
    action: { signIn: "Sign in", signOut: "Sign out", cancel: "Cancel", up: "Move up", down: "Move down" },
    event: {
      timeout: "Sign-in timed out. Try again.",
      cancelled: "Sign-in cancelled.",
      failed: "Sign-in failed.",
    },
    orderHint: "Used in this order. If one reaches its limit, the next one takes over.",
  },
  chat: {
    title: "Chat",
    brandLabel: "Brand",
    noBrands: "Add a brand to start chatting.",
    addBrand: "Add a brand",
    brandName: "Brand name",
    brandSlug: "Brand id",
    brandKey: "Brand key",
    save: "Save",
    cancel: "Cancel",
    remove: "Remove brand",
    placeholder: "Ask about your brand…",
    send: "Send",
    stop: "Stop",
    stopped: "Stopped.",
    working: "Working…",
    tools: {
      list_compositions: "Looking at your drafts…",
      get_composition: "Opening a draft…",
      list_runs: "Checking recent runs…",
      get_run: "Checking a run…",
      list_posts: "Looking at your posts…",
      search: "Searching…",
    } as Record<string, string>,
  },
  setup: {
    title: "Set up CFW Render",
    keyLabel: "Brand key",
    keyHint: "Copy it from CFW → Settings → Render.",
    paste: "Paste",
    consent: (mb: number | null) =>
      mb ? `Install the tools CFW Render needs (about ${mb} MB, into CFW Render/app)` : "Install the tools CFW Render needs (into CFW Render/app)",
    toolNames: "node, Python, ffmpeg, ImageMagick, Codex",
    signInFirst: "Sign in to ChatGPT or Claude to continue",
    connect: "Connect",
    cancel: "Cancel",
    tryAgain: "Try again",
    steps: {
      checking: "Checking",
      tools: "Installing tools",
      installing: "Installing",
      connecting: "Connecting",
      test_render: "Test render",
      ready: "Ready",
    } as Record<string, string>,
    alreadySetUp: "Already set up",
    finish: "Finish in CFW: brand basics, a channel, first automation",
    openCfw: "Open CFW",
  },
} as const;
