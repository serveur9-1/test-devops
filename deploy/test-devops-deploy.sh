#!/usr/bin/env bash
# Script de déploiement privilégié, à installer par un administrateur dans
# /usr/local/sbin/test-devops-deploy (root:root, mode 0755).
#
# Il est lancé par gha-runner via « sudo -n /usr/local/sbin/test-devops-deploy
# <sha> ». Cette copie du dépôt n'est qu'une source versionnée : le runner ne
# l'exécute jamais, sinon il pourrait modifier le code tournant en root.
#
# Règle de sécurité : ce script ne doit lire aucun fichier modifiable par
# gha-runner. Un fichier Compose est équivalent à une exécution root
# arbitraire (privileged, montage de /, ...), d'où les contrôles ci-dessous.
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

COMPOSE_DIR=/opt/test-devops
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.prod.yml"
HEALTH_URL=http://localhost/api/health
CONTAINERS=(task-manager-backend task-manager-frontend)
MAX_ATTEMPTS=10
DELAY=5

fail() {
  echo "ERREUR: $*" >&2
  exit 1
}

# Le tag provient de la CI : on n'accepte qu'un SHA Git complet, jamais une
# chaîne arbitraire qui désignerait une image non construite par la pipeline.
[ $# -eq 1 ] || fail "usage: $(basename "$0") <sha-git-40-hex>"
IMAGE_TAG=$1
[[ $IMAGE_TAG =~ ^[0-9a-f]{40}$ ]] || fail "tag invalide: attendu 40 caractères hexadécimaux"

# Refuse de continuer si le dossier ou le fichier Compose n'appartient pas à
# root, ou s'il est inscriptible par le groupe ou les autres : ce serait une
# porte ouverte vers un root complet pour gha-runner.
for path in "$COMPOSE_DIR" "$COMPOSE_FILE"; do
  [ -e "$path" ] || fail "$path est absent"
  if [ -n "$(find "$path" -maxdepth 0 \( ! -user root -o -perm /022 \))" ]; then
    fail "$path doit être root:root et non inscriptible par groupe/autres"
  fi
done

echo "Déploiement du tag $IMAGE_TAG"
export IMAGE_TAG

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

compose pull
# Ni « down » ni « -v » : les conteneurs sont recréés en place et le volume
# test-devops_tasks-data, qui porte la base SQLite, est conservé.
# --no-build : le fichier n'a pas de section build, l'option garantit qu'un
# ajout ultérieur ne déclencherait pas de build silencieux en root.
compose up -d --no-build --remove-orphans

# Double vérification : les healthchecks Docker des deux conteneurs ET la
# réponse HTTP à travers Nginx. Le backend n'expose pas 8000 hors du réseau
# Compose, http://localhost:8000 serait injoignable depuis l'hôte.
echo "Vérification des conteneurs et de $HEALTH_URL"
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  healthy=1

  for container in "${CONTAINERS[@]}"; do
    status=$(docker inspect \
      -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sans-healthcheck{{end}}' \
      "$container" 2>/dev/null || echo absent)
    if [ "$status" != healthy ]; then
      echo "  $container : $status"
      healthy=0
    fi
  done

  if [ "$healthy" -eq 1 ] && curl -fsS --max-time 5 "$HEALTH_URL" > /dev/null; then
    echo "Déploiement réussi (tentative $attempt/$MAX_ATTEMPTS)."
    compose ps
    docker image prune -f
    exit 0
  fi

  echo "Tentative $attempt/$MAX_ATTEMPTS sans succès, nouvel essai dans ${DELAY}s."
  sleep "$DELAY"
done

echo "Healthcheck en échec après $MAX_ATTEMPTS tentatives." >&2
compose ps
compose logs --tail 50
exit 1
