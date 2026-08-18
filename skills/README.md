# cfw-skills

Public, self-contained CFW recipe skills. Each top-level folder is one ready-to-run
recipe (`SKILL.md` + its vendored `.hub/` closure). **No archives, no git clone** —
just fetch the plain files.

Built and published from `cfw-social/cfw-skills-pack`. **Do not hand-edit** — changes
are overwritten on the next publish.

---

## For agents (Codex / Claude Desktop / cowork): install ALL skills

```
1. GET https://raw.githubusercontent.com/cfw-social/cfw-skills/main/index.json
2. for each <recipe> in index.recipes:
     for each <file> in index.recipes[<recipe>].files:
       GET https://raw.githubusercontent.com/cfw-social/cfw-skills/main/<recipe>/<file>
       save to  ~/.claude/skills/cfw/<recipe>/<file>
       (or wherever your runtime loads skills from)
```

That's it — `index.json` lists every recipe and every file in it (with a per-file
`sha256` you may verify). Each recipe self-verifies its own renders via its
`acceptance.json` (the `c-eval-runner` gate), so a bad render is blocked before delivery.

## Then connect the MCP (to drive a brand)

Add the CFW MCP server to your runtime and authenticate with your **brand API key**
(create one at `app.cfw.social/<brand>/settings/api-keys` — the "Copy setup
instructions" button there gives you this whole flow pre-filled):

```
endpoint:  https://app.cfw.social/api/v1/mcp
header:    x-api-key: <YOUR_BRAND_API_KEY>
```

The key is scoped to one brand. Once connected, your agent creates workspaces, produces
content, and requests approvals via the MCP tools — using the recipes you installed above.

---

## Discover
- `index.json` — every recipe, its file list, and per-file sha256.

_14 recipes in this release._
