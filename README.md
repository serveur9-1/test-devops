# Task Manager DevOps

Application de gestion de tâches servant de support à une chaîne DevOps
complète : API REST FastAPI, base SQLite, interface HTML/CSS/JavaScript natif,
le tout conteneurisé et déployé automatiquement sur AWS EC2 à chaque push.

Projet réalisé dans le cadre d'un exercice technique de 4 heures. Les choix
privilégient la simplicité et la lisibilité.

Application en ligne : <http://13.63.34.25/>

## Technologies

| Brique | Choix | Rôle |
|---|---|---|
| API | FastAPI + Uvicorn | endpoints REST, validation Pydantic |
| Base de données | SQLite (`sqlite3`) | persistance, bibliothèque standard |
| Frontend | HTML/CSS/JavaScript natif | interface, sans framework |
| Serveur web | Nginx (`nginx:alpine`) | fichiers statiques + reverse proxy |
| Conteneurs | Docker Compose | orchestration des deux services |
| CI/CD | GitHub Actions | tests, build, déploiement |
| Registre | Docker Hub | images taguées par commit |
| Hébergement | AWS EC2 Ubuntu 24.04 | runner auto-hébergé |
| Tests | pytest, k6 | unitaires et charge |

## Architecture

La chaîne complète, du commit à la production :

```
GitHub → GitHub Actions → Docker Hub → AWS EC2
```

Et l'application telle qu'elle tourne sur le serveur :

```
                         Navigateur
                             │
                             │  HTTP port 80 (seul port ouvert)
                             ▼
 ┌─── EC2 Ubuntu 24.04 ──────────────────────────────────────┐
 │                                                           │
 │  ┌──────────────────┐         ┌──────────────────────┐    │
 │  │ frontend         │  /api/  │ backend              │    │
 │  │ nginx:alpine     │────────►│ FastAPI + Uvicorn    │    │
 │  │ port 80 publié   │  proxy  │ port 8000 non publié │    │
 │  │ HTML / CSS / JS  │         │ utilisateur non-root │    │
 │  └──────────────────┘         └──────────┬───────────┘    │
 │        réseau privé Docker Compose       │ sqlite3        │
 │                                          ▼                │
 │                            ┌─────────────────────────┐    │
 │                            │ volume Docker           │    │
 │                            │ test-devops_tasks-data  │    │
 │                            │ → /data/tasks.db        │    │
 │                            └─────────────────────────┘    │
 └───────────────────────────────────────────────────────────┘
```

Docker Compose lance ces deux conteneurs. SQLite écrit les tâches dans un
fichier posé sur un volume Docker nommé, ce qui permet aux données de survivre
à la recréation des conteneurs lors d'un déploiement.

### Le parcours d'une requête

Le navigateur charge `http://13.63.34.25/` : Nginx renvoie `index.html`, le CSS
et le JavaScript. Le JavaScript appelle ensuite `/api/tasks` en chemin relatif.
Nginx reconnaît le préfixe `/api/` et transmet la requête au backend, en
**retirant ce préfixe** au passage : FastAPI reçoit donc `/tasks`. Il interroge
SQLite et renvoie le JSON, que Nginx retransmet au navigateur.

Deux conséquences utiles. Le navigateur ne voit qu'une seule origine, donc
aucune configuration CORS n'est nécessaire et le frontend ne contient aucune
URL d'API codée en dur. Et le backend n'est jamais joignable depuis Internet :
il est déclaré avec `expose` et non `ports`, il n'existe que sur le réseau
privé Docker.

### Structure du projet

```
backend/        main.py (API), test_main.py (12 tests), Dockerfile
frontend/       index.html, style.css, app.js, Dockerfile Nginx
nginx/          default.conf — reverse proxy /api/ vers le backend
load-tests/     scripts k6 : smoke, load, stress
deploy/         script de déploiement privilégié et règle sudoers
docker-compose.yml       développement local, construit les images
docker-compose.prod.yml  production, utilise les images Docker Hub
.github/workflows/deploy.yml   pipeline CI/CD
```

Deux fichiers Compose distincts : celui de développement construit les images
localement, celui de production tire les images publiées et fixe le nom du
volume. Le fichier de production vit sur le serveur, dans `/opt/test-devops`,
et appartient à root.

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

### Endpoints

Les routes sont préfixées par `/api` lorsqu'on passe par Nginx.

| Méthode | Route | Rôle |
|---|---|---|
| GET | `/health` | l'application répond, utilisé par le healthcheck |
| GET | `/ready` | la base SQLite est accessible en lecture |
| GET | `/tasks` | liste des tâches, les plus récentes d'abord |
| POST | `/tasks` | crée une tâche, titre de 1 à 200 caractères |
| DELETE | `/tasks/{id}` | supprime une tâche, 404 si elle n'existe pas |

