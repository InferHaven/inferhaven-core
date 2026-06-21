# Cline: InferHaven Integration Guide

[Cline](https://github.com/cline/cline) is an autonomous AI coding agent for VS Code that can read/write files, run terminal commands, and browse the web. You can configure it to use InferHaven's local Ollama instance for fully private, offline-capable AI assistance.

## Installation

1. Open VS Code (or code-server)
2. Install the [Cline extension](https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev) from the Marketplace
3. Click the Cline icon in the Activity Bar to open the sidebar

## Configuration

Open Cline settings (gear icon in the Cline panel) → **API Configuration**:

| Field | Value |
| ------- | ------- |
| **API Provider** | `Ollama` |
| **Base URL** | See options below |
| **Model** | Your chosen model (see Recommended Models) |

### Local connection (running inside code-server or SSH session)

When you are connected to InferHaven via Remote SSH VSCode session or using the built-in code-server, Ollama is reachable on the Docker network:

```html
http://ollama:11434
```

### Remote connection (Cline in a local VS Code, InferHaven on a different machine)

Open an SSH tunnel before starting Cline:

```bash
ssh -L 11434:ollama:11434 -p 2222 haven@your-server-ip
```

Then set Base URL to:

```html
http://localhost:11434
```

Add to `~/.ssh/config` to tunnel automatically on every connect:

```bash
Host inferhaven
  HostName your-server-ip
  Port 2222
  User haven
  IdentityFile ~/.ssh/id_ed25519
  LocalForward 11434 ollama:11434
```

### Remote connection via domain

If InferHaven is deployed with a public domain and HTTPS, Caddy proxies `/api/*` to Ollama. You must have a proper DNS setup for a valid cert or node will complain:

```html
https://your-domain.com
```

## Recommended models

Cline drives agentic loops, it needs reliable tool use and a context window large enough to hold file contents plus conversation history. Set the context window to at least **32 768 tokens** in Cline's model settings.

| Model | Size | Note |
| ------- | ------------- | ---------- |
| `qwen2.5-coder:7b` | 4.4 GB | Fast; good for CPU or low-VRAM GPUs |
| `qwen3.5:9b` | 6.6GB | Open-source multimodal model, runs on modest hardware |
| `qwen2.5-coder:14b` | 8.4 GB | Balanced quality and speed |
| `gemma4:e4b-it-q4_K_M` | 9.6GB | Designed to deliver frontier-level performance. Well-suited for reasoning, agentic workflows, coding, and multimodal understanding. |
| `qwen3-coder:30b` | 19 GB | Very well performing coding model. |

Pull a model before connecting:

```bash
# Within inferhaven-core/
haven pull qwen2.5-coder:14b
```

## Performance tip

For local models, enable **Compact Prompts** in Cline Settings → Features → "Use Compact Prompt". This reduces prompt size by ~90% while preserving the information Cline needs, improving both speed and context headroom.

> [!NOTE]
> *Qwen2.5 Coder models:*
>
> - may have issues tool calling using the compact system prompt. [github](https://github.com/QwenLM/Qwen3-Coder/issues/180)
>
> - may work better using the OpenAI compatible endpoint instead of Ollama: [`http://localhost:11434/v1`](http://localhost:11434/v1)

## Troubleshooting

**"Connection refused" / model list empty:**

- Confirm InferHaven is running: `make status`
- Verify Ollama responds: `curl http://localhost:11434/api/tags`
- If remote, check that your SSH tunnel is active

**Slow or stalled responses:**

- Large models on CPU are slow, prefer 7B on CPU-only setups
- Check available VRAM: `docker exec inferhaven-ollama nvidia-smi` (GPU setups)
- Monitor Ollama logs: `make logs s=ollama`

**Model not found:**

- Pull it first: `make pull m=<model-name>`
- List downloaded models: `make chat m=list` or `curl http://localhost:11434/api/tags`

**Cline hits context limit mid-task:**

- Enable compact prompts (see above)
- Switch to a model with a larger context window, or reduce the number of open files in the task
