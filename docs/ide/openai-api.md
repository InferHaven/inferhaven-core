# Generic OpenAI API — InferHaven Integration Guide

InferHaven's Ollama instance exposes an **OpenAI-compatible API**. This means any tool, library, or IDE extension that can talk to the OpenAI API can be pointed at InferHaven instead — with zero code changes.

## API Endpoints

| Endpoint | Description |
| ---------- | ------------- |
| `http://localhost:11434/v1/chat/completions` | Chat completions (GPT-compatible) |
| `http://localhost:11434/v1/completions` | Text completions |
| `http://localhost:11434/v1/models` | List available models |
| `http://localhost:11434/v1/embeddings` | Text embeddings |
| `http://localhost:11434/api/tags` | List models (Ollama native) |
| `http://localhost:11434/api/generate` | Generate (Ollama native) |
| `http://localhost:11434/api/chat` | Chat (Ollama native) |

Replace `localhost:11434` with your server's address if remote.

## Examples

### curl

```bash
# Chat completion
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder:7b",
    "messages": [
      {"role": "system", "content": "You are a helpful coding assistant."},
      {"role": "user", "content": "Write a Python function to merge two sorted lists."}
    ]
  }'

# List models
curl http://localhost:11434/v1/models
```

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11434/v1",
    api_key="not-needed"  # Ollama doesn't require an API key
)

response = client.chat.completions.create(
    model="qwen2.5-coder:7b",
    messages=[
        {"role": "system", "content": "You are a helpful coding assistant."},
        {"role": "user", "content": "Explain Python decorators with an example."}
    ]
)

print(response.choices[0].message.content)
```

### Node.js (OpenAI SDK)

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'http://localhost:11434/v1',
  apiKey: 'not-needed',
});

const response = await client.chat.completions.create({
  model: 'qwen2.5-coder:7b',
  messages: [
    { role: 'system', content: 'You are a helpful coding assistant.' },
    { role: 'user', content: 'Write a React hook for debouncing.' },
  ],
});

console.log(response.choices[0].message.content);
```

### Go

```go
package main

import (
    "context"
    "fmt"
    openai "github.com/sashabaranov/go-openai"
)

func main() {
    config := openai.DefaultConfig("not-needed")
    config.BaseURL = "http://localhost:11434/v1"
    client := openai.NewClientWithConfig(config)

    resp, _ := client.CreateChatCompletion(
        context.Background(),
        openai.ChatCompletionRequest{
            Model: "qwen2.5-coder:7b",
            Messages: []openai.ChatCompletionMessage{
                {Role: "user", Content: "Write a Go HTTP server with graceful shutdown."},
            },
        },
    )
    fmt.Println(resp.Choices[0].Message.Content)
}
```

## Framework Integration

### LangChain (Python)

```python
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(
    base_url="http://localhost:11434/v1",
    api_key="not-needed",
    model="qwen2.5-coder:7b",
)

response = llm.invoke("Explain the observer pattern.")
print(response.content)
```

### LlamaIndex

```python
from llama_index.llms.openai_like import OpenAILike

llm = OpenAILike(
    api_base="http://localhost:11434/v1",
    api_key="not-needed",
    model="qwen2.5-coder:7b",
)
```

## Remote Access

### SSH tunnel (recommended for security)

```bash
ssh -L 11434:ollama:11434 -p 2222 haven@your-server-ip
# Now use http://localhost:11434 in any config
```

### Via HTTPS (if domain configured)

If you set `DOMAIN=dev.example.com` in `.env`, Caddy auto-provisions HTTPS:

```html
https://dev.example.com/v1/chat/completions
https://dev.example.com/api/tags
```

## Key notes

- **No API key required.** Ollama doesn't authenticate by default. For production, use SSH tunnels or restrict network access.
- **Streaming works.** Add `"stream": true` to requests for streaming responses.
- **Model names use Ollama format.** Use `qwen2.5-coder:7b` not `gpt-4` — the model name must match what's pulled in Ollama.
- **Context window varies by model.** Most coding models support 4K-32K tokens. Check model card for specifics.
