#!/bin/sh
# Caddy entrypoint — auto-selects TLS mode based on DOMAIN, then starts Caddy.
#
# TLS_MODE values (set in .env to override auto-detection):
#   auto     — detect from DOMAIN (default)
#   acme     — force Let's Encrypt (public domain required)
#   internal — Caddy self-signed CA (trust root.crt in your browser/OS)
#   off      — plain HTTP (no TLS)
set -ex

# Merge stderr into stdout so `docker logs` captures every line. Without this,
# clean exits in stripped-tty environments (nested compose, some CI runners)
# can drop the failure reason on the floor.
exec 2>&1

# Pre-flight: every runtime file must exist and be non-empty. Round 5 bakes
# these into the image (docker/caddy/Dockerfile), so a missing file here means
# someone re-added a bind-mount override that failed silently — fail loud.
for _f in /entrypoint.sh /etc/caddy/ide.html.template /srv/status.html /srv/denied.html; do
    if [ ! -s "$_f" ]; then
        echo "InferHaven: FATAL — $_f is missing or empty." >&2
        echo "InferHaven:   In nested compose this usually means a relative-path bind" >&2
        echo "InferHaven:   resolved to an inner path the host daemon can't see." >&2
        echo "InferHaven:   Round 5 ships caddy as inferhaven/caddy:local with these" >&2
        echo "InferHaven:   files baked in — make sure your compose isn't binding them" >&2
        echo "InferHaven:   from ./docker/caddy/*. Rebuild with 'docker compose build caddy'." >&2
        exit 1
    fi
done

DOMAIN="${DOMAIN:-localhost}"
TLS_MODE="${TLS_MODE:-auto}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8443}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
ALLOWED_IPS="${ALLOWED_IPS:-}"

# Normalize bare IPv6 addresses (e.g. ::1, fe80::1) to Caddy's bracketed form [::1].
# Already-bracketed values like [::1] pass through unchanged.
if echo "$DOMAIN" | grep -qE '^[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{0,4}){2,7}$'; then
    DOMAIN="[${DOMAIN}]"
fi

if [ "$TLS_MODE" = "auto" ]; then
    # localhost, bare IPv4, or IPv6 (bracketed after normalization above) → plain HTTP
    if [ "$DOMAIN" = "localhost" ] || \
       echo "$DOMAIN" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || \
       echo "$DOMAIN" | grep -qE '^\[.*\]$'; then
        TLS_MODE="off"
    # Private/reserved TLDs or single-label hostnames → Caddy internal CA
    elif ! echo "$DOMAIN" | grep -q '\.' || \
         echo "$DOMAIN" | grep -qiE '\.(lan|local|home|internal|test|example|invalid|corp|private|arpa)$'; then
        TLS_MODE="internal"
    else
        # Multi-label public domain → Let's Encrypt
        TLS_MODE="acme"
    fi
fi

case "$TLS_MODE" in
    off)
        # Bind all interfaces — any hostname or IP reaches this server.
        # Access control is handled entirely by ALLOWED_IPS.
        # TLS modes keep domain-specific binding for cert provisioning/SNI.
        SITE_ADDR=":80"
        TLS_LINE=""
        ;;
    internal)
        SITE_ADDR="${DOMAIN}"
        TLS_LINE="	tls internal"
        ;;
    acme|*)
        SITE_ADDR="${DOMAIN}"
        TLS_LINE=""
        ;;
esac

# IP allowlist: when ALLOWED_IPS is set, build a Caddy matcher that blocks all
# other IPs. Default fallback 0.0.0.0/0 ::/0 matches every address, so the
# "not remote_ip" block never fires when ALLOWED_IPS is empty.
#
# Localhost access from the host machine arrives at Caddy with the Docker bridge
# gateway as the source IP (Docker's NAT rewrites it). Auto-detect and append the
# gateway so host→localhost connections are never blocked by the allowlist.
# This is safe: Docker bridge IPs are private/non-routable; external TCP connections
# keep their real source IP and cannot spoof the gateway address.
if [ -n "$ALLOWED_IPS" ]; then
    DOCKER_GW=$(ip route show 2>/dev/null | awk '/^default/ {print $3; exit}')
    if [ -n "$DOCKER_GW" ]; then
        ALLOWED_IPS="${ALLOWED_IPS} ${DOCKER_GW}/32"
        echo "InferHaven: Docker gateway ${DOCKER_GW} auto-added to allowlist for localhost access"
    fi
fi
ALLOWED_CIDRS="${ALLOWED_IPS:-0.0.0.0/0 ::/0}"

echo "InferHaven: Caddy starting — domain=${DOMAIN} tls=${TLS_MODE} allowed_ips=${ALLOWED_IPS:-all}"

