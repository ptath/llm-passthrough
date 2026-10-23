#!/usr/bin/env bash
# llm-passthrough — interactive installer (v0.4.1, multi-provider)
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/ptath/llm-passthrough/main/install.sh | bash
# Or download first, inspect, then run:  bash install.sh [--lang en]
#
# Env overrides (rarely needed):
#   LLM_PASSTHROUGH_DIR         install location (default /opt/llm-passthrough)
#   BIND_IP / BIND_PORT         bind for the debug listener (defaults 127.0.0.1/8080)
#
# Multi-provider: answer "y" to "add another proxy" — each provider gets its
# own container, secret prefix and subdomain. State: instances.conf.

set -u

REPO_TARBALL="https://github.com/ptath/llm-passthrough/archive/refs/heads/main.tar.gz"
INSTALL_DIR="${LLM_PASSTHROUGH_DIR:-/opt/llm-passthrough}"
TMP_TGZ="/tmp/llm-passthrough.$$.tgz"
trap 'rm -f "$TMP_TGZ"' EXIT

# ---------- CLI flags --------------------------------------------------------
UI_LANG="ru"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang) UI_LANG="${2:-ru}"; shift 2 ;;
    --lang=*) UI_LANG="${1#*=}"; shift ;;
    -h|--help)
      echo "usage: install.sh [--lang ru|en]"
      echo "  curl -fsSL https://raw.githubusercontent.com/ptath/llm-passthrough/main/install.sh | bash"
      exit 0 ;;
    *) shift ;;
  esac
done
[[ "$UI_LANG" != "en" && "$UI_LANG" != "ru" ]] && UI_LANG="ru"

# ---------- helpers ----------------------------------------------------------
# L "text in russian" "text in english" — prints in the selected language
L() {
  local ru="$1" en="${2:-$1}"
  if [[ "$UI_LANG" == "en" ]]; then printf '%s\n' "$en"; else printf '%s\n' "$ru"; fi
}

die() { L "Ошибка: $1" "Error: $2" >&2; exit 1; }

# ask "ru prompt" "en prompt" [default] -> echoes the answer to stdout.
# Prompts go to stderr. Reads /dev/tty when possible (works under `curl | bash`),
# otherwise stdin. EOF without input is fatal — no endless loops.
ask() {
  local def="${3:-}" a="" ok=0
  L "→ $1" "→ $2" >&2
  [[ -n "$def" ]] && L "   [${def}]" "   [${def}]" >&2
  # 1) direct run: stdin is a terminal
  # 2) `curl | bash`: stdin is the script itself — read the real terminal
  # 3) piped answers (agents): no tty anywhere — read stdin
  if [[ -t 0 ]]; then
    IFS= read -r a && ok=1
  elif ( : < /dev/tty ) 2>/dev/null; then
    IFS= read -r a < /dev/tty && ok=1
  else
    IFS= read -r a && ok=1
  fi
  if [[ $ok -eq 0 ]]; then
    L "Нет ввода (EOF). Прерываю." "No input (EOF). Aborting." >&2
    exit 1
  fi
  [[ -z "$a" ]] && a="$def"
  printf '%s' "$a"
}

# HTTP code of a URL ("000" on failure). Uses curl; presence is checked in preflight.
probe() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-6}" "$1" 2>/dev/null; }

# Same, but with a deliberately invalid key: public endpoints stay 200,
# key-gated ones answer 401 — both mean "reachable and passthrough intact".
probe_auth() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-6}" -H 'Authorization: Bearer sk-invalid-probe' "$1" 2>/dev/null; }

# classify: ok / maybe-blocked (403) / unknown (000, timeout, DNS)
verdict_class() {
  case "$1" in
    000) echo unknown ;;
    403) echo maybe-blocked ;;
    *)   echo ok ;;
  esac
}

gen_prefix() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    tr -dc 'a-f0-9' < /dev/urandom | head -c 32
  fi
}

gen_label() {
  local s
  if command -v openssl >/dev/null 2>&1; then
    s="$(openssl rand -hex 3)"
  else
    s="$(tr -dc 'a-f0-9' < /dev/urandom | head -c 6)"
  fi
  printf 'or-%s' "$s"
}

# extract hostname from "scheme://host[:port][/path]"
uphost() {
  local h="${1#*://}"
  h="${h%%/*}"
  h="${h%%:*}"
  printf '%s' "$h"
}

resolve_ip() { # first A record of a name, empty if none
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$1" 2>/dev/null | awk '{print $1; exit}'
  elif command -v host >/dev/null 2>&1; then
    host -t A "$1" 2>/dev/null | awk '/has address/{print $4; exit}'
  fi
}

public_ip() {
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "?"
}

# ---------- instance naming --------------------------------------------------
sanitize_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

