# Task Manager DevOps

Petite application de gestion de tâches servant de support à une chaîne
DevOps complète. Le backend est une API REST FastAPI avec persistance SQLite,
le frontend une page HTML/CSS/JavaScript natif servie par Nginx, qui fait
aussi office de reverse proxy vers l'API. L'ensemble tourne dans deux
conteneurs Docker orchestrés par Docker Compose.

Chaque push sur `main` déclenche les tests, construit les images, les publie
sur Docker Hub et déploie automatiquement sur une instance AWS EC2. Le projet
a été réalisé dans le cadre d'un exercice technique de 4 heures : les choix
privilégient la simplicité et la lisibilité plutôt que l'exhaustivité.

Application en ligne : <http://13.63.34.25/>

## Technologies

| Brique | Choix |
|---|---|
| API | FastAPI + Uvicorn, validation Pydantic |
| Base de données | SQLite via la bibliothèque standard `sqlite3` |
| Frontend | HTML, CSS et JavaScript natif, sans framework |
| Serveur web | Nginx (`nginx:alpine`) |
| Conteneurs | Docker et Docker Compose |
| CI/CD | GitHub Actions, Docker Hub |
| Hébergement | AWS EC2 Ubuntu 24.04 |
| Tests | pytest, k6 |

## Architecture

Le navigateur ne communique qu'avec Nginx, sur le port 80, le seul port
publié. Nginx sert les fichiers statiques et transmet tout ce qui commence par
`/api/` au backend, en retirant ce préfixe au passage : `/api/tasks` arrive
donc sur `/tasks` côté FastAPI.

Comme le navigateur ne voit qu'une seule origine, aucune configuration CORS
n'est nécessaire et le frontend ne contient aucune URL d'API codée en dur. Le
backend n'est jamais joignable directement depuis Internet : il est déclaré
avec `expose` et non `ports`, et reste accessible uniquement depuis le réseau
privé Docker. Il tourne sous un utilisateur non-root et écrit sa base dans
`/data/tasks.db`, sur un volume Docker nommé `test-devops_tasks-data` qui
survit à la recréation des conteneurs.

Les deux conteneurs ont un healthcheck. Nginx n'est démarré qu'une fois le
backend déclaré `healthy`, car il a besoin de résoudre le nom du service pour
charger sa configuration.

```
backend/      API FastAPI, tests pytest, Dockerfile
frontend/     page statique et Dockerfile Nginx
nginx/        configuration du reverse proxy
load-tests/   scripts k6
deploy/       script de déploiement privilégié et règle sudoers
```

## Installation locale

Prérequis : Docker et Docker Compose. L'application est ensuite disponible sur
<http://localhost>.

```bash
docker compose up --build
```

Pour arrêter, `docker compose down` conserve les tâches enregistrées ;
`docker compose down -v` supprime le volume et donc les données.

Le backend peut aussi être lancé seul, sans Docker, pour du développement :

```bash
cd backend
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

## Endpoints

Les routes sont préfixées par `/api` lorsqu'on passe par Nginx.

| Méthode | Route | Rôle |
|---|---|---|
| GET | `/health` | l'application répond |
| GET | `/ready` | la base SQLite est accessible |
| GET | `/tasks` | liste des tâches, les plus récentes d'abord |
| POST | `/tasks` | crée une tâche, titre de 1 à 200 caractères |
| DELETE | `/tasks/{id}` | supprime une tâche, 404 si elle n'existe pas |

```bash
curl http://localhost/api/health
curl http://localhost/api/tasks
curl -X POST http://localhost/api/tasks \
  -H 'Content-Type: application/json' -d '{"title":"Ma tâche"}'
```

Les requêtes SQL sont paramétrées et les titres validés côté serveur. Un titre
vide ou composé uniquement d'espaces est refusé avec un code 422.

## CI/CD

Le workflow est défini dans `.github/workflows/deploy.yml`.

Sur une **Pull Request** vers `main` : les tests pytest sont exécutés, puis
les deux images Docker sont construites pour vérifier qu'elles compilent. Rien
n'est publié et aucun déploiement n'a lieu.

Sur un **push sur `main`** : les tests sont exécutés, les images sont
construites et publiées sur Docker Hub sous `serveur91225/test-devops-backend`
et `serveur91225/test-devops-frontend`, avec les tags `latest` et le SHA du
commit. Le déploiement sur EC2 suit automatiquement. Un échec des tests ou du
build arrête la chaîne avant toute publication.

Le déploiement s'appuie sur un **runner GitHub Actions auto-hébergé** installé
sur l'EC2. C'est lui qui initie la connexion vers GitHub, ce qui évite
d'ouvrir le port SSH aux plages d'adresses des runners GitHub. Le runner n'a
qu'un seul droit privilégié, via une règle sudoers limitée au script
`deploy/test-devops-deploy.sh` : il ne peut pas exécuter de commande Docker
arbitraire.

Le script récupère les images du SHA concerné, recrée les conteneurs sans
jamais supprimer le volume SQLite, puis vérifie que les deux conteneurs sont
`healthy` et que `/api/health` répond, avec plusieurs tentatives. Si la
vérification échoue, il sort en erreur et affiche les logs.

## Tests

Le backend est couvert par **12 tests pytest**, qui vérifient les
healthchecks, la création, la liste et la suppression de tâches, ainsi que les
cas d'erreur. Chaque test utilise une base SQLite temporaire.

```bash
cd backend
pip install -r requirements.txt
python -m pytest -v
```

Trois scénarios k6 sont disponibles dans `load-tests/` : `smoke.js` (1
utilisateur, 30 s), `load.js` (10 utilisateurs, 1 min) et `stress.js` (30
utilisateurs, 1 min). Ils interrogent `/api/health` et `/api/tasks` en lecture
seule, sans modifier les données.

```bash
docker run --rm --network host \
  -v "$PWD/load-tests:/scripts:ro" grafana/k6:latest run /scripts/load.js
```

Résultats mesurés le 22 octobre 2026 sur l'EC2 :

| Scénario | Requêtes | Erreurs | p95 |
|---|---|---|---|
| 10 utilisateurs, 60 s | 1 200 | 0 % | 9,57 ms |
| 30 utilisateurs, 60 s | 3 600 | 0 % | 11,8 ms |

Les seuils fixés (moins de 1 % d'erreur, p95 sous 500 ms) sont largement
respectés. À noter : les tests ne couvrent que des requêtes GET, et k6 tournait
sur la même machine que l'application, ce qui exclut la latence réseau réelle.

## Limites connues

Le service est exposé en HTTP, sans HTTPS ni nom de domaine. Le volume SQLite
n'a pas de sauvegarde automatisée. La persistance des données après un
redéploiement n'a **pas encore été validée par un test réel** : le script ne
supprime jamais le volume, mais la vérification reste à faire. Enfin,
l'application tourne sur une seule instance, sans haute disponibilité, et
SQLite ne conviendrait pas à un trafic en écriture concurrent important.

## Améliorations possibles

HTTPS via Caddy ou un certificat Let's Encrypt. Sauvegarde planifiée du volume
SQLite vers S3. Migration vers PostgreSQL si le volume d'écritures augmente.
Rollback automatique vers le SHA précédent en cas d'échec du healthcheck.
Enfin, de la supervision et de la centralisation des logs, aujourd'hui
consultés directement avec `docker logs`.