if [ "$TLS_MODE" = "internal" ]; then
    echo "InferHaven: Using self-signed TLS. To trust the cert, import the Caddy root CA:"
    echo "InferHaven:   docker cp inferhaven-caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt"
    echo "InferHaven:   Then add caddy-root.crt to your browser or OS trust store."
fi

# Write startup timestamp so the status page can calculate true stack uptime.
echo "{\"startedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > /srv/startup.json

# Render ide.html from its template, substituting __WORKSPACE__ with the
# configured DEFAULT_WORKSPACE. Without this, the redirect lands on /ide/?folder=/
# which makes code-server open / as the workspace; Continue's @file walker then
# recurses the entire filesystem and crashes on EACCES /root.
DEFAULT_WORKSPACE="${DEFAULT_WORKSPACE:-/config/workspace/projects}"
if [ -f /etc/caddy/ide.html.template ]; then
    # Use a sed delimiter that cannot appear in a unix path (|) and escape | in the value.
    _ws_escaped=$(printf '%s' "$DEFAULT_WORKSPACE" | sed 's/|/\\|/g')
    sed "s|__WORKSPACE__|${_ws_escaped}|g" /etc/caddy/ide.html.template > /srv/ide.html
    echo "InferHaven: ide.html rendered with workspace=${DEFAULT_WORKSPACE}"
else
    echo "InferHaven: WARNING — /etc/caddy/ide.html.template not mounted; /ide redirect will not work"
fi

cat > /etc/caddy/Caddyfile <<CADDYEOF
${SITE_ADDR} {
${TLS_LINE}
	# IP allowlist — handle evaluates before other handlers (mutual exclusion).
	# error 403 triggers handle_errors below, which serves the styled denied page.
	@blocked {
		not remote_ip ${ALLOWED_CIDRS}
	}
	handle @blocked {
		error 403
	}

	handle_errors 403 {
		root * /srv
		rewrite * /denied.html
		file_server
	}

	# Startup timestamp (used by status page for true uptime display)
	handle /startup.json {
		root * /srv
		file_server
	}

	# Health check / status dashboard
	handle /status {
		root * /srv
		rewrite * /status.html
		file_server
	}

	# VS Code in browser.
	#
	# Pre-redirect /ide and /ide/ (no folder param) to /ide/?folder=<DEFAULT_WORKSPACE>
	# via the rendered ide.html. Without this, code-server responds 302 → /?folder=/ on
	# the bare domain, the VS Code service worker (scope "/") serves that from cache as
	# a blank page, AND Continue's @file walker recurses / and crashes on EACCES /root.
	@ideNoFolder {
		path /ide /ide/
		not query folder=*
	}
	handle @ideNoFolder {
		root * /srv
		rewrite * /ide.html
		file_server
	}

	# handle_path strips /ide before proxying so code-server sees its own root.
	# X-Forwarded-Prefix tells VS Code to prefix all generated asset URLs with
	# /ide, so browser requests for /ide/static/... route back here correctly.
	# Service-Worker-Allowed restricts the VS Code SW scope to /ide/ so it
	# cannot intercept bare-domain requests (/?folder=/, /status, etc.).
	handle_path /ide* {
		reverse_proxy code-server:${CODE_SERVER_PORT} {
			header_up X-Forwarded-Prefix /ide
			header_down Service-Worker-Allowed /ide/
		}
	}

	# Ollama API (for IDE extensions, CLI tools, coding assistants)
	# Bare /api with no sub-path: rewrite to / so clients get "Ollama is running".
	@apiRoot {
		path_regexp ^/api/?$
	}
	handle @apiRoot {
		rewrite * /
		reverse_proxy ollama:${OLLAMA_PORT}
	}

	# /api* matches /api/tags, /api/generate, /api/chat, etc.
	handle /api* {
		reverse_proxy ollama:${OLLAMA_PORT}
	}

	# OpenAI-compatible endpoint (many tools expect /v1/...)
	handle /v1* {
		reverse_proxy ollama:${OLLAMA_PORT}
	}

	# System metrics for the status page resources section
	handle /metrics.json {
		reverse_proxy workspace:9091
	}

	# code-server on older setups responds to the initial /ide request with a
	# bare-domain redirect: 302 Location: https://<domain>/?folder=<workspace>
	# This matcher catches that and serves ide.html, which JS-redirects to
	# /ide?folder=<workspace> so handle_path /ide* proxies it correctly.
	@codeServerFolderRedir {
		path /
		query folder=*
	}
	handle @codeServerFolderRedir {
		root * /srv
		rewrite * /ide.html
		file_server
	}

	# Bare / serves the status dashboard directly (no redirect round trip).
	handle / {
		root * /srv
		rewrite * /status.html
		file_server
	}

	# Default: status dashboard for any other unmatched path
	handle {
		root * /srv
		rewrite * /status.html
		file_server
	}
}
CADDYEOF

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
