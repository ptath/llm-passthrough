# Nginx Proxy Manager

## Вариант A (рекомендуется): контейнер из этого репо + форвард

1. Возьмите `examples/pangolin/compose.override.yml`, положите рядом с `compose.yml` как `compose.override.yml` и замените имя сети на сеть вашего NPM:

   ```bash
   docker ps    # найдите контейнер NPM
   docker inspect <npm-container> --format '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}'
   ```

   (обычно это `npm_default`)

2. `./install.sh` из корня репо.
3. В NPM: **Hosts → Proxy Hosts → Add Proxy Host**:
   - **Domain**: `openrouter.example.com`
   - **Forward**: scheme `http`, hostname `openrouter-proxy`, port `80`
   - **Websockets**: ON (стриминг SSE)
   - **Caching**: off, **Block common exploits**: если начнутся странности с API — выключите
   - **SSL**: выпустите серт (Request a new certificate) + Force SSL
4. Проверка — curl из README корня репо.

Плюс этого варианта: секретный префикс и конфиг полностью соответствуют проверенному пути репо.

## Вариант B (без контейнера, менее проверен)

NPM умеет форвардить на https-хост, но UI не даёт вырезать секретный префикс — защита сводится к сокрытию домена:

1. **Proxy Host**: Domain `openrouter.example.com`
2. **Forward**: scheme `https`, hostname `openrouter.ai`, port `443`
3. **Websockets**: ON
4. Вкладка **Advanced**:

   ```nginx
   proxy_set_header Host openrouter.ai;
   proxy_ssl_server_name on;
   proxy_ssl_name openrouter.ai;
   proxy_buffering off;
   proxy_read_timeout 600s;
   proxy_send_timeout 600s;
   ```

Если получаете 403/404 от OpenRouter — проверьте, что advanced-директивы реально применились (см. логи и `nginx -T` внутри контейнера NPM).
