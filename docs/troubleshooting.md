# Troubleshooting

Common issues and how to fix them. Run `haven doctor` first, it catches most problems automatically.

## Services won't start

### "port is already in use"

Another service is using a port InferHaven needs.

```bash
# Find what's using the port (e.g., port 80)
sudo lsof -i :80
# or
sudo ss -tlnp | grep :80

# Fix: change the port in .env
HTTP_PORT=8080
HTTPS_PORT=8443
SSH_PORT=2222
```

### "permission denied" on Docker socket

Your user isn't in the Docker group.

```bash
sudo usermod -aG docker $USER
# Log out and back in (or: newgrp docker)
```

### "no space left on device"

Docker images and models consume significant disk space.

```bash
# Check disk usage
df -h

# Clean unused Docker data
docker system prune -a

# Check model sizes
haven models
```

## Can't SSH into workspace

### "Connection refused"

```bash
# Check workspace is running
docker ps | grep inferhaven-workspace

# Check SSH port
docker compose logs workspace | tail -20

# Verify port mapping
docker port inferhaven-workspace
```

### "Permission denied (publickey)"

Your SSH key isn't configured.

```bash
# Add your key (from the host)
./scripts/haven ssh-key "$(cat ~/.ssh/id_ed25519.pub)"

# Or from inside the workspace
haven ssh-key "$(cat ~/.ssh/id_ed25519.pub)"

# Or set it in .env
AUTHORIZED_KEYS=ssh-ed25519 AAAA... user@host

# Then restart
docker compose restart workspace
```

### SSH works but shell is broken or has no colors

The default shell is zsh with Oh My Zsh. If it's not loading correctly:

```bash
# Check which shell is running
echo $SHELL

# Manually launch zsh (or set it as default)
zsh

# Reset zsh config (will be restored from image on next build)
docker exec inferhaven-workspace cp /home/haven/.zshrc /home/haven/.zshrc.bak

# If the terminal tab title is blank — ensure your terminal emulator allows
# title changes via OSC escape sequences (most modern terminals do by default).
```

## Ollama / AI model issues

### "Ollama is not reachable"

```bash
# Check Ollama container
docker compose logs ollama | tail -30

# Restart Ollama
docker compose restart ollama

# Wait for health check
docker compose ps ollama
# Should show "healthy"
```

### Model download stuck or failed

```bash
# Check Ollama logs
docker compose logs ollama | tail -50

# Retry the pull
haven pull qwen2.5-coder:7b

# If still stuck, remove and re-pull
haven remove qwen2.5-coder:7b
haven pull qwen2.5-coder:7b
```

### Very slow AI responses

1. **Check if GPU is being used:** `nvidia-smi`, if no GPU process listed, model is on CPU
2. **Model too large for RAM:** Use a smaller model (`3b` or `7b` for CPU)
3. **First request is slow:** Ollama loads the model into memory on first request. Subsequent requests are faster.
4. **Check available RAM:** `free -h`, Ollama needs 2-4x the model file size in RAM

### "model not found" errors

```bash
# List what's actually installed (run from inside the workspace or host)
haven models

# Pull the model you need
haven pull qwen2.5-coder:7b

# Verify the exact model name (case-sensitive, from inside the workspace)
curl http://ollama:11434/api/tags | jq '.models[].name'

# From the host (uses the mapped port)
curl http://localhost:11434/api/tags | jq '.models[].name'
```

### OpenCode doesn't show Ollama models

OpenCode's Ollama provider config is written to `~/.config/opencode/config.json` when opencode is first installed. If the file is missing or stale:

```bash
# Check the config
cat ~/.config/opencode/config.json

# The list auto-updates after any haven pull/remove.
# To manually refresh after pulling models outside of haven:
haven pull <model>   # triggers a sync as a side effect
# or remove and re-add to force refresh:
rm ~/.config/opencode/config.json
# then pull any model to regenerate it:
haven pull qwen2.5-coder:7b
```

If you pulled Ollama models before `INSTALL_ASSISTANTS=opencode` ran (e.g., they were already on disk from a previous install), the config may have been seeded with only `DEFAULT_MODEL`. Run the above to regenerate it with the full list.

## Web IDE (code-server) issues

### Can't access web IDE

```bash
# Check code-server is running
docker compose logs code-server | tail -20

# Verify port
curl -I http://localhost:80

# Check Caddy proxy
docker compose logs caddy | tail -20
```

### Wrong password

