#!/usr/bin/env node
// InferHaven metrics server — listens on :9091, returns system stats as JSON.
// Internal only (not exposed to host). Caddy proxies /metrics.json here.
// Reads /proc for CPU/RAM, df for disk, Docker socket for container uptimes.
'use strict';

const http = require('http');
const fs = require('fs');
const { execSync } = require('child_process');
const net = require('net');

const PORT = 9091;
const DOCKER_SOCKET = '/var/run/docker.sock';
const GPU_CACHE_TTL_MS = 2000;          // 2s — covers tmux 5s status refresh
const REQ_TIMEOUT_MS = 5000;
const PRECOMPUTE_INTERVAL_MS = 1000;    // refresh full payload in background

// ── Compose-label-based container resolution ────────────────────────────────
// Identify our own container via /proc/self/mountinfo (the same trick the
// haven CLI uses), read its com.docker.compose.project label, then resolve
// sibling containers by (project, service) label rather than literal name.
// Falls back to historical literal names when no compose labels exist.
function readSelfContainerId() {
  try {
    const mi = fs.readFileSync('/proc/self/mountinfo', 'utf8');
    const m = mi.match(/\/containers\/([0-9a-f]{64})/);
    return m ? m[1] : null;
  } catch { return null; }
}

function dockerInspectLabel(id, label) {
  try {
    const out = execSync(
      `docker inspect --format '{{index .Config.Labels "${label}"}}' ${id} 2>/dev/null`,
      { encoding: 'utf8', timeout: 1500 }
    ).trim();
    return out || null;
  } catch { return null; }
}

function dockerPsByServiceLabel(project, service) {
  try {
    const projFilter = project
      ? `--filter "label=com.docker.compose.project=${project}"` : '';
    const out = execSync(
      `docker ps ${projFilter} --filter "label=com.docker.compose.service=${service}" --format '{{.Names}}' 2>/dev/null | head -1`,
      { encoding: 'utf8', timeout: 1500, shell: '/bin/bash' }
    ).trim();
    return out || null;
  } catch { return null; }
}

const SELF_ID = readSelfContainerId();
const COMPOSE_PROJECT = SELF_ID ? dockerInspectLabel(SELF_ID, 'com.docker.compose.project') : null;
const OLLAMA_CONTAINER = dockerPsByServiceLabel(COMPOSE_PROJECT, 'ollama') || 'inferhaven-ollama';

// ── CPU: persistent prev-snapshot, no per-request 200ms sleep ───────────────
let _prevStat = null;

function readProcStat() {
  const line = fs.readFileSync('/proc/stat', 'utf8').split('\n')[0];
  const parts = line.trim().split(/\s+/).slice(1).map(Number);
  const idle = parts[3] + (parts[4] || 0);
  const total = parts.reduce((a, b) => a + b, 0);
  return { idle, total, ts: Date.now() };
}

function cpuPercent() {
  const cur = readProcStat();
  if (!_prevStat || cur.ts - _prevStat.ts < 100) {
    // Can't compute reliable delta; return last cached value (or 0 on first call).
    return _prevStat ? (_prevStat.lastPct || 0) : 0;
  }
  const idleDelta = cur.idle - _prevStat.idle;
  const totalDelta = cur.total - _prevStat.total;
  const pct = totalDelta === 0 ? 0 : (1 - idleDelta / totalDelta) * 100;
  const rounded = Math.round(pct * 10) / 10;
  cur.lastPct = rounded;
  _prevStat = cur;
  return rounded;
}

// Background ticker: refresh prev snapshot every 1s independent of HTTP traffic.
setInterval(() => {
  const cur = readProcStat();
  if (_prevStat) {
    const idleDelta = cur.idle - _prevStat.idle;
    const totalDelta = cur.total - _prevStat.total;
    const pct = totalDelta === 0 ? 0 : (1 - idleDelta / totalDelta) * 100;
    cur.lastPct = Math.round(pct * 10) / 10;
  } else {
    cur.lastPct = 0;
  }
  _prevStat = cur;
}, 1000).unref();

function memInfo() {
  const raw = fs.readFileSync('/proc/meminfo', 'utf8');
  const get = (key) => {
    const m = raw.match(new RegExp(`^${key}:\\s+(\\d+)`, 'm'));
    return m ? parseInt(m[1], 10) : 0;
  };
  const totalKb = get('MemTotal');
  const availKb = get('MemAvailable');
  return {
    mem_total_mb: Math.round(totalKb / 1024),
    mem_avail_mb: Math.round(availKb / 1024),
    mem_used_mb:  Math.round((totalKb - availKb) / 1024),
  };
}

