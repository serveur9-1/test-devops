# Task Manager DevOps

Application de gestion de tâches servant de support à une chaîne DevOps
complète : API REST FastAPI, base SQLite, interface HTML/CSS/JavaScript natif,
le tout conteneurisé et déployé automatiquement sur AWS EC2.

Projet réalisé dans le cadre d'un exercice technique de 4 heures. Les choix
privilégient la simplicité et la lisibilité.

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

```
GitHub → GitHub Actions → Docker Hub → AWS EC2
```

Docker Compose lance deux conteneurs : le frontend Nginx, qui sert la page
statique et relaie les appels `/api/` vers le backend, et le backend FastAPI,
qui n'est pas exposé sur Internet. Seul le port 80 est publié.

SQLite stocke les tâches dans un fichier `/data/tasks.db`, placé sur un volume
Docker nommé `test-devops_tasks-data`. Les données survivent ainsi à la
recréation des conteneurs. Chaque conteneur dispose d'un healthcheck.

## Lancement du projet

Prérequis : Docker et Docker Compose. L'application est ensuite disponible sur
<http://localhost>.

```bash
docker compose up --build
```

`docker compose down` conserve les tâches ; `docker compose down -v` supprime
le volume et donc les données.

Pour lancer le backend seul, sans Docker :

```bash
cd backend
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

Les routes sont préfixées par `/api` lorsqu'on passe par Nginx.

| Méthode | Route | Rôle |
|---|---|---|
| GET | `/health` | l'application répond |
| GET | `/ready` | la base SQLite est accessible |
| GET | `/tasks` | liste des tâches |
| POST | `/tasks` | crée une tâche, titre de 1 à 200 caractères |
| DELETE | `/tasks/{id}` | supprime une tâche, 404 si elle n'existe pas |

Les requêtes SQL sont paramétrées et les titres validés côté serveur.

## CI/CD

Le workflow est défini dans `.github/workflows/deploy.yml`.

Sur une **Pull Request** vers `main` : tests pytest, puis construction des deux
images Docker pour vérifier qu'elles compilent. Rien n'est publié, aucun
déploiement.

Sur un **push sur `main`** : tests, construction, publication sur Docker Hub
(`serveur91225/test-devops-backend` et `-frontend`, tags `latest` et SHA du
commit), puis déploiement automatique sur l'EC2. Un échec des tests ou du build
arrête la chaîne.

Le déploiement passe par un runner GitHub Actions auto-hébergé installé sur
l'EC2. Il récupère les images du SHA concerné, recrée les conteneurs sans
toucher au volume SQLite, puis vérifie que les deux conteneurs sont `healthy`
et que `/api/health` répond.

## Tests

Le backend est couvert par **12 tests pytest** : healthchecks, création, liste,
suppression et cas d'erreur. Chaque test utilise une base SQLite temporaire.

```bash
cd backend
pip install -r requirements.txt
python -m pytest -v
```

Trois scénarios k6 dans `load-tests/` : `smoke.js` (1 utilisateur, 30 s),
`load.js` (10 utilisateurs, 1 min) et `stress.js` (30 utilisateurs, 1 min). Ils
interrogent `/api/health` et `/api/tasks` en lecture seule.

```bash
docker run --rm --network host \
  -v "$PWD/load-tests:/scripts:ro" grafana/k6:latest run /scripts/load.js
```

Résultats mesurés le 22 octobre 2026 sur l'EC2 :

| Scénario | Requêtes | Erreurs | p95 |
|---|---|---|---|
| 10 utilisateurs, 60 s | 1 200 | 0 % | 9,57 ms |
| 30 utilisateurs, 60 s | 3 600 | 0 % | 11,8 ms |

Les tests ne couvrent que des requêtes GET, et k6 tournait sur la même machine
que l'application : la latence réseau réelle n'est donc pas mesurée.

## Difficultés rencontrées et solutions

**Le port SSH de l'EC2 était restreint à mon adresse IP.** Un déploiement par
SSH depuis GitHub aurait obligé à ouvrir le port 22 aux plages d'adresses des
runners GitHub. J'ai installé un runner auto-hébergé sur l'EC2 : c'est lui qui
initie la connexion sortante vers GitHub, donc aucun port entrant à ouvrir.

**Donner au runner le droit de déployer sans lui donner Docker.** Ajouter
l'utilisateur `gha-runner` au groupe `docker` équivaut à un accès root sur la
machine. J'ai créé un script de déploiement appartenant à root et une règle
sudoers autorisant cette seule commande. Le script refuse de démarrer si le
fichier Compose de production est modifiable par un autre utilisateur, et
n'accepte qu'un SHA de 40 caractères hexadécimaux comme argument.

**Le backend répondait 404 sur tous les appels `/api/`.** Nginx transmettait
l'URL complète, et FastAPI ne connaît pas ce préfixe. La solution tient au
slash final de `proxy_pass http://backend:8000/;`, qui retire `/api` avant de
transmettre la requête.

