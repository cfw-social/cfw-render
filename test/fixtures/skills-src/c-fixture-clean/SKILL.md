---
name: c-fixture-clean
kind: component
visibility: catalog
---

# c-fixture-clean (CFW-312 test fixture)

A clean recipe with no `dependsOn` and no host-path resolver at all — proves
the rewrite pass and the portability gate don't false-positive on a recipe
that never had the bug (mirrors c-composio in the real bundle).

```bash
echo "nothing to resolve here"
```