function diskInfo() {
  try {
    const out = execSync('df -BM / 2>/dev/null | tail -1', { encoding: 'utf8', timeout: 1000 });
    const parts = out.trim().split(/\s+/);
    const total = parseInt(parts[1], 10) || 0;
    const used  = parseInt(parts[2], 10) || 0;
    return { disk_total_mb: total, disk_used_mb: used };
  } catch {
    return { disk_total_mb: 0, disk_used_mb: 0 };
  }
}

function parseNvidiaSmi(line) {
  if (!line) return null;
  const parts = line.split(', ').map(s => s.trim());
  const name    = parts[0] || '';
  const totalMb = parseInt(parts[1], 10) || 0;
  const utilPct = parseFloat(parts[2]) || 0;
  const usedMb  = parseInt(parts[3], 10) || 0;
  if (!name) return null;
  return {
    gpu_name:          name,
    gpu_vram_total_mb: totalMb || undefined,
    gpu_util_pct:      utilPct,
    gpu_vram_used_mb:  usedMb || undefined,
  };
}

// ── GPU: cache for GPU_CACHE_TTL_MS, read once per cache window ─────────────
let _gpuCache = { ts: 0, data: null };

function gpuInfoUncached() {
  const nvCmd = 'nvidia-smi --query-gpu=name,memory.total,utilization.gpu,memory.used --format=csv,noheader 2>/dev/null | head -1';

  try {
    const out = execSync(nvCmd, { encoding: 'utf8', timeout: 1500 }).trim();
    const parsed = parseNvidiaSmi(out);
    if (parsed) return parsed;
  } catch { /* not available directly */ }

  try {
    const out = execSync(
      `docker exec ${OLLAMA_CONTAINER} sh -c '${nvCmd}' 2>/dev/null`,
      { encoding: 'utf8', timeout: 2500 }
    ).trim();
    const parsed = parseNvidiaSmi(out);
    if (parsed) return parsed;
  } catch { /* no NVIDIA GPU or docker exec failed */ }

  try {
    const rocmOut = execSync(
      `docker exec ${OLLAMA_CONTAINER} sh -c 'rocm-smi --showuse --showmeminfo vram 2>/dev/null'`,
      { encoding: 'utf8', timeout: 2500 }
    ).trim();
    if (rocmOut) {
      const utilM  = rocmOut.match(/GPU use[^:]*:\s*(\d+)/);
      const usedM  = rocmOut.match(/VRAM Total Used Memory[^:]*:\s*(\d+)/);
      const totalM = rocmOut.match(/VRAM Total Memory[^:]*:\s*(\d+)/);
      if (utilM) {
        let gpuName = 'AMD GPU';
        try {
          const nameOut = execSync(
            `docker exec ${OLLAMA_CONTAINER} sh -c 'rocm-smi --showproductname 2>/dev/null'`,
            { encoding: 'utf8', timeout: 1500 }
          );
          const nm = nameOut.match(/Card series[^:]*:\s*(.+)/);
          if (nm) gpuName = nm[1].trim();
        } catch { /* ignore */ }
        return {
          gpu_name:          gpuName,
          gpu_vram_total_mb: totalM ? Math.round(parseInt(totalM[1]) / 1048576) : undefined,
          gpu_util_pct:      parseInt(utilM[1]),
          gpu_vram_used_mb:  usedM  ? Math.round(parseInt(usedM[1])  / 1048576) : undefined,
        };
      }
    }
  } catch { /* no rocm-smi or docker exec failed */ }

  // AMD sysfs fallback (read from container — /sys is bind-mounted)
  try {
    const drmBase = '/sys/class/drm';
    const cards = fs.readdirSync(drmBase).filter(d => /^card\d+$/.test(d)).sort();
    for (const card of cards) {
      const dev = `${drmBase}/${card}/device`;
      if (!fs.existsSync(`${dev}/gpu_busy_percent`)) continue;
      const utilPct  = parseInt(fs.readFileSync(`${dev}/gpu_busy_percent`, 'utf8').trim(), 10);
      let gpuName = 'AMD GPU', totalMb, usedMb;
      try { gpuName = fs.readFileSync(`${dev}/product_name`, 'utf8').trim(); } catch { /* optional */ }
      if (gpuName === 'AMD GPU') {
        try {
          const logsOut = execSync(
            `docker logs ${OLLAMA_CONTAINER} 2>&1 | grep 'ggml_vulkan:.*=' | head -1`,
            { encoding: 'utf8', timeout: 1500, shell: '/bin/bash' }
          ).trim();
          const m = logsOut.match(/ggml_vulkan:\s*\d+\s*=\s*([^(|]+)/);
          if (m) gpuName = m[1].trim();
        } catch { /* no docker logs or no Vulkan device */ }
      }
      try { totalMb = Math.round(parseInt(fs.readFileSync(`${dev}/mem_info_vram_total`, 'utf8').trim()) / 1048576); } catch { /* optional */ }
      try { usedMb  = Math.round(parseInt(fs.readFileSync(`${dev}/mem_info_vram_used`,  'utf8').trim()) / 1048576); } catch { /* optional */ }
      return {
        gpu_name:          gpuName,
        gpu_vram_total_mb: totalMb,
        gpu_util_pct:      utilPct,
        gpu_vram_used_mb:  usedMb,
      };
    }
  } catch { /* sysfs not available */ }

  return {};
}

function gpuInfo() {
  const now = Date.now();
  if (_gpuCache.data && now - _gpuCache.ts < GPU_CACHE_TTL_MS) {
    return _gpuCache.data;
  }
  const data = gpuInfoUncached();
  _gpuCache = { ts: now, data };
  return data;
}

function dockerContainersDetailed() {
  return new Promise((resolve) => {
    if (!fs.existsSync(DOCKER_SOCKET)) {
      resolve([]);
      return;
    }
    const sock = net.createConnection(DOCKER_SOCKET);
    // Filter by compose project label so we see siblings regardless of project
    // name. Fall back to a name-prefix filter when our self container has no
    // project label (running outside compose, very rare).
    const filtersObj = COMPOSE_PROJECT
      ? { label: [`com.docker.compose.project=${COMPOSE_PROJECT}`] }
      : { name: ['inferhaven'] };
    const filtersEnc = encodeURIComponent(JSON.stringify(filtersObj));
    const req = `GET /containers/json?all=0&filters=${filtersEnc} HTTP/1.0\r\nHost: localhost\r\n\r\n`;
    let buf = '';
    sock.on('data', (d) => { buf += d.toString(); });
    sock.on('end', () => {
      try {
        const body = buf.slice(buf.indexOf('\r\n\r\n') + 4);
        const list = JSON.parse(body);
        const containers = list.map(c => ({
          name: (c.Names[0] || '').replace(/^\//, ''),
          started_at: c.Status && c.Status.startsWith('Up') ? new Date(c.Created * 1000).toISOString() : null,
        }));
        Promise.all(containers.map(c => inspectContainer(c.name))).then(resolve);
      } catch {
        resolve([]);
      }
    });
    sock.on('error', () => resolve([]));
    sock.write(req);
  });
}

function inspectContainer(name) {
  return new Promise((resolve) => {
    const sock = net.createConnection(DOCKER_SOCKET);
    const req = `GET /containers/${encodeURIComponent(name)}/json HTTP/1.0\r\nHost: localhost\r\n\r\n`;
    let buf = '';
    sock.on('data', (d) => { buf += d.toString(); });
    sock.on('end', () => {
      try {
        const body = buf.slice(buf.indexOf('\r\n\r\n') + 4);
        const data = JSON.parse(body);
        resolve({
          name,
          started_at: data.State?.StartedAt || null,
        });
      } catch {
        resolve({ name, started_at: null });
      }
    });
    sock.on('error', () => resolve({ name, started_at: null }));
    sock.write(req);
  });
}

// ── Precomputed payload — never block an HTTP request on metrics gathering ──
// Background loop refreshes the JSON payload every PRECOMPUTE_INTERVAL_MS; HTTP
// handler returns whatever's cached. Even under heavy load (slow nvidia-smi)
// the request returns instantly; only the *freshness* of the data degrades.
let _payloadCache = JSON.stringify({
  cpu_pct: 0, mem_used_mb: 0, mem_total_mb: 0, generated_at: 0,
});
let _payloadGeneratedAt = 0;
let _payloadInFlight = false;

async function refreshPayload() {
  if (_payloadInFlight) return;
  _payloadInFlight = true;
  try {
    const containers = await dockerContainersDetailed();
    const cpu  = cpuPercent();
    const mem  = memInfo();
    const disk = diskInfo();
    const gpu  = gpuInfo();
    _payloadCache = JSON.stringify({
      cpu_pct: cpu,
      ...mem,
      ...disk,
      ...gpu,
      containers,
      generated_at: Date.now(),
    });
    _payloadGeneratedAt = Date.now();
  } catch (err) {
    // Keep the previous cache rather than wiping it on a transient error.
    console.error('[metrics] refresh error:', err && err.message);
  } finally {
    _payloadInFlight = false;
  }
}

// Kick off the first refresh, then schedule recurring ones.
refreshPayload();
setInterval(refreshPayload, PRECOMPUTE_INTERVAL_MS).unref();

const server = http.createServer((req, res) => {
  if (req.method !== 'GET' || !req.url.startsWith('/')) {
    res.writeHead(404);
    res.end();
    return;
  }
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      uptime_s: Math.round(process.uptime()),
      payload_age_ms: Date.now() - _payloadGeneratedAt,
    }));
    return;
  }
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(_payloadCache);
});

server.timeout = REQ_TIMEOUT_MS;

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[InferHaven] Metrics server listening on :${PORT}`);
});
