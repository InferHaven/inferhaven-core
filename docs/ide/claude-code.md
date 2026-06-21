# Claude Code: InferHaven Integration Guide

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) is Anthropic's CLI harness. While Claude Code primarily uses Anthropic's API, you can use it alongside InferHaven in a powerful hybrid workflow: Claude Code for complex reasoning and multi-file changes, InferHaven's local models for quick completions, privacy-sensitive code, and offline work.

## Setup

### Option A: Pre-configure in .env (recommended)

The easiest path, configure everything before the container starts:

```bash
# In your inferhaven-core/.env file:
INSTALL_ASSISTANTS=claudecode
ANTHROPIC_API_KEY=sk-ant-...
CLAUDE_CODE_DISABLE_TELEMETRY=true
```

Then `docker compose up -d`. By the time you SSH in, `claude` is on your PATH and your API key is loaded automatically in every session (stored in `~/.inferhaven`, chmod 600).

### Option B: Install manually after startup

SSH into your InferHaven workspace and install:

```bash
ssh -p 2222 haven@localhost

# Install Claude Code (writes to ~/.npm-global/bin — no root, no sudo)
npm install -g @anthropic-ai/claude-code
```

Set your API key, edit `~/.inferhaven` for persistence across sessions:

```bash
# Append to ~/.inferhaven (sourced by every login shell)
echo 'export ANTHROPIC_API_KEY=sk-ant-...' >> ~/.inferhaven
source ~/.inferhaven
```

### Using Claude Code from InferHaven

```bash
cd ~/projects/my-app

# Start Claude Code
claude

# Claude Code operates on files in your InferHaven workspace.
# All file I/O is local. Only prompts and responses go to Anthropic's API.

# Start Claude Code with a selected local model from menu
haven claude
```

## Privacy Architecture

When using Claude Code inside InferHaven:

```bash
┌─────────────────────────────────────────┐
│           InferHaven Server             │
│                                         │
│  ┌──────────┐      ┌────────────────┐   │
│  │  Claude  │      │   Your Code    │   │
│  │ Code CLI │ ───> │   (private,    │   │
│  └────┬─────┘      │    on disk)    │   │
│       │            └────────────────┘   │
│       │ Prompts only                    │
│       v                                 │
│  ┌──────────┐                           │
│  │ Anthropic│ (code snippets in prompts │
│  │   API    │  go to Anthropic)         │
│  └──────────┘                           │
│                                         │
│  ┌──────────┐      ┌────────────────┐   │
│  │  Ollama  │ ───> │  100% private  │   │
│  │  (local) │      │  (never leaves │   │
│  └──────────┘      │   the server)  │   │
│                    └────────────────┘   │
└─────────────────────────────────────────┘
```

**Key insight:** Your codebase lives on the InferHaven server. Claude Code reads files locally (fast) and only sends prompts/responses over the network. For tasks where even prompts must stay private, switch to the local Ollama model via aider or Continue.dev.

## Advanced: MCP Server for Local Context

You can configure Claude Code to use InferHaven's Ollama as an MCP (Model Context Protocol) server for augmented context:

```json
// ~/.claude/mcp.json
{
  "mcpServers": {
    "inferhaven-ollama": {
      "command": "curl",
      "args": ["-s", "http://localhost:11434/api/chat"]
    }
  }
}
```

This is experimental and depends on Claude Code's MCP support for custom endpoints.

## Tips

- **Use Claude Code for the hard stuff:** Multi-file refactoring, understanding complex codebases, generating test suites, architecture decisions.
- **Use local models for the fast stuff:** Autocomplete (Continue.dev), quick single-file edits (aider), boilerplate, and anything where latency matters.
- **Use local models for the sensitive stuff:** If a file contains API keys, credentials, proprietary algorithms, or client data, use Ollama instead of Claude Code for that file.
- **InferHaven as your dev server:** Even if you primarily use Claude Code with Anthropics models, InferHaven gives you a reproducible, always-available dev environment accessible from any device.
