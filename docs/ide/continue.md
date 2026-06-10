# Continue.dev — InferHaven Integration Guide

[Continue.dev](https://continue.dev) is an open-source AI coding assistant available as a CLI (`cn`), a VS Code / code-server extension, and a JetBrains plugin. InferHaven ships the `cn` CLI inside the workspace container and keeps its config in sync with your installed Ollama models. The browser editor extension is **not** auto-installed — see [Install the editor extension yourself](#install-the-editor-extension-yourself) below.

## What InferHaven manages

Add `continue` to `INSTALL_ASSISTANTS` in `.env`:

```bash
INSTALL_ASSISTANTS=continue
```

This configures InferHaven to:

1. Install the `@continuedev/cli` package globally in the **workspace** container (so `cn` is on `PATH` for the `haven` SSH user).
2. Write `~/.continue/config.yaml` listing every installed Ollama model + any cloud providers you've configured in `.env`.
3. Re-sync that file after every `haven pull`, `haven tune`, and `haven remove`.

That's it. Nothing is installed into the code-server browser editor — InferHaven does not modify your IDE's extension state.

### Cloud providers auto-configured from `.env`

When a key is present, the matching provider entry is added to `~/.continue/config.yaml`:

| `.env` variable | Provider | Default model |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | Claude (cloud) | claude-sonnet-4-6 |
| `OPENAI_API_KEY` | GPT-4o (cloud) | gpt-4o |
| `GEMINI_API_KEY` | Gemini 2.0 Flash (cloud) | gemini-2.0-flash |
| `OPENROUTER_API_KEY` | OpenRouter (cloud) | anthropic/claude-sonnet-4-6 |

### Opt out of auto-sync

`touch ~/.continue/.no-autosync` — InferHaven will never rewrite `config.yaml` again.

### Customizing models without losing your changes

The managed config has a `# _haven: user-models` sentinel near the bottom. Add any extra models (additional cloud providers, alternate model versions, non-Ollama providers) **below** the sentinel — InferHaven carries that section forward verbatim on every sync. Roles assigned to managed models are also preserved.

### `cn` first-run login

The `cn` CLI requires a one-time login with a Continue.dev account on first run — this is a Continue CLI requirement unrelated to which models or API keys are configured. After authenticating once, the session token is stored in `~/.continue/` on the `workspace_home` volume and persists across container restarts.

```bash
# From inside the workspace (after SSH or via `haven tmux`)
cn -p "explain the function in src/foo.ts"
```

---

## Install the editor extension yourself

InferHaven intentionally does **not** auto-install the Continue extension in the code-server browser editor. The extension has had a string of activation regressions (duplicate version conflicts, dual activation events, command re-registration, filesystem scanner crashes on permission-restricted paths) that aren't InferHaven's to fix. Keeping the editor's extension state under your control means upgrades land when you say they land.

To install:

1. Open code-server in the browser.
2. Open the Extensions panel (`Ctrl+Shift+X`).
3. Search for **Continue** by Continue.dev.
4. Click **Install**.

The extension reads its config from `~/.continue/config.yaml` inside its own container's home (`/config/.continue/config.yaml` for code-server's `abc` user). To point the extension at the same config InferHaven maintains for the CLI, open a terminal in code-server and either symlink or copy the file:

```bash
# Copy once
mkdir -p /config/.continue
cp /config/workspace/projects/.continue/config.yaml /config/.continue/config.yaml  # if accessible via mounts
# or just paste the contents into /config/.continue/config.yaml via the editor
```

