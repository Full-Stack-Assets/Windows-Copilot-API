# CLAUDE.md

Guidance for AI assistants (and humans) working in this repository.

## What this project is

**Windows Copilot API** turns a free, signed-in [copilot.microsoft.com](https://copilot.microsoft.com)
account into a programmable LLM API — no API key, no billing. It exposes two surfaces:

1. **A Python library** (`copilot` package) — `CopilotClient().chat("Hi")`, with streaming
   and multi-turn conversations.
2. **An OpenAI-compatible HTTP server** (`server` package) — a FastAPI app at
   `http://localhost:8000/v1` that speaks the OpenAI Chat Completions shape, so the official
   `openai` SDK and OpenAI-compatible tools work as a drop-in by pointing at `localhost`.

It is an **unofficial** project that automates the consumer Copilot web experience for
personal use. There is exactly **one model** (`copilot`) — Copilot has no model selector.

## Architecture in one picture

```
              ┌─────────────────────────────────────────────────────────┐
  user code   │  copilot.CopilotClient   (high-level, recommended entry) │
  ───────────▶│   • auth refresh + Cloudflare-clearance recovery loop    │
              └───────────────┬─────────────────────────────────────────┘
                              │ uses
              ┌───────────────▼──────────────┐     ┌──────────────────────┐
              │ copilot.driver.Copilot       │     │ copilot.browser       │
              │ pure-HTTP chat over curl_cffi │◀───▶│ BrowserCopilot        │
              │ (WebSocket, PoW challenges)   │     │ (Playwright)          │
              └───────────────┬──────────────┘     │ • interactive sign-in │
                              │                     │ • headless token mint │
                              │                     │ • Cloudflare clearance│
                              ▼                     └──────────────────────┘
                   wss://copilot.microsoft.com/c/api/chat

  server/  (FastAPI)  wraps CopilotClient → OpenAI /v1/chat/completions + /v1/models
```

**Key design split:** *all actual chatting goes over pure HTTP* (`copilot/driver.py` using
`curl_cffi` to impersonate Chrome). The browser (`copilot/browser.py`, Playwright) is used
**only** to establish/refresh the signed-in session and Cloudflare clearance — it never
chats. This keeps normal operation browser-free and fast.

## Repository layout

| Path | Responsibility |
| --- | --- |
| `copilot/` | Core library |
| `copilot/client.py` | `CopilotClient` — the recommended entry point. Auth refresh, clearance-recovery retry loop, `chat()`/`stream()`, `ChatReply`/`ChatStream`. |
| `copilot/driver.py` | `Copilot` — pure-HTTP chat engine. Speaks Copilot's WebSocket protocol via `curl_cffi`. Raises `ClearanceRequired` when Cloudflare gates a turn. |
| `copilot/browser.py` | `BrowserCopilot` — Playwright. Interactive login, headless chat-token capture, Cloudflare clearance refresh (`auto_clear`). Does **not** chat. |
| `copilot/auth.py` | Session caching. `load_auth()` returns `{cookies, access_token, identity_type, saved_at}`, refreshing from the browser profile when stale. |
| `copilot/protocol.py` | Single source of truth for the chat-socket wire shapes (`CHAT_WEBSOCKET_URL`, `SET_OPTIONS_FRAME`, `CONSENTS_FRAME`). Both drivers follow it. |
| `copilot/challenges.py` | Proof-of-work challenge solvers (`hashcash`, arithmetic `copilot`). |
| `copilot/models.py` | Plain data types: `Conversation`, `ImageResponse`, `AbstractProvider`. No I/O. |
| `copilot/utils.py` | Stateless helpers: HTTP status checks, WebSocket frame reassembly (`drain_json`), image encoding. |
| `copilot/__main__.py` | CLI: `python -m copilot login` / `python -m copilot ask "..."`. |
| `server/` | FastAPI OpenAI-compatible server |
| `server/api.py` | The FastAPI app, routes, the **upstream serialization lock**, and rate-limit gate. |
| `server/__init__.py` | `app()` launcher — establishes a session, then runs uvicorn. |
| `server/config.py` | Constants/env config: `MODEL_NAME`, `RATE_LIMIT_RPM`, `RATE_LIMIT_BURST`. |
| `server/schemas.py` | Pydantic request models (`ChatCompletionRequest`, `ChatMessage`). |
| `server/prompt.py` | Flattens an OpenAI `messages[]` array into a single Copilot prompt. |
| `server/openai_format.py` | Builders for OpenAI response/SSE-chunk shapes. |
| `server/ratelimit.py` | Thread-safe token-bucket limiter. |
| `app.py` | Entry point: `python app.py` starts the server. |
| `examples/` | Runnable examples (01–03 direct library, 04–06 over HTTP). See `examples/README.md`. |
| `tests/` | `test_server.py` (unittest), plus operational scripts: `stress.py`, `ratelimit.py`, `diagnostic.py`, `gpqa_bench.py`. |
| `Dockerfile`, `docker-compose.yml` | Container build/run (headless server only). |

## Setup & common commands

```bash
# Environment
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
playwright install chromium          # one-time, browser for sign-in/clearance

# Sign in once (opens a visible browser; session saved under session/)
python -m copilot login

# Use it
python -m copilot ask "Hello!"       # one-shot CLI
python app.py                        # start the OpenAI-compatible server (127.0.0.1:8000)
HOST=0.0.0.0 PORT=8080 python app.py # override bind address
uvicorn server.api:app --host 0.0.0.0 --port 8080   # equivalent

# Docker (sign in on the host first; container is headless)
docker compose up --build
```

### Dependencies

Only four runtime deps (`requirements.txt`): `curl_cffi` (Chrome-impersonating HTTP/WS),
`playwright` (sign-in/clearance browser), `fastapi`, `uvicorn`. **Python 3.9+.**

## Testing

```bash
python -m unittest tests.test_server   # the only real unit test (server startup config)
python -m unittest discover tests      # discover (note: most files in tests/ are scripts, not unittest)
```

`tests/test_server.py` is a standard `unittest` suite. The other files in `tests/` are
**operational/manual scripts** that require a running server and a real Copilot account —
they are *not* part of an automated suite:

- `tests/stress.py` — concurrency probe (doubles batch size until first error).
- `tests/ratelimit.py` — open-loop rate probe (distinguishes 429 bridge-limit from 502 upstream).
- `tests/diagnostic.py` — fix-and-capture tool for bug reports; writes redacted, shareable
  reports to `session/`.
- `tests/gpqa_bench.py` — accuracy benchmark (needs the access-gated GPQA CSV).

There is no configured linter/formatter or CI in the repo. Match the existing style.

## Key conventions & invariants

These are the non-obvious rules that keep the bridge working — preserve them when editing:

- **Pure HTTP for chat, browser only for auth.** Don't route chatting through Playwright,
  and don't add browser dependencies to the driver path. `copilot/models.py`, `utils.py`,
  `challenges.py`, and `protocol.py` deliberately have no browser imports.

- **`protocol.py` is the single source of truth** for the WebSocket wire format. The connect
  sequence is fixed: `setOptions` → `reportLocalConsents` → `send`. A `send` issued before
  the handshake is rejected with `invalid-event`. If Microsoft changes the protocol,
  recapture with `tests/diagnostic.py` (writes `session/ws_capture.log`) and update this file
  — both drivers follow it.

- **Cloudflare clearance is the central failure mode.** `cf_clearance` lasts ~30 min and can
  only be minted by a real browser. The driver raises `ClearanceRequired` when a turn is
  gated (a `challenge` frame with `method` null or `"cloudflare"`). The library
  (`CopilotClient`) recovers by opening a browser; the **server never opens a browser** and
  returns **HTTP 503** (`type: "clearance_required"`) instead — re-clear out of band with
  `python -m copilot login`.

- **The server serializes all upstream calls** behind a single `threading.Lock`
  (`_upstream_lock` in `server/api.py`). Copilot's per-account socket doesn't tolerate
  concurrent conversations from one process. This is intentional: throughput is sequential.
  Keep concurrent in-flight requests low (~1–4). Don't remove this lock.

- **Conversations are addressed by `conversation_id`.** `chat()`/`stream()` return it; pass
  it back to continue a thread, omit it to start fresh. The server surfaces it as an extra
  top-level `conversation_id` field on responses/chunks (outside OpenAI's schema; standard
  clients ignore it, but it can be set via `extra_body`).

- **Auth tokens:** the chat WebSocket needs the MSAL token scoped `ChatAI.ReadWrite` (a
  wrong-audience token 401s the upgrade). REST calls authenticate by **cookie only** — never
  send a `Bearer` header there. Federated (Google) logins carry an extra
  `X-UserIdentityType` marker that the drivers replay; their MSAL cache is encrypted, so the
  token is captured live off the page's chat socket during a warm-up turn rather than read
  from storage.

- **Status/progress goes to stderr** (`_status`, `[copilot] …` lines) so it never mixes into
  the reply text read off stdout.

- **The server flattens OpenAI messages into one prompt** (`server/prompt.py`) — Copilot has
  no system/role channel. Unsupported OpenAI fields (temperature, max_tokens, …) are accepted
  and silently ignored.

- **Rate limiting is self-imposed** (token bucket, default 12 rpm / burst 4) because Copilot
  publishes none. Tunable via `RATE_LIMIT_RPM` (0 disables) and `RATE_LIMIT_BURST`.

## Secrets & files to never commit

- Everything under `session/` (browser profile, cookies, cached token) is **secret** and
  git-ignored. Never read these values into code paths that log or transmit them; never
  commit them.
- `tests/diagnostic.py` redacts tokens/cookies/emails/OAuth codes before writing its reports
  — keep that redaction intact if you touch it.
- `config.json`, `test.py`, `main.py` are git-ignored dev/local files.

## Configuration (environment variables)

| Var | Default | Effect |
| --- | --- | --- |
| `HOST` | `127.0.0.1` | Server bind host (Docker sets `0.0.0.0`). |
| `PORT` | `8000` | Server bind port. |
| `RATE_LIMIT_RPM` | `12` | Requests/minute the bridge accepts; `0` disables. |
| `RATE_LIMIT_BURST` | `4` | Back-to-back requests before pacing. |

## HTTP API surface

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/v1/chat/completions` | Supports `"stream": true` (SSE) and optional `"conversation_id"`. |
| `GET` | `/v1/models` | Returns the single `copilot` model. |
| `GET` | `/` | Service banner / endpoint list. |

Error contract: `429` + `Retry-After` (bridge rate limit), `502` (upstream Copilot error),
`503` (`clearance_required`). Clients should use exponential backoff — 429/502 are transient.

## Git workflow for this task

- Active development branch: `claude/claude-md-docs-7qowjp`.
- Commit with clear messages; push with `git push -u origin <branch>`; open a draft PR.
</content>
</invoke>
