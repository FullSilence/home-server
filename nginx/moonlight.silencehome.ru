server {
    listen 80;
    server_name moonlight.silencehome.ru;

    # Редирект HTTP на HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name moonlight.silencehome.ru;

    # SSL сертификаты
    ssl_certificate /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/private.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Важные заголовки для безопасности и работы WebRTC
    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # Основное проксирование Moonlight
    location / {
        proxy_pass http://192.168.1.1:47989;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass $http_upgrade;

        # Увеличиваем буферы для потоковой передачи
        proxy_buffer_size   128k;
        proxy_buffers   4 256k;
        proxy_busy_buffers_size   256k;

        # WebSocket и RTC
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_redirect off;
    }
}
