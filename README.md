# VPN-стек: s-ui + wg-easy + Nginx

Готовый стек для запуска на одной VPS:

- **s-ui / sing-box** — VLESS Reality, Naive, TUN и маршрутизация;
- **wg-easy v15** — управление WireGuard-клиентами;
- **Nginx** — HTTPS-доступ к панелям;
- **Certbot** — выпуск и обновление сертификата Let's Encrypt;
- **UFW** — базовая фильтрация входящего и транзитного трафика;
- один интерактивный скрипт `setup.sh` для установки, настройки, обновления и диагностики.

Контейнеры работают с `network_mode: host`. Поэтому порты не публикуются через секцию `ports:` в Docker Compose, а открываются непосредственно на хосте.

> [!CAUTION]
> В архив включена предварительно настроенная база s-ui `s-ui.db.tmp`. Она содержит конфигурацию, пользователей, клиентские данные, ключи и другие секреты. Не публикуйте эту БД и не используйте содержащиеся в ней учётные данные на новом сервере без полной ротации.
>
> После установки обязательно смените пароль администратора (admin/admin), пересоздайте клиентов и сгенерируйте новые ключи Reality/WireGuard.

## Содержание архива

```text
.
├── README.md
├── proxy-resources.json
├── block-resources.json
└── vpn-sui-wg/
    ├── docker-compose.yml
    ├── setup.sh
    └── data/
        ├── s-ui/
        │   ├── cert/
        │   └── db/
        │       └── s-ui.db.tmp
        └── wg-easy/
```

Назначение файлов:

| Файл | Назначение |
|---|---|
| `vpn-sui-wg/setup.sh` | Интерактивная установка и управление стеком |
| `vpn-sui-wg/docker-compose.yml` | Контейнеры s-ui и wg-easy |
| `vpn-sui-wg/data/s-ui/db/s-ui.db.tmp` | Предварительно настроенный шаблон БД s-ui |
| `proxy-resources.json` | Пользовательский список ресурсов для отдельной маршрутизации |
| `block-resources.json` | Пользовательский список блокировок |

## Что будет установлено

Скрипт рассчитан на Debian/Ubuntu с `apt` и выполняет следующие действия:

1. сохраняет выбранные параметры в `vpn-sui-wg/.env`;
2. устанавливает Nginx, UFW, Certbot и вспомогательные утилиты;
3. при необходимости предлагает установить Docker;
4. включает маршрутизацию IPv4 через `sysctl`;
5. выпускает SAN-сертификат Let's Encrypt;
6. создаёт конфигурацию Nginx для двух панелей;
7. настраивает UFW без сброса уже существующих правил;
8. запускает s-ui и wg-easy через Docker Compose;
9. умеет создавать резервную копию существующих контейнеров;
10. показывает состояние контейнеров, портов, Nginx, UFW и VPN-интерфейсов.

## Требования

Перед установкой понадобятся:

- VPS с Debian или Ubuntu;
- доступ `root` или пользователь с `sudo`;
- публичный IPv4-адрес;
- домен, которым вы управляете;
- открытый извне `80/tcp` для проверки Let's Encrypt;
- поддержка `/dev/net/tun`;
- установленный Docker Compose v2, доступный командой:

```bash
docker compose version
```

Если команда не работает, установите Compose v2 средствами вашей системы. Наличие только старой команды `docker-compose` недостаточно: скрипт запускает именно `docker compose`.

## DNS

Скрипт запрашивает один основной домен. Например, если указать:

```text
example.com
```

автоматически будут использоваться:

```text
example.com      — серверное имя и сертификат Naive
sui.example.com  — панель s-ui
wg.example.com   — панель wg-easy
```

До выпуска сертификата создайте три DNS-записи типа `A`, указывающие на IPv4-адрес VPS:

```text
example.com
sui.example.com
wg.example.com
```

Скрипт выпускает один SAN-сертификат на три точных имени. Это не wildcard-сертификат `*.example.com`.

## Порты

Параметры по умолчанию:

