#!/bin/bash
set -e

# -------------------------------
# Константы и переменные
# -------------------------------
GITHUB_USER="FullSilence"          # Замените на ваш GitHub username
REPO_NAME="home-server"                 # Имя репозитория на GitHub
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
# Копирование конфигураций из репозитория (архивом)
# -------------------------------
echo "Скачивание конфигураций из GitHub..."

TEMP_DIR=$(mktemp -d)
ARCHIVE_URL="https://github.com/$GITHUB_USER/$REPO_NAME/archive/refs/heads/main.tar.gz"

curl -L -s "$ARCHIVE_URL" -o "$TEMP_DIR/repo.tar.gz"

echo "Распаковка архива..."
tar -xzf "$TEMP_DIR/repo.tar.gz" -C "$TEMP_DIR"

# Внутри архива папка называется REPO_NAME-main
if [ -d "$TEMP_DIR/$REPO_NAME-main/sites-available" ]; then
  echo "Копирование конфигов..."
  cp -r "$TEMP_DIR/$REPO_NAME-main/sites-available/"* "$SITES_DIR/"
  echo "Файлы скопированы успешно."
else
  echo "Папка sites-available не найдена."
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