# short service name for an upstream host
derive_service_name() {
  local base
  case "$1" in
    openrouter.ai)                      base="openrouter" ;;
    api.openai.com)                     base="openai" ;;
    api.anthropic.com)                  base="anthropic" ;;
    generativelanguage.googleapis.com)  base="gemini" ;;
    *)
      base="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
      base="${base#api.}"; base="${base#llm.}"; base="${base#chat.}"
      base="${base%%.*}"            # first meaningful label, before sanitize turns dots into dashes
      base="$(sanitize_name "$base")"
      [[ -z "$base" ]] && base="proxy"
      ;;
  esac
  printf '%s-proxy' "$base"
}

array_contains() {
  local x
  for x in ${SVCS[@]+"${SVCS[@]}"}; do [[ "$x" == "$1" ]] && return 0; done
  return 1
}

unique_service_name() {
  local name="$1" n=2
  while array_contains "$name"; do name="${1}-$n"; n=$((n+1)); done
  printf '%s' "$name"
}

# ---------- preflight --------------------------------------------------------
preflight() {
  if [[ $EUID -ne 0 ]]; then
    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
      die "нет прав на $INSTALL_DIR — запусти с sudo:  curl -fsSL <url> | sudo bash" \
          "cannot write to $INSTALL_DIR — run with sudo:  curl -fsSL <url> | sudo bash"
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    die "нужен curl: apt install curl (или dnf install curl)" \
        "curl is required: apt install curl (or dnf install curl)"
  fi

  if ! command -v docker >/dev/null 2>&1; then
    L "Docker не найден. Установи и вернись:" "Docker not found. Install it and come back:"
    L "  https://docs.docker.com/engine/install/" "  https://docs.docker.com/engine/install/"
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    if docker info 2>&1 | grep -qi "permission denied"; then
      die "нет доступа к docker — запусти с sudo или добавь себя в группу docker" \
          "cannot talk to docker — run with sudo or add yourself to the docker group"
    fi
    die "docker установлен, но демон не запущен: systemctl start docker" \
        "docker is installed but the daemon is not running: systemctl start docker"
  fi

  if ! docker compose version >/dev/null 2>&1; then
    L "Плагин docker compose не найден." "The docker compose plugin is missing."
    L "  https://docs.docker.com/compose/install/linux/" "  https://docs.docker.com/compose/install/linux/"
    exit 1
  fi
}

# ---------- files ------------------------------------------------------------
fetch_files() {
  say() { L "==> $1" "==> $2"; }
  mkdir -p "$INSTALL_DIR"

  # local checkout? (script run from a repo clone) — use it, no download needed
  local src=""
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  fi
  if [[ -n "$src" && -f "$src/compose.yml" && -f "$src/templates/default.conf.template" && "$src" != "$INSTALL_DIR" ]]; then
    say "Найден локальный чекаут — копирую из $src" "Local checkout found — copying from $src"
    for item in compose.yml templates examples install.sh README.md README.en.md LICENSE .env.example; do
      cp -r "$src/$item" "$INSTALL_DIR/" 2>/dev/null || true
    done
    return 0
  fi

  say "Скачиваю файлы из GitHub → $INSTALL_DIR" "Downloading files from GitHub → $INSTALL_DIR"
  if ! curl -fsSL --max-time 60 "$REPO_TARBALL" -o "$TMP_TGZ"; then
    die "не смог скачать $REPO_TARBALL" "failed to download $REPO_TARBALL"
  fi
  if ! tar -xzf "$TMP_TGZ" -C "$INSTALL_DIR" --strip-components=1; then
    die "не смог распаковать архив" "failed to unpack the archive"
  fi
}

# ---------- step: connectivity table (informational) -------------------------
probe_table() {
  say() { L "==> $1" "==> $2"; }
  say "Проверяю доступность популярных API с этой машины:" "Checking reachability of popular APIs from this machine:"
  local row name url code cls icon text
  while IFS='|' read -r name url; do
    code=$(probe "$url" 6)
    cls=$(verdict_class "$code")
    case "$cls" in
      ok)             icon="✓"; text=$([[ "$UI_LANG" == en ]] && echo "reachable" || echo "доступен") ;;
      maybe-blocked)  icon="✗"; text=$([[ "$UI_LANG" == en ]] && echo "likely blocked (403)" || echo "похоже заблокирован (403)") ;;
      *)              icon="?"; text=$([[ "$UI_LANG" == en ]] && echo "no answer (timeout/DNS)" || echo "нет ответа (таймаут/DNS)") ;;
    esac
    printf '  %s %-10s %s\n' "$icon" "$name" "$text" >&2
  done <<EOF
OpenRouter|https://openrouter.ai/api/v1/models
OpenAI|https://api.openai.com/v1/models
Anthropic|https://api.anthropic.com/v1/models
Gemini|https://generativelanguage.googleapis.com/
EOF
}

