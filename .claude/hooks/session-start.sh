#!/bin/bash
# SessionStart hook: install Python dependencies so tests/linters work in
# Claude Code on the web. Idempotent and non-interactive.
set -euo pipefail

# Only run in the remote (web) environment; local sessions manage their own venv.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Run in the background so the session starts without waiting on the install.
# The remaining work below runs while the agent loop spins up.
echo '{"async": true, "asyncTimeout": 300000}'

cd "$CLAUDE_PROJECT_DIR"

# Runtime deps: curl_cffi, playwright, fastapi, uvicorn (see requirements.txt).
# Chromium is pre-installed in the web image (PLAYWRIGHT_BROWSERS_PATH), so we
# deliberately do NOT run `playwright install`.
python3 -m pip install --quiet --disable-pip-version-check -r requirements.txt

# Make the repo packages (copilot, server) importable from anywhere in-session.
echo 'export PYTHONPATH="$CLAUDE_PROJECT_DIR"' >> "$CLAUDE_ENV_FILE"
