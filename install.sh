#!/usr/bin/env bash
# openrouter-passthrough — interactive installer (v0.2.1)
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/ptath/openrouter-passthrough/main/install.sh | bash
# Or download first, inspect, then run:  bash install.sh [--lang en]
#
# Env overrides (rarely needed):
#   OPENROUTER_PASSTHROUGH_DIR  install location (default /opt/openrouter-passthrough)
#   BIND_IP / BIND_PORT         bind for the debug listener (defaults 127.0.0.1/8080)

set -u

REPO_TARBALL="https://github.com/ptath/openrouter-passthrough/archive/refs/heads/main.tar.gz"
INSTALL_DIR="${OPENROUTER_PASSTHROUGH_DIR:-/opt/openrouter-passthrough}"
TMP_TGZ="/tmp/openrouter-passthrough.$$.tgz"
trap 'rm -f "$TMP_TGZ"' EXIT

# ---------- CLI flags --------------------------------------------------------
UI_LANG="ru"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang) UI_LANG="${2:-ru}"; shift 2 ;;
    --lang=*) UI_LANG="${1#*=}"; shift ;;
    -h|--help)
      echo "usage: install.sh [--lang ru|en]"
      echo "  curl -fsSL https://raw.githubusercontent.com/ptath/openrouter-passthrough/main/install.sh | bash"
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

# ---------- preflight --------------------------------------------------------
preflight() {
  say() { L "==> $1" "==> $2"; }

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
      1) UPSTREAM_URL="https://openrouter.ai";                        UPSTREAM_HOST="openrouter.ai";                        url="https://openrouter.ai/api/v1/models" ;;
      2) UPSTREAM_URL="https://api.openai.com";                       UPSTREAM_HOST="api.openai.com";                       url="https://api.openai.com/v1/models" ;;
      3) UPSTREAM_URL="https://api.anthropic.com";                    UPSTREAM_HOST="api.anthropic.com";                    url="https://api.anthropic.com/v1/models" ;;
      4) UPSTREAM_URL="https://generativelanguage.googleapis.com";    UPSTREAM_HOST="generativelanguage.googleapis.com";    url="https://generativelanguage.googleapis.com/" ;;
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
choose_domain() {
  local BASE LABEL FQDN rip sip
  L "" >&2
  while :; do
    BASE=$(ask "Твой базовый домен (например, mydomain.tld):" "Your base domain (e.g. mydomain.tld):" "")
    BASE="$(printf '%s' "$BASE" | tr '[:upper:]' '[:lower:]')"
    BASE="${BASE// /}"
    if [[ "$BASE" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]; then break; fi
    L "Не похоже на домен. Пример: mydomain.tld" "Does not look like a domain. Example: mydomain.tld" >&2
  done
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

# ---------- step: reverse proxy ----------------------------------------------
detect_network() { # pattern -> echoes "container|network"; empty on failure
  local line id name nets count sel i
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
    i=1; local all
    while IFS= read -r n; do L "  $i) $n" "  $i) $n" >&2; all+="$n"$'\n'; i=$((i+1)); done <<< "$nets"
    sel=$(ask "Какую использовать? (номер):" "Which one? (number):" "1")
    n=$(printf '%s\n' "$all" | sed -n "${sel}p")
    [[ -z "$n" ]] && return 1
    printf '%s|%s' "$name" "$n"
  else
    printf '%s|%s' "$name" "$nets"
  fi
}

write_override() { # network name
  cat > "$INSTALL_DIR/compose.override.yml" <<EOF
# Generated by install.sh — attaches the proxy container to the docker
# network of your reverse proxy, so it is reachable by container name.
services:
  openrouter-proxy:
    networks: [extnet]

networks:
  extnet:
    name: $1
    external: true
EOF
}

print_pangolin_steps() {
  L "" >&2
  L "==> Осталось в дашборде Pangolin (Resources → Create Resource):" "==> Remaining steps in the Pangolin dashboard (Resources → Create Resource):" >&2
  L "    Site: сайт этого коннектора" "    Site: this connector's site" >&2
  L "    Domain: $1" "    Domain: $1" >&2
  L "    Target: метод http, адрес openrouter-proxy, порт 80" "    Target: method http, address openrouter-proxy, port 80" >&2
  L "    Authentication: выключить; Bot protection: выключить" "    Authentication: off; Bot protection: off" >&2
  L "    После создания проверь: curl https://$1/$2/api/v1/models" "    After that check: curl https://$1/$2/api/v1/models" >&2
}

print_npm_steps() {
  L "" >&2
  L "==> В Nginx Proxy Manager (Hosts → Proxy Hosts → Add):" "==> In Nginx Proxy Manager (Hosts → Proxy Hosts → Add):" >&2
  L "    Domain: $1; Forward: scheme http, host openrouter-proxy, port 80" "    Domain: $1; Forward: scheme http, host openrouter-proxy, port 80" >&2
  L "    Websockets: ON; SSL: выпусти сертификат + Force SSL" "    Websockets: ON; SSL: issue a certificate + Force SSL" >&2
}

print_traefik_steps() {
  L "" >&2
  L "==> Добавь в динамический конфиг Traefik (file provider):" "==> Add to your Traefik dynamic config (file provider):" >&2
  cat >&2 <<EOF
http:
  routers:
    openrouter-passthrough:
      rule: "Host(\`$1\`)"
      service: openrouter-passthrough
  services:
    openrouter-passthrough:
      loadBalancer:
        servers:
          - url: "http://openrouter-proxy:80"
EOF
  L "    (entrypoints/TLS — по твоей настройке Traefik)" "    (entrypoints/TLS — per your Traefik setup)" >&2
}

print_caddy_steps() {
  L "" >&2
  L "==> Добавь в Caddyfile:" "==> Add to your Caddyfile:" >&2
  cat >&2 <<EOF
$1 {
    reverse_proxy openrouter-proxy:80
}
EOF
  L "    (Caddy сам получит сертификат)" "    (Caddy obtains the certificate automatically)" >&2
}

ask_proxy() {
  local choice P net det PORT ip
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
        net="${det##*|}"
        write_override "$net"
        L "  найден: ${det%%|*}; сеть: $net → compose.override.yml записан" "  found: ${det%%|*}; network: $net → compose.override.yml written" >&2
      else
        L "  не нашёл автоматически. Контейнер будет доступен только на 127.0.0.1." "  could not detect it automatically. The container will only listen on 127.0.0.1." >&2
        L "  Вручную: docker ps → docker inspect <контейнер> (смотри Networks)," "  Manually: docker ps → docker inspect <container> (see Networks)," >&2
        L "  затем скопируй examples/<твой-прокси>/compose.override.yml рядом с compose.yml," "  then copy examples/<your-proxy>/compose.override.yml next to compose.yml," >&2
        L "  впиши имя сети и запусти: docker compose up -d" "  put the network name in, and run: docker compose up -d" >&2
      fi
      case "$P" in
        1) print_pangolin_steps "${FQDN_OUT:-your.domain}" "${PREFIX_OUT:-YOUR_PREFIX}" ;;
        2) print_npm_steps "${FQDN_OUT:-your.domain}" ;;
        3) print_traefik_steps "${FQDN_OUT:-your.domain}" ;;
        4) print_caddy_steps "${FQDN_OUT:-your.domain}" ;;
      esac
      ;;
    5)
      L "" >&2
      L "==> Голый nginx: вставь в свою конфигурацию (TLS — твой, например certbot):" "==> Plain nginx: add this to your config (TLS is yours, e.g. certbot):" >&2
      cat >&2 <<EOF