# ---------- step: choose upstream --------------------------------------------
choose_upstream() {
  local UPSTREAM_URL="" UPSTREAM_HOST="" choice code cls url ans
  while :; do
    L "" >&2
    L "Что проксируем?" "What are we proxying?" >&2
    L "  1) OpenRouter   (openrouter.ai)" "  1) OpenRouter   (openrouter.ai)" >&2
    L "  2) OpenAI       (api.openai.com)" "  2) OpenAI       (api.openai.com)" >&2
    L "  3) Anthropic    (api.anthropic.com)" "  3) Anthropic    (api.anthropic.com)" >&2
    L "  4) Gemini       (generativelanguage.googleapis.com)" "  4) Gemini       (generativelanguage.googleapis.com)" >&2
    L "  5) Свой URL" "  5) Custom URL" >&2
    choice=$(ask "Номер (Enter = 1):" "Number (Enter = 1):" "1")

    case "$choice" in
      1) UPSTREAM_URL="https://openrouter.ai";                     UPSTREAM_HOST="openrouter.ai";                     url="https://openrouter.ai/api/v1/models" ;;
      2) UPSTREAM_URL="https://api.openai.com";                    UPSTREAM_HOST="api.openai.com";                    url="https://api.openai.com/v1/models" ;;
      3) UPSTREAM_URL="https://api.anthropic.com";                 UPSTREAM_HOST="api.anthropic.com";                 url="https://api.anthropic.com/v1/models" ;;
      4) UPSTREAM_URL="https://generativelanguage.googleapis.com"; UPSTREAM_HOST="generativelanguage.googleapis.com"; url="https://generativelanguage.googleapis.com/" ;;
      5)
        ans=$(ask "URL апстрима, например https://api.example.com:" "Upstream URL, e.g. https://api.example.com:" "")
        [[ -z "$ans" ]] && continue
        [[ "$ans" != *"://"* ]] && ans="https://$ans"
        UPSTREAM_URL="${ans%/}"
        UPSTREAM_HOST=$(uphost "$UPSTREAM_URL")
        [[ -z "$UPSTREAM_HOST" ]] && { L "Не понял URL, попробуй ещё раз." "Could not parse the URL, try again." >&2; continue; }
        url="$UPSTREAM_URL"
        ;;
      *) continue ;;
    esac

    L "" >&2
    L "Проверяю $UPSTREAM_HOST с этого сервера..." "Checking $UPSTREAM_HOST from this server..." >&2
    code=$(probe "$url" 10)
    cls=$(verdict_class "$code")
    if [[ "$cls" == "ok" ]]; then
      L "  ✓ доступен (HTTP $code)" "  ✓ reachable (HTTP $code)" >&2
      UPSTREAM_URL_OUT="$UPSTREAM_URL"; UPSTREAM_HOST_OUT="$UPSTREAM_HOST"
      return 0
    fi

    if [[ "$cls" == "maybe-blocked" ]]; then
      L "  ✗ HTTP 403 — похоже, этот сервис блокирует регион этого сервера" "  ✗ HTTP 403 — this service appears to block this server's region" >&2
      L "    (для некоторых API 403 бывает и просто за отсутствие ключа)" "    (for some APIs 403 also means 'no API key')" >&2
      L "    Прокси на этом сервере не поможет." "    A proxy on this server will not help." >&2
    else
      L "  ? нет ответа (HTTP 000) — таймаут или DNS" "  ? no answer (HTTP 000) — timeout or DNS" >&2
    fi

    ans=$(ask "1) выбрать другой сервис  2) продолжить всё равно  3) выйти:" "1) choose another  2) continue anyway  3) quit:" "3")
    case "$ans" in
      1) : ;;
      2) UPSTREAM_URL_OUT="$UPSTREAM_URL"; UPSTREAM_HOST_OUT="$UPSTREAM_HOST"; return 0 ;;
      *) exit 1 ;;
    esac
  done
}

DETECT_FAILED=0

