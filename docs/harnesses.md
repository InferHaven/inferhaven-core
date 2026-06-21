# Coding Assistant Harnesses

InferHaven can auto-install and pre-configure suported harnesses on first boot. Set `INSTALL_ASSISTANTS` and any relevant API keys in `.env` before starting, and they will be ready in your workspace within a couple of minutes, SSH is never delayed.

```bash
# .env
INSTALL_ASSISTANTS=claudecode,opencode,aider
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
```

Available values for `INSTALL_ASSISTANTS`:

| Value | Harness | Install method |
| ------- | --------- | ---------------- |
| `opencode` | OpenCode | autoscript / npm |
| `aider` | Aider | `uv tool install aider-chat` |
| `pi` | Pi | npm |
| `goose` | Goose | autoscript / curl |
| `continue` | Continue | npm (binary: `cn`) |
| `claudecode` | Claude Code | autoscript / npm |
| `qwencode` | Qwen Code | autoscript / npm |
| `gemini` | Gemini CLI | npm |
| `amp` | Amp | npm |
| `avante` | Avante (Neovim) | lazy.nvim (Neovim plugin) |

Check what is installed at any time: `haven harness`

Harnesses that support local Ollama sync (`opencode`, `aider`, `pi`, `qwencode`, `goose`, `continue`, `avante`) automatically update their configs after every `haven pull`, `haven tune`, and `haven remove`.

---

## OpenCode (`opencode`)

Terminal TUI harness. Supports local Ollama models and cloud APIs. InferHaven auto-generates and keeps `~/.config/opencode/config.json` in sync, no manual setup needed.

### Local models

All models are added with `tools: true` and the actual `num_ctx` from Ollama. The recommended models are simply models that are known to work with OpenCode.

| Model | Size | Notes |
| ------- | ------ | ------- |
| `qwen3.5:9b` | 6.6GB | Open-source multimodal model, runs on modest hardware |
| `gemma4:e4b-it-q4_K_M` | 9.6GB | Designed to deliver frontier-level performance. Well-suited for reasoning, agentic workflows, coding, and multimodal understanding. |
| `gpt-oss:20b` | 14GB | OpenAI’s open-weight model designed for powerful reasoning, agentic tasks, and versatile developer use cases. |
| `devstral-small-2:24b-instruct-2512-q4_K_M` | 15GB | 24B model that excels at using tools to explore codebases, editing multiple files and power software engineering agents. |
| `qwen3-coder:30b` | 19GB | Alibaba's performant long context model for agentic and coding tasks. |

### Cloud models

