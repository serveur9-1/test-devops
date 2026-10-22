FROM python:3.12-slim

# Logs non bufferisés, sinon ils n'apparaissent pas dans `docker logs`.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Copié seul : la couche pip reste en cache tant que les dépendances ne bougent pas.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py ./

# Le chown de /data doit avoir lieu ici : Docker reprend ces droits à
# l'initialisation du volume nommé, sinon l'utilisateur non-root ne peut
# pas écrire la base.
RUN useradd --create-home --uid 1000 appuser \
    && mkdir -p /data \
    && chown -R appuser:appuser /app /data

ENV DATABASE_PATH=/data/tasks.db

USER appuser

EXPOSE 8000

# 0.0.0.0 et non 127.0.0.1, sinon le conteneur est injoignable de l'extérieur.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
