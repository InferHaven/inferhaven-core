# Security Hardening

Production security checklist for InferHaven. Covers access control, network exposure, TLS, and secrets.

---

## Must-do before exposing to the internet

### 1. Change the code-server password

The default `CODE_SERVER_PASSWORD=inferhaven` is public. Set a strong password before starting:

```env
CODE_SERVER_PASSWORD=<strong-random-password>
```

### 2. Add SSH authorized keys

SSH is key-only, password auth is disabled in the workspace container. Set at least one key or you cannot log in:

```env
AUTHORIZED_KEYS=ssh-ed25519 AAAA... you@host
```

Add keys after startup: `docker exec inferhaven-workspace add-ssh-key "ssh-ed25519 ..."`

### 3. Set a domain and enable TLS

Caddy auto-provisions TLS based on `DOMAIN`:

| `DOMAIN` value | TLS behavior |
| --- | --- |
| `localhost` / bare IP | Plain HTTP |
| `*.lan`, `*.local`, `*.home` | Self-signed internal CA |
| Public domain | Let's Encrypt (requires port 80 reachable) |

```env
DOMAIN=dev.example.com   # Let's Encrypt auto-configured
```

Override with `TLS_MODE=internal|acme|off` if auto-detection isn't right.

---

## Network access control

### Restrict by IP (recommended for LAN/VPN setups)

Set `ALLOWED_IPS` to lock all Caddy routes to specific CIDRs. Uses actual TCP source IP, cannot be bypassed by spoofed headers:

```env
# Single subnet
ALLOWED_IPS=192.168.1.0/24

# VPN + LAN
ALLOWED_IPS=10.8.0.0/24 192.168.1.0/24
```

Apply changes with `docker compose up -d caddy` (not `restart`, restart keeps old env vars).

### Ollama API is unauthenticated

The Ollama API (`/api/*`, `/v1/*`) has no built-in authentication. Anyone who can reach Caddy can call it. Mitigations:

- Set `ALLOWED_IPS` (simplest for trusted-network setups)
- Put InferHaven behind a VPN and bind to a VPN interface only
- Set a host firewall rule to restrict ports 80/443 to known IPs

Ollama's own port (11434) is **not** exposed to the host by default, it stays inside the Docker network. Don't uncomment the `ports:` block in `docker-compose.yml` for it.

### Host firewall

Minimal recommended rules for a public server:

| Port | Protocol | Allow from |
| --- | --- | --- |
| 22 | TCP | Your IPs (host SSH, if needed) |
| 2222 | TCP | Your IPs (workspace SSH) |
| 80 | TCP | Anywhere (Let's Encrypt ACME challenge) |
| 443 | TCP | Anywhere (or restrict with ALLOWED_IPS) |
| 60000-60010 | UDP | Your IPs (mosh, optional) |

Everything else should be blocked inbound.

---

## Secrets and .env

The `.env` file contains `CODE_SERVER_PASSWORD`, API keys, and (if using cloud) `HAVEN_AGENT_TOKEN`. Protect it:

```bash
chmod 600 .env
```

Never commit `.env` to version control, `.gitignore` excludes it by default.

API keys (`ANTHROPIC_API_KEY`, etc.) are injected into `~/.inferhaven` (chmod 600) inside the workspace at startup. They are not written elsewhere.

> **Tip:** Never run `docker compose config` and paste the output anywhere, it renders the resolved `environment:` block including every key from `.env`. Use `docker compose config --format json | jq 'del(.services[].environment)'` for safe diagnostics.

---

## Docker socket access

Both the workspace container and the optional cloud agent mount `/var/run/docker.sock`. Any process inside those containers with shell access can control Docker on the host, equivalent to root on the host machine. This is intentional for the `haven service` / `docker compose` workflow but means:

- SSH access to the workspace = effective host root
- Protect SSH keys accordingly; rotate immediately if compromised

---

## Multi-user deployments

When using `HAVEN_EXTRA_USERS`, extra users do **not** get sudo by default. Only grant it explicitly:

```env
HAVEN_EXTRA_USERS=alice,bob
HAVEN_EXTRA_USERS_SUDO=alice   # bob has no sudo
```

Each user needs their own SSH key via `AUTHORIZED_KEYS_<USERNAME_UC>`.

---

## Cloud agent (optional)

The Haven Agent (`--profile cloud`) connects outbound only, no inbound ports. Keep `HAVEN_AGENT_TOKEN` secret; rotate it from the cloud dashboard if compromised. The agent token is the only credential the dashboard uses to authorize commands to your server.