The password is set in `.env` as `CODE_SERVER_PASSWORD`. After changing it:

```bash
docker compose restart code-server
```

### Extensions not loading

```bash
# Install extensions from the terminal inside code-server
docker exec inferhaven-code-server code-server --install-extension continue.continue
```

## Network / Caddy issues

### HTTPS not working

```bash
# Check domain is set in .env
grep DOMAIN .env

# Check Caddy logs
docker compose logs caddy | tail -30

# Verify DNS points to your server
dig your-domain.com
```

For HTTPS to work:

1. `DOMAIN` must be set to a real domain (not `localhost`)
2. Ports 80 and 443 must be open to the internet
3. DNS must point to your server's public IP

### Can't reach Ollama API from outside

By default, the Ollama API is only accessible from within the Docker network. To access it externally, use an SSH tunnel (zero configuration required):

```bash
ssh -L 11434:ollama:11434 -p 2222 haven@your-server-ip
```

If you prefer to use the HTTPS Caddy proxy (`https://your-domain/v1/`) instead, see **[HTTPS with a private hostname](#https-with-a-private-hostname-self-signed-certificate)** below, you'll need to trust the Caddy root CA first.

### HTTPS with a private hostname (self-signed certificate)

When `DOMAIN` is set to a private hostname like `proxnas.lan`, `server.local`, or any name ending in `.lan`, `.local`, `.home`, etc., Caddy automatically issues a self-signed certificate using its own internal CA. This CA is not trusted by browsers, operating systems, or tools like VS Code extensions (Cline, Continue) out of the box.

**Symptoms:**

- `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` from Node.js tools (Cline, Continue, etc.)
- "Connection error" from VS Code extensions hitting `/v1/` or `/api/`
- Browser certificate warning when opening the web IDE or status page
- `curl: (60) SSL certificate problem: unable to get local issuer certificate`

Everything works over plain HTTP (bare IP or `localhost`) because no TLS is involved, the Caddy routing itself is correct. The issue is client-side trust only.

**Quick fix, export and trust the Caddy root CA:**

```bash
# From the host
./scripts/haven caddy cert

# Or from inside the workspace (SSH session)
haven caddy cert
```

This exports `caddy-root.crt` and prints per-platform install instructions. The cert only changes if you recreate the `caddy_data` volume, once trusted it stays valid indefinitely.

**Per-platform trust instructions:**

macOS:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./caddy-root.crt
```

Linux, Debian / Ubuntu:

```bash
sudo cp ./caddy-root.crt /usr/local/share/ca-certificates/inferhaven-caddy.crt
sudo update-ca-certificates
```

Linux, RHEL / Fedora / Arch:

```bash
sudo trust anchor --store ./caddy-root.crt
```

Windows (cmd as Administrator):

```bash
certutil -addstore Root caddy-root.crt
```

**Node.js tools, VS Code extensions (Cline, Continue, RooCode, etc.):**

VS Code extensions run in VS Code's own Node.js runtime, which does not inherit the OS trust store. You must point Node.js at the cert explicitly via `NODE_EXTRA_CA_CERTS`.

In VS Code **settings.json** (File → Preferences → Settings → Open Settings JSON):

```json
{
  "terminal.integrated.env.linux": {
    "NODE_EXTRA_CA_CERTS": "/absolute/path/to/caddy-root.crt"
  }
}
```

Use `terminal.integrated.env.mac` on macOS or `terminal.integrated.env.windows` on Windows. Restart VS Code after saving.

**Verify the cert is trusted before pointing a tool at it:**

```bash
curl --cacert ./caddy-root.crt https://your-domain.lan/api/tags
# Should return JSON — if it does, the cert path and trust are correct
```

**Zero-config alternative:**

If you don't want to manage cert trust, use an SSH tunnel, no cert changes needed on the client:

```bash
ssh -L 11434:ollama:11434 -p 2222 haven@your-server-ip
# Then point your tool at http://localhost:11434
```

## Mosh / connection-resilient SSH

### Mosh client says "Connection timed out"

Mosh uses UDP `60000-60010` by default. Check the host firewall lets the range through:

```bash
sudo ufw allow 60000:60010/udp                 # Ubuntu UFW
sudo firewall-cmd --add-port=60000-60010/udp   # firewalld
```

Override the range in `.env` (e.g. behind another service): `MOSH_PORTS=60100-60110` then `docker compose up -d workspace`.

To disable host port mapping entirely (mosh still works inside the container, just not from outside): `MOSH_PORTS=` (empty).

### `mosh-server` not found

Mosh ships with the workspace image. If `mosh haven@<host>` reports "missing mosh-server", confirm the image is current: `docker compose pull workspace && docker compose up -d --build workspace`.

---

## Build / image issues

### Build fails with `invalid user index: -1`

BuildKit `COPY --link` cannot resolve named users at link-time. The Dockerfile uses numeric `--chown=1000:1000` (haven UID), if you forked the image and added `--chown=haven:haven` to a `COPY --link`, change it back to numeric.

### "supercronic not found" / scheduled tasks not running

Check the supercronic process and its cron file:

```bash
pgrep -af supercronic
cat /etc/inferhaven/crontab
tail -n 50 ~/.haven/install.log | grep -i cron
```

`haven doctor` flags this automatically.

### Pinned tool version is wrong / missing feature

The workspace pins `Go`, `fzf`, `neovim`, `uv`, `lazygit` via `ARG ..._VERSION` (see [docs/development/tool-sourcing.md](development/tool-sourcing.md#bumping-pinned-tool-versions)). One-off override:

```bash
docker compose build --build-arg LAZYGIT_VERSION=0.55.2 workspace
docker compose up -d workspace
```

For a permanent bump, edit the ARG default and open a PR.

---

## Multi-user (`HAVEN_EXTRA_USERS`) issues

### Extra user can't SSH in

```bash
docker compose exec workspace getent passwd | grep -E "(alice|bob)"
docker compose exec workspace cat ~alice/.ssh/authorized_keys.auto
```

The per-user env var is uppercase: `AUTHORIZED_KEYS_ALICE` (not `_alice`). Restart workspace after changing `.env`: `docker compose restart workspace`.

### Extra user has no `~/.inferhaven`

Extra users get a minimal `~/.inferhaven` with `OLLAMA_HOST` only, no API keys (those live in the primary `haven` user's `~/.inferhaven`). Each extra user can `cp ~haven/.inferhaven ~/` if they want shared keys, or set their own.

### Provisioning skipped: "/home is not a volume mount"

`HAVEN_EXTRA_USERS` requires the workspace volume to be mounted at `/home` (so each user gets a persistent home). Older deployments mount it at `/home/haven`. Migration is one-time:

```bash
docker compose down workspace
# In docker-compose.yml workspace.volumes, ensure:
#   - workspace_home:/home
docker compose up -d workspace                     # auto-runs haven-migrate-home
docker compose logs workspace | grep migrate-home  # confirm migration completed
```

The migration script (`/usr/local/bin/haven-migrate-home`) re-nests existing files into a `/home/haven/` subdir on the volume. It is idempotent, safe to re-run. A sentinel `~/.haven/.layout-migrated` prevents repeat work.

---

## Tooling notes

### `mise`: `unknown field in /tmp/.mise.toml: node`

`.mise.toml` requires a `[tools]` table; bare entries at the file root are ignored. Copy the shipped example:

```bash
cp /etc/inferhaven/mise.toml.example /your/project/.mise.toml
cd /your/project && mise install
```

The example shows the correct `[tools]` syntax for node, python, and go.

### `atuin status`: "You are not logged in to a sync server"

This is by design, `atuin` ships in local-only mode (no cloud history sync). Local history capture works without login. To enable cross-device sync:

```bash
atuin register -u <user> -e <email>   # or: atuin login
```

See [atuin.sh](https://atuin.sh) for self-hosting the sync server.

### `haven tmate`: web URL returns 503

The 503 originates upstream at `tmate.io` and is intermittent. SSH still works. To check session state:

```bash
haven tmate status     # current SSH/web URLs + uptime
haven tmate fg         # attach in this terminal
haven tmate kill       # tear down
```

State lives in `~/.haven/tmate.state`; the Sessions tab in the right-click tmux popup also lists active tmate sessions (keys: `t` start, `T` kill).

---

## Reset everything

If nothing else works, a full reset:

```bash
# Stop and remove all containers and data
haven reset
# Type 'yes' to confirm

# Start fresh
cp .env.example .env
# Edit .env with your settings
docker compose up -d
```

This deletes all models, projects, and settings. Back up `~/projects` first if needed.

## Still stuck?

1. Run `haven doctor` for automated diagnostics
2. Check the [GitHub Issues](https://github.com/InferHaven/inferhaven-core/issues)
3. Join the [Discord](https://discord.gg/X5htGNnEh5) community
4. Open a new issue with `haven doctor` output and relevant logs