The cleanest option is to keep the cloud API keys in `.env` and let InferHaven write a fresh `config.yaml` in the workspace; the editor extension then needs its own copy (manually synced when models change). If you want fully shared state, follow [Continue's docs](https://docs.continue.dev/) for setting `CONTINUE_GLOBAL_DIR`.

---

## Manual setup (local VS Code or JetBrains connecting to a remote server)

For a local IDE installation connecting to a remote InferHaven server via SSH tunnel, configure Continue manually. This is the most stable, recommended setup.

### Installation

**VS Code / code-server** — install [Continue](https://marketplace.visualstudio.com/items?itemName=Continue.continue) from the marketplace.
**JetBrains** — install Continue from Settings → Plugins.

### Configuration

Continue uses `~/.continue/config.yaml`. Edit it directly or via the Continue settings UI.

### Local connection

```yaml
models:
  - name: InferHaven — Qwen Coder
    provider: ollama
    model: qwen2.5-coder:7b-instruct-q4_K_M
    apiBase: http://localhost:11434
    contextLength: 32768
    roles:
      - chat
      - edit
      - autocomplete
```

### Remote connection (InferHaven on another machine)

Use SSH port forwarding:

```bash
ssh -L 11434:localhost:11434 -p 2222 haven@your-server-ip
```

Then use the `localhost:11434` config above. Alternatively, with a configured domain:

```yaml
models:
  - name: InferHaven — Qwen Coder
    provider: ollama
    model: qwen2.5-coder:7b-instruct-q4_K_M
    apiBase: https://your-domain.com/api
    contextLength: 32768
    roles:
      - chat
      - edit
```

### Multiple models

```yaml
models:
  - name: Qwen Coder 7B (fast)
    provider: ollama
    model: qwen2.5-coder:7b-instruct-q4_K_M
    apiBase: http://localhost:11434
    contextLength: 32768
    roles:
      - chat
      - edit
      - autocomplete
  - name: Qwen Coder 30B (quality)
    provider: ollama
    model: qwen3-coder:30b
    apiBase: http://localhost:11434
    contextLength: 32768
    roles:
      - chat
      - edit
  - name: Gemma 4 E4B
    provider: ollama
    model: gemma4:e4b-it-q4_K_M
    apiBase: http://localhost:11434
    contextLength: 32768
    roles:
      - chat
      - edit
```

## Features that work with InferHaven

- **CLI agent:** `cn -p "your task"` runs Continue headlessly from the workspace terminal — the main supported path.
- **Chat / Edit / Autocomplete:** all work in the IDE extension once you install and point it at Ollama.
- **Context providers:** `@file`, `@folder`, `@codebase` work normally.

## Troubleshooting

**`cn` not found:**

- Confirm `continue` is in `INSTALL_ASSISTANTS` and the workspace has finished post-install: `cat ~/.haven/install.log | grep continue`
- Open a fresh login shell (`bash -l`) — `cn` lives in `~/.npm-global/bin/`.

**"Connection refused" from `cn` or the IDE extension:**

- Make sure InferHaven is running: `haven status`
- Check Ollama: `curl http://localhost:11434/api/tags`
- If remote, verify your SSH tunnel.

**Slow responses:**

- Large models on CPU are slow — pick smaller quant for CPU, 32B+ for GPU.
- Check resources inside the workspace: `htop`, `haven gpu-info`.

**Model not found:**

- Pull first: `haven pull qwen2.5-coder:7b-instruct-q4_K_M`
- Verify: `haven models`

**After `cn` login, only cloud models appear:**

- If you logged in to Continue Hub interactively, Continue may have rewritten `config.yaml`. Run `haven pull <any-model>` to restore — InferHaven rebuilds the full config (Ollama + any cloud keys from `.env`).

**PostHog network errors in the terminal** (`ERR_TLS_CERT_ALTNAME_INVALID` / `app.posthog.com`):

- Harmless — Continue's analytics client hitting a local DNS intercept. No action needed.

**Clipboard not working / extension assets failing to render (private domain or IP):**

The browser Clipboard API and extension asset loading both require a **secure context** (HTTPS or `localhost`). If you access code-server over plain HTTP — typically when `DOMAIN` is an IP address — clipboard is blocked at the browser level and extensions may fail to render assets.

*When does this apply?*

- `DOMAIN=<IP address>` → Caddy serves HTTP → clipboard unavailable
- `DOMAIN=localhost` → privileged secure origin → clipboard works
- `DOMAIN=<public domain>` → Let's Encrypt cert → clipboard works
- `DOMAIN=<private hostname>` → Caddy internal CA → works **after you trust the root cert**

*Trusting the Caddy root CA:*

```bash
docker cp inferhaven-caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

Import `caddy-root.crt` into your browser or OS trust store:

| Platform | Steps |
| --- | --- |
| Chrome/Edge (Linux) | Settings → Privacy and security → Security → Manage certificates → Authorities → Import |
| Chrome/Edge (macOS) | Double-click the `.crt` → Keychain Access → Always Trust |
| Firefox | Settings → Privacy & Security → View Certificates → Authorities → Import |
| Windows | Double-click → Install Certificate → Local Machine → Trusted Root Certification Authorities |
