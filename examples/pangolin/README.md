# Pangolin (коннектор на той же машине)

Сценарий: сервер Pangolin где-то ещё (или тут же), а на этом VPS крутится его коннектор (`fosrl/pangolin-cli` / `newt`). Ресурс объявляется в дашборде Pangolin и указывает на контейнер из этого репо.

## 1. Подключить контейнер к сети коннектора

Скопируйте `compose.override.yml` из этой папки рядом с `compose.yml` и укажите имя сети вашего коннектора:

```bash
docker ps    # найдите контейнер коннектора (pangolin-cli / newt)
docker inspect <имя-коннектора> --format '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}'
```

## 2. Установка

`./install.sh` из корня репо — override подхватится автоматически. Порты наружу не нужны: трафик пойдёт по внутренней docker-сети (127.0.0.1:8080 из базового compose — только для отладки).

## 3. Ресурс в дашборде Pangolin

Resources → Create Resource:

- **Site** — сайт этого коннектора
- **Domain** — `openrouter.example.com` (поддомен вашего домена; его DNS должен указывать на сервер Pangolin)
- **Target** — метод `http`, адрес `openrouter-proxy`, порт `80` (имя резолвится по docker-сети; **не** `127.0.0.1` — у коннектора свой loopback)
- **Authentication** — выключить (иначе API-клиенты со своим `Authorization` не пройдут)
- **Bot protection / блокеры** — выключить

## 4. Health check

Коннектор раз в 30 секунд опрашивает `GET /` на таргете и ждёт 2xx — иначе таргет уходит в unhealthy, а ресурс отдаёт `503 no available server`. Шаблон из репо уже отвечает 200 на `GET /`: если переписываете шаблон — не удаляйте этот location.

## 5. Проверка

```bash
curl -s https://openrouter.example.com/<SECRET_PREFIX>/api/v1/models | head -c 200
```