server {
    listen 443 ssl;
    server_name ${FQDN_OUT:-your.domain};
    # ssl_certificate     /path/fullchain.pem;
    # ssl_certificate_key /path/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${BIND_PORT:-8080};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;              # SSE streaming
        proxy_read_timeout 600s;
    }
}
EOF
      ;;
    6)
      PORT=$(ask "Порт, который слушает этот сервер (Enter = 8080):" "Port this server should listen on (Enter = 8080):" "8080")
      BIND_IP_OUT="0.0.0.0"; BIND_PORT_OUT="$PORT"
      ip=$(public_ip)
      L "" >&2
      L "==> Настрой реверс-прокси на ДРУГОЙ машине на http://$ip:$PORT" "==> Point the reverse proxy on the OTHER machine at http://$ip:$PORT" >&2
      L "    Префикс НЕ вырезай у себя — его обрабатывает контейнер. Пример (nginx там):" "    Do NOT strip the prefix there — the container handles it. Example (nginx there):" >&2
      cat >&2 <<EOF
location / {
    proxy_pass http://$ip:$PORT;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_read_timeout 600s;
}
EOF
      L "    Порт открыт наружу — секретный префикс остаётся единственным замком." "    The port is public — the secret prefix is now the only gate." >&2
      ;;
    7)
      L "" >&2
      L "==> Реверс-прокси не настроен — это за рамками проекта." "==> No reverse proxy — that is outside this project's scope." >&2
      L "    Самый простой вариант — Caddy (сертификаты сам): https://caddyserver.com/" "    Simplest option — Caddy (automatic certificates): https://caddyserver.com/" >&2
      L "    Поставишь — запусти установщик снова, он доделает связку." "    Once it is up, run this installer again and it will wire things up." >&2
      NO_PROXY=1
      ;;
  esac
}

