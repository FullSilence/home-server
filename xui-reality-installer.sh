#!/usr/bin/env bash
# Установщик XUI Reality с интеграцией Cloudflare
# Производственный скрипт с интерактивным меню
# Этот скрипт автоматизирует установку XUI с поддержкой протокола VLESS REALITY + XHTTP
# Он включает в себя интеграцию с Cloudflare для автоматического управления DNS-записями
# и SSL-сертификатами, настройку nginx для decoy-сайта и защиту через брандмауэр

# Устанавливаем строгие параметры выполнения для обеспечения надежности и безопасности:
# -E: Наследовать ERR-трассировку
# -e: Выходить при ошибках в командах
# -u: Выходить при использовании неопределенных переменных
# -o pipefail: Выходить при ошибках в конвейере
set -Eeuo pipefail

# Значения по умолчанию для различных параметров системы
readonly SCRIPT_NAME=$(basename "$0")  # Имя текущего скрипта
readonly DEFAULT_DECOY_PORT=8443       # Порт для decoy-сайта (по умолчанию 8443, слушает только localhost)
readonly DEFAULT_PANEL_PREFIX="/site/" # Префикс пути для панели управления XUI
readonly DEFAULT_UI_MIN_PORT=20000     # Минимальный порт для UI-панели
readonly DEFAULT_UI_MAX_PORT=40000     # Максимальный порт для UI-панели
readonly LOG_FILE="/var/log/xui-install.log"  # Файл для логирования операций
readonly BACKUP_DIR="/root/xui-backups"       # Директория для хранения резервных копий

# Глобальные переменные (будут установлены во время настройки)
DOMAIN=""              # Домен для настройки (например, example.com)
CF_API_TOKEN=""        # API-токен Cloudflare для автоматизации DNS и SSL
XUI_ADMIN_USER=""      # Имя администратора для панели XUI
XUI_ADMIN_PASS=""      # Пароль администратора для панели XUI
PANEL_PATH=""          # Случайно сгенерированный путь к панели управления
UI_PORT=""             # Случайно выбранный свободный порт для UI-панели (20000-40000)
REALITY_SERVERNAME=""  # Серверное имя для REALITY (SNI - Server Name Indication)
REALITY_DEST=""        # Назначение для REALITY (куда направлять трафик)
REALITY_SHORT_ID=""    # Короткий идентификатор для REALITY

