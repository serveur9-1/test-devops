# Contexte de build = racine du projet, pour copier frontend/ et nginx/.
FROM nginx:alpine

COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY frontend/index.html frontend/style.css frontend/app.js /usr/share/nginx/html/

EXPOSE 80
