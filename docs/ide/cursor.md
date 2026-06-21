# Cursor: InferHaven Integration Guide

[Cursor](https://cursor.com) is an AI-native code editor built on VS Code. You can configure Cursor to use InferHaven's local Ollama instance for fully private AI completions and chat.

## Configuration

### Step 1: Connect via SSH

Cursor supports VS Code's Remote-SSH extension. Connect to your InferHaven workspace:

1. Open Cursor
2. Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on macOS)
3. Type "Remote-SSH: Connect to Host"
4. Enter: `haven@your-server-ip -p 2222`

You're now editing files directly on your InferHaven server.

### Step 2: Configure local model for completions

Open Cursor Settings (`Ctrl+,`) → search "OpenAI API":

**For local connection (SSH'd into InferHaven):**

```bash
API Base URL: http://ollama:11434/v1
Model: qwen2.5-coder:7b
```

**For remote via SSH tunnel:**

```bash
# Terminal: open tunnel
ssh -L 11434:ollama:11434 -p 2222 haven@your-server-ip
```

```bash
API Base URL: http://localhost:11434/v1
Model: qwen2.5-coder:7b
```

### Step 3: Use Cursor's AI features with local model

- **Tab completion:** Uses your configured local model
- **Cmd+K / Ctrl+K:** Inline code generation with local model
- **Chat sidebar:** Ask questions about your codebase

## Hybrid approach

You can keep Cursor's built-in Claude/GPT-4 for complex tasks while using InferHaven's local models for tab completion:

1. Set "OpenAI API Base" to InferHaven for completions
2. Keep the default Cursor AI for chat and Cmd+K
3. This gives you zero-latency autocomplete (local) with high-quality reasoning (cloud) when needed

## SSH config for convenience

Add to `~/.ssh/config` on your local machine:

```bash
Host inferhaven
  HostName your-server-ip
  Port 2222
  User haven
  IdentityFile ~/.ssh/id_ed25519
  LocalForward 11434 ollama:11434
```

Then in Cursor, just connect to `inferhaven` and the Ollama tunnel is automatically established.

## Troubleshooting

**Can't connect via Remote-SSH:**

- Verify SSH works from terminal: `ssh -p 2222 haven@your-server-ip`
- Check your SSH key is configured in InferHaven's `.env`
- Ensure port 2222 is accessible (firewall/security group)

**Completions not working:**

- Verify Ollama is reachable: `curl http://localhost:11434/v1/models`
- Check the model is downloaded: `haven models`
- Restart Cursor after changing API settings
