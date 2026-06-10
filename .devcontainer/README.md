# InferHaven Devcontainer Flavors

This repo ships two devcontainer configurations. They build the same workspace image but boot different surrounding stacks. Every conformant devcontainer client (GitHub Codespaces, VS Code Dev Containers, DevPod, JetBrains Gateway, `@devcontainers/cli`) will present a flavor picker when more than one `devcontainer.json` is present.

## Flavors at a glance

| Flavor | Path | Services | Use when |
| --- | --- | --- | --- |
| **codespaces** (default) | `.devcontainer/devcontainer.json` | ollama + model-loader + workspace | You want a fast, lightweight environment that mirrors what GitHub Codespaces runs. CPU-only by design. |
| **full-stack** | `.devcontainer/full-stack/devcontainer.json` | ollama + workspace + code-server + Caddy (+ optional haven-agent) | You want to develop against the same stack self-hosters run, including the web IDE and the reverse proxy. GPU works the same way it does in production (uncomment in `docker-compose.yml`). |

The full-stack flavor uses a separate compose project name (`inferhaven-dev`), so it never collides with a production `inferhaven` stack running on the same host. All its volumes are prefixed `inferhaven_dev_*`.

## Picking a flavor at open time

**VS Code Dev Containers** — Command Palette → `Dev Containers: Reopen in Container` → pick from the list.

**GitHub Codespaces** — Codespaces only reads the top-level `.devcontainer/devcontainer.json` (the codespaces flavor). The full-stack flavor is for local development.

**DevPod CLI** - Fully opensource, repeatable dev environment for any infra, any IDE, and any programming language.

```bash
# Codespaces flavor (default)
devpod up <path-or-git-url>

# Full-stack flavor
devpod up <path-or-git-url> --devcontainer-path .devcontainer/full-stack/devcontainer.json
```

**JetBrains Gateway** — When configuring the remote dev connection, JetBrains shows the same flavor picker as VS Code.

**`@devcontainers/cli` (headless / CI)**

```bash
# Codespaces flavor
devcontainer up --workspace-folder .

# Full-stack flavor
devcontainer up --workspace-folder . \
  --config .devcontainer/full-stack/devcontainer.json
```

## Mount layout

Both flavors bind the repo at **`/home/haven/projects/inferhaven-core`** (a subdir of the workspace folder), matching the `/workspaces/<repo>` layout that GitHub Codespaces uses. Editor sessions open at that path; the parent `/home/haven/projects/` stays available for sibling clones (e.g. `inferhaven-cloud/`, dotfiles repos, scratch work).

If you want a different layout, override the bind in your own compose / devcontainer config — the convention is just the default.

## VS Code vs VSCodium

DevPod's `--ide vscode` expects the `code` CLI on your PATH. If you use VSCodium (no `code` binary), pass `--ide codium` instead:

```bash
devpod up --ide codium                                 # codespaces flavor
devpod up --ide codium \
  --devcontainer-path .devcontainer/full-stack/devcontainer.json
```

