# llm-passthrough

Крошечный passthrough-реверс-прокси для [OpenRouter](https://openrouter.ai) и любого другого LLM API, недоступного из вашего региона. Официальный образ `nginx:alpine`, без сборок, ~10 МБ RAM. Ставится за вашим реверс-прокси — Pangolin, Caddy, Nginx Proxy Manager, Traefik или голым nginx.

**v0.4.1** · beta · [MIT](LICENSE)

> ⚠️ **Дисклеймер.** Обход региональных ограничений может нарушать ToS апстрима — есть риск для аккаунта. Всё, что вы делаете, вы делаете на свой страх и риск. Домен прокси не публикуйте, ключ храните у себя.

English short version: [README.en.md](README.en.md)

## Установка одной командой

На сервере (VPS) с root-доступом:

```bash
curl -fsSL https://raw.githubusercontent.com/ptath/llm-passthrough/main/install.sh | bash
```

Установщик сам проверит docker, покажет, какие API доступны с этой машины, спросит, что проксировать, сгенерирует секретный префикс и поддомен, найдёт твой реверс-прокси (Pangolin/NPM/Traefik/Caddy в docker) и напишет за тебя `compose.override.yml`. Можно проксировать сразу несколько API — на вопрос «Добавить ещё один прокси?» отвечай `y` (см. [ниже](#несколько-провайдеров-на-одном-сервере)). Для недоверчивых — скачать и прочитать перед запуском:

```bash
curl -fsSL https://raw.githubusercontent.com/ptath/llm-passthrough/main/install.sh -o install.sh
less install.sh && bash install.sh
```

Параметры: `--lang en` переключает диалог на английский (по умолчанию русский).

## Несколько провайдеров на одном сервере

После первого провайдера установщик спросит **«Добавить ещё один прокси?»** — ответь `y` и задай следующий апстрим, префикс и поддомен. Каждый провайдер получает:

- свой контейнер (~10 МБ RAM) в одном compose-проекте;
- свой секретный префикс;
- свой поддомен и, соответственно, свой ресурс в Pangolin (или хост в NPM, блок в Caddy/Traefik/nginx — установщик печатает инструкции по каждому).

Имена сервисов выводятся в итоговой сводке: первый всегда называется `passthrough` (имя базового сервиса из `compose.yml`, независимо от того, чей апстрим первый), остальные — по провайдеру: `openai-proxy`, `anthropic-proxy`, `gemini-proxy`, `<метка>-proxy` для своих URL.

Состояние хранится в `instances.conf` (права 600). Повторный запуск установщика:

- **Enter (keep)** — пересобирает всё из `instances.conf`, ни одного вопроса; полезно после правок или при обновлении;
- **r** — полная перенастройка с нуля.

Старую установку v0.2.x установщик подхватит: `.env` без `instances.conf` восстанавливается как один инстанс, дальше можно добавить остальные через `y`.

## Зачем

OpenRouter (как и ряд других сервисов) блокирует запросы из некоторых регионов. Если у вас есть VPS за рубежом, трафик можно заворачивать через него: приложение думает, что ходит на OpenRouter, а по факту — на ваш прокси, который пересылает запросы дальше с «правильного» IP.

```
приложение ──► ваш домен (TLS: ваш реверс-прокси)
                 └─► passthrough (этот контейнер, HTTP)
                       └─► https://openrouter.ai (SNI/Host подменяются)
```

- Приложение меняет только Base URL: `https://openrouter.example.com/<SECRET_PREFIX>` вместо `https://openrouter.ai`
- API-ключ пробрасывается как есть и нигде не хранится — прокси stateless
- Всё вне `/<SECRET_PREFIX>/` отдаёт 404 — префикс единственный «замок»
- SSE-стриминг не буферизуется, таймауты 600 с под длинные ответы

## Требования

- VPS за пределами блокируемого региона: от 1 ядра / 512 МБ RAM / 1 ГБ диска
- Docker 20+ с плагином compose (`docker compose version`)
- Домен с A-записью на этот VPS + реверс-прокси с TLS (см. таблицу ниже)

## Быстрый старт (ручная установка)

```bash
git clone https://github.com/ptath/llm-passthrough.git
cd llm-passthrough
./install.sh
```

`install.sh` можно запустить и из клона — он задаст те же вопросы и не будет ничего скачивать. При первом запуске:

- создаст `.env` и сгенерирует случайный `SECRET_PREFIX` (32 hex-символа); свой вариант можно задать заранее: `SECRET_PREFIX=my-long-prefix ./install.sh` — или потом отредактировать `.env` и сделать `docker compose up -d`
- поднимет контейнер, слушающий `127.0.0.1:8080` (только loopback, для локальных проверок)

### Где взять SECRET_PREFIX

Префикс печатается в конце `install.sh` и лежит в `.env`. Посмотреть ещё раз:

```bash
grep SECRET_PREFIX .env
```

Base URL для приложений: `https://твой-домен/<SECRET_PREFIX>` — приложения сами дописывают `/api/v1`.

Если `.env` потерялся, а контейнер ещё работает — префикс можно вытащить из его окружения:

```bash
docker compose exec passthrough env | grep SECRET_PREFIX
```

Пересоздайте `.env` с этим же значением — тогда конфигурацию приложений менять не придётся.

Дальше — подключение к вашему реверс-прокси:

| У вас стоит | Что делать |
|---|---|
| [Pangolin](examples/pangolin/README.md) (коннектор на этой же машине) | `compose.override.yml` + ресурс в UI |
| [Caddy](examples/caddy/Caddyfile.example) | контейнер не нужен — сниппет в Caddyfile |
| [Nginx Proxy Manager](examples/nginx-proxy-manager/README.md) | proxy host, два варианта |
| [Traefik](examples/traefik/dynamic.yml) | динамический конфиг |
| Голый nginx | см. ниже |

## Голый nginx (без Docker)

Полный аналог контейнерного варианта — вставьте в свою конфигурацию:

```nginx
server {
    listen 80;                      # TLS терминирует ваш внешний слой (certbot и т.п.)
    client_max_body_size 100m;

    location = / { default_type text/plain; return 200 "ok\n"; }  # health checks коннекторов

    location = /CHANGE_ME { return 301 /CHANGE_ME/$is_args$args; }
    location /CHANGE_ME/ {
        resolver 1.1.1.1 8.8.8.8 valid=300s;
        set $or https://openrouter.ai;          # set строго ДО rewrite ... break!
        rewrite ^/CHANGE_ME/(.*)$ /$1 break;
        proxy_pass $or;
        proxy_ssl_server_name on;
        proxy_ssl_name openrouter.ai;
        proxy_set_header Host openrouter.ai;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;                    # иначе SSE приходит одним куском
        proxy_cache off;
        proxy_read_timeout  600s;
        proxy_send_timeout  600s;
    }
    location / { return 404; }
}
```

## Проверка

```bash
# 1) связка жива (ожидаем 200 и JSON со списком моделей)
curl -s https://openrouter.example.com/<SECRET_PREFIX>/api/v1/models | head -c 200

# 2) API с вашим ключом
curl -s https://openrouter.example.com/<SECRET_PREFIX>/api/v1/chat/completions \
  -H "Authorization: Bearer sk-or-ВАШ-КЛЮЧ" -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":20}'

# 3) стриминг: токены должны приходить постепенно, не одним куском
curl -N https://openrouter.example.com/<SECRET_PREFIX>/api/v1/chat/completions \
  -H "Authorization: Bearer sk-or-ВАШ-КЛЮЧ" -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-4o-mini","stream":true,"messages":[{"role":"user","content":"10 пунктов"}],"max_tokens":300}'
```

## Переменные

| Переменная | По умолчанию | Описание |
|---|---|---|
| `SECRET_PREFIX` | генерируется install.sh | обязательна; часть ваших URL |
| `UPSTREAM_URL` | `https://openrouter.ai` | куда форвардить |
| `UPSTREAM_HOST` | `openrouter.ai` | SNI/Host для апстрима |
| `BIND_IP` / `BIND_PORT` | `127.0.0.1` / `8080` | адрес отладочного листенера; для прокси на другой машине — `0.0.0.0` и открытый порт |

Другой API — меняются две переменные, например OpenAI: `UPSTREAM_URL=https://api.openai.com`, `UPSTREAM_HOST=api.openai.com`. Пути проксируются как есть, так что заведётся и Anthropic (`/v1/messages`), и любой другой HTTP API.

В мультипровайдерной установке `.env` относится к первому инстансу; остальные вписаны установщиком в `compose.override.yml`, а состояние хранится в `instances.conf` — правь их через повторный запуск `install.sh` (Enter = keep, r = перенастройка), а не руками.

## Коды ответов

| Код | Причина |
|---|---|
| 200 | работает |
| 401 | неверный/пустой ключ апстрима |
| 403 | апстрим блокирует IP вашего VPS (редко) или не сработала подмена Host |
| 404 | пропущен или неверен `SECRET_PREFIX` |
| 429 | rate limit вашего тарифа апстрима — прокси не при чём |
| 503 | (Pangolin) таргет unhealthy — см. Troubleshooting |

## Troubleshooting

- **503 «no available server» с Pangolin.** Коннектор раз в 30 с дёргает `GET /` на таргете и ждёт 2xx; иначе помечает таргет unhealthy. В шаблоне `GET /` уже отвечает 200 — не удаляйте этот location. В ресурсе Pangolin выключите авторизацию и bot protection.
- **OpenAI: пустой 404 на `GET /v1/models` через прокси.** Фильтр Cloudflare режет GET-запросы с TLS-отпечатком nginx; `POST`-ы (`/v1/chat/completions`) с ключом проходят нормально — это штатная ошибка 401 «invalid key». Для проверки связки по OpenAI используйте POST или любой путь с ключом; 404 от апстрима не означает, что прокси сломан.
- **Ответы приходят одним куском.** Где-то включена буферизация: у nginx — `proxy_buffering off`, в NPM — включите Websockets, в Caddy и Traefik стриминг по умолчанию.
- **Обрывы длинных ответов.** Таймауты: проверьте `proxy_read_timeout` у себя и таймауты вашего реверс-прокси.
- **Ротация префикса.** Правьте `.env` → `docker compose up -d`. При рестарте за Pangolin будет ~30 сек 503 (health check перезаходит).
- **`.env` потерялся.** Если контейнер ещё работает, достаньте префикс из его окружения: `docker compose exec passthrough env | grep SECRET_PREFIX` — пересоздайте `.env` с этим же значением, приложения трогать не придётся. Если контейнер уже пересоздан — запустите `./install.sh` заново: префикс будет новый, обновите Base URL в приложениях.

## Безопасность

- `SECRET_PREFIX` — единственная защита эндпоинта. Держите его длинным и случайным, домен не публикуйте.
- Реальный ключ API живёт только в ваших приложениях; прокси ничего не хранит.
- `.env` в `.gitignore`, права 600 ставит `install.sh`.
- Обновление: `git pull && docker compose up -d`.

## FAQ

**Можно ли поручить деплой AI-агенту?** Да — дайте агенту ссылку на репозиторий: в `AGENTS.md` описаны проверка условий (нужен VPS/VDS, с которого есть прямой доступ к сервису), порядок установки и меры предосторожности.

**Почему не Cloudflare Worker?** Можно и Worker; здесь — свой VPS, полный контроль и независимость от CF.

**Почему не LiteLLM / one-api?** Это шлюзы (виртуальные ключи, лимиты, логи), им нужно 300+ МБ RAM и БД. Здесь задача одна — достучаться, и это ~10 МБ RAM.

**Несколько апстримов?** Теперь штатно: при установке ответь `y` на вопрос «Добавить ещё один прокси?» — каждый провайдер получит свой контейнер, префикс и поддомен (см. [«Несколько провайдеров»](#несколько-провайдеров-на-одном-сервере)). Ручной вариант для отдельных проектов: скопируй папку, в её `compose.yml` переименуй сервис (`passthrough:` под `services:` — это имя станет DNS-именем в общей сети), в её `.env` поменяй префикс и апстрим; проект изолируется через `COMPOSE_PROJECT_NAME` в её `.env`.

## Лицензия

[MIT](LICENSE)