# ---------- step: secret prefix ----------------------------------------------
choose_prefix() {
  local PREFIX p
  PREFIX=$(gen_prefix)
  L "" >&2
  L "==> Секретный префикс — часть твоих URL, единственный «замок»." "==> Secret prefix — part of your URLs, the only gate." >&2
  L "    СОХРАНИ ЕГО:" "    SAVE IT:" >&2
  echo "    $PREFIX" >&2
  while :; do
    p=$(ask "Enter — оставить сгенерированный, или введи свой (мин. 16 символов):" "Enter — keep the generated one, or type your own (min 16 chars):" "$PREFIX")
    if [[ ${#p} -lt 16 ]]; then
      L "Слишком короткий (мин. 16 символов)." "Too short (min 16 chars)." >&2
      continue
    fi
    PREFIX_OUT="$p"
    return 0
  done
}

# ---------- step: domain -----------------------------------------------------
BASE_DEFAULT=""   # remembered between providers in the multi loop

choose_domain() {
  local BASE LABEL FQDN rip sip
  L "" >&2
  while :; do
    BASE=$(ask "Твой базовый домен (например, mydomain.tld):" "Your base domain (e.g. mydomain.tld):" "$BASE_DEFAULT")
    BASE="$(printf '%s' "$BASE" | tr '[:upper:]' '[:lower:]')"
    BASE="${BASE// /}"
    if [[ "$BASE" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]; then break; fi
    L "Не похоже на домен. Пример: mydomain.tld" "Does not look like a domain. Example: mydomain.tld" >&2
  done
  BASE_DEFAULT="$BASE"
  LABEL=$(gen_label)
  FQDN=$(ask "Поддомен — метка или полное имя (Enter = сгенерированный):" "Subdomain — label or full name (Enter = generated):" "${LABEL}.${BASE}")
  FQDN="$(printf '%s' "$FQDN" | tr '[:upper:]' '[:lower:]')"
  FQDN="${FQDN// /}"
  # a dotless answer is treated as a label — append the base domain
  [[ "$FQDN" != *.* && -n "$BASE" ]] && FQDN="${FQDN}.${BASE}"
  FQDN_OUT="$FQDN"

  rip=$(resolve_ip "$FQDN"); sip=$(public_ip)
  L "" >&2
  if [[ -n "$rip" ]]; then
    L "DNS: $FQDN → $rip; IP этого сервера: $sip" "DNS: $FQDN → $rip; this server's IP: $sip" >&2
    if [[ "$rip" != "$sip" ]]; then
      L "   (резолвится не сюда — для Pangolin это норма; иначе добавь A-запись)" "   (resolves elsewhere — normal for Pangolin; otherwise add an A record)" >&2
    fi
  else
    L "DNS: $FQDN пока не резолвится — добавь A-запись на вход своего реверс-прокси" "DNS: $FQDN does not resolve yet — add an A record pointing at your reverse proxy entry" >&2
    L "   (IP этого сервера: $sip)" "   (this server's IP: $sip)" >&2
  fi
}

# ---------- instances state --------------------------------------------------
SVCS=(); URLS=(); HOSTS=(); PREFIXES=(); DOMAINS=()
NETWORK_NAME=""
PROXY_TYPE=""
BIND_IP_OUT=""; BIND_PORT_OUT=""
NO_PROXY=0

# first instance always lives in the base compose service (its key is fixed)
add_instance() {
  local svc
  if [[ ${#SVCS[@]} -eq 0 ]]; then
    svc="passthrough"
  else
    svc=$(unique_service_name "$(derive_service_name "$UPSTREAM_HOST_OUT")")
  fi
  SVCS+=("$svc"); URLS+=("$UPSTREAM_URL_OUT"); HOSTS+=("$UPSTREAM_HOST_OUT")
  PREFIXES+=("$PREFIX_OUT"); DOMAINS+=("$FQDN_OUT")
}

save_instances() {
  local i
  mkdir -p "$INSTALL_DIR"
  {
    echo "# proxy_type | network (empty = none)"
    echo "${PROXY_TYPE:-}|${NETWORK_NAME:-}"
    echo "# service | upstream_url | upstream_host | prefix | domain"
    for ((i=0; i<${#SVCS[@]}; i++)); do
      printf '%s|%s|%s|%s|%s\n' "${SVCS[$i]}" "${URLS[$i]}" "${HOSTS[$i]}" "${PREFIXES[$i]}" "${DOMAINS[$i]}"
    done
  } > "$INSTALL_DIR/instances.conf"
  chmod 600 "$INSTALL_DIR/instances.conf"
}

load_instances() {
  SVCS=(); URLS=(); HOSTS=(); PREFIXES=(); DOMAINS=()
  local line first=1 f1 f2 f3 f4 f5
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS='|' read -r f1 f2 f3 f4 f5 <<< "$line"
    if [[ $first -eq 1 && -z "$f3" ]]; then
      PROXY_TYPE="$f1"; NETWORK_NAME="$f2"; first=0
    else
      SVCS+=("$f1"); URLS+=("$f2"); HOSTS+=("$f3"); PREFIXES+=("$f4"); DOMAINS+=("$f5")
    fi
  done < "$INSTALL_DIR/instances.conf"
}

# ---------- reverse proxy ----------------------------------------------------
detect_network() { # pattern -> echoes "container|network"; empty on failure
  local line id name nets count sel i all n
  line=$(docker ps --format '{{.ID}}|{{.Image}}|{{.Names}}' 2>/dev/null | grep -iE "$1" | head -n1)
  [[ -z "$line" ]] && return 1
  id="${line%%|*}"
  name="${line##*|}"
  nets=$(docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}
{{end}}' "$id" 2>/dev/null | sed '/^$/d')
  [[ -z "$nets" ]] && return 1
  count=$(printf '%s\n' "$nets" | wc -l | tr -d ' ')
  if [[ "$count" -gt 1 ]]; then
    L "У контейнера $name несколько сетей:" "Container $name is on several networks:" >&2
    i=1; all=""
    while IFS= read -r n; do L "  $i) $n" "  $i) $n" >&2; all+="$n"$'\n'; i=$((i+1)); done <<< "$nets"
    sel=$(ask "Какую использовать? (номер):" "Which one? (number):" "1")
    n=$(printf '%s\n' "$all" | sed -n "${sel}p")
    [[ -z "$n" ]] && return 1
    printf '%s|%s' "$name" "$n"
  else
    printf '%s|%s' "$name" "$nets"
  fi
}

# generates compose.override.yml for ALL instances; empty network → no networks
gen_override() {
  local net="$1" i
  local bip="${BIND_IP_OUT:-${BIND_IP:-127.0.0.1}}"

  if [[ -z "$net" && ${#SVCS[@]} -le 1 ]]; then
    rm -f "$INSTALL_DIR/compose.override.yml"
    return 0
  fi

  {
    echo "# Generated by install.sh — rerun the installer to regenerate."
    if [[ -n "$net" ]]; then
      echo "services:"
      echo "  ${SVCS[0]}:"
      echo "    networks: [extnet]"
    fi
    for ((i=1; i<${#SVCS[@]}; i++)); do
      echo "  ${SVCS[$i]}:"
      echo "    image: nginx:alpine"
      echo "    restart: unless-stopped"
      echo "    environment:"
      echo "      SECRET_PREFIX: \"${PREFIXES[$i]}\""
      echo "      UPSTREAM_URL: \"${URLS[$i]}\""
      echo "      UPSTREAM_HOST: \"${HOSTS[$i]}\""
      echo "    ports:"
      echo "      - \"${bip}:$((8080+i)):80\""
      echo "    volumes:"
      echo "      - ./templates:/etc/nginx/templates:ro"
      [[ -n "$net" ]] && echo "    networks: [extnet]"
    done
    if [[ -n "$net" ]]; then
      echo "networks:"
      echo "  extnet:"
      echo "    name: $net"
      echo "    external: true"
    fi
  } > "$INSTALL_DIR/compose.override.yml"
}

# ---------- per-proxy instructions (loop over instances) ---------------------
print_pangolin_steps() {
  local i
  L "" >&2
  L "==> Дашборд Pangolin (Resources → Create Resource) — по ресурсу на инстанс:" "==> Pangolin dashboard (Resources → Create Resource) — one resource per instance:" >&2
  for ((i=0; i<${#SVCS[@]}; i++)); do
    L "  $((i+1))) Domain: ${DOMAINS[$i]}; Target: метод http, адрес ${SVCS[$i]}, порт 80; auth off, bot-protection off" \
      "  $((i+1))) Domain: ${DOMAINS[$i]}; Target: method http, address ${SVCS[$i]}, port 80; auth off, bot-protection off" >&2
  done
  L "    После создания проверь: curl https://${DOMAINS[0]}/${PREFIXES[0]}/api/v1/models" "    Then check: curl https://${DOMAINS[0]}/${PREFIXES[0]}/api/v1/models" >&2
}

print_npm_steps() {
  local i
  L "" >&2
  L "==> Nginx Proxy Manager (Hosts → Proxy Hosts → Add) — по хосту на инстанс:" "==> Nginx Proxy Manager (Hosts → Proxy Hosts → Add) — one host per instance:" >&2
  for ((i=0; i<${#SVCS[@]}; i++)); do
    L "  $((i+1))) Domain: ${DOMAINS[$i]}; Forward: http, ${SVCS[$i]}, 80; Websockets: ON" \
      "  $((i+1))) Domain: ${DOMAINS[$i]}; Forward: http, ${SVCS[$i]}, 80; Websockets: ON" >&2
  done
}

print_traefik_steps() {
  local i
  L "" >&2
  L "==> Динамический конфиг Traefik (file provider):" "==> Traefik dynamic config (file provider):" >&2
  echo "http:" >&2
  echo "  routers:" >&2
  for ((i=0; i<${#SVCS[@]}; i++)); do
    printf '    p%d: { rule: "Host(`%s`)", service: p%d }\n' "$i" "${DOMAINS[$i]}" "$i" >&2
  done
  echo "  services:" >&2
  for ((i=0; i<${#SVCS[@]}; i++)); do
    printf '    p%d: { loadBalancer: { servers: [{ url: "http://%s:80" }] } }\n' "$i" "${SVCS[$i]}" >&2
  done
  L "    (entrypoints/TLS — по твоей настройке Traefik)" "    (entrypoints/TLS — per your Traefik setup)" >&2
}

print_caddy_steps() {
  local i
  L "" >&2
  L "==> Caddyfile (Caddy сам получит сертификаты):" "==> Caddyfile (Caddy obtains certificates automatically):" >&2
  for ((i=0; i<${#SVCS[@]}; i++)); do
    cat >&2 <<EOF
${DOMAINS[$i]} {
    reverse_proxy ${SVCS[$i]}:80
}
EOF
  done
}

print_nginx_steps() {
  local i port
  L "" >&2
  L "==> Голый nginx — по server-блоку на инстанс (TLS твой, например certbot):" "==> Plain nginx — one server block per instance (TLS is yours, e.g. certbot):" >&2
  for ((i=0; i<${#SVCS[@]}; i++)); do
    if [[ $i -eq 0 ]]; then port="${BIND_PORT_OUT:-${BIND_PORT:-8080}}"; else port=$((8080+i)); fi
    cat >&2 <<EOF
server {
    listen 443 ssl;
    server_name ${DOMAINS[$i]};
    # ssl_certificate     /path/fullchain.pem;
    # ssl_certificate_key /path/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;              # SSE streaming
        proxy_read_timeout 600s;
    }
}
EOF
  done
}

print_remote_steps() {
  local i port ip
  ip=$(public_ip)
  L "" >&2
  L "==> Реверс-прокси на ДРУГОЙ машине → цели (префикс НЕ режь у себя):" "==> Reverse proxy on the OTHER machine → targets (do NOT strip the prefix there):" >&2
  for ((i=0; i<${#SVCS[@]}; i++)); do
    if [[ $i -eq 0 ]]; then port="${BIND_PORT_OUT:-8080}"; else port=$((8080+i)); fi
    L "  ${DOMAINS[$i]} → http://$ip:$port" "  ${DOMAINS[$i]} → http://$ip:$port" >&2
  done
  L "    Пример блока (nginx там): proxy_pass http://$ip:<порт>; + proxy_buffering off" "    Example block (nginx there): proxy_pass http://$ip:<port>; + proxy_buffering off" >&2
  L "    Порт(ы) открыты наружу — секретные префиксы остаются единственным замком." "    The port(s) are public — secret prefixes are the only gate." >&2
}

ask_proxy() { # optional $1 = pre-known proxy type (skip the menu, e.g. when
              # reconstructing a v0.2.x install from .env)
  local preset="${1:-}" choice P net det PORT
  if [[ -n "$preset" ]]; then
    P="$preset"
  else
  L "" >&2
  L "Какой у тебя реверс-прокси и где?" "Which reverse proxy do you have, and where?" >&2
  L "  1) Pangolin — коннектор (newt/pangolin-cli) в docker на этой машине" "  1) Pangolin — connector (newt/pangolin-cli) in docker on this machine" >&2
  L "  2) Nginx Proxy Manager — docker на этой машине" "  2) Nginx Proxy Manager — docker on this machine" >&2
  L "  3) Traefik — docker на этой машине" "  3) Traefik — docker on this machine" >&2
  L "  4) Caddy — docker на этой машине" "  4) Caddy — docker on this machine" >&2
  L "  5) Голый nginx на этой машине (без docker)" "  5) Plain nginx on this machine (no docker)" >&2
  L "  6) Реверс-прокси на другой машине" "  6) Reverse proxy on another machine" >&2
  L "  7) Реверс-прокси пока нет" "  7) No reverse proxy yet" >&2
  while :; do
    P=$(ask "Номер:" "Number:" "")
    [[ "$P" =~ ^[1-7]$ ]] && break
    L "Нужна цифра 1–7." "Enter a number 1–7." >&2
  done
  fi
  PROXY_TYPE="$P"

  case "$P" in
    1|2|3|4)
      local pattern=""
      case "$P" in
        1) pattern='pangolin|newt' ;;
        2) pattern='nginx-proxy-manager|jc21' ;;
        3) pattern='traefik' ;;
        4) pattern='caddy' ;;
      esac
      L "Ищу контейнер ($pattern)..." "Looking for the container ($pattern)..." >&2
      det=$(detect_network "$pattern") || det=""
      if [[ -n "$det" ]]; then
        NETWORK_NAME="${det##*|}"
        L "  найден: ${det%%|*}; сеть: $NETWORK_NAME" "  found: ${det%%|*}; network: $NETWORK_NAME" >&2
      else
        DETECT_FAILED=1
        L "  не нашёл автоматически — настрой сеть вручную по examples/ и перезапусти установщик (Enter = keep)." \
          "  could not detect it — configure the network manually per examples/ and rerun the installer (Enter = keep)." >&2
      fi
      ;;
    5) : ;;
    6)
      if [[ -n "$preset" && -n "${BIND_PORT:-}" ]]; then
        BIND_IP_OUT="${BIND_IP:-0.0.0.0}"; BIND_PORT_OUT="${BIND_PORT}"   # already sourced from .env
      else
        PORT=$(ask "Порт, который слушает этот сервер (Enter = 8080):" "Port this server should listen on (Enter = 8080):" "8080")
        BIND_IP_OUT="0.0.0.0"; BIND_PORT_OUT="$PORT"
      fi
      ;;
    7) NO_PROXY=1 ;;
  esac
}

# ---------- env file ---------------------------------------------------------
write_env() {
  {
    echo "# Generated by install.sh (first instance; the rest — see instances.conf)"
    echo "SECRET_PREFIX=${PREFIX_OUT}"
    echo "UPSTREAM_URL=${UPSTREAM_URL_OUT}"
    echo "UPSTREAM_HOST=${UPSTREAM_HOST_OUT}"
    echo "DOMAIN=${FQDN_OUT}"
    echo "PROXY_TYPE=${PROXY_OUT}"
    [[ -n "${BIND_IP_OUT:-}" ]]   && echo "BIND_IP=${BIND_IP_OUT}"
    [[ -n "${BIND_PORT_OUT:-}" ]] && echo "BIND_PORT=${BIND_PORT_OUT}"
  } > "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
}

env_get() { grep -E "^$1=" "$INSTALL_DIR/.env" 2>/dev/null | head -n1 | cut -d= -f2-; }

# ---------- main -------------------------------------------------------------
main() {
  say() { L "==> $1" "==> $2"; }

  L "llm-passthrough — установка" "llm-passthrough — installer" >&2
  L "=====================================" "=====================================" >&2

  preflight
  fetch_files

  # --- fresh or keep? ------------------------------------------------------
  local fresh=1 ans keep_answer
  if [[ -f "$INSTALL_DIR/instances.conf" && -f "$INSTALL_DIR/.env" ]]; then
    keep_answer=$(ask "Найдена существующая установка — использовать её? (Enter = да, r = перенастроить всё):" \
                      "Existing installation found — use it? (Enter = yes, r = reconfigure):" "")
    if [[ "$keep_answer" != "r" && "$keep_answer" != "R" ]]; then
      load_instances
      # make .env values visible for regenerating overrides (BIND_IP etc.)
      set -a; source "$INSTALL_DIR/.env"; set +a
      fresh=0
    fi
  elif [[ -f "$INSTALL_DIR/.env" ]]; then
    # v0.2-style install: reconstruct a single instance from .env, then
    # re-detect the reverse-proxy network so the override survives the rewrite
    PREFIX_OUT=$(env_get SECRET_PREFIX)
    UPSTREAM_URL_OUT=$(env_get UPSTREAM_URL); UPSTREAM_URL_OUT=${UPSTREAM_URL_OUT:-https://openrouter.ai}
    UPSTREAM_HOST_OUT=$(env_get UPSTREAM_HOST); UPSTREAM_HOST_OUT=${UPSTREAM_HOST_OUT:-openrouter.ai}
    FQDN_OUT=$(env_get DOMAIN)
    SVCS=("passthrough"); URLS=("$UPSTREAM_URL_OUT"); HOSTS=("$UPSTREAM_HOST_OUT")
    PREFIXES=("$PREFIX_OUT"); DOMAINS=("$FQDN_OUT")
    PROXY_TYPE=$(env_get PROXY_TYPE)
    keep_answer=$(ask "Найден старый .env — оставить как есть? (Enter = да, r = перенастроить):" \
                      "Old-style .env found — keep as is? (Enter = yes, r = reconfigure):" "")
    if [[ "$keep_answer" == "r" || "$keep_answer" == "R" ]]; then
      SVCS=(); URLS=(); HOSTS=(); PREFIXES=(); DOMAINS=(); fresh=1
    else
      fresh=0
      set -a; source "$INSTALL_DIR/.env"; set +a   # BIND_IP/BIND_PORT etc.
      if [[ -n "$PROXY_TYPE" && "$PROXY_TYPE" != 5 ]]; then
        ask_proxy "$PROXY_TYPE"
      fi
    fi
  fi

  # --- collect instances ---------------------------------------------------
  if [[ $fresh -eq 1 ]]; then
    probe_table
    while :; do
      choose_upstream
      choose_prefix
      choose_domain
      add_instance
      ans=$(ask "Добавить ещё один прокси на этом сервере? [y/N]:" "Add another proxy on this server? [y/N]:" "N")
      [[ "$ans" == "y" || "$ans" == "Y" ]] || break
    done
    ask_proxy
  fi

  # --- persist -------------------------------------------------------------
  PREFIX_OUT="${PREFIXES[0]:-}"; UPSTREAM_URL_OUT="${URLS[0]:-}"; UPSTREAM_HOST_OUT="${HOSTS[0]:-}"
  FQDN_OUT="${DOMAINS[0]:-}"; PROXY_OUT="${PROXY_TYPE}"
  write_env
  save_instances

  if [[ "${NO_PROXY:-0}" == "1" ]]; then
    gen_override ""   # single instance → file removed; multi → extra services on loopback
    say "Поднимаю контейнер(ы) — только loopback, прокси не настроен..." \
        "Bringing containers up — loopback only, no reverse proxy yet..."
    (cd "$INSTALL_DIR" && docker compose up -d) || die "docker compose up не удался" "docker compose up failed"
    L "" >&2
    L "Реверс-прокси не настроен — это за рамками проекта." "No reverse proxy — that is outside this project's scope." >&2
    L "Самый простой вариант — Caddy (сертификаты сам): https://caddyserver.com/" "Simplest option — Caddy: https://caddyserver.com/" >&2
    L "Поставишь — запусти установщик снова (Enter = keep), он доделает связку." "Once it is up, rerun this installer (Enter = keep)." >&2
    exit 0
  fi

  if [[ "$DETECT_FAILED" == "1" && "$fresh" == "0" ]]; then
    say "Сеть реверс-прокси не определилась — оставляю прежний compose.override.yml без изменений." \
        "Could not re-detect the network — keeping the existing compose.override.yml untouched."
  elif [[ "$DETECT_FAILED" == "1" ]]; then
    rm -f "$INSTALL_DIR/compose.override.yml"
  else
    gen_override "$NETWORK_NAME"
  fi

  # the network must exist; if it vanished (proxy stack recreated), fail loudly
  if [[ -n "$NETWORK_NAME" ]] && ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    die "сеть docker '$NETWORK_NAME' не существует — перезапусти установщик и ответь r" \
        "docker network '$NETWORK_NAME' does not exist — rerun the installer and answer r"
  fi
  say "Поднимаю контейнер(ы)..." "Bringing container(s) up..."
  (cd "$INSTALL_DIR" && docker compose up -d) || die "docker compose up не удался — смотри вывод выше" "docker compose up failed — see the output above"

  # --- summary -------------------------------------------------------------
  local i port code bip="${BIND_IP_OUT:-${BIND_IP:-127.0.0.1}}"
  L "" >&2
  L "================= ГОТОВО =================" "================= DONE =================" >&2
  case "$PROXY_TYPE" in
    1) print_pangolin_steps ;;
    2) print_npm_steps ;;
    3) print_traefik_steps ;;
    4) print_caddy_steps ;;
    5) print_nginx_steps ;;
    6) print_remote_steps ;;
  esac
  L "" >&2
  L "Инстансы:" "Instances:" >&2
  for ((i=0; i<${#SVCS[@]}; i++)); do
    if [[ $i -eq 0 ]]; then port="${BIND_PORT_OUT:-${BIND_PORT:-8080}}"; else port=$((8080+i)); fi
    # nginx spends a moment in its entrypoint (envsubst + config test) after
    # the container starts; a connection-refused here is a race, not a failure.
    # Wait for it to bind before probing — up to ~8 s.
    h="000"
    for _ in 1 2 3 4 5 6 7 8; do
      h=$(probe "http://127.0.0.1:${port}/" 3)
      [[ "$h" != "000" ]] && break
      sleep 1
    done
    code=$(probe_auth "http://127.0.0.1:${port}/${PREFIXES[$i]}/api/v1/models" 10)
    L "  $((i+1))) ${DOMAINS[$i]}" "  $((i+1))) ${DOMAINS[$i]}" >&2
    L "     Base URL: https://${DOMAINS[$i]}/${PREFIXES[$i]}" "     Base URL: https://${DOMAINS[$i]}/${PREFIXES[$i]}" >&2
    L "     Апстрим:  ${URLS[$i]}   Таргет: ${SVCS[$i]}:80" "     Upstream: ${URLS[$i]}   Target: ${SVCS[$i]}:80" >&2
    L "     Локально: nginx $h, апстрим HTTP $code (порт $port)" "     Local:    nginx $h, upstream HTTP $code (port $port)" >&2
  done
  L "" >&2
  L "  nginx 200 — контейнер жив; любой HTTP от апстрима — связка работает" "  nginx 200 — container is alive; any HTTP from the upstream — the chain works" >&2
  L "  (200/401 — норма; у OpenAI GET models бывает 404 от фильтра, POST-ы проходят)." "  (200/401 are normal; OpenAI may 404 GET models — POSTs pass fine)." >&2
  L "" >&2
  L "Состояние: instances.conf · Документация: $INSTALL_DIR/README.md" "State: instances.conf · Docs: $INSTALL_DIR/README.md" >&2
}

# run when executed directly or piped (BASH_SOURCE empty); skip when sourced
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
  main "$@"
fi
