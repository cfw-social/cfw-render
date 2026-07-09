#!/usr/bin/env bash
# fake-claude.sh — stands in for the real `claude` binary during tests, on
# PATH ahead of any real one. Only exercised via cfw-render-subagent.sh's
# claude_ollama_failover call (the top-level Director spawn itself is
# bypassed by CFW_RENDER_DIRECTOR_CMD=test/fake-director.sh). Always
# succeeds immediately — no network, no real Ollama call.
set -u
echo "fake-claude: ok ($*)"
exit 0