# ---------- env file ---------------------------------------------------------
write_env() {
  {
    echo "# Generated by install.sh"
    echo "SECRET_PREFIX=${PREFIX_OUT}"
    echo "UPSTREAM_URL=${UPSTREAM_URL_OUT}"
    echo "UPSTREAM_HOST=${UPSTREAM_HOST_OUT}"
    echo "DOMAIN=${FQDN_OUT}"
    echo "PROXY_TYPE=${PROXY_OUT}"
    [[ -n "${BIND_IP_OUT:-}" ]]    && echo "BIND_IP=${BIND_IP_OUT}"
    [[ -n "${BIND_PORT_OUT:-}" ]]  && echo "BIND_PORT=${BIND_PORT_OUT}"
  } > "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
}

env_get() { grep -E "^$1=" "$INSTALL_DIR/.env" 2>/dev/null | head -n1 | cut -d= -f2-; }

# ---------- main -------------------------------------------------------------
main() {
  say() { L "==> $1" "==> $2"; }

  L "openrouter-passthrough — установка" "openrouter-passthrough — installer" >&2
  L "=====================================" "=====================================" >&2

  preflight
  fetch_files

  # existing .env?
  PREFIX_OUT=""; UPSTREAM_URL_OUT=""; UPSTREAM_HOST_OUT=""; FQDN_OUT=""; PROXY_OUT=""
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    local ans
    ans=$(ask "Найден существующий .env — использовать его? (Enter = да, r = перенастроить):" \
               "Existing .env found — use it? (Enter = yes, r = reconfigure):" "")
    if [[ "$ans" != "r" && "$ans" != "R" ]]; then
      PREFIX_OUT=$(env_get SECRET_PREFIX)
      UPSTREAM_URL_OUT=$(env_get UPSTREAM_URL); UPSTREAM_URL_OUT=${UPSTREAM_URL_OUT:-https://openrouter.ai}
      UPSTREAM_HOST_OUT=$(env_get UPSTREAM_HOST); UPSTREAM_HOST_OUT=${UPSTREAM_HOST_OUT:-openrouter.ai}
      FQDN_OUT=$(env_get DOMAIN)
      if [[ -z "$FQDN_OUT" ]]; then choose_domain; fi
    else
      choose_upstream; choose_prefix; choose_domain
    fi
  else
    probe_table
    choose_upstream
    choose_prefix
    choose_domain
  fi

  ask_proxy

  if [[ "${NO_PROXY:-0}" == "1" ]]; then
    PROXY_OUT="none"
    write_env
    (cd "$INSTALL_DIR" && docker compose up -d)
    exit 0
  fi

  write_env
  say "Поднимаю контейнер..." "Bringing the container up..."
  (cd "$INSTALL_DIR" && docker compose up -d) || die "docker compose up не удался — смотри вывод выше" "docker compose up failed — see the output above"

  # summary
  local port="${BIND_PORT_OUT:-${BIND_PORT:-8080}}"
  sleep 2
  local code
  code=$(probe "http://127.0.0.1:${port}/${PREFIX_OUT}/api/v1/models" 10)
  L "" >&2
  L "================= ГОТОВО =================" "================= DONE =================" >&2
  L "Сервис:          openrouter-proxy" "Service:          openrouter-proxy" >&2
  L "Префикс:          $PREFIX_OUT" "Prefix:           $PREFIX_OUT" >&2
  L "Апстрим:          $UPSTREAM_URL_OUT" "Upstream:         $UPSTREAM_URL_OUT" >&2
  L "Домен:            $FQDN_OUT" "Domain:           $FQDN_OUT" >&2
  L "Base URL (в приложениях): https://$FQDN_OUT/$PREFIX_OUT" "Base URL (for apps): https://$FQDN_OUT/$PREFIX_OUT" >&2
  L "Локальный тест:   HTTP $code (http://127.0.0.1:$port/$PREFIX_OUT/api/v1/models)" "Local test:       HTTP $code (http://127.0.0.1:$port/$PREFIX_OUT/api/v1/models)" >&2
  L "  (любой HTTP-код от апстрима = связка работает)" "  (any HTTP code from the upstream edge means the chain works)" >&2
  L "Полная документация: $INSTALL_DIR/README.md" "Full docs: $INSTALL_DIR/README.md" >&2
}

# run when executed directly or piped (BASH_SOURCE empty); skip when sourced
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
  main "$@"
fi
