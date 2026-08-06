#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT}/.env"
COMPOSE_FILE="${ROOT}/docker-compose.yml"

NGINX_SITE="/etc/nginx/sites-available/vpn-panels.conf"
NGINX_LINK="/etc/nginx/sites-enabled/vpn-panels.conf"
NGINX_ACME_SITE="/etc/nginx/sites-available/vpn-panels-acme.conf"
NGINX_ACME_LINK="/etc/nginx/sites-enabled/vpn-panels-acme.conf"
SYSCTL_FILE="/etc/sysctl.d/90-vpn-routing.conf"
UFW_BEFORE_RULES="/etc/ufw/before.rules"

# Значения по умолчанию. После первой настройки сохраняются в .env.
BASE_DOMAIN="${BASE_DOMAIN:-tembra.ru}"
SUI_DOMAIN="sui.${BASE_DOMAIN}"
WG_DOMAIN="wg.${BASE_DOMAIN}"

PANEL_HTTPS_PORT="${PANEL_HTTPS_PORT:-9443}"
SUI_PANEL_PORT="${SUI_PANEL_PORT:-2095}"
WG_UI_PORT="${WG_UI_PORT:-27111}"
WG_PORT="${WG_PORT:-27110}"
SUI_UPSTREAM_SCHEME="${SUI_UPSTREAM_SCHEME:-http}"
SUI_BASE_URL="${SUI_BASE_URL:-/app/}"
LE_EMAIL="${LE_EMAIL:-}"

# Один SAN-сертификат:
#   BASE_DOMAIN     — Naive;
#   sui.BASE_DOMAIN — панель s-ui;
#   wg.BASE_DOMAIN  — панель wg-easy.
CERT_PATH="${CERT_PATH:-/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem}"
KEY_PATH="${KEY_PATH:-/etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem}"

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

warn() {
  printf '\033[1;33mВНИМАНИЕ: %s\033[0m\n' "$*" >&2
}

die() {
  printf '\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2
  exit 1
}

pause() {
  read -r -p $'\nНажми Enter для продолжения...'
}

yes_no() {
  local question="$1"
  local default="${2:-N}"
  local answer suffix

  if [[ "${default^^}" == "Y" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  read -r -p "${question} ${suffix}: " answer
  answer="${answer:-$default}"

  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ||
     "${answer,,}" == "д" || "${answer,,}" == "да" ]]
}

prompt_value() {
  local variable="$1"
  local label="$2"
  local current="${!variable:-}"
  local value

  read -r -p "${label} [${current}]: " value
  printf -v "${variable}" '%s' "${value:-$current}"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт через sudo: sudo ./setup.sh"
}

refresh_derived_settings() {
  SUI_DOMAIN="sui.${BASE_DOMAIN}"
  WG_DOMAIN="wg.${BASE_DOMAIN}"
}

load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi

  refresh_derived_settings
  CERT_PATH="${CERT_PATH:-/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem}"
  KEY_PATH="${KEY_PATH:-/etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem}"
}

save_config() {
  refresh_derived_settings

  cat >"${CONFIG_FILE}" <<EOF
BASE_DOMAIN=${BASE_DOMAIN}
PANEL_HTTPS_PORT=${PANEL_HTTPS_PORT}
SUI_PANEL_PORT=${SUI_PANEL_PORT}
WG_UI_PORT=${WG_UI_PORT}
WG_PORT=${WG_PORT}
SUI_UPSTREAM_SCHEME=${SUI_UPSTREAM_SCHEME}
SUI_BASE_URL=${SUI_BASE_URL}
LE_EMAIL=${LE_EMAIL}
CERT_PATH=${CERT_PATH}
KEY_PATH=${KEY_PATH}
EOF
  chmod 600 "${CONFIG_FILE}"
  log "Настройки сохранены в ${CONFIG_FILE}"
}

validate_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  (( value >= 1 && value <= 65535 ))
}