**Nginx refusait de démarrer avec `host not found in upstream "backend"`.** Il
résout le nom du service au chargement de sa configuration, donc avant que le
backend ne soit prêt. Résolu avec `depends_on` et `condition: service_healthy`.

**Le backend ne pouvait pas écrire dans `/data`.** Le conteneur tourne sous un
utilisateur non-root, et le volume hérite des droits du dossier tel qu'il
existe dans l'image. Il a fallu créer et attribuer `/data` à `appuser` dans le
Dockerfile, avant l'instruction `USER`.

**Risque de déployer sur un volume vide.** Docker Compose préfixe les noms de
volume par le nom du projet, qui dépend du dossier courant. Lancé depuis un
autre répertoire, le fichier de production aurait créé un volume neuf et les
tâches auraient semblé disparues. Le volume est désormais nommé explicitement
`test-devops_tasks-data` dans `docker-compose.prod.yml`.

**Le healthcheck de fin de déploiement ne pouvait pas viser le backend.**
Celui-ci est déclaré avec `expose` et non `ports`, donc `localhost:8000` est
injoignable depuis l'hôte. La vérification passe par Nginx, sur
`http://localhost/api/health`, et contrôle en plus le statut `healthy` des deux
conteneurs.

**Les commandes de dépannage étaient trompeuses en production.** Un
`docker compose ps` lancé depuis `/home/ubuntu/test-devops` lit le fichier
Compose de développement, et un `docker compose up -d` y aurait reconstruit les
images par-dessus la production. Le fichier de production, lui, exige la
variable `IMAGE_TAG`. Pour le diagnostic, on utilise donc des commandes Docker
nommées, indépendantes de tout fichier Compose :

```bash
docker ps
docker logs task-manager-backend --tail 50
docker exec task-manager-backend ls -ld /data
```

**Une erreur HTTP 403 signalée sur la page d'accueil.** Vérification faite,
l'application répond bien 200 : treize variantes de requête ont été testées
(méthodes, User-Agent, chemins avec et sans slash final), toutes correctes, et
les endpoints API fonctionnaient déjà. Le 403 venait de l'outil de test
externe, pas du serveur. Aucune modification n'a été nécessaire.

**Un environnement de développement Windows pour une cible Linux.** Les
scripts shell commités en CRLF échouent sur `$'\r': command not found` : un
fichier `.gitattributes` force les fins de ligne LF sur les `*.sh` et les
Dockerfile. Par ailleurs, Pydantic ne s'installait pas sur la version de Python
locale faute de paquet précompilé ; les versions sont épinglées dans
`backend/requirements.txt`, avec la même version de Python en CI et dans
l'image.

**Persistance après redéploiement : non validée.** Le script de déploiement
n'exécute jamais `docker compose down -v` et le volume est nommé
explicitement, mais le test n'a pas encore été effectué de bout en bout. C'est
le point ouvert assumé du projet.

## Améliorations possibles

Le service est exposé en HTTP, sans HTTPS ni nom de domaine, et le volume
SQLite n'a pas de sauvegarde automatisée. L'application tourne sur une seule
instance, sans haute disponibilité.

Les pistes naturelles : HTTPS via Let's Encrypt, sauvegarde planifiée du volume
vers S3, rollback automatique vers le SHA précédent si le healthcheck échoue,
migration vers PostgreSQL si les écritures concurrentes augmentent, et
centralisation des logs aujourd'hui consultés avec `docker logs`.
