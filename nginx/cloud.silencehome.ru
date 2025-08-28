server {
    listen 80;
    server_name cloud.silencehome.ru;

    # Перенаправляем весь HTTP трафик на HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name cloud.silencehome.ru;

    # SSL сертификаты
    ssl_certificate /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/private.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Проксирование Nextcloud
    location / {
        proxy_pass https://192.168.1.204:443;
        proxy_http_version 1.1;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass $http_upgrade;

        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;

        # Для корректной работы WebDAV и WebSocket
        proxy_set_header Host $host;
        proxy_redirect off;
    }

    # Рекомендуемые заголовки безопасности для Nextcloud
    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header X-Download-Options noopen;
    add_header X-Permitted-Cross-Domain-Policies none;
}