Set `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` in `.env` and configure via OpenCode's own provider settings. Recommended models are from [OpenCode's docs](https://opencode.ai/docs/models/#recommended-models).

| Model | Backend | Notes |
| ----------------- | ----------------- | ----------------- |
| `GPT 5.2` | OpenAI API/ChatGPT | Reasoning, writing, coding; three-tier intelligence (instant/thinking/pro) |
| `GPT 5.1 Codex` | OpenAI API/Codex (via OpenAI) | Agentic coding, software engineering, faster token-efficient development workflows |
| `Claude Opus 4.5` | Anthropic API/Bedrock/Vertex | Coding, agents, computer use, enterprise workflows |
| `Claude Sonnet 4.5` | Anthropic API/Bedrock/Vertex | Top coding/agent model, computer use (SWE-bench/OSWorld), reasoning/math |
| `Minimax M2.1` | MiniMax API | Multi-language programming, code generation/refactoring, agent/tool generalization, efficient responses. |
| `Gemini 3 Pro` | Google Vertex AI/Gemini app | Reasoning, multimodality, coding/math benchmarks (GPQA/MathArena). |

```bash
opencode
# /models → select model
```

Your last `/models` selection is mirrored back into `~/.config/opencode/config.json` whenever tmux state is saved (every 15 min and on detach), so a container restart relaunches opencode on the same model, no model-picker prompt, no revert to the cloud-priority default seeded at first install.

---

## Aider (`aider`)

Diff-based AI pair programmer. Reads your codebase, proposes changes as unified diffs. Does **not** require tool calling, almost any model works.

### Local models via `haven aider`

When `aider` is in `INSTALL_ASSISTANTS` .env variable, InferHaven manages `~/.aider.model.settings.yml` automatically.
**Opt out of auto-sync**: remove the `## inferhaven:managed` line at the top of `~/.aider.model.settings.yml`. InferHaven will never touch that file again once the sentinel is gone.

**Per-project overrides**: create `.aider.model.settings.yml` in your repo root. Aider loads it *after* the home-dir file, so your per-project settings win on any conflicts, no need to edit the managed file.

`haven aider` handles model selection and endpoint wiring for local Ollama models. It sets `OLLAMA_API_BASE` and passes the `ollama_chat/` prefix automatically, no manual config needed per session. The `OLLAMA_API_BASE` environment variable is scoped to that `aider` invocation only, running plain `aider` afterwards still uses whatever `~/.aider.conf.yml` specifies.

```bash
haven aider          # launch with local Ollama model (auto-configured)
aider                # launch with cloud key or ~/.aider.conf.yml default

# Override model for one session (use ollama_chat/ prefix — recommended)
aider --model ollama_chat/qwen2.5-coder:14b

# Search for then use a specific model before launching the harness
aider --list-models openai      # Searching for models with openai in the name
aider --model openai/gpt-5.5    # Run aider using OpenAis GPT-5.5 cloud model, utilizing your configured openai API key

# Specify files to edit
aider src/main.py tests/test_main.py
```

**How it behaves:**

IF a single model is installed, that model will be loaded, and if multiple models are installed you will see a model menu just like the one below.

```bash
╭─  haven aider — local models  ───────────────────────────────────╮
│  MODEL                                       PARAMS     SIZE     │
│  qwen2.5-coder:7b-instruct-q4_K_M            7B         4.7 GB   │
│> qwen2.5-coder:14b-instruct-q4_K_M           14B        9.0 GB   │
│  › _                                                             │
╰──────────────────────────────────────────────────────────────────╯
```

**Recommendations**

| Model | Size | Notes |
| ------- | ------ | ------- |
| `qwen3:1.7b-q4_K_M` | 1.3 GB | Fast on CPU, suprisingly capable for extremely simple tasks |
| `qwen2.5-coder:3b-instruct-q4_K_M` | 1.9 GB | Run on CPU for simple tasks |
| `qwen3:4b-instruct-2507-q4_K_M` | 2.5 GB | Strong model for size, fast on modest GPU |
| `qwen2.5-coder:7b-instruct-q4_K_M` | 4.7 GB | Great balance between quality and hardware |
| `qwen2.5-coder:14b-instruct-q4_K_M` | 9 GB | Better output, solid coding ability; needs GPU |
| `gemma4:e4b-it-q4_K_M` | 9.6GB | Designed to deliver frontier-level performance. Well-suited for reasoning, agentic workflows, coding, and multimodal understanding. |
| `gpt-oss:20b` | 14 GB | OpenAI’s open-weight model designed for powerful reasoning, agentic tasks, and versatile developer use cases. |
| `qwen3-coder:30b` | 19GB | Latest Qwen coding iteration. Improved instruction-following for coding tasks. Useful for multi-file edits, bug fixes, code explanation. Scales well on consumer hardware. |

### Cloud models

Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` in `.env`. The key is exported via `~/.inferhaven` and picked up by Aider automatically, no extra config needed. Cloud key config takes priority over Ollama auto-config.

| Model | Backend | Notes |
| ------------------------ | ------------------------ | ------------------------ |
| `gpt-5` | OpenAI | OpenAI’s most advanced model with major improvements in reasoning, code quality, and user experience; 400K context; ideal for complex tasks. |
| `o3-pro` / `o3` | OpenAI | High-end reasoning model from OpenAI; 200K context; suited for advanced prompts requiring deep analysis. |
| `gemini-2.5-pro` | Google | Google’s state-of-the-art model for reasoning, coding, math, and science; 1M+ context; excels in multimodal and long-context tasks. |
| `grok-4` | xAI | xAI’s latest reasoning model with 256K context, parallel tool calling, and multimodal support; strong for STEM and technical analysis. |
| `DeepSeek V3.2` | DeepSeek AI | Open-source model from DeepSeek AI; focuses on efficient coding, math, and general reasoning; targeted for cost-effective, high-performance developer workflows. |
| `Claude Opus 4.6` / `Sonnet 4.6` | Anthropic | Anthropic’s premium models emphasizing safety and ethics; 200K context; best for research, creative writing, and enterprise applications. |

---

## Pi (`pi`)

Terminal harness designed for local and cloud models side-by-side. Pi uses an OpenAI-compatible custom provider system (`~/.pi/agent/models.json`) to connect to Ollama, making it easy to mix local and cloud models in a single session without any manual wiring. API keys for cloud providers are picked up automatically from the environment as well.

### Local models

When `pi` is in `INSTALL_ASSISTANTS`, InferHaven writes `~/.pi/agent/models.json` with all available Ollama models registered under a custom `ollama` provider.

**Compat flags**: Ollama does not support the `developer` role used by some reasoning models or the `reasoning_effort` parameter. InferHaven sets `compat.supportsDeveloperRole: false` and `compat.supportsReasoningEffort: false` on the Ollama provider so Pi sends a standard `system` message instead.

**Opt out of auto-sync**: remove the `"_haven": "managed"` key from `~/.pi/agent/models.json`. InferHaven will never touch that file again once the sentinel is gone.

**Adding your own providers**: edit `~/.pi/agent/models.json` and add additional entries under `providers`. The `ollama` block is the only one InferHaven manages, everything else is yours.

**Recommendations**

| Model | Size | Notes |
| ------- | ------ | ------- |
| `qwen3.5:9b` | 6.6 GB | Open-source multimodal model, runs on modest hardware |
| `gemma4:e4b-it-q4_K_M` | 9.6GB | Designed to deliver frontier-level performance. Well-suited for reasoning, agentic workflows, coding, and multimodal understanding. |
| `gpt-oss:20b` | 14 GB | MoE architecture for efficient agentic tasks; suitable for local setups with 16GB+ RAM |
| `qwen3-coder:30b` | 19 GB | Best local agentic model; needs GPU |
| `glm-4.7-flash:latest` | 19 GB | 30B MoE (3B active), tool calling, 128K context, best for full agentic workflows |
| `gemma4:31b-it-q4_K_M` | 20 GB | Higher quality than e4b model. |

### Cloud models

Set cloud API keys in `.env`. They are exported via `~/.inferhaven` and picked up by Pi automatically as environment variables. InferHaven also writes `~/.pi/agent/auth.json` (create-once, never overwritten) that references the env var names using Pi's variable-name resolution syntax, key rotation only requires updating `.env`.

| Key variable | Pi provider | Notes |
| ------------ | ----------- | ----- |
| `ANTHROPIC_API_KEY` | `anthropic` | Claude models |
| `OPENAI_API_KEY` | `openai` | GPT models |
| `GEMINI_API_KEY` | `google` | Gemini models |
| `OPENROUTER_API_KEY` | `openrouter` | OpenRouter gateway |

```bash
pi                    # launch (local Ollama models auto-configured)
pi --help             # full option reference

# Inspect configured models
cat ~/.pi/agent/models.json

# Add a cloud model session (auth picked up from env)
pi  # /model → select provider → select model
```

---

## Goose (`goose`)

Agentic CLI harness run by the [AAIF](https://aaif.io/). Runs tasks autonomously using extensions (MCP servers, developer tools). Works best with models that support tool calling.

InferHaven writes `~/.config/goose/config.yaml` on first install with the Ollama provider and the first available model, so goose is usable immediately without running `goose configure`. `OLLAMA_CONTEXT_LENGTH` is exported via `~/.inferhaven` and kept in sync with the active model's actual `num_ctx`.

The InferHaven installed Goose version is pinned to v1.27.2 to avoid installing releases that break Ollama streaming. Override to test a newer release using the GOOSE_VERSION variable in the `.env` file, check [the goose repo](https://github.com/aaif-goose/goose/releases) for currently available versions.

### Local models via `haven goose`

Goose connects to a single API endpoint per session. The `haven goose` command handles the model selection and endpoint wiring for you for you: it sets the required environment variables, presents a model menu if more than one is installed, and drops you straight into Goose. All environment variables are scoped to that session only, running plain `goose` afterwards still uses `~/.config/goose/config.yaml`.

When multiple models are installed, a model picker is presented before launch (same UI as `haven aider`).

### Ollama Tool Shims

After selecting a model, a second menu asks whether to enable the **Ollama tool shim**:

```bash
╭─  haven goose — Ollama tool shim  ────────────────────────────────╮
│  Experimental — helps models without native tool calls work with  │
│  Goose                                                            │
│> No  — standard mode (use native tool calls)                      │
│  Yes — enable tool shim  [shim interpreter: qwen2.5-coder:7b]     │
│  Yes — enable tool shim  [pick a different shim interpreter]      │
╰───────────────────────────────────────────────────────────────────╯
```

The tool shim routes Goose's tool calls through a second interpreter model, which can help models without native tool-call support participate in agentic workflows. Models with native tool calling don't need it, use standard mode.

> **Tool shim and memory:** enabling the shim holds two model instances simultaneously. On memory-constrained hardware this doubles VRAM/RAM pressure and can trigger OOM kills, `haven goose` displays a warning when the shim is enabled.

### Streaming stalls and context tuning

Goose loads a large set of tool schemas into the context on every request. Combined with a large context window this can push Ollama's KV-cache allocation high enough to cause slow inference, stream stalls, or OOM crashes on marginal hardware. `haven goose` caps `OLLAMA_CONTEXT_LENGTH` at `GOOSE_CTX_LIMIT` (default `32768`) regardless of what tuning is set for the model. If your model was tuned to a higher value, the launch line shows:

  `[InferHaven] Context:    32768 tokens (model supports 131072, capped; set GOOSE_CTX_LIMIT to override)`

To reduce pressure further, set `GOOSE_CTX_LIMIT=16384` in `.env`. To allow the full model context, set it to the desired value. The cap only applies to `haven goose`, plain `goose` reads `~/.inferhaven` directly.

**Recommendations**

| Model | Size | Notes |
| ------- | ------ | ------- |
| `qwen3.5:9b` | 6.6 GB | Open-source multimodal model, runs on modest hardware |
| `gemma4:e4b-it-q4_K_M` | 9.6 GB | Designed to deliver frontier-level performance. Well-suited for reasoning, agentic workflows, coding, and multimodal understanding. |
| `gemma4:26b-a4b-it-q4_K_M` | 16.8 GB | Very good results for model class/ |
| `qwen3.5:27b` | 17 GB | Higher quality than qwen3.5 9b for more complex tasks |
| `qwen3-coder:30b` | 19 GB | Best local agentic model; needs GPU |
| `gemma4:31b-it-q4_K_M` | 20 GB | Higher quality than e4b model. |

### Cloud models

Goose supports multiple cloud providers. API keys exported via `~/.inferhaven` are picked up automatically.

| Key variable | Goose provider | Notes |
| ------------ | -------------- | ----- |
| `ANTHROPIC_API_KEY` | `anthropic` | Claude models, recommended for best tool-call reliability |
| `OPENAI_API_KEY` | `openai` | GPT models |
| `GEMINI_API_KEY` | `google` (set as `GOOGLE_API_KEY`) | Gemini models |

```bash
haven goose                            # launch with model picker + tool shim option
goose                                  # launch with ~/.config/goose/config.yaml defaults
goose configure                        # interactive setup (switch provider, add extensions)

# Inspect config
cat ~/.config/goose/config.yaml
```

---

## Claude Code (`claudecode`)

Anthropic's official CLI harness. Full agentic loop: reads files, writes patches, runs shell commands, runs tests, iterates.

**Requires:** `ANTHROPIC_API_KEY` or sign in using OAuth to use cloud models.

| Model | Notes |
| ------- | ------- |
| `claude-sonnet-4-6` | Recommended, best balance of speed and quality |
| `claude-opus-4-7` | Maximum capability and higher cost |
| `claude-haiku-4-5` | Fastest; good for completions and simple edits |

### Local models via `haven claude`

Claude Code connects to a single API endpoint per session. `haven claude` handles the switching for you: it sets the required environment variables, presents a model menu if more than one is installed, and drops you straight into Claude Code.

```bash
haven claude
```

**How it behaves:**

With multiple models installed you will be able to select from a menu. Select with arrow keys or type to fuzzy-search, then press Enter. Escape or Ctrl-C exits without launching.
The picker looks like this when multiple models are installed:

```bash
╭─  haven claude — local models  ──────────────────────────────────╮
│  MODEL                                       PARAMS     SIZE     │
│  qwen3.5:9b                                  9B         6.6 GB   │
│  gpt-oss:20b                                 20B        14.0 GB  │
│> qwen3-coder:30b                             30B        19.0 GB  │
│  › _                                                             │
╰──────────────────────────────────────────────────────────────────╯
```

The environment variables are scoped to that `claude` invocation only, running plain `claude` afterwards still uses the cloud.

**Recommended local models**: agentic features (tool use, file edits) require tool-calling support. Models without it can still handle simple Q&A and code generation via the chat loop.

| Model | Size | Notes |
| ------- | ------- | ------- |
| `ministral-3:8b-instruct-2512-q4_K_M` | 6 GB | The Ministral 3 family is designed for edge deployment, capable of running on a wide range of hardware. |
| `qwen3.5:9b` | 6.6 GB | Modest hardware, simple tasks |
| `gpt-oss:20b` | 14 GB | Strong reasoning and agentic tasks |
| `qwen3.5:27b` | 17 GB | Better quality, still consumer-friendly |
| `qwen3-coder:30b` | 19 GB | Best general local coding model |
| `glm-4.7-flash:latest` | 19 GB | 30B MoE (3B active), tool calling, 128K context, best for full agentic workflows |
| `llama3.3:70b-instruct-q4_K_M` | 43 GB | High-end hardware only; strong general capability |

```bash
claude          # launch (cloud)
claude --help   # full option reference
haven claude    # Choose a local model to run 
```

---

## Qwen Code (`qwencode`)

Alibaba's CLI harness, designed around the Qwen model family. InferHaven auto-generates and keeps `~/.qwen/settings.json` in sync, no manual setup needed.

### Local models

All Ollama models are registered as OpenAI-compatible providers pointing at the container-internal Ollama endpoint, with `num_ctx` sourced from the actual model parameters (reflecting any `haven tune` values).

| Model | Size | Notes |
| ------- | ------ | ------- |
| `ministral-3:8b-instruct-2512-q4_K_M` | 6 GB | The Ministral 3 family is designed for edge deployment, capable of running on a wide range of hardware. |
| `qwen3.5:9b` | 6.6 GB | Modest hardware, simple tasks |
| `ministral-3:14b-instruct-2512-q4_K_M` | 9.1 GB | Higher quality than the 8b model |
| `gemma4:e4b-it-q4_K_M` | 9.6GB | Designed to deliver frontier-level performance. Well-suited for reasoning, agentic workflows, coding, and multimodal understanding. |
| `gpt-oss:20b` | 14 GB | Strong reasoning and agentic tasks |
| `qwen3.5:27b` | 17 GB | Better quality than 9b, still consumer-friendly |
| `gemma4:31b-it-q4_K_M` | 20 GB | Higher quality than e4b model. |

**Opt out of auto-sync**: remove the `~/.qwen/.inferhaven-managed` sidecar file. InferHaven will never touch `settings.json` again once the sidecar is gone.

**Adding your own providers**: InferHaven only manages the entries it created (tracked via the sidecar). Any providers you add manually are preserved across syncs.

### Cloud models

Set `QWEN_API_KEY` or any supported cloud API key in `.env` and add your provider to `~/.qwen/settings.json`. InferHaven will not overwrite existing user config.

| Model | Backend | Notes |
| ------- | --------- | ------- |
| `qwen3.6-plus` | Qwen API / Coding Plan | General-purpose flagship; strong reasoning + coding; good default cloud model |
| `kimi-k2.5` | Qwen API / Coding Plan | Long-context specialist; great for large docs, logs, and repo analysis |
| `glm-4.7` | Qwen API / Coding Plan | Balanced performance model; solid reasoning with lower cost than top-tier |
| `glm-5` | Qwen API / Coding Plan | Newer high-end GLM; improved reasoning, tool use, and code generation |
| `MiniMax-M2.5` | Qwen API / Coding Plan | Fast and cost-efficient; good for high-throughput or lightweight tasks |
| `qwen-3-coder-next` | Qwen API / Coding Plan | Code-optimized model; excels at refactoring, debugging, and structured output |

```bash
haven qwen    # recommended — model picker, bypasses auth screen, launches directly

qwen          # also works — InferHaven writes security.auth.selectedType and
              # model.name into settings.json so the auth screen is skipped

# List configured models (auto-populated by InferHaven)
cat ~/.qwen/settings.json
```

---

## Gemini CLI (`gemini`)

Google's CLI harness. Uses the Gemini API, not local Ollama.

**Requires:** `GEMINI_API_KEY` or OAuth with an account.

```bash
gemini
```

| Model | Notes |
| ------- | ------- |
| `gemini-2.5-pro` | Recommended, strong reasoning and code |
| `gemini-2.5-flash` | Faster; good for completions |
| `gemini-3-flash-preview` | State-of-the-art reasoning |

---

## Amp (`amp`)

Sourcegraph's agentic harness. Full agent loop with codebase search.

**Requires:** AMP Access Token (configured interactively on first run)

```bash
amp
```

| Model | Notes |
| ------- | ------- |
| `claude-sonnet-4.6` | Large-scale retrieval & research on external code |
| `claude-opus-4.6` | Maximum capability, unconstrained state-of-the-art model use |
| `claude-haiku-4.6` | Faster and cheaper for small, well-defined tasks |
| `GPT-5.4` | Deep reasoning with extended thinking |

---

## Continue (`continue`)

Open-source AI coding assistant with a CLI agent (`cn`) and VS Code/code-server extension.
When `continue` is in `INSTALL_ASSISTANTS`, InferHaven:

1. Installs the `cn` CLI (`npm i -g @continuedev/cli`)
2. Writes `~/.continue/config.yaml` with all available Ollama models
3. Keeps the config in sync after every `haven pull`, `haven tune`, and `haven remove`

### Local models

InferHaven manages `~/.continue/config.yaml` as long as `cn` is installed. Each model is registered with its actual `contextLength` (from `haven tune`), and the `DEFAULT_MODEL` (or first available model) is also assigned the `autocomplete` role. The config is re-written on every sync, so it always reflects the current model list, even if Continue's auth flow modifies it.

**Opt out of auto-sync**: `touch ~/.continue/.no-autosync`. InferHaven will never touch the file again.

**Note:** Continue's first-run prompts for login or an Anthropic/cloud API key. This is for Continue Hub cloud features, it does not affect local Ollama models. Use `cn login` for Continue Hub. As of current testing a quick way through this is simply inputing something like `sk-ant-1` as an Anthropic key as shown below.

```bash
How do you want to get started?
1. ⏩ Log in with Continue
2. 🔑 Enter your Anthropic API key

Enter choice (1): 2

Enter your Anthropic API key: sk-ant-1
✓ Config file updated successfully at /home/haven/.continue/config.yaml
```

| Model | Size | Notes |
| ------- | ------ | ------- |
| `qwen2.5-coder:1.5b-instruct-q4_K_M` | 0.9 GB | Fast, ultra low memory, works for basic autocomplete |
| `qwen2.5-coder:3b-instruct-q4_K_M` | 1.8 GB | Balance between speed / ability between 1.5b and 7b models - autocomplete |
| `qwen2.5-coder:7b-instruct-q4_K_M` | 4.7 GB | Fast, low memory, good default for autocomplete, should do well at basic chat |
| `qwen2.5-coder:14b-instruct-q4_K_M` | 8.4 GB | Will work great for autocomplete and basic chat functions |
| `gemma4:e4b-it-q4_K_M` | 9.6GB | Designed to deliver frontier-level performance. Well-suited for reasoning, agentic workflows, coding, and multimodal understanding. Should work for tool use, although continue issues a model warning |
| `gpt-oss:20b` | 14 GB | Strong reasoning and agentic tasks, can edit and apply with tool use |
| `qwen3-coder:30b` | 19 GB | Best local coding quality can edit and apply with tool use; needs GPU |

### CLI usage

```bash
cn                         # interactive agent session
cn -p "fix the failing tests"  # headless mode
cn --resume                # resume last conversation
cn --help                  # full option reference

# Inspect config
cat ~/.continue/config.yaml
```

### VS-Code Extension - Remote (non-code-server) setup

For a local VS Code with the Continue extension connecting to a remote InferHaven server, use SSH port forwarding and point `apiBase` at `http://localhost:11434`. See [docs/ide/continue.md](ide/continue.md) for details.

---

## Avante (`avante`)

[avante.nvim](https://github.com/yetone/avante.nvim) is a Neovim plugin with a Cursor-like AI sidebar. Unlike other harnesses, `avante` installs a Neovim plugin (via lazy.nvim) rather than a standalone CLI tool. The `avante` command enters **Zen Mode**, a full-screen AI coding interface that looks like a CLI agent but runs entirely inside Neovim, giving you all Vim keybindings and your existing plugin ecosystem.

When `avante` is in `INSTALL_ASSISTANTS`, InferHaven:

1. Installs lazy.nvim and avante.nvim (with a minimal `init.lua` if you have no existing Neovim config)
2. Writes `~/.config/nvim/lua/plugins/avante.lua`, the plugin config (written once, never overwritten)
3. Writes `~/.config/nvim/lua/inferhaven-avante-config.lua`, the multi-provider sidecar (managed, see below)
4. Installs `~/.local/bin/avante`, a command that opens Neovim directly into Zen Mode
5. Keeps the active Ollama model in sync after every `haven pull`, `haven tune`, and `haven remove`

```bash
avante                            # open Zen Mode — AI-assisted coding in Neovim
nvim                              # standard Neovim (avante sidebar available via <leader>aa)
```

Inside Neovim, use `:AvanteModels` to pick a model (all Ollama models + configured cloud models are listed) and `:AvanteSwitchProvider` to switch between providers. Your last selection persists across sessions.

### Local models

All available Ollama models appear under the `ollama` provider in `:AvanteModels`. InferHaven keeps the sidecar in sync after every `haven pull`, `haven tune`, and `haven remove`, new models appear in the picker automatically.

**Recommended models**

| Model | Size | Notes |
| ------- | ------ | ------- |
| `qwen3.5:9b` | 6.6GB | Open-source multimodal model, runs on modest hardware |
| `gemma4:e4b-it-q4_K_M` | 9.6GB | Designed to deliver frontier-level performance. Well-suited for reasoning, agentic workflows, coding, and multimodal understanding. |
| `gpt-oss:20b` | 14GB | OpenAI’s open-weight model designed for powerful reasoning, agentic tasks, and versatile developer use cases. |
| `qwen3-coder:30b` | 19GB | Alibaba's performant long context model for agentic and coding tasks. |

**Opt out of auto-sync**: remove the `-- _haven: managed` first line from `~/.config/nvim/lua/inferhaven-avante-config.lua`. InferHaven will never touch that file again while preserving your existing config. You can then set any provider, model, or endpoint freely.

**Existing Neovim config**: if `~/.config/nvim/init.lua` already exists, InferHaven only adds `avante.lua` to your `lua/plugins/` directory, your existing config is untouched. If you don't use lazy.nvim, add avante.nvim via your plugin manager manually.

**Full diff features**: the harness build step (`make`) downloads the prebuilt `avante_lib` binary automatically (no Rust required). If the download fails, run it manually:

```bash
cd ~/.local/share/nvim/lazy/avante.nvim && make
```

### Cloud models

InferHaven writes a **multi-provider sidecar** that includes every cloud provider whose API key is configured in `.env`, alongside the local Ollama provider. The default provider is always `ollama` (local-first). Use `:AvanteSwitchProvider` inside Neovim to switch providers, the selection persists across sessions.

```bash
# .env — include any combination of cloud keys
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
OPENROUTER_API_KEY=sk-or-...
INSTALL_ASSISTANTS=avante
```

| `.env` variable | Avante provider | Default model |
| --------------- | --------------- | ------------- |
| `ANTHROPIC_API_KEY` | `claude` | `claude-sonnet-4-6` |
| `OPENAI_API_KEY` | `openai` | `gpt-4o` |
| `GEMINI_API_KEY` | `gemini` | `gemini-2.0-flash` |
| `OPENROUTER_API_KEY` | `openrouter` | `deepseek/deepseek-r1` |
