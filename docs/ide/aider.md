# aider: InferHaven Integration Guide

[aider](https://aider.chat) is a terminal-based AI pair programming tool. It works directly with your git repos to make AI-assisted code changes. It connects perfectly to InferHaven's Ollama instance.

## Installation

### Option A: Pre-configure in .env (recommended)

```bash
# In your inferhaven-core/.env file:
INSTALL_ASSISTANTS=aider

# Optional: set an API key for cloud backends
ANTHROPIC_API_KEY=sk-ant-...   # uses claude-sonnet-4-6 by default
# or
OPENAI_API_KEY=sk-...          # uses gpt-4o by default
```

Then `docker compose up -d`. Aider installs in the background via `uv` and `~/.aider.conf.yml` is created automatically with the right backend.

### Option B: Install manually inside the workspace

```bash
ssh -p 2222 haven@localhost

# Recommended: uv tool install (isolated env, no root, no venv management)
uv tool install aider-chat

# Classic pip --user also works
pip install --user aider-chat
```

Or install on your local machine and connect via SSH tunnel.

## Configuration

### Direct connection (from inside InferHaven workspace)

```bash
# Use the default InferHaven model
aider --model ollama/qwen2.5-coder:7b

# Use a larger model (if GPU is available)
aider --model ollama/qwen2.5-coder:32b

# Specify the Ollama endpoint explicitly
aider --model ollama/qwen2.5-coder:7b --ollama-api-base http://ollama:11434
```

### From your local machine via SSH tunnel

```bash
# Terminal 1: Open SSH tunnel
ssh -L 11434:ollama:11434 -p 2222 haven@your-server-ip

# Terminal 2: Run aider locally, pointed at the tunnel
aider --model ollama/qwen2.5-coder:7b --ollama-api-base http://localhost:11434
```

### Persistent configuration

`~/.aider.conf.yml` is auto-created when `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` is set in `.env`. You can also create or edit it manually:

```yaml
# InferHaven aider config
model: ollama/qwen2.5-coder:7b
ollama-api-base: http://localhost:11434
auto-commits: true
dark-mode: true
```

## Recommended workflows

### Basic usage

```bash
cd ~/projects/my-app
aider --model ollama/qwen2.5-coder:7b

# Inside aider:
# > Add authentication to the login endpoint
# > Fix the bug in the payment handler
# > Write tests for the User model
```

### Using aider with a specific set of files

```bash
aider --model ollama/qwen2.5-coder:7b src/auth.py src/models/user.py tests/
```

## Model recommendations for aider

| Model | Speed | Quality | Best for |
| ------- | ------- | --------- | ---------- |
| `qwen2.5-coder:3b` | Very fast | Good | Quick fixes, simple edits |
| `qwen2.5-coder:7b` | Fast | Great | Daily driver (default) |
| `qwen2.5-coder:14b` | Medium | Excellent | Complex logic, refactoring |
| `qwen2.5-coder:32b` | Slow (CPU) / Fast (GPU) | Outstanding | Architecture, multi-file changes |

## Troubleshooting

**"Could not connect to Ollama":**

- Inside workspace: Check `$OLLAMA_HOST` is set (`echo $OLLAMA_HOST`)
- From local: Verify SSH tunnel is running
- Check Ollama is up: `haven status`

**Slow generation:**

- Switch to a smaller model: `--model ollama/qwen2.5-coder:3b`
- Verify GPU is being used: `nvidia-smi` (if applicable)

**aider not finding files:**

- Make sure you're in a git repository: `git init` if needed
- Specify files explicitly: `aider file1.py file2.py`
