# Security Policy

We take the security of InferHaven seriously. Thank you for helping keep
InferHaven and its users safe.

This policy covers **inferhaven-core** (the self-hostable Docker stack). For
operational hardening guidance — access control, network exposure, TLS, secrets,
and the deliberate trust boundaries of the stack — see
[`docs/security.md`](docs/security.md). Reading that document first will help you
distinguish a genuine vulnerability from a documented, by-design behavior (see
[Scope](#scope) below).

## Reporting a vulnerability

**Please do not open public issues, pull requests, or forum posts for security
vulnerabilities.** Disclosing a flaw publicly before a fix is available puts
every InferHaven operator at risk.

Instead, report privately:

- **Email:** [lookout@inferhaven.com](mailto:lookout@inferhaven.com)
- **Encryption (recommended for sensitive reports):** If your report contains
  credentials, tokens, customer data, or working exploit code, encrypt it to our
  OpenPGP key before sending. Do not include live secrets in an unencrypted
  message.

### OpenPGP key

**OpenPGP fingerprint: `4992 80D5 D75E 3A4F 837C  6A68 85D8 E097 0D05 CEC0`**

- **User ID:** `InferHaven <lighthouse@inferhaven.com>`
- **Key type:** RSA 4096, created 2026-06-03, **expires 2028-06-02**
- **Subkeys:** encryption `2514 388B 8AF4 B051 BB43  64F9 3103 8F68 3461 7D60`,
  signing `83BB 8610 7868 5655 60E4  52FE C075 355A E78E FD6D`

The public key is published at, and should match across, all of these locations
— verify the fingerprint above against at least one independent source before
trusting it:

- This repository: [`inferhaven_pub.asc`](inferhaven_pub.asc) (repo root)
- Stable URL: <https://inferhaven.com/pgpkey.asc>
- Our github profile

Encrypt your report to this key and send it to
[lookout@inferhaven.com](mailto:lookout@inferhaven.com). (The key's user ID is
`lighthouse@inferhaven.com` — this is the same organization key; the reporting
inbox is `lookout@`.)

**Import and verify:**

```bash
# Import from the repo (or download from the stable URL / org profile)
gpg --import inferhaven_pub.asc

# Confirm the fingerprint matches the one printed above
gpg --fingerprint lighthouse@inferhaven.com

# Encrypt your report before sending
gpg --encrypt --armor --recipient lighthouse@inferhaven.com report.txt
```

If you do not receive an acknowledgement within the window below, see
[Contact and escalation](#contact-and-escalation).

## What to include in a report

A good report lets us reproduce and triage quickly. Where possible, include:

- **Affected version(s)** — release tag, commit SHA, or `inferhaven-core`
  Docker image tag.
- **Component** — e.g. `workspace`, `code-server`, `caddy` config, a `haven`
  script, the optional cloud agent, or the entrypoint/sync logic.
- **Clear description and impact** — what an attacker can do, and under what
  preconditions (network position, existing access, configuration).
- **Steps to reproduce or a proof of concept** — exact commands, request
  payloads, or a minimal `.env` / compose configuration.
- **Supporting evidence** — relevant logs, screenshots, or exploit code.
- **Your contact details** — so we can follow up. You may request anonymity
  (see [Credits](#credits)).

## Scope

**In scope** — vulnerabilities in code and configuration shipped by this
repository:

- The Docker stack as defined in `docker-compose.yml` and the
  `docker/` build files (`workspace`, `caddy`, etc.).
- The `haven` CLI and the `scripts/` it sources (entrypoint, sync driver,
  backup, tmate, tune, and related logic).
- The default Caddy routing and TLS configuration in `docker/caddy/`.
- The optional cloud agent service (`--profile cloud`) as built and configured
  in this repository.
- Official tagged releases and the published `inferhaven-core` images.

**Out of scope:**

- Forks and third-party redistributions of InferHaven.
- Upstream vulnerabilities in third-party components we package (Ollama,
  code-server, Caddy, the base OS image, language toolchains). Report those to
  the respective projects. If our **default configuration** of one of those
  components is the problem, that *is* in scope — tell us.
- Behavior of AI models pulled at runtime (model output, prompt injection
  against a model, etc.).
- Findings that require pre-existing privileged access already documented as
  equivalent to host root (see below), or that depend on the operator ignoring
  the hardening steps in [`docs/security.md`](docs/security.md).

### Documented, by-design behaviors (not vulnerabilities)

These are intentional trade-offs documented in
[`docs/security.md`](docs/security.md). Please don't file them as
vulnerabilities on their own — though a way to *escape* or *bypass* an intended
boundary is in scope:

- **The Ollama API (`/api/*`, `/v1/*`) is unauthenticated.** It is meant to be
  protected by `ALLOWED_IPS`, a VPN, or a host firewall. Reaching it from an
  allowed network is expected.
- **The workspace and cloud-agent containers mount the Docker socket.** SSH or
  shell access to those containers is, by design, equivalent to root on the
  host. Protect SSH keys accordingly.
- **The shipped default `CODE_SERVER_PASSWORD` is public** and documented as a
  must-change item before exposure.

A flaw that lets an attacker reach any of the above *without* the documented
precondition (e.g. bypassing `ALLOWED_IPS`, spoofing the source IP that Caddy
trusts, or breaking out of the intended network isolation) is a real
vulnerability — please report it.

## Process and timelines

We aim to:

- **Acknowledge** your report within **72 hours**.
- **Triage and give an initial assessment** (severity, whether we can reproduce,
  next steps) within **7 days**.
- **Provide a fix or mitigation** on a timeline driven by severity and
  complexity. We will keep you updated on progress and let you know when a fix
  ships.

## Coordinated disclosure

We follow coordinated disclosure. Please give us up to **90 days** from your
initial report to release a fix before disclosing publicly. If the issue is
being actively exploited, or if you need a different timeline, tell us — we will
work with you in good faith to agree on a schedule.

We will publish an advisory (and patched release) when a fix is available, and
coordinate the disclosure date with you.

## Severity and CVE

We classify severity by impact and exploitability (roughly following CVSS).
Critical and high-severity issues are prioritized, and significant
vulnerabilities may be assigned a CVE and published as a security advisory.

## Safe harbor

We welcome good-faith security research. We will not pursue legal action against,
or ask law enforcement to investigate, researchers who:

- Make a good-faith effort to follow this policy.
- Avoid privacy violations, data destruction, and service degradation
  (no denial-of-service, no exfiltration beyond what's needed to prove the
  issue).
- Only test against systems they own or are explicitly authorized to test — do
  **not** attack other operators' deployments.
- Give us a reasonable window to remediate before public disclosure.

If in doubt about whether an action is authorized, ask us first.

## Credits

With your permission, we will credit you by name (or handle) in the advisory and
release notes for the fix. If you prefer to remain anonymous, just say so in your
report and we will keep your identity confidential.

## Contact and escalation

- **Primary:** [lookout@inferhaven.com](mailto:lookout@inferhaven.com)
- If you receive **no response within 7 days**, please re-send and explicitly
  flag the report as **unacknowledged / escalation** in the subject line so it
  is routed for priority attention.
