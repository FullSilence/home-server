server {
    listen 80;
    listen [::]:80;
    server_name nginx.silencehome.ru;
    return 301 https://$host$request_uri;
}
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name nginx.silencehome.ru;
    ssl_certificate /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/private.key;
    location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_pass http://127.0.0.1:9000/;
    }
}