> **Note on port forwarding:** the default `--ide openvscode` (what `devpod up` picks if you don't pass a flag) and `--ide vscode` both auto-forward `forwardPorts`. Only `--ide codium` is the odd one out — it's SSH-only and doesn't forward. See the [Port forwarding by IDE](#port-forwarding-by-ide) section under Troubleshooting for the matrix and the manual `devpod ssh -L …` workaround if you need codium specifically.

## Nerd Fonts (icons in the prompt + lsd)

InferHaven's prompt and `lsd` output use Nerd Font glyphs. Fonts are a **client-side** concern — the devcontainer does not (and should not) override your editor's font. Install a Nerd Font on your host and point your editor's terminal font at it:

1. Download a [Nerd Font](https://www.nerdfonts.com/font-downloads) (JetBrains Mono NF and FiraCode NF are common picks) and install it system-wide.
2. In VSCodium / VS Code → Settings → search `terminal.integrated.fontFamily` → set it to e.g. `'JetBrainsMono Nerd Font'`. Set at the **User** level so it applies inside devcontainers too.

The devcontainer's `customizations.vscode.settings` deliberately leaves `terminal.integrated.fontFamily` unset — that lets your user-level setting win when you open the workspace.

## GPU passthrough (full-stack flavor)

Open `docker-compose.yml` and uncomment the GPU block on the `ollama` service (the same block used for production). The full-stack devcontainer flavor layers `docker-compose.devcontainer.override.yml` on top without touching the GPU plumbing — what you uncomment for production is what your devcontainer gets.

NVIDIA hosts need the NVIDIA Container Toolkit installed first. See [GPU Setup](../docs/gpu-setup.md).

## Nested devcontainers (dev inside prod)

If you're SSH'd into a running InferHaven workspace and want to run a devcontainer project inside it, use the `haven devcontainer` helper. The helper reads the inner config (so it parses correctly) and injects an explicit `workspaceMount` pointing at the matching host path — the only path the host docker daemon can actually resolve via `/proc/self/mountinfo`.

### Supported: build-based devcontainers

Projects whose `devcontainer.json` uses `image:` or `build:` (no `dockerComposeFile`):

```bash
# Inside the outer workspace
git clone https://github.com/anthropics/claude-code ~/projects/claude-code
haven devcontainer up   ~/projects/claude-code
haven devcontainer exec ~/projects/claude-code -- ls
haven devcontainer down ~/projects/claude-code
```

### Compose-based nested via `haven nest`

`haven devcontainer up` only handles build-based devcontainers (single `image:` / `build:` entries). For **compose-based** projects — including InferHaven nested inside InferHaven — use `haven nest`. It auto-translates the workspace bind paths and reuses the outer workspace image:

```bash
# Inside the outer workspace
git clone https://github.com/InferHaven/inferhaven-core ~/projects/inferhaven-dev
haven nest up   ~/projects/inferhaven-dev                        # codespaces flavor (default)
haven nest up   ~/projects/inferhaven-dev --flavor full-stack    # full-stack flavor
haven nest exec ~/projects/inferhaven-dev -- ls /home/haven/projects/inferhaven-core
haven nest logs ~/projects/inferhaven-dev workspace
haven nest down ~/projects/inferhaven-dev
haven nest status all
```

Each nested stack runs under compose project `haven-nest-<basename>`, fully isolated by name from the outer stack. `haven nest help` lists every subcommand.

What it does under the hood:

1. Walks `/proc/self/mountinfo` to translate `~/projects/inferhaven-dev` (inner) to its outer-host equivalent (`/var/lib/docker/volumes/inferhaven_projects/_data/inferhaven-dev` on a prod outer).
2. Reads the cloned project's `.devcontainer/devcontainer.json` (and any flavor subdir) for `dockerComposeFile`, `service`, `workspaceFolder`.
3. Generates a small compose override at `/tmp/haven-nest-*.yml` that:
   - Pins the workspace service to the outer's already-built image (no rebuild).
   - Replaces the `.` binds in the workspace service with the absolute host path via `volumes: !override`.
4. Runs `docker compose -f <repo-compose-files> -f <override> -p haven-nest-<basename> up -d`.

`haven nest` is inferhaven-aware: it expects the cloned project to have an InferHaven-shaped compose layout (workspace service with `.` binds at `/home/haven/projects/inferhaven-core` and `/opt/inferhaven`). For arbitrary compose-based devcontainers, `haven devcontainer up` will still refuse — translate manually via the printed inner→host path mapping.

> **Outer-image freshness gotcha.** `haven nest up` reuses the *outer* workspace image for the inner stack (skips a rebuild — see `_haven_resolve_self_container_id` in the helper). If the outer was brought up before the changes you want to test (e.g. you've SSH'd into a long-lived devpod workspace and the workspace image predates a haven.sh / Dockerfile / install-assistants change), the inner stack inherits the stale tooling too. Symptoms: nested smoke fails on `pwd` / `opencode missing` even though the local repo has the fixes. Rebuild the outer first: `devpod up . --recreate` (DevPod), `devcontainer up --workspace-folder . --recreate` (CLI), or `docker compose build workspace && docker compose up -d workspace` (plain compose).

### DevPod-in-DevPod (full-stack inside full-stack)

If you SSH into a DevPod-up'd InferHaven workspace and run another `devpod up` inside it for the same full-stack flavor, you'll hit a few rough edges. None are fatal but they should be expected:

1. **`docker-credential-devpod: executable file not found in $PATH`.** Outer DevPod injected a `credHelpers` entry into `~/.docker/config.json` pointing at a wrapper that lives in the outer host's `~/.devpod/` tree — invisible from inside the workspace container. Every docker build inside the workspace (including BuildKit's syntax-image resolution) blows up on the very first image lookup. The workspace image now ships a no-op `/usr/local/bin/docker-credential-devpod` stub (Round 5 follow-up) that returns empty credentials, falling back to anonymous auth for public images. **If you're on a pre-stub workspace image, rebuild it: `docker compose build workspace` on the outer host.**

2. **SSH agent forwarding fails** with `fatal dial unix /tmp/auth-agent…/listener.sock: connect: no such file or directory`. Outer DevPod set `SSH_AUTH_SOCK` to a socket that doesn't exist inside the inner workspace. Note: there's no `--ssh-agent-forwarding` flag on `devpod up` — the only released agent-forward toggle is `--gpg-agent-forwarding`. Strip the env var instead:

   ```bash
   env -u SSH_AUTH_SOCK devpod up . \
     --devcontainer-path .devcontainer/full-stack/devcontainer.json
   ```

   Same trick on `devpod ssh`. If you need real ssh-agent forwarding inside the inner workspace, bind-mount the outer socket via `--workspace-env SSH_AUTH_SOCK=/tmp/host-ssh-agent.sock` and a matching `runArgs: -v /tmp/host-ssh-agent.sock:/tmp/host-ssh-agent.sock` — out of scope here.

3. **Port-forward conflicts.** Outer workspace already forwards 80 / 8443 / 11434 from its own full-stack. Inner DevPod's `devpod ssh` will print `Error port forwarding <port>: accept tcp 127.0.0.1:<port>: use of closed network connection` for each. The inner stack is still running; reach its services from inside the outer workspace with `docker exec -it inferhaven-dev-workspace zsh` and curl via the inner service hostnames (`http://caddy`, `http://ollama:11434`).

4. **DevPod overrides the compose project name.** `docker compose -p inferhaven-dev …` returns empty. The `container_name:` directives still produce literal `inferhaven-dev-*` names, so `docker logs inferhaven-dev-caddy` works directly. Find the actual project label with `docker inspect inferhaven-dev-workspace --format '{{index .Config.Labels "com.docker.compose.project"}}'`.

For everyday nested dev, `haven nest up <clone>` is usually a cleaner path than `devpod up` — it avoids the DevPod auth-agent / port-forward / credHelpers friction entirely and reuses the outer's built images. Use the DevPod-in-DevPod path only when you specifically need DevPod's own IDE forwarding inside the inner.

### BuildKit + custom Caddy image prerequisites

- The workspace image bundles `docker-buildx-plugin` required by the workspace Dockerfile's `--mount=type=cache` directives.
- Caddy ships as `inferhaven/caddy:local` (`docker/caddy/Dockerfile`). `docker compose up -d` automatically builds it on first run (~3–5 s cold, cached thereafter). Edits to `docker/caddy/entrypoint.sh` or the HTML templates need `docker compose up -d caddy --build` to take effect instead of `docker compose restart caddy`.

See the [Development README](../docs/development/README.md) for more.

## Smoke test

The same script verifies every flavor:

```bash
DEVCONTAINER_FLAVOR=codespaces  bash scripts/devcontainer-smoke.sh
DEVCONTAINER_FLAVOR=full-stack  bash scripts/devcontainer-smoke.sh
DEVCONTAINER_FLAVOR=nested      bash scripts/devcontainer-smoke.sh
```

Skip flags (set to `1` to skip the named section):

| Flag | Skips |
| --- | --- |
| `SKIP_MODEL` | Waiting for the model in `/api/tags` (CI doesn't pull models) |
| `SKIP_OPENCODE` | `opencode` binary check (install is async) |
| `SKIP_DIND` | Docker-in-Docker section (envs without socket mount) |
| `SKIP_TOOLCHAIN` | PATH binary loop (minimal-image testing) |
| `SKIP_POSTCREATE` | postCreate idempotency rerun (noisy; iterating on smoke) |
| `SKIP_FULL_STACK_EXTRAS` | code-server + Caddy + metrics block (full-stack flavor) |
| `SKIP_NESTED` | `@devcontainers/cli` existence check |

Tuning: `MODEL_WAIT=<seconds>` — seconds to wait for the model in `/api/tags` (default `300`).

## Troubleshooting

- **`haven doctor` says "Compose file: ⚠ no compose labels".** The haven CLI couldn't read a `com.docker.compose.project` label off its own container. Confirm the container was started by `docker compose` (not bare `docker run`).

### Port forwarding by IDE

`forwardPorts` in devcontainer.json is honored by the **client** (the IDE plugin that brought the stack up), not by the compose stack itself. Behavior differs by IDE:

| IDE / launcher | Default? | Auto-forwards `forwardPorts`? | Notes |
| --- | --- | --- | --- |
| `devpod up` (no `--ide` flag) | **yes** — uses `--ide openvscode` | **Yes** | Runs an OpenVSCode server inside the container with built-in port forwarding; reachable via DevPod's printed URL |
| `devpod up --ide vscode` | | Yes | Host VSCode + native Dev Containers extension; requires `code` on host PATH |
| `devpod up --ide codium` | | **No** | SSH-only; no plugin ([loft-sh/devpod#1198](https://github.com/loft-sh/devpod/issues/1198)). Use the manual tunnel below |
| `devpod up --ide jetbrains` | | Yes | JetBrains Gateway; requires Gateway + license |
| `devcontainer up` (headless) | | No | Manage ports manually |
| GitHub Codespaces | | Yes | Codespaces UI panel; strips host port bindings server-side |

If you didn't pass `--ide` and your browser auto-opens with a forwarded URL, that's the default `openvscode` IDE doing its job — that's the normal path. The codium / headless rows are the special cases.

**Codium / headless workaround** — open SSH tunnels manually:

```bash
# Find your workspace name
devpod list

# Tunnel the ports you care about (full-stack flavor shown)
devpod ssh <workspace> -L 11434:ollama:11434 \
                       -L 8443:code-server:8443 \
                       -L 80:caddy:80
```

Or omit `--ide codium` (default `openvscode` forwards automatically), or pass `--ide vscode` if you have the `code` CLI on your host.

**Verifying Caddy is healthy (vs port-forwarding issue).** If `curl http://localhost:80` from your host returns connection-refused but the full-stack flavor is up, distinguish "Caddy is broken" from "port not forwarded":

```bash
# From your host — test Caddy from INSIDE the workspace container
docker exec inferhaven-dev-workspace curl -sI http://caddy/

# Expect 200/308 — proves Caddy is healthy; the issue is purely client-side
# port forwarding (use the codium tunnel workaround above).
```

- **`devcontainer exec --workspace-folder . …` returns "Dev container not found".** `@devcontainers/cli` finds containers by the `devcontainer.local_folder` label set during `up`. If you brought the stack up via `devpod up`, DevPod uses its own labels and `devcontainer exec` finds nothing. Either:
  - `devpod ssh <workspace>` into the running workspace and run commands directly (e.g. `bash scripts/devcontainer-smoke.sh`), or
  - Bring the stack up with `devcontainer up --workspace-folder .` (not DevPod) when you specifically need `devcontainer exec`.

- **`docker compose -p inferhaven-dev ps` returns empty rows even though `docker ps` shows containers.** DevPod overrides the compose project name during `up`. The `container_name:` directives in our override file still produce literal names (`inferhaven-dev-*`), but the compose project *label* on those containers is DevPod's generated name, not `inferhaven-dev`. Workarounds:
  - Use `docker ps`, `docker logs <name>`, `docker inspect <name>` directly.
  - Find the actual project name: `docker inspect inferhaven-dev-workspace --format '{{index .Config.Labels "com.docker.compose.project"}}'`.

- **`InvalidDefaultArgInFrom` warning during build** (`Default value for ARG $BASE_IMAGE results in empty or invalid base image name (line 4)`). Comes from `@devcontainers/cli`'s auto-generated `updateUID.Dockerfile-<ver>` which uses `FROM $BASE_IMAGE` without a default. The value is supplied via `--build-arg` at build time; the warning is a Docker linter false-positive. Harmless. Ignore.
