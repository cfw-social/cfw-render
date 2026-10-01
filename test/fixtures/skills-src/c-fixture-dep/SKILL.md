---
name: c-fixture-dep
kind: component
visibility: catalog
---

# c-fixture-dep (CFW-312 test fixture)

A dependency with its own broken "locate my own dir" resolver — the exact
shape c-typing-ui/c-broll-sync/c-reel-premium use in the real source.

```bash
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" -maxdepth 4 -type d -name c-fixture-dep 2>/dev/null | head -1)
```