```bash
curl http://localhost/api/health
curl -X POST http://localhost/api/tasks \
  -H 'Content-Type: application/json' -d '{"title":"Ma tâche"}'
```

Les requêtes SQL sont paramétrées et les titres validés côté serveur : un titre
vide ou composé uniquement d'espaces est refusé avec un code 422.

## CI/CD

```
                      GitHub Actions                        EC2
 git push
    │
    ├── Pull Request ──► pytest ──► build des images ──► fin
    │                                (rien n'est publié, pas de déploiement)
    │
    └── push main ─────► pytest ──► build ──► Docker Hub ──► runner
                                              latest + SHA    auto-hébergé
                                                                  │
                                              compose pull ◄───────┤
                                              up -d (volume gardé) │
                                              healthchecks ◄───────┘
```

Sur une **Pull Request** vers `main` : les 12 tests pytest sont exécutés, puis
les deux images sont construites pour vérifier qu'elles compilent. Rien n'est
publié, aucun secret n'est manipulé, aucun déploiement n'a lieu.

Sur un **push sur `main`** : tests, construction, puis publication sur Docker
Hub (`serveur91225/test-devops-backend` et `-frontend`) avec les tags `latest`
et le SHA du commit. Le déploiement suit automatiquement. Un échec des tests ou
du build arrête la chaîne avant toute publication.

### Le déploiement, étape par étape

Le déploiement s'exécute sur un **runner GitHub Actions auto-hébergé** installé
sur l'EC2. C'est lui qui initie la connexion sortante vers GitHub, ce qui évite
d'ouvrir le moindre port entrant pour la CI/CD.

Le runner lance une seule commande, via `sudo`, vers un script appartenant à
root. Ce script récupère les images du SHA concerné, recrée les conteneurs sans
jamais supprimer le volume SQLite, puis vérifie pendant dix tentatives que les
deux conteneurs sont `healthy` **et** que `/api/health` répond à travers Nginx.
En cas d'échec, il sort en erreur et affiche les logs des conteneurs.

Le déploiement utilise toujours le tag SHA, jamais `latest` : chaque mise en
production correspond à un commit identifiable, et un retour arrière consiste à
redéployer un SHA antérieur.

### Sécurité mise en place

L'utilisateur `gha-runner` n'appartient **pas** au groupe `docker`, qui
équivaudrait à un accès root sur la machine. Il ne dispose que d'une règle
sudoers autorisant une unique commande : `/usr/local/sbin/test-devops-deploy`.

Le script lui-même se protège. Il refuse de démarrer si le fichier Compose de
production n'appartient pas à root ou s'il est modifiable par un autre
utilisateur, car un fichier Compose équivaut à une exécution root arbitraire.
Il n'accepte comme argument qu'un SHA de 40 caractères hexadécimaux, ce qui
interdit de déployer une image qui ne sort pas du pipeline. Enfin, le job de
déploiement ne fait aucun `checkout` du dépôt : rien de ce qui tourne en root
n'est modifiable depuis une branche.

Côté application, le backend tourne sous un utilisateur non-root et n'est pas
exposé sur Internet. Aucun secret n'est stocké dans le dépôt : les
identifiants Docker Hub sont des secrets GitHub, et le déploiement est protégé
par une variable `DEPLOY_ENABLED` qui permet de le suspendre sans toucher au
workflow.

## Tests

Le backend est couvert par **12 tests pytest** : healthchecks, création, liste,
suppression et cas d'erreur (titre vide, titre trop long, suppression d'une
tâche inexistante). Chaque test utilise une base SQLite temporaire, donc les
tests ne dépendent pas de l'ordre d'exécution.

```bash
cd backend
pip install -r requirements.txt
python -m pytest -v
```

Trois scénarios k6 dans `load-tests/` : `smoke.js` (1 utilisateur, 30 s),
`load.js` (10 utilisateurs, 1 min) et `stress.js` (30 utilisateurs, 1 min). Ils
interrogent `/api/health` et `/api/tasks` en lecture seule, sans modifier les
données.

```bash
docker run --rm --network host \
  -v "$PWD/load-tests:/scripts:ro" grafana/k6:latest run /scripts/load.js
```

Résultats mesurés le 22 octobre 2026 sur l'EC2 :

| Scénario | Requêtes | Erreurs | p95 |
|---|---|---|---|
| 10 utilisateurs, 60 s | 1 200 | 0 % | 9,57 ms |
| 30 utilisateurs, 60 s | 3 600 | 0 % | 11,8 ms |

