---
name: p-fixture-recipe
kind: pipeline
visibility: catalog
dependsOn: [c-fixture-dep]
---

# p-fixture-recipe (CFW-312 test fixture)

Minimal recipe reproducing the exact bug shape (CFW-312): a "locate my own
dir" resolver and a "locate a sub-skill dir" resolver, both searching host
skill-install roots that don't exist on the runtime-free render box.

### 0 — Setup

```bash
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/testuser/ecosystem/harness/skills -maxdepth 5 -type d -name p-fixture-recipe 2>/dev/null | head -1)
FIXTURE_DEP_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.hermes/profiles" /Users/testuser/ecosystem/harness/skills -maxdepth 5 -type d -name c-fixture-dep 2>/dev/null | head -1)
[ -n "$FIXTURE_DEP_DIR" ] || FIXTURE_DEP_DIR="$SKILL_DIR/.hub/c-fixture-dep"
```
