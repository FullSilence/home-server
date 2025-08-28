server {
    listen 80;
    server_name proxmox.silencehome.ru;

    return 301 https://$host$request_uri;
}  

server {
    listen 443 ssl;
    server_name proxmox.silencehome.ru;

    ssl_certificate /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/*.silencehome.ru_silencehome.ru_P256/private.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass https://192.168.1.200:8006;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}  