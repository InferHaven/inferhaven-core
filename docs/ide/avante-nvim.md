# avante.nvim — InferHaven Integration Guide

[avante.nvim](https://github.com/yetone/avante.nvim) is a Neovim plugin that brings AI assistance directly into your editor with a Cursor-like experience. It works with InferHaven's local Ollama instance and any configured cloud providers.

Neovim 0.10+ is required. InferHaven's workspace image ships Neovim from the official GitHub releases — no manual upgrade needed.

## Harness install (recommended)

Add `avante` to `INSTALL_ASSISTANTS` in your `.env`:

```bash
INSTALL_ASSISTANTS=avante
```

InferHaven automatically:

- Installs avante.nvim via lazy.nvim with a minimal Neovim config (won't touch an existing `init.lua`)
- Writes a multi-provider sidecar with all installed Ollama models + any configured cloud providers
- Installs the `avante` command for Zen Mode access
- Keeps the full model list in sync after every `haven pull`, `haven tune`, and `haven remove`

After the container starts:

```bash
avante        # open Zen Mode
nvim          # standard Neovim (avante sidebar via <leader>aa)
```

Inside Neovim, use `:AvanteModels` to switch between any local Ollama model or cloud provider — all installed local models appear as individual entries. Your selection persists across sessions.

## Zen Mode

Zen Mode makes avante look and feel like a coding agent CLI — you type a prompt and get AI-assisted code changes — but it's Neovim underneath. You keep all your Vim keybindings, text objects, and any plugins you've already configured.

The `avante` command installed by the harness enters Zen Mode directly:

```bash
avante
```

To set it up manually (add to `~/.inferhaven` or `~/.zshrc`):

```bash
alias avante='nvim -c "lua vim.defer_fn(function()require(\"avante.api\").zen_mode()end, 100)"'
```

## Manual installation

If you already have a Neovim config and prefer to manage it yourself, add to `~/.config/nvim/lua/plugins/avante.lua`:

```lua
return {
  "yetone/avante.nvim",
  event = "VeryLazy",
  build = "make",
  opts = function()
    return {
      provider = "ollama",
      providers = {
        ollama = {
          __inherited_from   = "openai",
          endpoint           = "http://ollama:11434/v1",  -- workspace-internal Docker endpoint
          model              = "qwen2.5-coder:7b",
          api_key_name       = "OLLAMA_OPENAI_KEY",       -- set to any non-empty value
          timeout            = 120000,
          extra_request_body = { options = { num_ctx = 32768 } },
        },
      },
    }
  end,
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "stevearc/dressing.nvim",
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
  },
}
```

You also need `OLLAMA_OPENAI_KEY` set to any non-empty value in your shell (avante uses it as a placeholder API key; Ollama ignores the `Authorization` header):

```bash
export OLLAMA_OPENAI_KEY=ollama  # add to ~/.zshrc or ~/.bashrc
```

Run `:Lazy sync` in Neovim to install.

## Default keybindings

| Keybinding | Action |
| ------------ | -------- |
| `<leader>aa` | Open Avante chat sidebar |
| `<leader>ae` | Edit selected code with AI |
| `<leader>ar` | Refresh Avante |
| `<leader>af` | Focus Avante window |

## Multiple providers

InferHaven's managed sidecar (`~/.config/nvim/lua/inferhaven-avante-config.lua`) includes all configured providers in one file. Every installed local Ollama model gets its own provider entry so all models appear in `:AvanteSwitchProvider`. Cloud providers are added automatically for every API key in `.env`.

Example sidecar with two local models and all cloud providers configured:

```lua
-- _haven: managed
-- InferHaven rewrites this file on model sync (haven pull/tune/remove).
-- Remove the first line above to manage this file yourself.
return {
  provider = "ollama",   -- default: always local-first (most-recent pull)
  providers = {
    ollama = {                         -- first/default local model
      __inherited_from   = "openai",
      endpoint           = "http://ollama:11434/v1",
      model              = "gemma4:e4b-it-q4_K_M",
      api_key_name       = "OLLAMA_OPENAI_KEY",
      timeout            = 120000,
      extra_request_body = { options = { num_ctx = 32768 } },
    },
    ["qwen3.5:9b"] = {                 -- additional local models
      __inherited_from   = "openai",
      endpoint           = "http://ollama:11434/v1",
      model              = "qwen3.5:9b",
      api_key_name       = "OLLAMA_OPENAI_KEY",
      timeout            = 120000,
      extra_request_body = { options = { num_ctx = 32768 } },
    },
    claude     = { model = "claude-sonnet-4-6" },   -- ANTHROPIC_API_KEY
    openai     = { model = "gpt-4o" },              -- OPENAI_API_KEY
    gemini     = { model = "gemini-2.0-flash" },    -- GEMINI_API_KEY
    openrouter = {                                   -- OPENROUTER_API_KEY
      __inherited_from = "openai",
      endpoint     = "https://openrouter.ai/api/v1",
      api_key_name = "OPENROUTER_API_KEY",
      model        = "deepseek/deepseek-r1",
    },
  },
}
```

All local models use `__inherited_from = "openai"` pointing at Ollama's OpenAI-compatible endpoint (`/v1`). This uses avante's fully-tested OpenAI provider code for native tool calling — no patches to avante internals are needed.

Use `:AvanteSwitchProvider` to switch between any local model or cloud provider. Your selection persists across sessions and triggers a full avante restart with the new provider active.

## Cloud models

| `.env` variable | Avante provider | Default model |
| --------------- | --------------- | ------------- |
| `ANTHROPIC_API_KEY` | `claude` | `claude-sonnet-4-6` |
| `OPENAI_API_KEY` | `openai` | `gpt-4o` |
| `GEMINI_API_KEY` | `gemini` | `gemini-2.0-flash` |
| `OPENROUTER_API_KEY` | `openrouter` | `deepseek/deepseek-r1` |

API keys are exported automatically via `~/.inferhaven` — no extra configuration needed.

## Customizing without losing your changes

InferHaven rewrites `inferhaven-avante-config.lua` on every `haven pull`, `haven tune`, and `haven remove` to keep the full model list current. Three levels of control:

**Change a cloud model** (e.g. swap `claude-sonnet-4-6` for `claude-opus-4-5`): edit the `model = "..."` value in the managed section — the changed value is carried forward on every sync.

**Add custom providers**: add them below the `-- _haven: user-providers` line inside the `providers = {}` table — anything in that section is preserved verbatim.

```lua
    -- _haven: user-providers — add custom providers below this line; haven will never overwrite this section
    my_bedrock = {
      __inherited_from = "openai",
      endpoint     = "https://bedrock.example.com/v1",
      api_key_name = "MY_BEDROCK_KEY",
      model        = "anthropic.claude-3-5-sonnet-20241022-v2:0",
    },
```

**Change the default provider**: edit `provider = "ollama"` — the value is preserved on every sync.

**Full opt-out**: remove the `-- _haven: managed` first line. InferHaven will never touch the file again.

## Troubleshooting

**"Connection refused":**

- Inside the workspace, the endpoint must be `http://ollama:11434/v1` — not `http://localhost:11434/v1`
- From a local machine, ensure the SSH tunnel is active

**Timeout errors:**

- Larger models take longer on first load — `timeout = 120000` is set by default in the managed sidecar
- Check `haven ps` to see if a model is currently loaded in GPU/RAM

**Plugin not loading:**

- Run `:Lazy sync` in Neovim to install all dependencies
- Run `:checkhealth avante` for diagnostics

**Tool calls freeze / inline edits stall:**

InferHaven configures Ollama using `__inherited_from = "openai"` pointing at Ollama's OpenAI-compatible endpoint (`http://ollama:11434/v1`). This uses avante's fully-tested OpenAI provider code for native tool calling and requires no patches to avante internals.

If you still see stalls after a rebuild, verify the managed sidecar has the correct format:

```bash
grep '__inherited_from\|endpoint' ~/.config/nvim/lua/inferhaven-avante-config.lua
```

Should show `__inherited_from   = "openai"` and `endpoint = "http://ollama:11434/v1"`. If it shows the old format (no `__inherited_from`), run `haven pull <model>` to trigger a sidecar rewrite.

**Models that show thinking tokens (`<think>...</think>`) in chat (qwen3 family):**

qwen3 models enable extended reasoning by default and stream thinking tokens into the response. Avante displays these as part of the output. This is model behavior — not an InferHaven issue. To suppress thinking, add `/no_think` at the start of your first message, or tune the model to disable thinking: `haven params <model> set thinking false` (if supported by your Ollama version).
