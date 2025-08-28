server {
    listen 80;
    server_name keenetik.silencehome.ru;

    # Перенаправляем весь HTTP трафик на HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name keenetik.silencehome.ru;

    # SSL сертификаты
    ssl_certificate /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/private.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://192.168.1.254:80;
        proxy_http_version 1.1;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass $http_upgrade;

        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;

        proxy_set_header Host $host;
        proxy_redirect off;
    }
}
