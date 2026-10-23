# AGENTS.md — guidance for AI coding agents

This repository is **openrouter-passthrough**: a tiny passthrough reverse
proxy (official `nginx:alpine` image, no builds) that lets apps reach a
region-blocked HTTP API — OpenRouter by default — through the user's own
server abroad. You are probably reading this because the user pasted the repo
link into an AI agent. Your job: verify prerequisites, then deploy and verify.

## HARD REQUIREMENT — check before anything else

The user MUST have a server (VPS/VDS) from which the target service is
directly reachable, i.e. the server's region is NOT blocked by the service.

- No suitable server? **Stop.** Tell the user to rent one (1 core / 1 GB RAM /
  10 GB disk is enough; region: one where the service works and latency to
  the user is acceptable). Do not start deployment without it.
- Verify reachability **from that server**:
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" https://openrouter.ai/api/v1/models
  ```
  - `200` or `401` (auth required) → reachable, proceed
  - `403` → the server's region is blocked by the service; the user needs a
    different server/region
- Also required: Docker 20+ with the compose plugin (`docker compose version`),
  a domain (subdomain) with DNS pointing at the server — or at the reverse
  proxy entry — and the user's upstream API key (it stays in their apps,
  never on the proxy).

## Deployment flow

1. Confirm the requirements above with the user, explicitly including the
   region/reachability question.
2. On the server, install. Preferred — the interactive installer (it checks
   docker, probes reachability, asks what to proxy, generates the secret
   prefix and subdomain, detects the reverse proxy and writes
   `compose.override.yml` itself):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/ptath/openrouter-passthrough/main/install.sh | bash
   ```
   For non-interactive (agent) runs, pipe the answers and use env overrides —
   the installer reads input from /dev/tty with a stdin fallback:
   ```bash
   printf '1\n\ndomain.tld\n\n\n1\n' | \
     OPENROUTER_PASSTHROUGH_DIR=/opt/openrouter-passthrough bash install.sh --lang en
   # answer order: upstream choice, prefix (empty = generated), base domain,
   #               subdomain label (empty = generated), add-another? (empty = N),
   #               reverse-proxy choice
   ```
   Multi-provider: answer `y` to the add-another question and repeat the
   upstream/prefix/domain triple for each extra provider. Every provider gets
   its own service, secret prefix and subdomain; state lives in
   `instances.conf` in the install dir (rerun the installer with Enter to
   rebuild from it without questions).
   Alternatively, clone the repo and run `./install.sh` — no download needed.
3. Ask which reverse proxy the user already runs and follow the matching
   example in `examples/` (the installer does most of this automatically; the
   examples remain the manual reference):
   - Pangolin connector on the same host → `examples/pangolin/`
   - Caddy → `examples/caddy/` (no container needed at all)
   - Nginx Proxy Manager → `examples/nginx-proxy-manager/`
   - Traefik → `examples/traefik/`
   - Plain nginx → the server block in `README.md`
4. Verify — run these yourself and report the results:
   ```bash
   # from the server (loopback): expect 2xx from the upstream edge
   curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/<SECRET_PREFIX>/api/v1/models
   # through the public domain: same result
   curl -s -o /dev/null -w "%{http_code}\n" https://openrouter.example.com/<SECRET_PREFIX>/api/v1/models
   # outside the secret prefix: expect 404
   curl -s -o /dev/null -w "%{http_code}\n" https://openrouter.example.com/api/v1/models
   ```
   Then suggest the chat + streaming tests from `README.md` with the user's
   own API key.

## Do / Don't

- DO tell the user once that bypassing regional restrictions may violate the
  upstream ToS (account risk), then respect their decision.
- DO NOT store, echo or commit the user's API key. The proxy is stateless;
  keys live only in the user's apps and pass through in headers.
- DO NOT publish or weaken the `SECRET_PREFIX`. `.env` must never be
  committed (it is gitignored).
- DO NOT remove the `location = / { return 200 ...; }` health-check block:
  tunnel connectors (e.g. Pangolin's) poll `GET /` every 30 s and mark the
  target unhealthy on anything but 2xx → the resource starts returning 503
  ("no available server").
- In nginx configs, `set $var ...` MUST come before `rewrite ... break;`,
  otherwise the variable is uninitialized and nginx returns 500.
- Prefix rotation = edit `.env` + `docker compose up -d` (a ~30 s 503 window
  is normal while the connector re-runs its health check).
- Pointing at another API = set `UPSTREAM_URL` / `UPSTREAM_HOST` in `.env`
  (paths are forwarded as-is, so OpenAI, Anthropic and friends work the same).

## Project map

- `compose.yml` — universal stack, listens on loopback only
- `templates/default.conf.template` — rendered at container start via envsubst
- `install.sh` — bootstrap (creates `.env`, starts the container)
- `examples/` — per-reverse-proxy recipes (Pangolin, Caddy, NPM, Traefik)
- `README.md` — full docs in Russian; `README.en.md` — short English version
