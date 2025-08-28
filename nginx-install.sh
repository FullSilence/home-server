#!/bin/bash
set -e

# -------------------------------
# Константы и переменные
# -------------------------------
GITHUB_USER="ваш_пользователь"          # Замените на ваш GitHub username
REPO_NAME="nginx-setup"                 # Имя репозитория на GitHub
REPO_URL="https://github.com/$GITHUB_USER/$REPO_NAME" # URL репозитория
SITES_DIR="/etc/nginx/sites-available"  # Директория для копирования конфигураций
NGINX_UI_REPO="https://raw.githubusercontent.com/0xJacky/nginx-ui/master/install.sh" # URL скрипта установки NginxUI

# -------------------------------
# Проверка прав root
# -------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт от имени root"
  exit 1
fi

# -------------------------------
# Обновление системы
# -------------------------------
echo "Обновление системы..."
apt update -y && apt upgrade -y

echo "Установка зависимостей..."
# Проверка наличия пакетов
PACKAGES="nginx python3-pip python3-venv curl git build-essential libssl-dev libffi-dev libxml2-dev libxslt1-dev zlib1g-dev software-properties-common ufw"
for pkg in $PACKAGES; do
  if ! dpkg -l | grep -q "$pkg"; then
    apt install -y $pkg
  else
    echo "$pkg уже установлен"
  fi
done

# -------------------------------
# Настройка и запуск NGINX
# -------------------------------
echo "Включение и запуск NGINX..."
systemctl enable nginx
systemctl start nginx

# Проверка статуса NGINX
if systemctl is-active --quiet nginx; then
  echo "NGINX запущен успешно"
else
  echo "Ошибка запуска NGINX"
  exit 1
fi

# -------------------------------
# Установка NginxUI через официальный скрипт
# -------------------------------
echo "Установка NginxUI..."
export NGINX_UI_NONINTERACTIVE=1

bash <(curl -L -s $NGINX_UI_REPO) install

# Перезапуск и проверка службы NginxUI
echo "Настройка автозапуска NginxUI..."
systemctl daemon-reload
systemctl enable nginx-ui
systemctl restart nginx-ui

# -------------------------------
# Настройка Firewall
# -------------------------------
echo "Проверка и открытие портов в firewall..."
ufw status || ufw --force enable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp

# -------------------------------
# Копирование конфигураций из репозитория
# -------------------------------
echo "Скачивание конфигураций из GitHub..."

SITES_AVAILABLE_URL="$REPO_URL/raw/main/sites-available"  # Ссылка на директорию конфигураций (замените на ваш путь)
TEMP_DIR=$(mktemp -d)

# Скачивание файлов конфигурации с GitHub
curl -L "$SITES_AVAILABLE_URL" -o "$TEMP_DIR/sites-available.tar.gz"

# Разархивируем, если это архив
if [ -f "$TEMP_DIR/sites-available.tar.gz" ]; then
  echo "Распаковываем архив..."
  tar -xzvf "$TEMP_DIR/sites-available.tar.gz" -C "$TEMP_DIR"
fi

# Копируем файлы в нужную директорию
if [ -d "$TEMP_DIR/sites-available" ]; then
  echo "Копирование папки sites-available в $SITES_DIR"
  cp -r "$TEMP_DIR/sites-available" "$SITES_DIR"
  echo "Папка sites-available скопирована успешно."
else
  echo "Папка sites-available не найдена в репозитории."
fi

# Очистка пакетов
echo "Очистка пакетов..."
apt autoremove -y
apt clean

# -------------------------------
# Завершение установки
# -------------------------------
echo "Установка завершена!"
echo "NGINX работает и доступен на порту 80"
echo "NginxUI доступен"