| Порт | Назначение | Доступ |
|---|---|---|
| `80/tcp` | Certbot HTTP-01 | внешний |
| `443/tcp` | sing-box, обычно VLESS | внешний |
| `443/udp` | sing-box, обычно Naive/QUIC | внешний |
| `9443/tcp` | обе HTTPS-панели через Nginx | внешний |
| `27110/udp` | WireGuard | внешний |
| `2095/tcp` | upstream панели s-ui | не открывать извне |
| `27111/tcp` | upstream панели wg-easy | слушает localhost |
| `2096/tcp` | порт подписок в шаблонной БД s-ui | по умолчанию не публикуется |

> [!IMPORTANT]
> В приложенной шаблонной БД VLESS сейчас настроен на `8443/tcp`, а установщик открывает в UFW `443/tcp`.
>
> После установки выберите один вариант:
>
> - перенесите VLESS на `443/tcp` в s-ui; или
> - оставьте `8443/tcp` и отдельно разрешите его:
>
> ```bash
> sudo ufw allow 8443/tcp comment 'VLESS Reality'
> ```

Локальные порты `2095` и `27111` не должны быть доступны из интернета. Доступ к ним выполняется через Nginx на `9443/tcp`.

## Быстрая установка

### 1. Распакуйте архив

```bash
sudo mkdir -p /opt/vpn-stack
sudo unzip vpn-stack-sui-wgeasy-nginx.zip -d /opt/vpn-stack
cd /opt/vpn-stack/vpn-sui-wg
```

Если архив распаковался в дополнительный внешний каталог, сначала перейдите в него, а затем в `vpn-sui-wg`.

### 2. Выберите режим запуска s-ui

#### Вариант A: использовать приложенную настроенную БД

Шаблон имеет расширение `.tmp`, поэтому s-ui не использует его как рабочий файл `s-ui.db`.

Создайте рабочую копию:

```bash
sudo install -m 600 \
  data/s-ui/db/s-ui.db.tmp \
  data/s-ui/db/s-ui.db
```