validate_settings() {
  [[ "${BASE_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] ||
    die "Некорректный основной домен: ${BASE_DOMAIN}"

  [[ "${BASE_DOMAIN}" == *.* ]] ||
    die "Основной домен должен содержать точку, например example.com"

  refresh_derived_settings

  for port in \
    "${PANEL_HTTPS_PORT}" "${SUI_PANEL_PORT}" \
    "${WG_UI_PORT}" "${WG_PORT}"; do
    validate_port "${port}" || die "Некорректный порт: ${port}"
  done

  [[ "${SUI_UPSTREAM_SCHEME}" == "http" ||
     "${SUI_UPSTREAM_SCHEME}" == "https" ]] ||
    die "SUI_UPSTREAM_SCHEME должен быть http или https"

  [[ "${SUI_BASE_URL}" == /* ]] ||
    die "Base URL s-ui должен начинаться с /"
}

configure_settings() {
  load_config

  log "Настройка параметров"
  echo "Укажи один основной домен."
  echo "Поддомены создаются автоматически:"
  echo "  sui.<домен>"
  echo "  wg.<домен>"
  echo
  echo "Сертификат выпускается сразу для:"
  echo "  основного домена — Naive"
  echo "  sui.<домен>      — панель s-ui"
  echo "  wg.<домен>       — панель wg-easy"
  echo
  echo "443 остаётся у sing-box. Nginx слушает отдельный HTTPS-порт."

  local old_base_domain="${BASE_DOMAIN}"
  prompt_value BASE_DOMAIN "Основной домен, например tembra.ru"
  refresh_derived_settings

  prompt_value PANEL_HTTPS_PORT "Внешний HTTPS-порт панелей"
  prompt_value SUI_PANEL_PORT "Локальный порт панели s-ui"
  prompt_value WG_UI_PORT "Локальный порт панели wg-easy"
  prompt_value WG_PORT "UDP-порт WireGuard"
  prompt_value SUI_BASE_URL "Base URL панели s-ui"

  echo
  echo "Как Nginx подключается к локальной панели s-ui:"
  echo "  http  — сертификат веб-панели s-ui отключён (рекомендуется)"
  echo "  https — встроенный HTTPS панели s-ui пока оставлен"
  prompt_value SUI_UPSTREAM_SCHEME "Схема upstream s-ui (http/https)"

  prompt_value LE_EMAIL "Email Let's Encrypt (можно оставить пустым)"

  local default_cert="/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem"
  local default_key="/etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem"

  if [[ "${BASE_DOMAIN}" != "${old_base_domain}" ]] ||
     yes_no "Использовать стандартный путь сертификата ${BASE_DOMAIN}?" "Y"; then
    CERT_PATH="${default_cert}"
    KEY_PATH="${default_key}"
  else
    prompt_value CERT_PATH "Путь к fullchain.pem"
    prompt_value KEY_PATH "Путь к privkey.pem"
  fi

  validate_settings
  save_config

  echo
  show_config
}

ensure_config() {
  load_config
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    configure_settings
  fi
  load_config
  validate_settings
}

show_config() {
  load_config
  cat <<EOF
Текущие параметры:
  Основной домен: ${BASE_DOMAIN}
  Naive/SNI:      ${BASE_DOMAIN}

  s-ui:           https://${SUI_DOMAIN}:${PANEL_HTTPS_PORT}${SUI_BASE_URL}
  wg-easy:        https://${WG_DOMAIN}:${PANEL_HTTPS_PORT}/
  WireGuard:      ${WG_DOMAIN}:${WG_PORT}/udp

  Nginx → s-ui:    ${SUI_UPSTREAM_SCHEME}://127.0.0.1:${SUI_PANEL_PORT}
  Nginx → wg-easy: http://127.0.0.1:${WG_UI_PORT}

  Сертификат: ${CERT_PATH}
  Ключ:       ${KEY_PATH}

  SAN-имена:
    ${BASE_DOMAIN}
    ${SUI_DOMAIN}
    ${WG_DOMAIN}
EOF
}

install_packages() {
  require_root
  log "Установка Nginx, UFW, Certbot и утилит"

  command -v apt-get >/dev/null 2>&1 ||
    die "Этот установщик рассчитан на Debian/Ubuntu с apt."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nginx ufw certbot curl ca-certificates openssl

  systemctl enable nginx >/dev/null
  systemctl enable --now nginx

  if ! command -v docker >/dev/null 2>&1; then
    if yes_no "Docker не найден. Установить docker.io из репозитория Debian?" "Y"; then
      apt-get install -y docker.io
      systemctl enable --now docker
    else
      warn "Docker не установлен. Запуск Compose будет недоступен."
    fi
  fi

  if command -v docker >/dev/null 2>&1 &&
     ! docker compose version >/dev/null 2>&1; then
    if yes_no "Docker Compose не найден. Установить пакет docker-compose?" "Y"; then
      apt-get install -y docker-compose
    fi
  fi

  log "Пакеты установлены"
}

configure_sysctl() {
  require_root
  log "Настройка маршрутизации ядра для host network"

  cat >"${SYSCTL_FILE}" <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF

  sysctl --system >/dev/null

  sysctl net.ipv4.ip_forward
  sysctl net.ipv4.conf.all.src_valid_mark
}

write_acme_nginx_config() {
  require_root
  ensure_config

  install -d -m 0755 /var/www/letsencrypt
  install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled

  cat >"${NGINX_ACME_SITE}" <<EOF
server {
    listen 80;
    server_name ${BASE_DOMAIN} ${SUI_DOMAIN} ${WG_DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF

  ln -sfn "${NGINX_ACME_SITE}" "${NGINX_ACME_LINK}"

  # Старый полный конфиг с отсутствующим сертификатом может мешать
  # первоначальному получению сертификата.
  if ! nginx -t >/dev/null 2>&1; then
    rm -f "${NGINX_LINK}"
  fi

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_certificate() {
  require_root
  ensure_config

  command -v certbot >/dev/null 2>&1 || install_packages

  log "Проверка DNS"
  for domain in "${BASE_DOMAIN}" "${SUI_DOMAIN}" "${WG_DOMAIN}"; do
    echo "${domain}:"
    getent ahostsv4 "${domain}" |
      awk '{print "  " $1}' |
      sort -u || true
  done

  echo
  echo "Один SAN-сертификат будет выпущен на:"
  echo "  ${BASE_DOMAIN}"
  echo "  ${SUI_DOMAIN}"
  echo "  ${WG_DOMAIN}"
  echo
  echo "Это не wildcard: сертификат покрывает именно эти три имени."

  if ! yes_no "Все три DNS-имени указывают на VPS и порт 80 доступен извне?" "N"; then
    warn "Получение сертификата отменено."
    return
  fi

  write_acme_nginx_config

  local email_args=()
  if [[ -n "${LE_EMAIL}" ]]; then
    email_args=(--email "${LE_EMAIL}")
  else
    email_args=(--register-unsafely-without-email)
  fi

  log "Получение сертификата для домена, sui. и wg."
  certbot certonly \
    --webroot \
    --webroot-path /var/www/letsencrypt \
    --cert-name "${BASE_DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --expand \
    "${email_args[@]}" \
    -d "${BASE_DOMAIN}" \
    -d "${SUI_DOMAIN}" \
    -d "${WG_DOMAIN}"

  CERT_PATH="/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem"
  KEY_PATH="/etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem"
  save_config

  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  log "Сертификат получен"
  openssl x509 -in "${CERT_PATH}" \
    -noout -subject -issuer -dates -ext subjectAltName

  echo
  echo "Для Naive в s-ui:"
  echo "  SNI/server_name: ${BASE_DOMAIN}"
  echo "  certificate:     ${CERT_PATH}"
  echo "  private key:     ${KEY_PATH}"
}

set_existing_certificates() {
  require_root
  ensure_config

  log "Указание существующего SAN-сертификата"
  echo "Он должен содержать:"
  echo "  ${BASE_DOMAIN}"
  echo "  ${SUI_DOMAIN}"
  echo "  ${WG_DOMAIN}"

  prompt_value CERT_PATH "Путь к fullchain.pem"
  prompt_value KEY_PATH "Путь к privkey.pem"

  [[ -r "${CERT_PATH}" ]] ||
    die "Файл не найден или не читается: ${CERT_PATH}"
  [[ -r "${KEY_PATH}" ]] ||
    die "Файл не найден или не читается: ${KEY_PATH}"

  save_config

  openssl x509 -in "${CERT_PATH}" \
    -noout -subject -issuer -dates -ext subjectAltName
}

certificate_menu() {
  while true; do
    cat <<'EOF'

Сертификаты:
  1) Получить/обновить сертификат для домена + sui. + wg.
  2) Указать существующие сертификаты
  3) Показать текущий сертификат
  0) Назад
EOF
    read -r -p "Выбери действие: " choice
    case "${choice}" in
      1) issue_certificate ;;
      2) set_existing_certificates ;;
      3)
        ensure_config
        if [[ -r "${CERT_PATH}" ]]; then
          openssl x509 -in "${CERT_PATH}" \
            -noout -subject -issuer -dates -ext subjectAltName
        else
          warn "Сертификат не найден: ${CERT_PATH}"
        fi
        ;;
      0) return ;;
      *) warn "Неизвестный пункт" ;;
    esac
  done
}

configure_nginx() {
  require_root
  ensure_config
  command -v nginx >/dev/null 2>&1 || install_packages

  for file in "${CERT_PATH}" "${KEY_PATH}"; do
    [[ -r "${file}" ]] || {
      warn "Не найден сертификат или ключ: ${file}"
      if yes_no "Перейти к настройке сертификата?" "Y"; then
        certificate_menu
        ensure_config
      else
        return
      fi
      break
    }
  done

  for file in "${CERT_PATH}" "${KEY_PATH}"; do
    [[ -r "${file}" ]] || die "Файл не найден: ${file}"
  done

  log "Генерация Nginx-конфига"

  install -d -m 0755 /var/www/letsencrypt
  install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled

  cat >"${NGINX_SITE}" <<EOF
# 443 намеренно остаётся у sing-box.
# Обе панели работают на ${PANEL_HTTPS_PORT}, различаясь по домену.

server {
    listen 80;
    server_name ${BASE_DOMAIN} ${SUI_DOMAIN} ${WG_DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}

server {
    listen ${PANEL_HTTPS_PORT} ssl;
    server_name ${SUI_DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:VPN_PANEL_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    access_log /var/log/nginx/s-ui-panel.access.log;
    error_log  /var/log/nginx/s-ui-panel.error.log warn;

    location / {
        proxy_pass ${SUI_UPSTREAM_SCHEME}://127.0.0.1:${SUI_PANEL_PORT};
        proxy_ssl_verify off;
        proxy_ssl_server_name off;

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

server {
    listen ${PANEL_HTTPS_PORT} ssl;
    server_name ${WG_DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:VPN_PANEL_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    access_log /var/log/nginx/wg-easy-panel.access.log;
    error_log  /var/log/nginx/wg-easy-panel.error.log warn;

    location / {
        proxy_pass http://127.0.0.1:${WG_UI_PORT};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  ln -sfn "${NGINX_SITE}" "${NGINX_LINK}"
  rm -f "${NGINX_ACME_LINK}" "${NGINX_ACME_SITE}"

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  log "Nginx настроен"
  show_config
}

detect_ssh_ports() {
  local ports=""

  if command -v sshd >/dev/null 2>&1; then
    ports="$(sshd -T 2>/dev/null |
      awk '$1 == "port" {print $2}' |
      sort -nu || true)"
  fi

  if [[ -z "${ports}" ]]; then
    ports="$(ss -lntp 2>/dev/null |
      awk '/sshd/ {
        addr=$4
        sub(/^.*:/, "", addr)
        if (addr ~ /^[0-9]+$/) print addr
      }' | sort -nu || true)"
  fi

  printf '%s\n' "${ports}"
}

ensure_ufw_singbox_redirect_rule() {
  require_root

  local rule
  local backup_file
  local tmp_file

  rule='-A ufw-before-input -i wg0 -s 10.8.0.0/23 -p tcp -m conntrack --ctstate DNAT -j ACCEPT'

  [[ -f "${UFW_BEFORE_RULES}" ]] ||
    die "Не найден файл UFW: ${UFW_BEFORE_RULES}"

  if grep -Fqx -- "${rule}" "${UFW_BEFORE_RULES}"; then
    log "Правило UFW для TCP auto_redirect sing-box уже установлено"
    return
  fi

  grep -Eq '^[[:space:]]*\*filter[[:space:]]*$' "${UFW_BEFORE_RULES}" ||
    die "В ${UFW_BEFORE_RULES} не найдена секция *filter"

  backup_file="${UFW_BEFORE_RULES}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "${UFW_BEFORE_RULES}" "${backup_file}"

  tmp_file="$(mktemp)"
  if ! awk -v rule="${rule}" '
    BEGIN {
      in_filter = 0
      inserted = 0
    }

    /^[[:space:]]*\*filter[[:space:]]*$/ {
      in_filter = 1
    }

    in_filter && /^[[:space:]]*COMMIT[[:space:]]*$/ && !inserted {
      print ""
      print "# BEGIN s-ui WireGuard transparent redirect"
      print "# Allow only TCP connections already redirected by sing-box auto_redirect."
      print rule
      print "# END s-ui WireGuard transparent redirect"
      print ""
      inserted = 1
      in_filter = 0
    }

    {
      print
    }

    END {
      if (!inserted) {
        exit 42
      }
    }
  ' "${UFW_BEFORE_RULES}" >"${tmp_file}"; then
    rm -f "${tmp_file}"
    die "Не удалось вставить правило в секцию *filter. Backup: ${backup_file}"
  fi

  cat "${tmp_file}" >"${UFW_BEFORE_RULES}"
  rm -f "${tmp_file}"

  log "Добавлено постоянное правило UFW для TCP auto_redirect sing-box"
  echo "  Файл:  ${UFW_BEFORE_RULES}"
  echo "  Backup: ${backup_file}"
}

configure_ufw_forwarding() {
  local tun_interface

  read -r -p "Имя TUN-интерфейса sing-box [sui-tun]: " tun_interface
  tun_interface="${tun_interface:-sui-tun}"

  if ! ip link show wg0 >/dev/null 2>&1; then
    warn "Интерфейс wg0 ещё не существует. FORWARD-правила не добавлены."
    return
  fi

  if ! ip link show "${tun_interface}" >/dev/null 2>&1; then
    warn "Интерфейс ${tun_interface} ещё не существует. FORWARD-правила не добавлены."
    return
  fi

  ufw route allow \
    in on wg0 \
    out on "${tun_interface}" \
    from 10.8.0.0/23 \
    comment 'WireGuard to sing-box TUN'

  ufw route allow \
    in on "${tun_interface}" \
    out on wg0 \
    to 10.8.0.0/23 \
    comment 'sing-box TUN to WireGuard'

  log "Добавлены только узкие правила wg0 ↔ ${tun_interface}"
}

configure_ufw() {
  require_root
  ensure_config
  command -v ufw >/dev/null 2>&1 || install_packages

  log "Настройка UFW без сброса существующих правил"

  echo "Будут разрешены:"
  echo "  80/tcp                   — Certbot HTTP-01"
  echo "  443/tcp и 443/udp        — VLESS/Naive"
  echo "  ${PANEL_HTTPS_PORT}/tcp             — HTTPS панелей через Nginx"
  echo "  ${WG_PORT}/udp            — WireGuard"
  echo "  TCP DNAT с wg0            — sing-box auto_redirect"
  echo
  echo "Явные deny для ${SUI_PANEL_PORT} и ${WG_UI_PORT} не добавляются:"
  echo "их закрывает default deny incoming."

  if ! yes_no "Продолжить настройку UFW?" "Y"; then
    return
  fi

  ufw default deny incoming
  ufw default allow outgoing

  local ssh_ports
  ssh_ports="$(detect_ssh_ports)"

  if [[ -n "${ssh_ports}" ]]; then
    echo "Обнаружены SSH-порты:"
    echo "${ssh_ports}" | sed 's/^/  /'
    if yes_no "Разрешить обнаруженные SSH-порты?" "Y"; then
      while read -r port; do
        [[ -n "${port}" ]] &&
          ufw allow "${port}/tcp" comment 'SSH'
      done <<<"${ssh_ports}"
    fi
  else
    warn "Автоматически определить SSH-порт не удалось."
    local ssh_port="22"
    prompt_value ssh_port "SSH-порт"
    validate_port "${ssh_port}" || die "Некорректный SSH-порт"
    ufw allow "${ssh_port}/tcp" comment 'SSH'
  fi

  ufw allow 80/tcp comment 'ACME HTTP-01'
  ufw allow 443/tcp comment 'sing-box TCP'
  ufw allow 443/udp comment 'sing-box UDP'
  ufw allow "${PANEL_HTTPS_PORT}/tcp" comment 'VPN panels via Nginx'
  ufw allow "${WG_PORT}/udp" comment 'WireGuard'

  # Удаляем только возможные старые прямые allow-правила панелей.
  # Явные deny не создаём.
  ufw --force delete allow "${SUI_PANEL_PORT}/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "${WG_UI_PORT}/tcp" >/dev/null 2>&1 || true

  if yes_no "Добавить узкие FORWARD-правила wg0 ↔ TUN сейчас?" "N"; then
    configure_ufw_forwarding
  fi

  ensure_ufw_singbox_redirect_rule

  ufw status verbose

  if ufw status | grep -q '^Status: inactive'; then
    warn "UFW пока выключен."
    if yes_no "Включить UFW сейчас? Убедись, что SSH разрешён." "N"; then
      ufw --force enable
    fi
  else
    ufw reload
  fi

  ufw status numbered
}

backup_existing() {
  require_root
  command -v docker >/dev/null 2>&1 || {
    warn "Docker не установлен — резервировать контейнеры нечего."
    return
  }

  local stamp backup_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${ROOT}/backups/${stamp}"
  mkdir -p \
    "${backup_dir}/s-ui-db" \
    "${backup_dir}/s-ui-cert" \
    "${backup_dir}/wg-easy"

  log "Резервная копия текущих контейнеров"

  if docker inspect s-ui >/dev/null 2>&1; then
    docker cp s-ui:/app/db/. "${backup_dir}/s-ui-db/" || true
    docker cp s-ui:/app/cert/. "${backup_dir}/s-ui-cert/" || true
  fi

  if docker inspect wg-easy >/dev/null 2>&1; then
    docker cp wg-easy:/etc/wireguard/. "${backup_dir}/wg-easy/" || true
  fi

  docker inspect s-ui wg-easy \
    >"${backup_dir}/docker-inspect.json" 2>/dev/null || true
  docker ps -a >"${backup_dir}/docker-ps.txt"

  tar -C "${ROOT}/backups" \
    -czf "${backup_dir}.tar.gz" "${stamp}"
  rm -rf "${backup_dir}"

  log "Backup: ${backup_dir}.tar.gz"
}

directory_empty() {
  local dir="$1"
  [[ -z "$(find "${dir}" -mindepth 1 ! -name .gitkeep -print -quit 2>/dev/null)" ]]
}

import_existing_data() {
  mkdir -p \
    "${ROOT}/data/s-ui/db" \
    "${ROOT}/data/s-ui/cert" \
    "${ROOT}/data/wg-easy"

  if docker inspect s-ui >/dev/null 2>&1; then
    if directory_empty "${ROOT}/data/s-ui/db" &&
       yes_no "Скопировать БД текущего s-ui в новый каталог data/?" "Y"; then
      docker cp s-ui:/app/db/. "${ROOT}/data/s-ui/db/"
      docker cp s-ui:/app/cert/. "${ROOT}/data/s-ui/cert/" || true
    fi
  fi

  if docker inspect wg-easy >/dev/null 2>&1; then
    local image
    image="$(docker inspect wg-easy --format '{{.Config.Image}}' 2>/dev/null || true)"

    if [[ "${image}" == ghcr.io/wg-easy/wg-easy:15* ]]; then
      if directory_empty "${ROOT}/data/wg-easy" &&
         yes_no "Скопировать данные текущего wg-easy v15?" "Y"; then
        docker cp wg-easy:/etc/wireguard/. "${ROOT}/data/wg-easy/"
      fi
    else
      warn "Обнаружен старый wg-easy (${image})."
      warn "Его данные сохранены в backup, но автоматически в v15 не импортируются."
      warn "Экспортируй backup из старой панели и импортируй его в v15."
    fi
  fi
}

remove_conflicting_containers() {
  local found=0 container

  for container in s-ui wg-easy; do
    if docker inspect "${container}" >/dev/null 2>&1; then
      found=1
      echo "Найден существующий контейнер: ${container}"
    fi
  done

  if (( found == 0 )); then
    return
  fi

  if yes_no "Остановить и удалить существующие контейнеры s-ui/wg-easy?" "N"; then
    docker rm -f s-ui wg-easy 2>/dev/null || true
  else
    die "Новые контейнеры не смогут использовать те же имена и порты."
  fi
}

start_stack() {
  require_root
  ensure_config

  if ! command -v docker >/dev/null 2>&1 ||
     ! docker compose version >/dev/null 2>&1; then
    warn "Docker или Docker Compose не найден."
    if yes_no "Перейти к установке пакетов?" "Y"; then
      install_packages
    fi
  fi

  command -v docker >/dev/null 2>&1 ||
    die "Docker не установлен."
  docker compose version >/dev/null 2>&1 ||
    die "Команда docker compose недоступна."

  mkdir -p \
    "${ROOT}/data/s-ui/db" \
    "${ROOT}/data/s-ui/cert" \
    "${ROOT}/data/wg-easy"

  if docker inspect s-ui >/dev/null 2>&1 ||
     docker inspect wg-easy >/dev/null 2>&1; then
    if yes_no "Сделать backup существующих контейнеров?" "Y"; then
      backup_existing
    fi
    import_existing_data
    remove_conflicting_containers
  fi

  log "Проверка Compose"
  cd "${ROOT}"
  docker compose config >/dev/null

  log "Загрузка и запуск контейнеров"
  docker compose pull
  docker compose up -d

  docker compose ps

  echo
  warn "После первого входа в wg-easy установи:"
  echo "  IPv4 CIDR: 10.8.0.0/23"
  echo "  Resource:  10.8.0.x"
  echo "  Full:      10.8.1.x"
  echo "  PostUp:"
  echo "    ip rule del pref 100 from 10.8.0.0/23 iif wg0 table 2022 2>/dev/null || true; ip rule add pref 100 from 10.8.0.0/23 iif wg0 table 2022"
  echo "  PostDown:"
  echo "    ip rule del pref 100 from 10.8.0.0/23 iif wg0 table 2022 2>/dev/null || true"
}

check_status() {
  require_root
  ensure_config

  log "Слушающие порты"
  ss -lntup |
    grep -E ":(${PANEL_HTTPS_PORT}|${SUI_PANEL_PORT}|${WG_UI_PORT}|${WG_PORT}|443|80)\b" ||
    true

  echo
  log "Docker"
  if command -v docker >/dev/null 2>&1; then
    cd "${ROOT}"
    docker compose ps || true
  fi

  echo
  log "Nginx"
  if command -v nginx >/dev/null 2>&1; then
    nginx -t || true
    systemctl --no-pager --full status nginx |
      sed -n '1,14p' || true
  fi

  echo
  log "UFW"
  command -v ufw >/dev/null 2>&1 && ufw status verbose || true

  echo
  log "WireGuard/TUN"
  ip -br link show |
    grep -E '(^| )(wg0|sui-tun|tun)' || true
  command -v wg >/dev/null 2>&1 && wg show || true

  echo
  log "Проверка HTTPS"
  curl -kfsSI --max-time 10 \
    "https://${SUI_DOMAIN}:${PANEL_HTTPS_PORT}${SUI_BASE_URL}" |
    head -n 5 || true
  curl -kfsSI --max-time 10 \
    "https://${WG_DOMAIN}:${PANEL_HTTPS_PORT}/" |
    head -n 5 || true
}

full_setup() {
  require_root

  configure_settings
  install_packages
  configure_sysctl
  configure_ufw

  echo
  if [[ -r "${CERT_PATH}" && -r "${KEY_PATH}" ]]; then
    if ! yes_no "Найдены указанные сертификаты. Использовать их?" "Y"; then
      certificate_menu
    fi
  else
    certificate_menu
  fi

  configure_nginx
  start_stack
  check_status
}

main_menu() {
  require_root
  load_config

  while true; do
    cat <<'EOF'

============================================================
 s-ui + wg-easy + Nginx — установка и настройка
============================================================
  1) Полная установка/настройка
  2) Настроить основной домен, порты и сертификат
  3) Установить Nginx, UFW, Certbot и при необходимости Docker
  4) Настроить системную маршрутизацию (sysctl)
  5) SAN-сертификат: домен + sui. + wg.
  6) Создать и применить конфиг Nginx
  7) Настроить UFW
  8) Сделать backup текущих контейнеров
  9) Запустить/обновить Docker Compose
 10) Проверить состояние
 11) Показать текущие параметры
  0) Выход
EOF

    read -r -p "Выбери действие: " choice

    case "${choice}" in
      1) full_setup ;;
      2) configure_settings ;;
      3) install_packages ;;
      4) configure_sysctl ;;
      5) certificate_menu ;;
      6) configure_nginx ;;
      7) configure_ufw ;;
      8) backup_existing ;;
      9) start_stack ;;
      10) check_status ;;
      11) ensure_config; show_config ;;
      0) exit 0 ;;
      *) warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

main_menu
