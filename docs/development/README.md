# Development Guide

This is the contributor-facing documentation for InferHaven Core. If you want to *use* InferHaven, start at the [top-level README](../../README.md) and [docs/quickstart.md](../quickstart.md) instead.

InferHaven Core is, deliberately, a small project: a Docker Compose stack, a Bash CLI (`haven`), a handful of provisioning and lifecycle scripts, and a status-bar daemon. There is no application framework, no test pyramid, no compile step. If you are comfortable with Bash, Docker, and Make, you have everything you need.

## Contents

- [Local development loop](#local-development-loop) — how to clone, configure, and iterate on the stack.
- [Repository layout](#repository-layout) — where things live and what each piece does.
- [Adding a new coding-assistant harness](#adding-a-new-coding-assistant-harness) — the 7-file checklist.
- [Testing and linting](#testing-and-linting) — shellcheck, the devcontainer smoke test, manual verification.
- [Devcontainer flavors](#devcontainer-flavors) — quick note + pointer.
- [Tool sourcing in the workspace image](tool-sourcing.md) — how the workspace `Dockerfile` sources tools and how to bump pins.

## Local development loop

**Prerequisites.** Linux host with Docker Engine ≥ 24 and `docker compose` v2. Make is convenient but optional — every `make` target is a thin wrapper around `docker compose`. A GPU and the NVIDIA Container Toolkit (or ROCm runtime) are only required if you want to test GPU paths; the CPU-only stack runs fine without.

**First-time setup.**

```bash
git clone https://github.com/InferHaven/inferhaven-core.git
cd inferhaven-core
cp .env.example .env
# Edit .env — at minimum set CODE_SERVER_PASSWORD and AUTHORIZED_KEYS.
# If you are testing GPU paths, also uncomment the GPU block in docker-compose.yml.
make up
```

`make up` builds the workspace image (BuildKit cache mounts make warm rebuilds <30 s) and starts the four services: `ollama`, `workspace`, `code-server`, `caddy`.

**The iteration loop.** Most contributions touch the workspace container — either the `haven` CLI or one of the provisioning scripts. The loop:

```bash
# 1. Edit files under docker/workspace/scripts/ (or wherever you are working).
# 2. Rebuild just the workspace service.
make rebuild-fast              # DOCKER_BUILDKIT=1 docker compose build workspace + restart

# 3. SSH in and exercise the change.
ssh -p 2222 haven@localhost
```

Files in `docker/workspace/scripts/` are baked into the image at build time, so a script edit requires `rebuild-fast`. If you are iterating on shell logic, you can shortcut the loop by `docker cp`-ing the edited file into a running container and re-sourcing it — but commit only after a full `rebuild-fast` proves the path works from scratch.

**Useful Make targets** (run `make help` for the full list):

| Target | Purpose |
| --- | --- |
| `make up` | Start all services (builds on first run). |
| `make down` | Stop all services. |
| `make rebuild-fast` | Rebuild only the `workspace` service with BuildKit cache. Fastest inner loop. |
| `make logs s=workspace` | Stream logs for one service. |
| `make doctor` | Run `haven doctor` inside the workspace (environment diagnostic). |
| `make reset` | **Destructive.** Remove all data volumes and start over. Use when first-boot state is the bug. |

**Resetting state.** If you change first-boot logic (entrypoint, `configure-assistants.sh`, sentinel-gated init), use `make reset` to wipe the `workspace_home` volume so the next `make up` triggers cold-boot again. Warm-boot path skips most provisioning.

## Repository layout

```bash
inferhaven-core/
├── Makefile                          # Thin wrapper over docker compose
├── docker-compose.yml                # 4-service stack: ollama, workspace, code-server, caddy
├── docker-compose.codespaces.yml     # Codespaces-tuned variant
├── docker/
│   ├── caddy/                        # Reverse proxy config + entrypoint
│   ├── code-server/                  # custom-cont-init.d hooks
│   └── workspace/
│       ├── Dockerfile                # Ubuntu 24.04 + tools (see ./tool-sourcing.md)
│       └── scripts/                  # Everything that runs inside the workspace container
├── scripts/
│   ├── haven                         # Host-side CLI wrapper (manages docker compose)
│   └── devcontainer-smoke.sh         # Integration smoke test for devcontainers
├── docs/                             # User and contributor documentation
└── .devcontainer/                    # VS Code Remote Containers + Codespaces config
```

Inside the workspace image (`docker/workspace/scripts/`):

| Path | Role |
| --- | --- |
| `haven.sh` | The workspace-internal `haven` CLI. ~75 subcommands across models, harnesses, tmux, services. |
| `lib/haven-sync.sh` | Unified config-sync driver. One `_haven_sync_all` function renders Ollama models into every supported harness config in parallel. Replaces the seven former `_sync_*_models` functions. |
| `lib/haven-models.sh`, `lib/haven-log.sh`, `lib/haven-colors.sh` | Helper libraries sourced by `haven.sh`. |
| `entrypoint.sh` | Container entrypoint. Sentinel-gated (`~/.haven/.initialized`) — cold boot does full provisioning, warm boot skips. |
| `configure-assistants.sh` | First-boot config bootstrap. Writes default `~/.gitconfig`, harness credential files, etc. Idempotent (file-exists guards). |
| `install-assistants.sh` | Async installer. Reads `INSTALL_ASSISTANTS` from env and installs each named harness. Each tool has a `case` arm. |
| `inferhaven-status.sh`, `metrics-server.js` | Status bar. `metrics-server.js` (port 9091) is the canonical source for CPU/RAM/GPU/uptime; `inferhaven-status.sh` is the tmux status-bar consumer. |
| `haven-models-cache-warm.sh`, `haven-logrotate.sh` | Supercronic-scheduled maintenance jobs. |
| `haven-migrate-home.sh` | One-shot migration when an old single-user home layout is detected on first boot. |
| `add-ssh-key.sh` | Helper invoked by `haven ssh-key`. |

Two operational invariants the codebase enforces:

- **Sentinel gating.** First-boot work runs only if `~/.haven/.initialized` is missing. Cold-boot reason (sentinel missing vs. ownership drift) is logged. Restarts must stay under ~5 s wall time, which is what the bounded shutdown trap (`timeout 3` on tmux save) protects.
- **Managed-file sentinels.** Every config file `haven` writes carries a sentinel (`"_haven": "managed"`, `"_haven": true` per array entry, or `## inferhaven:managed` for YAML). Sync functions must check the sentinel and exit early if it is absent — InferHaven never overwrites user-customised configs.

## Adding a new coding-assistant harness

To wire a new harness (the kind of thing you would put in `INSTALL_ASSISTANTS=mytool`) end-to-end — install on first boot, auto-configure Ollama models, keep in sync on `haven pull`/`haven tune`/`haven remove`, and show up in `haven harness` — you need to touch **seven** files. The patterns are tightly enforced; copy from an existing harness rather than freelancing.

### 1. `docker/workspace/scripts/lib/haven-sync.sh`

Add a `_haven_render_<tool>` function alongside the existing renderers (`_haven_render_opencode`, `_haven_render_pi`, etc.). The function reads the live `/api/tags` model list, queries `/api/show` for per-model `num_ctx`, builds the harness-specific config with `jq -n`, and writes atomically (`> tmp && mv tmp file`, `chmod 600`).

Then register the renderer in `_haven_sync_all` so every `haven pull`/`tune`/`remove` re-renders the new harness in parallel with the others. Do not write a one-off `_sync_<tool>_models` function — the unified driver is the single source of truth.

### 2. `docker/workspace/scripts/haven.sh`

If you want the legacy `_sync_<tool>_models` name for back-compat (other call sites use it), add a one-liner wrapper at the top of the sync section: `_sync_mytool_models() { _haven_sync mytool; }`. Otherwise, callers should call `_haven_sync_all` (or `_haven_sync mytool`) directly.

Then add the harness to `cmd_harness`:

- One `_harness_row "MyTool" "binary-name"` row in the listing block.
- One `if command -v binary-name` summary block showing config path, endpoint, model count, and per-model context (model the OpenCode or Pi summary block).

### 3. `docker/workspace/scripts/install-assistants.sh`

Add a new arm to the install `case` switch:

```bash
mytool|my-tool-alias)
    install_npm "mytool" "@pkg/name" "binary-name"   # or install_pip, install_curl_sh
    _haven_sync mytool                                # render config now, not just on next pull
    ;;
```

Update the `# Supported tools` header comment and the unknown-tool error message to name the new harness.

### 4. `docker/workspace/scripts/configure-assistants.sh`

If the harness needs a credential file (e.g. `~/.mytool/auth.json`), add a block guarded by `[ ! -f "${FILE}" ]`. Build the JSON with `jq -n` — never string-concat with sed trailing-comma strip. Use the `write_secure_file` helper, which chmod 600s and chowns automatically.

### 5. `docker/workspace/scripts/entrypoint.sh`

Pre-create the tool's config directory in the `for _dir in` loop so it exists and is haven-owned before the async installer touches it: `"${HOME_DIR}/.mytool/subdir"`.

### 6. `.env.example`

Append the tool name to the `INSTALL_ASSISTANTS` comment line and document any new tool-specific env keys.

### 7. `docs/harnesses.md` and `README.md`

In `docs/harnesses.md`, add a row to the `INSTALL_ASSISTANTS` table and a full `## MyTool (\`mytool\`)` section before "Choosing a model". Cover: local-model auto-config behavior, opt-out sentinel, compat flags, cloud-model env keys, and usage examples.

In the top-level `README.md`, update the `Supported Harnesses:` line and the auto-sync blurb.

### Quality rules

Lifted from the simplify-review patterns the codebase already enforces:

- Declare `local` variables at the top of the function, never inside a loop — `bash local` is function-scoped, not loop-scoped.
- Don't introduce intermediate variables for one-liners. `curl ... | jq ...` inline beats `models_json=$(curl ...); jq <<< "$models_json"`.
- Don't suppress stderr on commands that never write it (`head -1` does not need `2>/dev/null`).
- Build JSON with `jq -n` exclusively. String concatenation plus sed trailing-comma stripping is a bug factory.
- Each install function ends with **one** log line: `log "mytool: configured N model(s) → path."`. No progress narration.
- The `${OLLAMA_URL}/v1` string is short — inline it into the `--arg baseUrl` call. No intermediate var.

## Testing and linting

InferHaven currently has no unit-test framework. The verification surface is:

**Shellcheck.** Every `.sh` file in the repo should pass `shellcheck` cleanly — the repo currently runs **zero warnings, zero infos** against shellcheck 0.10+. Several files carry `# shellcheck source=/dev/null`, `# shellcheck shell=bash`, or scoped `# shellcheck disable=...` directives where the warning is a known-false-positive against an intentional pattern; each suppression is annotated with *why*.

```bash
shellcheck $(git ls-files '*.sh')
```

Run this before opening a PR. If your editor has a shellcheck integration, enable it for the repo. Exit code 0 with zero output is the bar for green.

**Locale gotcha.** If your shell is in the `C` locale (no UTF-8), shellcheck can crash with `commitBuffer: invalid argument (invalid character)` when its error context happens to include a non-ASCII byte from the source file. Set a UTF-8 locale before running:

```bash
LC_ALL=C.UTF-8 shellcheck $(git ls-files '*.sh')
```

This is a shellcheck stdout-encoding limitation, not a real script bug.

**Suppressing intentional patterns.** When you must keep a pattern shellcheck flags (sourced color libs, nested-tmux `TMUX= tmux …`, single-quoted heredoc bodies that defer `$var` expansion to a subshell, `cat file 2>/dev/null` where you actually want the shell-error suppression, etc.) add a scoped `# shellcheck disable=SC####` with a one-line *why* comment. Do not blanket-disable a whole file unless every reasonable line in it triggers the same pattern (e.g. `inferhaven-right-popup.sh` for SC2016/SC1007).

**What's OK to see, what's not.** A truly green run prints nothing and exits 0 — that is the bar. If you see anything else, treat it as a fixable issue (either a real bug or a missing scoped disable with rationale). Do not paper over a new finding with a file-level disable just to silence it; pick the most specific scope (line, function, or file) that the warning actually applies to, and document the rationale inline.

**Devcontainer smoke test.** `scripts/devcontainer-smoke.sh` runs **inside** the workspace container after `devcontainer up` (or after the Codespaces / VS Code Dev Containers / DevPod / JetBrains UI finishes `postCreate`). It asserts every claim the README makes about the devcontainer experience — image layout, mounted volumes, expected binaries, harness availability, model presence. The harness is flavor-aware (`DEVCONTAINER_FLAVOR`) and adds extra assertions for `full-stack` (code-server + Caddy + metrics) and `nested` (compose-project isolation). Exit 0 = green; non-zero with line number on first failure.

```bash
# From inside the workspace container, after a fresh devcontainer up:
DEVCONTAINER_FLAVOR=codespaces scripts/devcontainer-smoke.sh
DEVCONTAINER_FLAVOR=full-stack scripts/devcontainer-smoke.sh

# Useful skip flags for fast iteration (set to 1 to skip the named section):
#   SKIP_MODEL              — wait for model in /api/tags
#   SKIP_OPENCODE           — opencode binary check
#   SKIP_DIND               — Docker-in-Docker section
#   SKIP_TOOLCHAIN          — PATH binary loop
#   SKIP_POSTCREATE         — postCreate idempotency rerun
#   SKIP_FULL_STACK_EXTRAS  — code-server + caddy + metrics block
#   SKIP_NESTED             — @devcontainers/cli existence check
# Tuning (seconds): MODEL_WAIT     (default 300) — model appears in /api/tags
#                   OPENCODE_WAIT  (default 180) — async opencode install finishes
#                   SERVICE_WAIT   (default 60)  — ollama API, code-server, Caddy, metrics
SKIP_MODEL=1 SKIP_OPENCODE=1 scripts/devcontainer-smoke.sh
```

Run the smoke test after any change to the workspace image, the devcontainer config, or first-boot provisioning. CI runs both flavors automatically via `.github/workflows/devcontainer.yml`.

**Manual verification checklist.** For non-trivial PRs, walk these by hand:

1. `make reset && make up` → cold boot completes in <60 s on a warm-cache host.
2. `ssh -p 2222 haven@localhost` → key-only auth works, `haven help` runs.
3. `haven doctor` → all checks green (P1/P2 binaries, swap, cgroup, supercronic).
4. `haven pull <model>` → progress reported, model lands in `haven models`, sync re-renders every harness config in `~/.<tool>/`.
5. Web IDE at `http://localhost` → code-server loads, password from `.env` works.
6. tmux session `Haven` exists, survives a `docker compose restart` (continuum auto-saves every 15 min). Interactive harness panes (opencode, aider, etc.) relaunch cleanly with no leaked keystrokes — `ih-pane-restore` uses `tmux respawn-pane -k` for any pane that had a non-shell foreground process.

If your change touches GPU paths, run the equivalent on a GPU host; CPU-only verification does not cover the metrics-server GPU readout.

## Devcontainer flavors

InferHaven ships two devcontainer configurations. Every conformant client (GitHub Codespaces, VS Code Dev Containers, DevPod, JetBrains Gateway, `@devcontainers/cli`) shows a flavor picker when more than one `devcontainer.json` is present. See `.devcontainer/README.md` for the full picker reference.

| Flavor | Path | Boots | Best for |
| --- | --- | --- | --- |
| `codespaces` (default) | `.devcontainer/devcontainer.json` | `docker-compose.codespaces.yml` — ollama + model-loader + workspace | Quick CPU-only iteration. Mirrors what Codespaces runs. |
| `full-stack` | `.devcontainer/full-stack/devcontainer.json` | `docker-compose.yml` + `docker-compose.devcontainer.override.yml` — full prod stack (+ code-server + Caddy) under compose project `inferhaven-dev` | Developing against the same surface self-hosters get, including the web IDE and reverse proxy. GPU works the same way as production. |
| `nested` (mode, not a separate config) | runs *inside* a prod workspace via `haven devcontainer up <path>` (build-based) or `haven nest up <path>` (compose-based) | Inner copy of any flavor above against the host docker daemon | Validating changes inside a live prod stack without leaving the host. |

**Switching flavors.**

```bash
# VS Code: Command Palette → "Dev Containers: Reopen in Container" → pick.

# DevPod CLI:
devpod up <path-or-url>                                    # codespaces
devpod up <path-or-url> --devcontainer-path \
  .devcontainer/full-stack/devcontainer.json               # full-stack

# Headless / CI:
devcontainer up --workspace-folder .                                            # codespaces
devcontainer up --workspace-folder . --config .devcontainer/full-stack/devcontainer.json  # full-stack
```

**GPU passthrough (full-stack only).** Uncomment the GPU block in `docker-compose.yml` exactly as documented for production — the override file deliberately does not touch it.

**SSH in Codespaces.** The full-stack flavor forwards the workspace SSH port (`2222`) so you can `ssh -p 2222 haven@localhost` and exercise SSH-tunnel workflows. In **GitHub Codespaces** specifically, key-only SSH needs `AUTHORIZED_KEYS` set at create time (the codespace has no interactive way to add a key afterward), and external SSH-tunnel testing is limited by Codespaces' port-forwarding model — prefer the integrated terminal there. The slim `codespaces` flavor omits `2222` on purpose to stay light for free-tier machines.

**Nested devcontainer (dev-in-prod).** Two helpers, depending on the cloned project's `devcontainer.json` shape:

- **`haven devcontainer up`** — build-based projects (single `image:` / `build:` in `devcontainer.json`, no `dockerComposeFile`). Injects an explicit `workspaceMount` pointing at the translated host path and hands that to `@devcontainers/cli` against the shared docker socket.
- **`haven nest up`** — compose-based projects, including InferHaven inside InferHaven. Generates a small compose override that rewrites the workspace service's `.` binds to absolute host paths via `/proc/self/mountinfo`, pins the workspace image to the outer's already-built one, and runs `docker compose -p haven-nest-<basename> up -d`.

```bash
# Build-based (example: claude-code, vscode-remote-try-*, microsoft samples):
git clone https://github.com/microsoft/vscode-remote-try-node ~/projects/try-node
haven devcontainer up   ~/projects/try-node
haven devcontainer exec ~/projects/try-node -- node --version
haven devcontainer down ~/projects/try-node

# Compose-based (inferhaven-in-inferhaven):
git clone https://github.com/InferHaven/inferhaven-core ~/projects/inferhaven-dev
haven nest up   ~/projects/inferhaven-dev                          # codespaces flavor (default)
haven nest up   ~/projects/inferhaven-dev --flavor full-stack      # full prod stack
haven nest exec ~/projects/inferhaven-dev -- ls /home/haven/projects/inferhaven-core
haven nest status all
haven nest down ~/projects/inferhaven-dev
```

Each nested stack runs under compose project `haven-nest-<basename>`, so volumes and the bridge network never collide with the outer `inferhaven_*` set. `haven devcontainer help` and `haven nest help` print full subcommand references.

The split exists because `@devcontainers/cli` has no flag to separate "where to read the config" from "what to bind", and docker-compose passes compose-relative `volumes:` entries straight to the daemon — neither tool can resolve inner paths that exist only inside the outer workspace container. The two helpers together close that gap for both project shapes.

For everyday backend dev work that doesn't need a devcontainer, prefer the local Docker loop instead — it is faster, gives you a real tty, and exercises the GPU and multi-user paths that the codespaces flavor cannot.

## Security hardening

InferHaven uses `env_file: .env` in `docker-compose.yml` to inject API keys, the code-server password, the agent token, and SSH-related vars into the workspace container. That choice is convenient but has a sharp edge: **every value in `.env` is plaintext-readable** from inside the running container (`cat /proc/1/environ`) and from any host process that reads the file or invokes `docker compose config`.

The repo + CLI ship defense-in-depth defaults:

| Layer | What it does |
| --- | --- |
| `.gitignore` | `.env` excluded from commits. |
| `.dockerignore` | `.env`, `.env.*` (and `caddy-root.crt`, `*.pem`, `*.key`) excluded from every Docker build context — secrets never bake into image layers. |
| `haven up` (host) | Auto-`chmod 600 .env` on every invocation. Surfaces the previous mode if it had to tighten. |
| `haven doctor` (host + in-container) | Warns when `.env` is not `600` or `400`. |
| `.env.example` header | Calls out the `docker compose config` footgun + the multi-user env-bleed under `HAVEN_EXTRA_USERS`. |

Things to keep in mind when contributing:

- **Never paste `docker compose config` output.** Use `docker compose config --format json | jq 'del(.services[].environment)'` to inspect non-env structure without leaking keys.
- **Don't echo env values from any new script.** Redact `*_KEY`, `*_TOKEN`, `*_SECRET`, `*_PASSWORD` patterns in diagnostic prints.
- **Multi-user (`HAVEN_EXTRA_USERS=alice,bob`) bleeds the haven user's `.env` to alice/bob via `/proc/1/environ`.** If you're running InferHaven as a shared workspace, scope per-user secrets to mounted runtime config files (`~/.haven/secrets/<provider>.env`, mode 600) rather than the global `.env`. (Helper for this is on the roadmap; PRs welcome.)
- **Backups (`haven backup push`) sync `~/.haven`, `~/.config`, `~/.continue`, `~/.inferhaven` — not the project mount.** The host `.env` is therefore NOT included by default. Confirm before pointing a backup at a remote you don't fully trust.
