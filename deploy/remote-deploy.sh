#!/usr/bin/env bash
# Exécuté sur l'EC2 via « ssh ... bash -s < deploy/remote-deploy.sh ».
# Variables attendues : IMAGE_TAG (SHA du commit), APP_DIR (optionnel).
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG est obligatoire}"
APP_DIR="${APP_DIR:-test-devops}"
APP_DIR="${APP_DIR/#\~/$HOME}"

HEALTH_URL="http://localhost/api/health"
MAX_ATTEMPTS=10
DELAY=5

cd "$APP_DIR"
export IMAGE_TAG

compose() {
  docker compose -f docker-compose.yml -f docker-compose.prod.yml "$@"
}

echo "Déploiement du tag ${IMAGE_TAG} depuis ${APP_DIR}"
compose pull
compose up -d --no-build --remove-orphans

# Le healthcheck passe par Nginx : le backend n'expose pas 8000 en dehors du
# réseau Compose, http://localhost:8000 serait donc injoignable depuis l'hôte.
echo "Vérification de ${HEALTH_URL}"
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if curl -fsS --max-time 5 "$HEALTH_URL" > /dev/null; then
    echo "Backend sain (tentative ${attempt}/${MAX_ATTEMPTS})."
    compose ps
    docker image prune -f
    exit 0
  fi
  echo "Tentative ${attempt}/${MAX_ATTEMPTS} sans succès, nouvel essai dans ${DELAY}s."
  sleep "$DELAY"
done

echo "Healthcheck en échec après ${MAX_ATTEMPTS} tentatives." >&2
compose ps
compose logs --tail 50
exit 1
