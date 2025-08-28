server {
    listen 80;
    server_name lampa.silencehome.ru;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name lampa.silencehome.ru;

    ssl_certificate /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/private.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # -----------------------------
    # Основной Lampa прокси
    # -----------------------------
    location / {
        proxy_pass http://192.168.1.205:11173;
        proxy_http_version 1.1;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass $http_upgrade;

        # Подставляем User-Agent на сервере
        proxy_set_header User-Agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) LampaProxy/1.0";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_redirect off;

        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type' always;

        if ($request_method = OPTIONS ) {
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain charset=UTF-8';
            add_header 'Content-Length' 0;
            return 204;
        }
    }

    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;
}