Les seuils fixés — moins de 1 % d'erreur et p95 sous 500 ms — sont largement
respectés. Deux réserves : les tests ne couvrent que des requêtes GET, et k6
tournait sur la même machine que l'application, donc la latence réseau réelle
n'est pas mesurée.

## Difficultés rencontrées et solutions

**Le port SSH de l'EC2 était restreint à mon adresse IP.** Un déploiement par
SSH depuis GitHub aurait obligé à ouvrir le port 22 aux plages d'adresses des
runners GitHub. J'ai installé un runner auto-hébergé sur l'EC2 : la connexion
part du serveur vers GitHub, donc aucun port entrant à ouvrir.

**Donner au runner le droit de déployer sans lui donner Docker.** Le réflexe
serait d'ajouter `gha-runner` au groupe `docker`, mais cela revient à lui
donner root. D'où le script appartenant à root, la règle sudoers limitée à
cette seule commande, et les contrôles que le script fait sur lui-même.

**Le backend répondait 404 sur tous les appels `/api/`.** Nginx transmettait
l'URL complète et FastAPI ne connaît pas ce préfixe. Tout tient au slash final
de `proxy_pass http://backend:8000/;`, qui retire `/api` avant de transmettre.

**Nginx refusait de démarrer avec `host not found in upstream "backend"`.** Il
résout le nom du service au chargement de sa configuration, donc avant que le
backend ne soit prêt. Résolu avec `depends_on` et `condition: service_healthy`.

**Le backend ne pouvait pas écrire dans `/data`.** Le conteneur tourne en
non-root, et un volume hérite des droits du dossier tel qu'il existe dans
l'image. Il a fallu créer et attribuer `/data` à `appuser` dans le Dockerfile,
avant l'instruction `USER`.

**Risque de déployer sur un volume vide.** Docker Compose préfixe les noms de
volume par le nom du projet, qui dépend du dossier courant. Lancé depuis un
autre répertoire, le fichier de production aurait créé un volume neuf et les
tâches auraient semblé disparues. Le volume est désormais nommé explicitement
`test-devops_tasks-data` dans `docker-compose.prod.yml`.

**Le healthcheck de fin de déploiement ne pouvait pas viser le backend.**
Celui-ci n'est pas publié sur l'hôte, donc `localhost:8000` est injoignable. La
vérification passe par Nginx sur `http://localhost/api/health`, et contrôle en
plus le statut `healthy` des deux conteneurs.

**Les commandes de dépannage étaient trompeuses en production.** Un
`docker compose ps` lancé depuis `/home/ubuntu/test-devops` lit le fichier
Compose de développement, et un `docker compose up -d` y aurait reconstruit les
images par-dessus la production. Le fichier de production, lui, exige la
variable `IMAGE_TAG`. Pour diagnostiquer, on utilise donc des commandes Docker
nommées, indépendantes de tout fichier Compose :

```bash
docker ps
docker logs task-manager-backend --tail 50
docker exec task-manager-backend ls -ld /data
```

**Une erreur HTTP 403 signalée sur la page d'accueil.** Vérification faite,
l'application répond bien 200 : treize variantes de requête ont été testées
(méthodes, User-Agent, chemins avec et sans slash final), toutes correctes,
alors que les endpoints API fonctionnaient déjà. Le 403 venait de l'outil de
test externe, pas du serveur. Aucune modification n'a été nécessaire.

**Un poste Windows pour une cible Linux.** Les scripts shell commités en CRLF
échouent sur `$'\r': command not found` ; un fichier `.gitattributes` force les
fins de ligne LF sur les `*.sh` et les Dockerfile. Par ailleurs Pydantic ne
s'installait pas sur la version de Python locale, faute de paquet précompilé :
les versions sont épinglées dans `backend/requirements.txt`, avec la même
version de Python en CI et dans l'image.

**Persistance après redéploiement : non validée.** Le script n'exécute jamais
`docker compose down -v` et le volume est nommé explicitement, mais le test
n'a pas encore été mené de bout en bout. C'est le point ouvert assumé du
projet.

## Améliorations possibles

Le service est exposé en HTTP, sans HTTPS ni nom de domaine, et le volume
SQLite n'a pas de sauvegarde automatisée. L'application tourne sur une seule
instance, sans haute disponibilité, et SQLite ne conviendrait pas à un trafic
en écriture concurrent important.

Les pistes naturelles : HTTPS via Let's Encrypt, sauvegarde planifiée du volume
vers S3, rollback automatique vers le SHA précédent si le healthcheck échoue,
migration vers PostgreSQL si les écritures concurrentes augmentent, et
centralisation des logs, aujourd'hui consultés avec `docker logs`.