После запуска необходимо заменить все старые домены, пароли, клиентские UUID, Reality-ключи и WireGuard-ключи. Полный список приведён в разделе [Обязательная настройка шаблонной БД](#обязательная-настройка-шаблонной-бд).

#### Вариант B: чистая установка s-ui

Не создавайте `s-ui.db`. При первом запуске s-ui создаст новую пустую БД:

```bash
sudo rm -f data/s-ui/db/s-ui.db
```

Файл `s-ui.db.tmp` можно оставить как резервный шаблон или удалить.

### 3. Запустите установщик

В архиве `setup.sh` не имеет исполняемого бита, поэтому сначала выполните:

```bash
sudo chmod +x setup.sh
sudo ./setup.sh
```

Для первой установки выберите:

```text
1) Полная установка/настройка
```

## Меню установщика

```text
1)  Полная установка/настройка
2)  Настроить основной домен, порты и сертификат
3)  Установить Nginx, UFW, Certbot и при необходимости Docker
4)  Настроить системную маршрутизацию (sysctl)
5)  SAN-сертификат: домен + sui. + wg.
6)  Создать и применить конфиг Nginx
7)  Настроить UFW
8)  Сделать backup текущих контейнеров
9)  Запустить/обновить Docker Compose
10) Проверить состояние
11) Показать текущие параметры
0)  Выход
```

Все выбранные значения сохраняются в файле:

```text
vpn-sui-wg/.env
```

Файл создаётся с правами `600` и не должен попадать в Git.

Пример содержимого:

```dotenv
BASE_DOMAIN=example.com
PANEL_HTTPS_PORT=9443
SUI_PANEL_PORT=2095
WG_UI_PORT=27111
WG_PORT=27110
SUI_UPSTREAM_SCHEME=http
SUI_BASE_URL=/app/
LE_EMAIL=admin@example.com
CERT_PATH=/etc/letsencrypt/live/example.com/fullchain.pem
KEY_PATH=/etc/letsencrypt/live/example.com/privkey.pem
```

## Прохождение полной установки

### Основной домен и порты

При первом запуске скрипт предложит проверить или изменить:

- основной домен;
- внешний HTTPS-порт панелей;
- локальный порт s-ui;
- локальный порт wg-easy;
- UDP-порт WireGuard;
- Base URL панели s-ui;
- схему подключения Nginx к s-ui;
- email Let's Encrypt;
- пути к сертификату и ключу.

Не принимайте незнакомый домен из значения по умолчанию: обязательно введите собственный.

Рекомендуемые значения:

```text
HTTPS-порт панелей: 9443
Порт s-ui:          2095
Порт wg-easy:       27111
Порт WireGuard:     27110
Base URL s-ui:      /app/
Upstream s-ui:      http
```

Для веб-панели s-ui рекомендуется отключить встроенный TLS и использовать `http` между Nginx и `127.0.0.1:2095`. Внешний HTTPS завершает Nginx.

### UFW

Установщик:

- не выполняет `ufw reset`;
- включает `default deny incoming`;
- оставляет исходящий трафик разрешённым;
- пытается определить реальный SSH-порт;
- открывает ACME, sing-box, панели и WireGuard;
- удаляет старые прямые `allow` для локальных портов панелей;
- добавляет отдельное правило для TCP-трафика, перенаправленного `sing-box auto_redirect`;
- по отдельному подтверждению добавляет узкие FORWARD-правила `wg0 ↔ sui-tun`.

Перед включением UFW внимательно проверьте, что SSH-порт разрешён:

```bash
sudo ufw status numbered
```

Полная установка настраивает UFW до запуска контейнеров. В этот момент интерфейсы `wg0` и `sui-tun` ещё могут отсутствовать, поэтому FORWARD-правила не будут добавлены.

После настройки wg-easy и запуска TUN повторно выполните:

```bash
sudo ./setup.sh
```

и выберите:

```text
7) Настроить UFW
```

На вопрос о правилах `wg0 ↔ TUN` ответьте `Y` и укажите интерфейс:

```text
sui-tun
```

### Сертификат

В меню сертификатов выберите:

```text
1) Получить/обновить сертификат для домена + sui. + wg.
```

Скрипт проверит DNS и запросит подтверждение, что все три имени указывают на VPS и `80/tcp` доступен извне.

Полученные файлы:

```text
/etc/letsencrypt/live/example.com/fullchain.pem
/etc/letsencrypt/live/example.com/privkey.pem
```

Для обновления сертификата создаётся deploy-hook, который перезагружает Nginx.

Проверка автоматического продления:

```bash
sudo certbot renew --dry-run
```

## Адреса панелей

После установки:

```text
s-ui:    https://sui.example.com:9443/app/
wg-easy: https://wg.example.com:9443/
```

Проверка с сервера:

```bash
curl -kI https://sui.example.com:9443/app/
curl -kI https://wg.example.com:9443/
```

## Первый запуск wg-easy

Откройте:

```text
https://wg.example.com:9443/
```

В мастере укажите:

```text
Host:        публичный IP, example.com или wg.example.com
Port:        27110
IPv4 CIDR:   10.8.0.0/23
Allowed IPs: 0.0.0.0/0
```

Распределение адресов:

```text
10.8.0.x — resource: выборочная маршрутизация
10.8.1.x — full: прямой полный доступ
```

Адрес конкретного клиента задавайте вручную в нужной подсети.

### Hooks

В `Admin → Hooks` задайте:

```text
PostUp:
ip rule del pref 100 from 10.8.0.0/23 iif wg0 table 2022 2>/dev/null || true; ip rule add pref 100 from 10.8.0.0/23 iif wg0 table 2022
```

```text
PostDown:
ip rule del pref 100 from 10.8.0.0/23 iif wg0 table 2022 2>/dev/null || true
```

Не добавляйте MASQUERADE для трафика клиентов перед передачей в s-ui. Иначе sing-box увидит адрес сервера вместо реального адреса WireGuard-клиента и маршрутизация по подсетям перестанет работать.

После сохранения перезапустите интерфейс WireGuard или контейнер:

```bash
sudo docker restart wg-easy
```

Проверка правила:

```bash
ip rule show
```

Ожидаемая строка:

```text
100: from 10.8.0.0/23 iif wg0 lookup 2022
```

## Настройка TUN в s-ui

Шаблонная БД содержит TUN-входящий со следующими параметрами:

```json
{
  "type": "tun",
  "tag": "tun-wg-in",
  "interface_name": "sui-tun",
  "address": [
    "172.42.0.1/30"
  ],
  "auto_route": true,
  "auto_redirect": true,
  "strict_route": false,
  "stack": "system",
  "mtu": 9000,
  "udp_timeout": "5m",
  "include_interface": [
    "wg0"
  ]
}
```

`include_interface` задать через S-UI невозможно, поэтому может потребоваться ручная правка БД.

После запуска проверьте наличие интерфейсов:

```bash
ip -br link show wg0
ip -br link show sui-tun
```

Проверьте таблицу маршрутизации sing-box:

```bash
ip route show table 2022
```

## Маршрутизация из шаблонной БД

В шаблоне настроены:

- DNS-over-HTTPS через Cloudflare;
- стратегия DNS `ipv4_only`;
- перехват DNS через `hijack-dns`;
- блокировка BitTorrent;
- блокировка рекламы, malware, phishing и cryptominers;
- наборы доменов и IP для отдельной маршрутизации;
- прямой выход `direct`;
- внешний WireGuard endpoint `wg-ru-vps-out`;
- группы клиентов `full-access` и `resource-access`.

Предполагаемая схема:

```text
10.8.1.0/24                       → direct
10.8.0.0/24 + proxy-resources     → direct
10.8.0.0/24, остальной трафик     → wg-ru-vps-out
запрещённые rule-set и BitTorrent → reject
```

### Важная корректировка правил

В текущей шаблонной БД есть раннее правило, которое отправляет **обе** подсети:

```text
10.8.1.0/24
10.8.0.0/24
```

в `direct`. Из-за порядка правил более поздний fallback на `wg-ru-vps-out` для `10.8.0.0/24` не срабатывает.

Для описанной выше схемы откройте правила маршрутизации s-ui и оставьте в раннем правиле только:

```text
10.8.1.0/24 → direct
```

Подсеть `10.8.0.0/24` должна проходить дальше:

1. совпавшие `proxy-resources` отправляются в `direct`;
2. весь оставшийся трафик TUN отправляется в `wg-ru-vps-out`.

После изменения проверьте итоговый конфиг и перезапустите sing-box.

## Обязательная настройка шаблонной БД

Если вы скопировали `s-ui.db.tmp` в `s-ui.db`, выполните все пункты ниже.

### 1. Смените пароль администратора

В шаблоне уже существует администратор. Сразу после первого входа установите новый уникальный пароль.

Не публикуйте рабочий файл:

```text
data/s-ui/db/s-ui.db
```

### 2. Проверьте часовой пояс

В шаблоне значение часового пояса содержит скрытый посторонний символ. В настройках панели вручную установите корректное значение, например:

```text
Europe/Moscow
```

или часовой пояс вашего сервера.

### 3. Исправьте домены входящих подключений

В шаблоне сохранён старый адрес сервера. Проверьте и замените его во всех местах:

- VLESS inbound → адрес сервера;
- Naive inbound → адрес сервера;
- TLS → `server_name`;
- пути `certificate_path` и `key_path`;
- генерируемые клиентские ссылки;
- подписки;
- внешний WireGuard endpoint.

Для нового домена сертификат должен ссылаться на:

```text
/etc/letsencrypt/live/example.com/fullchain.pem
/etc/letsencrypt/live/example.com/privkey.pem
```

### 4. Пересоздайте Reality

Сгенерируйте новую пару Reality-ключей и новый `short_id`. Не используйте ключи, находившиеся в архиве.

Также проверьте:

```text
handshake server
server_name / SNI
listen_port
```

### 5. Пересоздайте пользователей и клиентов

Удалите тестовых клиентов из шаблона и создайте новых. Это заменит:

- UUID VLESS;
- логины и пароли Naive;
- токены и данные подписок;
- готовые клиентские URI;
- прочие протокольные пароли.

### 6. Настройте Naive TLS

У TLS-профиля Naive замените:

```text
server_name
certificate_path
key_path
```

на ваш основной домен и сертификат Let's Encrypt.

Текущая схема шаблона использует Naive/QUIC на `443/udp`.

### 7. Настройте или удалите `wg-ru-vps-out`

Шаблон содержит WireGuard endpoint на отдельный VPN-сервер. Его ключи и адрес нельзя использовать как универсальные значения.

Выберите одно:

- замените адрес, порт, private key, public key, preshared key и клиентский адрес на параметры своего внешнего WireGuard-сервера;
- удалите endpoint и измените маршрутизацию на другой outbound;
- временно отправляйте fallback в `direct`, пока внешний сервер не настроен.

### 8. Исправьте правило подсетей

Удалите `10.8.0.0/24` из раннего правила `direct`, как описано в разделе [Важная корректировка правил](#важная-корректировка-правил).

### 9. Проверьте порт VLESS

Шаблон использует `8443/tcp`. Либо перенесите VLESS на `443/tcp`, либо разрешите `8443/tcp` в UFW.

### 10. Проверьте порт подписок

В БД задан отдельный порт подписок `2096` и путь `/sub/`, но установщик не открывает этот порт и не создаёт для него отдельный Nginx upstream.

Рекомендуется не публиковать `2096` напрямую. При необходимости добавьте отдельный HTTPS virtual host или location в Nginx, проксирующий запросы на:

```text
http://127.0.0.1:2096
```

Дополнительно используйте непредсказуемый путь/секрет подписки и не размещайте простые угадываемые URL.

## Пользовательские rule-set

Файлы в корне архива:

```text
proxy-resources.json
block-resources.json
```

имеют формат sing-box rule-set source:

```json
{
  "version": 4,
  "rules": []
}
```

Шаблонная БД загружает эти списки как **remote rule-set по HTTPS**. Простое редактирование локальных файлов рядом с README не меняет работающую конфигурацию s-ui.

После изменения файла необходимо:

1. опубликовать его по доступному HTTPS-URL, например через GitHub Raw;
2. заменить URL соответствующего rule-set в s-ui либо сохранить существующий URL своего репозитория;
3. дождаться `update_interval` или перезапустить sing-box.

В шаблоне интервал обновления:

```text
1d
```

Пример списка доменов:

```json
{
  "version": 4,
  "rules": [
    {
      "domain_suffix": [
        "example.com",
        "example.org"
      ]
    }
  ]
}
```

Пример блокировки адреса клиента:

```json
{
  "version": 4,
  "rules": [
    {
      "source_ip_cidr": [
        "10.8.0.50/32"
      ]
    }
  ]
}
```

## Проверка после установки

### Контейнеры

```bash
cd /opt/vpn-stack/vpn-sui-wg
sudo docker compose ps
```

Логи:

```bash
sudo docker compose logs --tail=200 s-ui
sudo docker compose logs --tail=200 wg-easy
```

Потоковый просмотр:

```bash
sudo docker compose logs -f s-ui wg-easy
```

### Порты

```bash
sudo ss -lntup | grep -E ':(80|443|9443|8443|2095|2096|27110|27111)\b'
```

### Nginx

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager
```

Логи панелей:

```bash
sudo tail -n 100 /var/log/nginx/s-ui-panel.error.log
sudo tail -n 100 /var/log/nginx/wg-easy-panel.error.log
```

### UFW

```bash
sudo ufw status verbose
sudo ufw status numbered
```

### WireGuard

```bash
sudo wg show
ip -br addr show wg0
```

### Маршрутизация

```bash
ip rule show
ip route show table 2022
ip -br addr show sui-tun
```

Проверка маршрута для клиента:

```bash
ip route get 1.1.1.1 from 10.8.0.2 iif wg0
```

Ожидается использование таблицы `2022` и интерфейса `sui-tun`.

## Обновление

Перед обновлением рекомендуется создать backup:

```bash
sudo ./setup.sh
```

Выберите:

```text
8) Сделать backup текущих контейнеров
```

Затем:

```text
9) Запустить/обновить Docker Compose
```

Скрипт выполнит:

```bash
docker compose pull
docker compose up -d
```

## Резервные копии

Backup создаётся в:

```text
vpn-sui-wg/backups/YYYYMMDD-HHMMSS.tar.gz
```

Архив включает:

- БД s-ui;
- сертификаты из каталога s-ui;
- данные wg-easy;
- `docker inspect`;
- список контейнеров.

Каталог `backups/` исключён из Git.

### Ручной backup

```bash
cd /opt/vpn-stack/vpn-sui-wg
sudo tar -czf "vpn-backup-$(date +%F-%H%M%S).tar.gz" \
  .env \
  docker-compose.yml \
  data/