# Функция логирования для записи сообщений в файл и на экран
# Принимает уровень важности сообщения (INFO, ERROR, WARNING и т.д.) и само сообщение
# Формат: [Дата и время] [Уровень] Сообщение
log() {
    local level="$1"  # Уровень важности сообщения (INFO, ERROR, WARNING и т.д.)
    shift             # Сдвигаем аргументы, чтобы $* содержал только сообщение
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# Функция для выхода с ошибкой
# Записывает сообщение об ошибке в лог и завершает выполнение скрипта с кодом 1
error_exit() {
    log "ERROR" "$1"  # Записываем сообщение об ошибке в лог
    exit 1           # Завершаем выполнение скрипта с кодом ошибки
}

# Устанавливаем перехватчик (trap) для обработки ошибок
# При возникновении любой ошибки будет вызвана функция error_handler
# с указанием номера строки и команды, вызвавшей ошибку
trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

# Функция обработки ошибок
# Записывает информацию о строке и команде, вызвавшей ошибку, в лог
error_handler() {
    local line_number=$1  # Номер строки, где произошла ошибка
    local command="$2"    # Команда, вызвавшая ошибку
    log "ERROR" "Error occurred at line $line_number: $command"
    exit 1               # Завершаем выполнение скрипта с кодом ошибки
}

# Функция установки необходимых пакетов
# Проверяет и устанавливает все зависимости, необходимые для работы системы
install_required_packages() {
    log "INFO" "Installing required packages"  # Записываем информацию в лог
    
    # Обновляем список пакетов из репозиториев
    apt-get update
    
    # Устанавливаем необходимые пакеты:
    # curl - для выполнения HTTP-запросов к API Cloudflare
    # wget - для скачивания файлов
    # jq - для обработки JSON-ответов от API
    # openssl - для генерации ключей и сертификатов
    # nginx-full - веб-сервер для decoy-сайта и прокси
    # socat - для сетевых операций
    # ufw - для настройки брандмауэра
    # net-tools - для команд сетевой диагностики (ss, netstat)
    # dnsutils - для команд DNS-диагностики (dig, nslookup)
    apt-get install -y curl wget jq openssl nginx-full socat ufw net-tools dnsutils
}

# Функция проверки прав суперпользователя
# Проверяет, запущен ли скрипт с правами root, и завершает работу с ошибкой, если нет
check_root() {
    if [[ $EUID -ne 0 ]]; then  # $EUID содержит эффективный UID пользователя
        error_exit "This script must be run as root"  # Завершаем с ошибкой, если не root
    fi
}

# Функция генерации случайной строки
# Создает строку из букв и цифр заданной длины (по умолчанию 16 символов)
generate_random_string() {
    local length=${1:-16}  # Длина строки (по умолчанию 16, если не указано)
    # Генерируем случайные символы A-Z, a-z, 0-9 из /dev/urandom
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

# Функция получения свободного порта в заданном диапазоне
# Возвращает случайный свободный порт между min_port и max_port
get_free_port() {
    local min_port=${1:-$DEFAULT_UI_MIN_PORT}  # Минимальный порт (по умолчанию из константы)
    local max_port=${2:-$DEFAULT_UI_MAX_PORT}  # Максимальный порт (по умолчанию из константы)
    
    # Цикл до тех пор, пока не найдем свободный порт
    while true; do
        # Генерируем случайный порт в заданном диапазоне
        local port=$((RANDOM % (max_port - min_port + 1) + min_port))
        
        # Проверяем, доступен ли порт (не используется ли он другим процессом)
        if ! ss -tuln | grep -q ":$port " && ! lsof -i :"$port" >/dev/null 2>&1; then
            echo "$port"  # Возвращаем свободный порт
            return
        fi
    done
}

# Функция проверки формата доменного имени
# Проверяет, соответствует ли домен стандартному формату доменного имени
validate_domain() {
    local domain="$1"  # Домен, который нужно проверить
    
    # Проверяем формат домена с помощью регулярного выражения:
    # - начинается с буквы или цифры
    # - может содержать буквы, цифры и дефисы (но не в начале и конце)
    # - имеет корректное доменное расширение
    if [[ ! $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
        error_exit "Invalid domain format: $domain"  # Завершаем с ошибкой при неверном формате
    fi
}

# Функция получения идентификатора зоны Cloudflare
# Получает уникальный ID зоны Cloudflare для указанного домена через API
get_cloudflare_zone_id() {
    local domain="$1"  # Домен, для которого нужно получить Zone ID
    log "INFO" "Getting Cloudflare Zone ID for domain: $domain"  # Логируем начало процесса
    
    # Выполняем GET-запрос к API Cloudflare для получения информации о зонах
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$domain&status=active" \
        -H "Authorization: Bearer $CF_API_TOKEN" \  # Заголовок авторизации с API-токеном
        -H "Content-Type: application/json")        # Указываем тип контента
    
    # Извлекаем статус успешности операции из ответа
    local success
    success=$(echo "$response" | jq -r '.success')
    
    # Проверяем, была ли операция успешной
    if [[ "$success" != "true" ]]; then
        # Извлекаем и показываем сообщение об ошибке из ответа API
        error_exit "Failed to get zone ID: $(echo "$response" | jq -r '.errors[0].message')"
    fi
    
    # Извлекаем идентификатор зоны из ответа API
    local zone_id
    zone_id=$(echo "$response" | jq -r '.result[0].id')
    
    # Проверяем, был ли получен действительный идентификатор зоны
    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        error_exit "Zone ID not found for domain: $domain"  # Завершаем с ошибкой, если ID не найден
    fi
    
    echo "$zone_id"  # Возвращаем идентификатор зоны
}

# Функция создания/обновления DNS-записей
# Создает или обновляет A-записи для домена и опционально для www-поддомена через Cloudflare API
update_dns_records() {
    local zone_id="$1"      # Идентификатор зоны Cloudflare
    local ip_address="$2"   # IP-адрес, который будет установлен в DNS-записи
    
    log "INFO" "Updating DNS records for domain: $DOMAIN"  # Логируем начало процесса
    
    # Получаем существующую A-запись для домена
    local existing_a_record_id
    existing_a_record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')
    
    # Определяем метод (POST для создания, PUT для обновления) и эндпоинт
    local method="POST"
    local endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
    local payload
    # Подготавливаем JSON-данные для запроса: тип записи A, имя домена, IP-адрес, TTL=1 (авто), проксирование включено
    payload=$(jq -n --arg name "$DOMAIN" --arg ip "$ip_address" '{"type":"A","name":$name,"content":$ip,"ttl":1,"proxied":true}')
    
    # Если запись уже существует, изменяем метод на PUT и указываем конкретный эндпоинт для обновления
    if [[ -n "$existing_a_record_id" && "$existing_a_record_id" != "null" ]]; then
        method="PUT"
        endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$existing_a_record_id"
    fi
    
    # Выполняем запрос к API Cloudflare для создания или обновления A-записи
    local response
    response=$(curl -s -X "$method" "$endpoint" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    # Проверяем успешность операции
    local success
    success=$(echo "$response" | jq -r '.success')
    
    if [[ "$success" != "true" ]]; then
        # В случае ошибки извлекаем и показываем сообщение об ошибке
        error_exit "Failed to update A record: $(echo "$response" | jq -r '.errors[0].message')"
    fi
    
    log "INFO" "A record updated successfully"  # Логируем успешное обновление
    
    # Опционально создаем DNS-запись для www-поддомена
    read -rp "Do you want to create a DNS record for www.$DOMAIN? (y/n): " create_www
    if [[ "$create_www" =~ ^[Yy]$ ]]; then
        # Получаем существующую A-запись для www-поддомена
        local existing_www_record_id
        existing_www_record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=www.$DOMAIN" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" | jq -r '.result[0].id')
        
        # Определяем метод и эндпоинт для www-записи
        local www_method="POST"
        local www_endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
        local www_payload
        # Подготавливаем JSON-данные для www-поддомена
        www_payload=$(jq -n --arg name "www.$DOMAIN" --arg ip "$ip_address" '{"type":"A","name":$name,"content":$ip,"ttl":1,"proxied":true}')
        
        # Если www-запись уже существует, изменяем метод на PUT
        if [[ -n "$existing_www_record_id" && "$existing_www_record_id" != "null" ]]; then
            www_method="PUT"
            www_endpoint="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$existing_www_record_id"
        fi
        
        # Выполняем запрос к API Cloudflare для создания или обновления www A-записи
        local www_response
        www_response=$(curl -s -X "$www_method" "$www_endpoint" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$www_payload")
        
        # Проверяем успешность операции для www-записи
        local www_success
        www_success=$(echo "$www_response" | jq -r '.success')
        
        if [[ "$www_success" != "true" ]]; then
            # В случае ошибки извлекаем и показываем сообщение об ошибке
            error_exit "Failed to update www A record: $(echo "$www_response" | jq -r '.errors[0].message')"
        fi
        
        log "INFO" "www A record updated successfully"  # Логируем успешное обновление www-записи
    fi
}

# Функция генерации SSL-сертификата Cloudflare Origin CA
# Создает SSL-сертификат для указанного домена через Cloudflare API
generate_origin_ca_cert() {
    local zone_id="$1"  # Идентификатор зоны Cloudflare
    
    log "INFO" "Generating Cloudflare Origin CA certificate for: $DOMAIN"  # Логируем начало процесса
    
    # Создаем директорию для хранения сертификатов
    local cert_dir="/etc/ssl/cloudflare/${DOMAIN}"
    mkdir -p "$cert_dir"
    
    # Подготавливаем JSON-данные для запроса сертификата
    # hostnames: домены, для которых создается сертификат
    # request_type: тип сертификата (origin-rsa - RSA ключи для Origin CA)
    # requested_validity: срок действия в днях (5475 дней = примерно 15 лет)
    local payload
    payload=$(jq -n --arg hostnames "[\"$DOMAIN\", \"www.$DOMAIN\"]" --arg csr "" '{"hostnames":$hostnames|fromjson,"request_type":"origin-rsa","requested_validity":5475}')
    
    # Выполняем POST-запрос к API Cloudflare для генерации сертификата
    local response
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/origin_ca/certificates" \
        -H "Authorization: Bearer $CF_API_TOKEN" \  # Заголовок авторизации с API-токеном
        -H "Content-Type: application/json" \       # Указываем тип контента
        -d "$payload")                              # Передаем подготовленные данные
    
    # Проверяем успешность операции
    local success
    success=$(echo "$response" | jq -r '.success')
    
    if [[ "$success" != "true" ]]; then
        # В случае ошибки извлекаем и показываем сообщение об ошибке
        error_exit "Failed to generate Origin CA certificate: $(echo "$response" | jq -r '.errors[0].message')"
    fi
    
    # Извлекаем сертификат и приватный ключ из ответа API
    local certificate
    certificate=$(echo "$response" | jq -r '.result.certificate')
    local private_key
    private_key=$(echo "$response" | jq -r '.result.private_key')
    
    # Сохраняем сертификат и приватный ключ в файлы
    echo "$certificate" > "$cert_dir/cert.pem"  # Публичный сертификат
    echo "$private_key" > "$cert_dir/key.pem"   # Приватный ключ
    
    # Устанавливаем безопасные права доступа к приватному ключу (только владелец может читать/писать)
    chmod 600 "$cert_dir/key.pem"
    
    log "INFO" "Origin CA certificate saved to $cert_dir"  # Логируем успешное сохранение
}

# Функция установки и настройки nginx
# Устанавливает и настраивает nginx для работы как decoy-сайт и прокси для панели XUI
install_nginx() {
    log "INFO" "Installing and configuring nginx"  # Логируем начало процесса
    
    # Устанавливаем nginx если еще не установлен
    apt-get update
    apt-get install -y nginx
    
    # Настраиваем nginx для прослушивания только на localhost
    local nginx_conf="/etc/nginx/sites-available/xui-decoy"  # Путь к файлу конфигурации
    local site_dir="/var/www/${DOMAIN}/site"                 # Директория для сайта
    mkdir -p "$site_dir"                                     # Создаем директорию если не существует
    
    # Создаем конфигурационный файл nginx с настройками для:
    # - прослушивания только на 127.0.0.1 (локальный доступ)
    # - SSL-шифрования с использованием сертификатов Cloudflare
    # - обслуживания основного сайта из директории site_dir
    # - проксирования запросов к панели XUI на внутренний UI_PORT
    cat > "$nginx_conf" << EOF
server {
    # Прослушиваем только на localhost, чтобы избежать внешнего доступа
    listen 127.0.0.1:$DECOY_PORT ssl;
    server_name 127.0.0.1;

    # Настройки SSL (сертификаты Cloudflare Origin CA)
    ssl_certificate /etc/ssl/cloudflare/${DOMAIN}/cert.pem;
    ssl_certificate_key /etc/ssl/cloudflare/${DOMAIN}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;  # Поддерживаемые протоколы SSL
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Обслуживание основного сайта (decoy)
    location / {
        root $site_dir;
        index index.html index.htm;
        try_files \$uri \$uri/ =404;
    }

    # Прокси для панели XUI по специальному пути
    location $PANEL_PATH {
        proxy_pass http://127.0.0.1:$UI_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }
}
EOF
    
    # Создаем символическую ссылку для включения сайта
    ln -sf "$nginx_conf" /etc/nginx/sites-enabled/
    # Удаляем стандартный сайт по умолчанию
    rm -f /etc/nginx/sites-enabled/default
    
    # Тестируем конфигурацию nginx перед запуском
    if ! nginx -t; then
        error_exit "Nginx configuration test failed"  # Завершаем с ошибкой при неудачном тесте
    fi
    
    # Включаем автозапуск nginx при старте системы и перезапускаем сервис
    systemctl enable nginx
    systemctl restart nginx
    
    log "INFO" "Nginx configured to listen on 127.0.0.1:$DECOY_PORT"  # Логируем успешное завершение
}

# Download random website template
download_website_template() {
    log "INFO" "Downloading website template for $DOMAIN"
    
    local site_dir="/var/www/${DOMAIN}/site"
    mkdir -p "$site_dir"
    
    # List of possible template sources
    local template_urls=(
        "https://templatemag.com/templates/preview/Maxim/index.html"
        "https://bootstrapmade.com/demo/templates/Arsha/index.html"
        "https://bootstrapmade.com/demo/templates/Ninestars/index.html"
    )
    
    local downloaded=false
    
    for url in "${template_urls[@]}"; do
        log "INFO" "Trying to download template from: $url"
        
        if curl -s -L "$url" -o "$site_dir/index.html" && [[ -s "$site_dir/index.html" ]]; then
            # Basic check if it's valid HTML
            if grep -q "<html\|<HTML" "$site_dir/index.html"; then
                log "INFO" "Template downloaded successfully from: $url"
                
                # Also download some basic assets if available
                curl -s -L "$(dirname "$url")/assets/css/style.css" -o "$site_dir/assets/css/style.css" 2>/dev/null || true
                curl -s -L "$(dirname "$url")/assets/js/main.js" -o "$site_dir/assets/js/main.js" 2>/dev/null || true
                
                downloaded=true
                break
            fi
        fi
    done
    
    # If no template was downloaded, create a simple placeholder
    if [[ "$downloaded" == false ]]; then
        log "INFO" "Creating basic placeholder website"
        cat > "$site_dir/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to $DOMAIN</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 50px; text-align: center; background-color: #f0f0f0; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
        h1 { color: #333; }
        p { color: #666; line-height: 1.6; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to $DOMAIN</h1>
        <p>This is a placeholder page.</p>
        <p>If you see this page, it means the connection to the server is working properly.</p>
    </div>
</body>
</html>
EOF
    fi
    
    # Set proper permissions
    chown -R www-data:www-data "$site_dir"
}

# Функция установки и настройки 3x-ui
# Устанавливает панель управления 3x-ui и настраивает ее с заданными параметрами
install_xui() {
    log "INFO" "Installing 3x-ui panel"  # Логируем начало установки
    
    # Загружаем и запускаем официальный скрипт установки
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    
    # Ждем завершения установки
    sleep 3
    
    # Устанавливаем учетные данные администратора
    /usr/local/x-ui/x-ui setting -username "$XUI_ADMIN_USER"
    /usr/local/x-ui/x-ui setting -password "$XUI_ADMIN_PASS"
    
    # Устанавливаем пользовательский путь к панели
    /usr/local/x-ui/x-ui setting -webBasePath "$PANEL_PATH"
    
    # Перезапускаем службу для применения настроек
    systemctl restart x-ui
    
    log "INFO" "3x-ui installed and configured with custom path: $PANEL_PATH"  # Логируем успешное завершение
}

# Функция настройки XRay с протоколом Reality
# Настраивает XRay с поддержкой VLESS REALITY + XHTTP и fallback на decoy-сайт
configure_xray_reality() {
    log "INFO" "Configuring XRay with VLESS REALITY + XHTTP"  # Логируем начало процесса
    
    # Генерируем приватный ключ для протокола Reality
    local priv_key
    priv_key=$(openssl ecparam -genkey -name prime256v1 -noout)
    local priv_key_b64
    priv_key_b64=$(echo "$priv_key" | sed -n '2,$p' | sed '$d' | base64 -w 0)
    
    # Генерируем публичный ключ из приватного
    local pub_key
    pub_key=$(echo "$priv_key" | openssl ec -pubout)
    local pub_key_b64
    pub_key_b64=$(echo "$pub_key" | sed -n '2,$p' | sed '$d' | base64 -w 0)
    
    # Генерируем короткий идентификатор для Reality
    REALITY_SHORT_ID=$(openssl rand -hex 8 | cut -c1-8)
    
    # Создаем конфигурационный файл XRay
    local xray_config="/usr/local/x-ui/bin/config.json"
    
    # Создаем конфигурацию XRay с:
    # - портом 443 для приема внешних подключений
    # - протоколом VLESS с шифрованием none
    # - сетью xhttp для транспорта
    # - настройками Reality: privateKey, serverNames, shortIds
    # - fallback на decoy-порт для обычных HTTPS-запросов
    cat > "$xray_config" << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(openssl rand -hex 16)",  # Уникальный UUID клиента
            "flow": "xtls-rprx-vision"        # Режим flow для Reality
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",                    # Используем xhttp для транспорта
        "security": "reality",               # Включаем протокол Reality
        "realitySettings": {
          "show": false,                     # Не показывать информацию об ошибке
          "dest": "$REALITY_DEST",           # Назначение для Reality
          "xver": 0,                        # Версия PROXY protocol
          "serverNames": ["$REALITY_SERVERNAME"],  # Допустимые serverName для SNI
          "privateKey": "$priv_key_b64",     # Приватный ключ для шифрования
          "minClientVer": "",               # Минимальная версия клиента (любая)
          "maxClientVer": "",               # Максимальная версия клиента (любая)
          "maxTimeDiff": 0,                 # Максимальная разница во времени (0 = любая)
          "shortIds": ["$REALITY_SHORT_ID"]  # Короткие идентификаторы для клиента
        }
      },
      "sniffing": {
        "enabled": true,                     # Включаем сниффинг для определения протокола
        "destOverride": ["http", "tls", "quic"]  # Переопределяем назначение для этих протоколов
      },
      "fallbacks": [
        {
          "dest": "127.0.0.1:$DECOY_PORT"   # Fallback на decoy-порт для обычных HTTPS-запросов
        }
      ]
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",                 # Выход в интернет
      "tag": "direct"
    }
  ]
}
EOF
    
    # Проверяем правильность конфигурации XRay
    if ! /usr/local/x-ui/bin/xray -test -config="$xray_config"; then
        error_exit "XRay configuration validation failed"  # Завершаем с ошибкой при неудачной проверке
    fi
    
    # Перезапускаем XRay через сервис x-ui
    systemctl restart x-ui
    
    log "INFO" "XRay configured with Reality protocol"  # Логируем успешное завершение
}

# Функция настройки брандмауэра UFW
# Настраивает правила брандмауэра для безопасности сервера
setup_firewall() {
    log "INFO" "Setting up UFW firewall"  # Логируем начало процесса
    
    # Устанавливаем UFW если не установлен
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi
    
    # Получаем текущий порт SSH (по умолчанию 22)
    local ssh_port
    ssh_port=$(ss -tlnp | grep ':22 ' | head -n1 | awk '{print $4}' | cut -d':' -f2) || ssh_port=22
    
    # Позволяем пользователю ввести порт SSH вручную
    read -rp "Enter SSH port (default: $ssh_port): " input_ssh_port
    ssh_port="${input_ssh_port:-$ssh_port}"
    
    # Сбрасываем все текущие правила UFW
    ufw --force reset
    
    # Разрешаем необходимые порты:
    # - SSH-порт для удаленного доступа
    # - 443 порт для внешнего доступа к XRay/VLESS
    ufw allow "$ssh_port"/tcp
    ufw allow 443/tcp
    
    # Блокируем доступ к внутренним портам снаружи:
    # - DECOY_PORT (порт для decoy-сайта, доступен только локально)
    # - UI_PORT (порт для панели XUI, доступен только локально)
    ufw deny "$DECOY_PORT"/tcp
    ufw deny "$UI_PORT"/tcp
    
    # Включаем брандмауэр UFW
    ufw --force enable
    
    log "INFO" "Firewall configured with SSH($ssh_port), 443 allowed; $DECOY_PORT, $UI_PORT denied"  # Логируем успешное завершение
}

# Main installation function
perform_installation() {
    log "INFO" "Starting installation process"
    
    # Install required packages
    install_required_packages
    
    # Validate inputs
    validate_domain "$DOMAIN"
    
    # Get Cloudflare Zone ID
    local zone_id
    zone_id=$(get_cloudflare_zone_id "$DOMAIN")
    
    # Get public IP
    local public_ip
    public_ip=$(curl -s https://api.ipify.org)
    
    # Update DNS records
    update_dns_records "$zone_id" "$public_ip"
    
    # Generate Origin CA certificate
    generate_origin_ca_cert "$zone_id"
    
    # Install and configure nginx
    install_nginx
    
    # Download website template
    download_website_template
    
    # Install 3x-ui
    install_xui
    
    # Configure XRay with Reality
    configure_xray_reality
    
    # Setup firewall
    setup_firewall
    
    log "INFO" "Installation completed successfully!"
    echo ""
    echo "==============================="
    echo "Installation Summary:"
    echo "Domain: $DOMAIN"
    echo "Panel Access: https://$DOMAIN$PANEL_PATH"
    echo "Username: $XUI_ADMIN_USER"
    echo "Password: $XUI_ADMIN_PASS"
    echo "Decoy Port (local): $DECOY_PORT"
    echo "UI Port (local): $UI_PORT"
    echo "==============================="
    echo ""
    echo "Note: Remember to set SSL/TLS mode in Cloudflare to 'Full (strict)'"
    echo "The panel is accessible via the domain with the path: $DOMAIN$PANEL_PATH"
}

# Backup function
perform_backup() {
    log "INFO" "Starting backup process"
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/xui_backup_$timestamp.tar.gz"
    local sha256_file="$backup_file.sha256"
    
    mkdir -p "$BACKUP_DIR"
    
    # Create backup archive
    tar -czf "$backup_file" \
        -C /etc/nginx/sites-available xui-decoy 2>/dev/null || true \
        -C /var/www "$DOMAIN/site" \
        -C /etc/ssl/cloudflare "$DOMAIN" \
        -C /usr/local/x-ui .
    
    # Generate SHA256 checksum
    sha256sum "$backup_file" > "$sha256_file"
    
    log "INFO" "Backup created: $backup_file"
    echo "Backup file: $backup_file"
    echo "Checksum: $(cat "$sha256_file")"
}

# Restore function
perform_restore() {
    log "INFO" "Starting restore process"
    
    read -rp "Enter path to backup file (.tar.gz): " backup_path
    
    if [[ ! -f "$backup_path" ]]; then
        error_exit "Backup file does not exist: $backup_path"
    fi
    
    # Verify checksum if available
    local checksum_file="${backup_path}.sha256"
    if [[ -f "$checksum_file" ]]; then
        log "INFO" "Verifying backup integrity..."
        if ! sha256sum -c "$checksum_file"; then
            error_exit "Backup integrity check failed!"
        fi
        log "INFO" "Backup integrity verified"
    else
        log "WARNING" "No checksum file found, skipping integrity check"
    fi
    
    # Stop services
    systemctl stop x-ui nginx
    
    # Extract backup
    local temp_dir="/tmp/xui_restore_$(date +%s)"
    mkdir -p "$temp_dir"
    
    tar -xzf "$backup_path" -C "$temp_dir"
    
    # Restore configurations
    if [[ -f "$temp_dir/etc/nginx/sites-available/xui-decoy" ]]; then
        cp "$temp_dir/etc/nginx/sites-available/xui-decoy" /etc/nginx/sites-available/
        ln -sf /etc/nginx/sites-available/xui-decoy /etc/nginx/sites-enabled/
    fi
    
    if [[ -d "$temp_dir/var/www/$DOMAIN/site" ]]; then
        mkdir -p "/var/www/$DOMAIN"
        cp -r "$temp_dir/var/www/$DOMAIN/site" "/var/www/$DOMAIN/"
    fi
    
    if [[ -d "$temp_dir/etc/ssl/cloudflare/$DOMAIN" ]]; then
        mkdir -p "/etc/ssl/cloudflare/$DOMAIN"
        cp -r "$temp_dir/etc/ssl/cloudflare/$DOMAIN/"* "/etc/ssl/cloudflare/$DOMAIN/"
        chmod 600 "/etc/ssl/cloudflare/$DOMAIN/key.pem"
    fi
    
    if [[ -d "$temp_dir/usr/local/x-ui" ]]; then
        cp -r "$temp_dir/usr/local/x-ui/"* /usr/local/x-ui/
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    # Test nginx configuration
    if ! nginx -t; then
        error_exit "Nginx configuration test failed after restore"
    fi
    
    # Restart services
    systemctl start nginx
    systemctl start x-ui
    
    log "INFO" "Restore completed successfully"
}

# Status function
check_status() {
    log "INFO" "Checking system status"
    
    echo "====================="
    echo "System Status Report"
    echo "====================="
    echo ""
    
    echo "1. Systemd Services:"
    systemctl is-active x-ui && echo "  x-ui: Active" || echo "  x-ui: Inactive"
    systemctl is-active nginx && echo "  nginx: Active" || echo "  nginx: Inactive"
    echo ""
    
    echo "2. Network Ports:"
    ss -tulnp | grep -E ':(443|8443|2[0-9]{4}|3[0-9]{4})' || echo "  No matching ports found"
    echo ""
    
    echo "3. Firewall Status:"
    ufw status verbose
    echo ""
    
    echo "4. Domain Access Test:"
    if curl -s --connect-timeout 5 "https://$DOMAIN" | head -c 100; then
        echo "  Domain $DOMAIN is accessible"
    else
        echo "  Domain $DOMAIN is not accessible"
    fi
    echo ""
    
    echo "5. Panel Access Test:"
    if curl -s --connect-timeout 5 "https://$DOMAIN$PANEL_PATH" | head -c 100; then
        echo "  Panel at $DOMAIN$PANEL_PATH is accessible"
    else
        echo "  Panel at $DOMAIN$PANEL_PATH is not accessible"
    fi
    echo ""
    
    echo "6. Configuration Files:"
    echo "  - Nginx: $(test -f /etc/nginx/sites-available/xui-decoy && echo 'Exists' || echo 'Missing')"
    echo "  - SSL Cert: $(test -f /etc/ssl/cloudflare/$DOMAIN/cert.pem && echo 'Exists' || echo 'Missing')"
    echo "  - Site Files: $(test -d /var/www/$DOMAIN/site && echo 'Exists' || echo 'Missing')"
    echo ""
}

# Interactive setup function
interactive_setup() {
    echo "=================================="
    echo "XUI Reality Installation Wizard"
    echo "=================================="
    echo ""
    
    # Get domain
    read -rp "Enter your domain (apex domain without scheme): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        read -rp "Domain is required. Enter your domain: " DOMAIN
    done
    
    # Get Cloudflare API token
    read -rsp "Enter Cloudflare API token: " CF_API_TOKEN
    echo ""
    while [[ -z "$CF_API_TOKEN" ]]; do
        read -rsp "API token is required. Enter Cloudflare API token: " CF_API_TOKEN
        echo ""
    done
    
    # Get admin credentials
    read -rp "Enter admin username for XUI panel: " XUI_ADMIN_USER
    while [[ -z "$XUI_ADMIN_USER" ]]; do
        read -rp "Username is required. Enter admin username: " XUI_ADMIN_USER
    done
    
    read -rsp "Enter admin password for XUI panel: " XUI_ADMIN_PASS
    echo ""
    while [[ -z "$XUI_ADMIN_PASS" ]]; do
        read -rsp "Password is required. Enter admin password: " XUI_ADMIN_PASS
        echo ""
    done
    
    # Generate panel path
    PANEL_PATH="$DEFAULT_PANEL_PREFIX$(generate_random_string $((RANDOM % 7 + 10)))"  # 10-16 chars
    echo "Generated panel path: $PANEL_PATH"
    
    # Get decoy port (with default)
    read -rp "Enter decoy port for nginx (default: $DEFAULT_DECOY_PORT): " input_decoy_port
    DECOY_PORT="${input_decoy_port:-$DEFAULT_DECOY_PORT}"
    
    # Get UI port (random free port in range)
    UI_PORT=$(get_free_port)
    echo "Selected UI port: $UI_PORT"
    
    # Get Reality settings
    read -rp "Enter Reality server name (SNI): " REALITY_SERVERNAME
    while [[ -z "$REALITY_SERVERNAME" ]]; do
        read -rp "Server name is required. Enter Reality server name (SNI): " REALITY_SERVERNAME
    done
    
    read -rp "Enter Reality destination (e.g., www.google.com:443): " REALITY_DEST
    while [[ -z "$REALITY_DEST" ]]; do
        read -rp "Destination is required. Enter Reality destination: " REALITY_DEST
    done
    
    # Ensure panel path ends with /
    if [[ "$PANEL_PATH" != */ ]]; then
        PANEL_PATH="${PANEL_PATH}/"
    fi
    
    echo ""
    echo "=================================="
    echo "Configuration Summary:"
    echo "Domain: $DOMAIN"
    echo "CF API Token: ***$(echo "$CF_API_TOKEN" | tail -c 5)"
    echo "Admin User: $XUI_ADMIN_USER"
    echo "Admin Pass: ***$(echo "$XUI_ADMIN_PASS" | tail -c 5)"
    echo "Panel Path: $PANEL_PATH"
    echo "Decoy Port: $DECOY_PORT"
    echo "UI Port: $UI_PORT"
    echo "Reality Server Name: $REALITY_SERVERNAME"
    echo "Reality Dest: $REALITY_DEST"
    echo "=================================="
    echo ""
    
    read -rp "Proceed with installation? (y/n): " confirm_install
    if [[ ! "$confirm_install" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

# Main menu function
show_menu() {
    echo ""
    echo "=================================="
    echo "XUI Reality Manager"
    echo "=================================="
    echo "1. Install"
    echo "2. Update"
    echo "3. Backup"
    echo "4. Restore"
    echo "5. Status"
    echo "6. Exit"
    echo "=================================="
    read -rp "Select an option [1-6]: " choice
    echo ""
    
    case $choice in
        1)
            interactive_setup
            perform_installation
            ;;
        2)
            log "INFO" "Starting update process"
            
            # Check if installation exists
            if [[ ! -f /usr/local/x-ui/x-ui ]]; then
                error_exit "3x-ui is not installed. Please run install first."
            fi
            
            log "INFO" "Updating 3x-ui panel"
            
            # Backup current configuration
            perform_backup
            
            # Run the official update script
            /usr/local/x-ui/x-ui update
            
            # Restart service
            systemctl restart x-ui
            
            log "INFO" "Update completed successfully"
            ;;
        3)
            perform_backup
            ;;
        4)
            perform_restore
            ;;
        5)
            check_status
            ;;
        6)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please select 1-6."
            show_menu
            ;;
    esac
}

# Check if running interactively
if [[ -t 0 ]]; then
    check_root
    show_menu
else
    # Non-interactive mode - expect arguments
    case "${1:-}" in
        install)
            # For non-interactive install, we'd need to pass parameters
            # This is a simplified example - in practice, you'd parse environment variables or flags
            if [[ -n "${DOMAIN:-}" && -n "${CF_API_TOKEN:-}" && -n "${XUI_ADMIN_USER:-}" && -n "${XUI_ADMIN_PASS:-}" ]]; then
                check_root
                perform_installation
            else
                echo "Non-interactive install requires environment variables: DOMAIN, CF_API_TOKEN, XUI_ADMIN_USER, XUI_ADMIN_PASS"
                exit 1
            fi
            ;;
        backup)
            check_root
            perform_backup
            ;;
        restore)
            check_root
            perform_restore
            ;;
        status)
            check_root
            check_status
            ;;
        *)
            echo "Usage: $SCRIPT_NAME {install|backup|restore|status|menu}"
            exit 1
            ;;
    esac
fi