```

## Миграция существующей установки

При обнаружении контейнеров с именами `s-ui` или `wg-easy` установщик предлагает:

1. создать backup;
2. скопировать текущую БД и сертификаты s-ui;
3. скопировать данные wg-easy v15;
4. остановить и удалить конфликтующие контейнеры;
5. запустить новый Compose.

Данные старого образа `weejewel/wg-easy` автоматически не подставляются в wg-easy v15. Экспортируйте backup из старой панели и импортируйте его в v15 либо создайте клиентов заново.

## Устранение проблем

### `docker compose` недоступен

Проверьте:

```bash
docker --version
docker compose version
```

Скрипту нужен Compose v2. Старый бинарник `docker-compose` не удовлетворяет этой проверке.

### Certbot не получает сертификат

Проверьте DNS:

```bash
getent ahostsv4 example.com
getent ahostsv4 sui.example.com
getent ahostsv4 wg.example.com
```

Проверьте порт 80:

```bash
sudo ss -lntp | grep ':80 '
sudo ufw status
```

Проверьте Nginx:

```bash
sudo nginx -t
sudo journalctl -u nginx -n 100 --no-pager
```

### Панель возвращает `502 Bad Gateway`

Проверьте локальные upstream:

```bash
curl -I http://127.0.0.1:2095/app/
curl -I http://127.0.0.1:27111/
```

Проверьте контейнеры и логи:

```bash
sudo docker compose ps
sudo docker compose logs --tail=200 s-ui wg-easy
```

Если в s-ui оставлен встроенный HTTPS, установите в `.env`:

```dotenv
SUI_UPSTREAM_SCHEME=https
```

и повторно выполните пункт `6` меню установщика.

### WireGuard подключается, но интернет не работает

Проверьте последовательно:

```bash
sudo wg show
ip -br link show wg0
ip -br link show sui-tun
ip rule show
ip route show table 2022
sudo ufw status numbered
```

Убедитесь, что присутствует правило:

```text
from 10.8.0.0/23 iif wg0 lookup 2022
```

Если интерфейсы появились уже после первоначальной настройки UFW, повторно запустите пункт `7` установщика и добавьте FORWARD-правила `wg0 ↔ sui-tun`.

### VLESS не подключается

Проверьте несоответствие порта:

```bash
sudo ss -lntp | grep -E ':(443|8443)\b'
sudo ufw status
```

Шаблонная БД слушает `8443/tcp`, а стандартное правило установщика открывает `443/tcp`.

Также проверьте:

- адрес сервера в inbound;
- Reality `server_name`;
- Reality public/private key;
- `short_id`;
- UUID клиента;
- порт в клиентской ссылке.

### Naive не подключается

Проверьте:

- `443/udp` в `ss` и UFW;
- пути сертификата и ключа;
- `server_name`;
- имя пользователя и пароль;
- что клиент поддерживает используемый режим Naive/QUIC;
- логи sing-box.

### Изменения `proxy-resources.json` не применяются

Локальный файл не читается контейнером автоматически. Проверьте URL remote rule-set в s-ui и доступность опубликованного файла:

```bash
curl -fL 'HTTPS_URL_ВАШЕГО_RULE_SET'
```

## Полезные команды

Перезапуск всего стека:

```bash
sudo docker compose restart
```

Перезапуск только s-ui:

```bash
sudo docker compose restart s-ui
```

Перезапуск только wg-easy:

```bash
sudo docker compose restart wg-easy
```

Остановка:

```bash
sudo docker compose down
```

Запуск:

```bash
sudo docker compose up -d
```

Проверка итогового Compose:

```bash
sudo docker compose config
```

Повторный запуск управляющего меню:

```bash
cd /opt/vpn-stack/vpn-sui-wg
sudo ./setup.sh
```

## Безопасность

После успешной установки:

1. смените пароль администратора s-ui;
2. задайте надёжный пароль wg-easy;
3. пересоздайте всех клиентов из шаблона;
4. замените Reality-ключи и `short_id`;
5. замените ключи внешнего WireGuard endpoint;
6. не публикуйте `.env`, `s-ui.db`, backup и конфигурацию wg-easy;
7. не открывайте напрямую `2095`, `2096` и `27111` без необходимости;
8. ограничьте доступ к `9443/tcp` по IP, если панели не должны быть доступны всему интернету;
9. регулярно обновляйте контейнеры и проверяйте backup;
10. после публикации архива с рабочей БД считайте все содержащиеся в ней секреты скомпрометированными;
11. для воспроизводимых обновлений закрепите проверенные версии образов вместо плавающих тегов.
