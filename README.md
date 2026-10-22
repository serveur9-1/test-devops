# Task Manager — Test technique DevOps

Application de gestion de tâches (lister, ajouter, supprimer) déployée de bout
en bout : API FastAPI, frontend statique servi par Nginx, conteneurisation
Docker Compose, pipeline CI/CD GitHub Actions et déploiement automatique sur
AWS EC2.

Le projet privilégie volontairement la simplicité : pas d'ORM, pas de
framework frontend, pas d'orchestrateur. Chaque brique doit pouvoir être
expliquée ligne à ligne.

## Architecture

```
                      Navigateur
                          │
                          │  http://<ec2>  (port 80, seul port public)
                          ▼
            ┌─────────────────────────────┐
            │ Conteneur frontend          │  nginx:alpine
            │                             │
            │  /         → fichiers statiques (HTML/CSS/JS)
            │  /api/...  → reverse proxy vers le backend
            └──────────────┬──────────────┘
                           │ réseau privé Docker Compose
                           │ hôte « backend », port 8000 (non publié)
                           ▼
            ┌─────────────────────────────┐
            │ Conteneur backend           │  python:3.12-slim
            │  FastAPI + Uvicorn          │  utilisateur non-root (appuser)
            │  écrit /data/tasks.db       │
            └──────────────┬──────────────┘
                           │
                           ▼
              ┌──────────────────────────┐
              │ Volume test-devops_      │  persiste hors des conteneurs
              │        tasks-data        │
              └──────────────────────────┘
```

Le point clé est le reverse proxy. Le navigateur ne connaît qu'une seule
origine, donc aucune configuration CORS n'est nécessaire et le frontend ne
contient aucune URL d'API codée en dur. Le backend n'est jamais exposé
directement : il utilise `expose` et non `ports`.

### Technologies

| Brique | Choix | Rôle |
|---|---|---|
| API | FastAPI + Uvicorn | Endpoints REST, validation Pydantic |
| Base | SQLite via `sqlite3` | Persistance, bibliothèque standard Python |
| Frontend | HTML/CSS/JavaScript natif | Interface, aucun framework |
| Serveur web | Nginx (`nginx:alpine`) | Fichiers statiques + proxy `/api/` |
| Conteneurs | Docker Compose | Orchestration des deux services |
| CI/CD | GitHub Actions | Tests, build, publication, déploiement |
| Registre | Docker Hub (`serveur91225`) | Images taguées `latest` et SHA |
| Hébergement | AWS EC2 Ubuntu 24.04 | Runner auto-hébergé + exécution |
| Charge | k6 | Tests de performance manuels |

### Arborescence

```
.
├── backend/
│   ├── main.py              API FastAPI (endpoints, accès SQLite)
│   ├── test_main.py         12 tests pytest
│   ├── requirements.txt     dépendances épinglées
│   ├── Dockerfile           image backend, utilisateur non-root
│   └── .dockerignore
├── frontend/
│   ├── index.html           page unique
│   ├── style.css            mise en page responsive
│   ├── app.js               appels fetch vers /api
│   └── Dockerfile           image Nginx (contexte = racine du dépôt)
├── nginx/
│   └── default.conf         statique + reverse proxy /api/
├── deploy/
│   ├── test-devops-deploy.sh       source du script privilégié EC2
│   └── test-devops-deploy.sudoers  source de la règle sudoers
├── load-tests/
│   ├── common.js            BASE_URL, seuils et requêtes partagées
│   ├── smoke.js             1 VU, 30 s
│   ├── load.js              10 VUs, 1 min
│   ├── stress.js            30 VUs, 1 min
│   └── README.md            commandes et lecture des résultats
├── .github/
│   ├── workflows/deploy.yml pipeline CI/CD
│   └── actionlint.yaml      déclare le label du runner auto-hébergé
├── docker-compose.yml       développement local (build depuis les sources)
├── docker-compose.prod.yml  production autonome (images Docker Hub)
├── .gitattributes           force le LF sur les .sh et Dockerfile
├── .gitignore               exclut .env, caches, .venv et *.db
└── README.md
```

## Prérequis

- Docker Engine et Docker Compose v2 (`docker compose version`)
- Python 3.12 et pip, uniquement pour lancer les tests hors conteneur
- k6 ou Docker, pour les tests de charge

## Installation locale

```bash
git clone https://github.com/serveur9-1/test-devops.git
cd test-devops
docker compose up --build
```

L'application est disponible sur <http://localhost>. Cette commande n'utilise
que `docker-compose.yml` : elle construit les deux images depuis les sources
et ne touche pas aux images Docker Hub.

Pour arrêter sans perdre les données :

```bash
docker compose down        # conserve le volume
docker compose down -v     # SUPPRIME le volume et donc les tâches
```

### Lancer le backend seul, pour développer

```bash
cd backend
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

La documentation interactive de l'API est alors sur
<http://localhost:8000/docs>. Attention : dans ce mode le frontend n'est pas
servi et `/api` n'est proxifié par personne, puisque c'est le rôle de Nginx.

Le chemin de la base est configurable par la variable `DATABASE_PATH`, qui
vaut `tasks.db` par défaut en local et `/data/tasks.db` dans l'image.

### Lancer les tests

```bash
cd backend
pip install -r requirements.txt
pytest -v
```

12 tests couvrent les deux sondes de santé, la liste vide initiale, la
création, le nettoyage des espaces, les titres invalides (vide, espaces seuls,
201 caractères), le titre manquant, la suppression et la suppression d'un
identifiant inexistant.

## Endpoints

Toutes les routes sont accessibles depuis le navigateur sous le préfixe
`/api/`, retiré par Nginx avant transmission au backend.

| Méthode | Route publique | Route backend | Succès | Erreurs |
|---|---|---|---|---|
| GET | `/api/health` | `/health` | 200 | — |
| GET | `/api/ready` | `/ready` | 200 | 503 si la base est inaccessible |
| GET | `/api/tasks` | `/tasks` | 200 | — |
| POST | `/api/tasks` | `/tasks` | 201 | 422 si le titre est invalide |
| DELETE | `/api/tasks/{id}` | `/tasks/{id}` | 204 | 404 si la tâche est absente |

Le titre doit contenir entre 1 et 200 caractères. Les espaces de début et de
fin sont retirés, et un titre composé uniquement d'espaces est rejeté en 422.
La liste est renvoyée par identifiant décroissant, la tâche la plus récente en
premier. Toutes les requêtes SQL sont paramétrées, ce qui écarte l'injection
SQL, et le frontend insère les titres avec `textContent` plutôt que
`innerHTML`, ce qui écarte l'injection HTML.

Le retrait du préfixe repose sur un détail de configuration facile à manquer :

```18:21:nginx/default.conf
    location /api/ {
        # Le "/" final retire le préfixe /api : /api/tasks -> /tasks.
        # Sans lui, FastAPI recevrait /api/tasks et répondrait 404.
        proxy_pass http://backend:8000/;
```

## Healthchecks

Deux sondes distinctes, avec des rôles différents. `/health` répond « le
processus tourne, ne le redémarre pas » (*liveness*). `/ready` exécute un
`SELECT 1` et répond « je peux réellement traiter du trafic » (*readiness*).
Un équilibreur de charge utiliserait `/ready`.

| Niveau | Cible | Paramètres |
|---|---|---|
| Conteneur backend | `/ready` via `urllib` | intervalle 10 s, timeout 5 s, 5 essais, démarrage 10 s |
| Conteneur frontend | `http://127.0.0.1/` via `wget` | intervalle 10 s, timeout 5 s, 3 essais, démarrage 5 s |
| Après déploiement | `http://localhost/api/health` via `curl` | 10 tentatives espacées de 5 s |

Le healthcheck du backend utilise `python` et celui du frontend `wget`, déjà
présents dans leurs images respectives : aucun paquet n'est ajouté juste pour
la sonde.

Le script de déploiement vérifie deux choses complémentaires : que les deux
conteneurs sont bien à l'état `healthy` selon Docker, et que l'API répond en
HTTP à travers Nginx. Cette vérification HTTP passe obligatoirement par le
port 80, car le backend n'expose pas le port 8000 en dehors du réseau
Compose — `http://localhost:8000` serait injoignable depuis l'hôte.

Le démarrage est ordonné par `depends_on` avec `condition: service_healthy`.
C'est nécessaire et pas seulement élégant : Nginx résout le nom d'hôte
`backend` au chargement de sa configuration, et refuse de démarrer avec
`host not found in upstream` si le service n'est pas encore là.

## Pipeline CI/CD

Définie dans `.github/workflows/deploy.yml`, déclenchée sur les Pull Requests
vers `main`, les push sur `main` et manuellement via `workflow_dispatch`.

```
   Pull Request vers main              Push sur main
            │                               │
            ▼                               ▼
    ┌───────────────┐               ┌───────────────┐
    │ Tests backend │               │ Tests backend │   pytest, Python 3.12
    └───────┬───────┘               └───────┬───────┘
            ▼                               ▼
    ┌───────────────┐               ┌───────────────┐
    │ Image backend │               │ Image backend │   build + push Docker Hub
    │ Image frontend│               │ Image frontend│   tags latest et SHA
    └───────┬───────┘               └───────┬───────┘
            │ build seul,                   ▼
            │ aucune publication     ┌───────────────┐
            ▼                        │ Déploiement   │   runner EC2
        (fin)                        │     EC2       │   auto-hébergé
                                     └───────────────┘
```

Les trois jobs sont enchaînés par `needs`, donc **un échec des tests ou du
build empêche tout déploiement**. Les permissions du workflow sont réduites à
`contents: read`.

| Job | Runner | Déclenchement |
|---|---|---|
| `Tests backend` | `ubuntu-24.04` | PR et push |
| `Image backend` / `Image frontend` | `ubuntu-24.04` | PR (build seul) et push (build + publication) |
| `Déploiement EC2` | `[self-hosted, Linux, X64, ec2-deploy]` | push sur `main` uniquement |

Sur une Pull Request, le job de build ne se connecte pas au registre : aucun
secret n'est manipulé sur du code provenant de l'extérieur. La publication est
en outre restreinte à `main`, pour qu'un `workflow_dispatch` lancé depuis une
autre branche ne puisse pas écraser le tag `latest`.

Le job de déploiement est conditionné à la variable de dépôt
`DEPLOY_ENABLED == 'true'` : c'est un interrupteur permettant de suspendre les
déploiements sans modifier le workflow. Il cible aussi l'environnement
`production`, où une approbation manuelle peut être exigée.

### Images publiées

| Image | Tags |
|---|---|
| `serveur91225/test-devops-backend` | `latest` et le SHA complet du commit |
| `serveur91225/test-devops-frontend` | `latest` et le SHA complet du commit |

Le déploiement utilise **exclusivement le tag SHA**, jamais `latest`. Chaque
mise en production correspond donc à un commit identifiable, et un retour
arrière consiste à redéployer un SHA antérieur.

### Secrets et variables

| Nom | Type | Usage |
|---|---|---|
| `DOCKERHUB_USERNAME` | secret | authentification au registre |
| `DOCKERHUB_TOKEN` | secret | authentification au registre |
| `DEPLOY_ENABLED` | variable | interrupteur du job de déploiement |
| `EC2_APP_DIR` | variable | optionnelle, dossier applicatif |

Le déploiement par runner auto-hébergé a rendu inutiles les secrets SSH
(`EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`) : ils peuvent être supprimés du dépôt.

## Sécurité du déploiement

Le runner auto-hébergé exécute du code issu du dépôt. Le modèle de sécurité
part donc du principe que **le compte `gha-runner` est potentiellement
hostile**, et limite strictement ce qu'il peut faire.

**`gha-runner` n'est pas membre du groupe `docker`.** Ce groupe équivaut à un
accès root sur la machine, puisqu'il permet de monter n'importe quel chemin de
l'hôte dans un conteneur.

**Un seul droit root, via sudoers.** Le runner ne peut lancer qu'une commande
précise :

```bash
gha-runner ALL=(root) NOPASSWD: /usr/local/sbin/test-devops-deploy
```

**Le script est hors de sa portée.** Il appartient à `root:root` en mode 0755,
et le job de déploiement ne fait aucun `checkout` : aucun fichier du dépôt
n'intervient dans l'exécution privilégiée. La copie présente dans `deploy/`
n'est qu'une source versionnée, installée manuellement par un administrateur.

**Les fichiers Compose privilégiés sont protégés.** C'est le point le plus
important et le moins intuitif : un fichier Compose exécuté par root équivaut
à une exécution de code arbitraire en root, puisqu'il suffit d'y écrire
`privileged: true` ou de monter `/`. Le fichier de production vit donc dans
`/opt/test-devops/`, en `root:root`, et le script refuse de démarrer si ce
n'est plus le cas :

```39:44:deploy/test-devops-deploy.sh
for path in "$COMPOSE_DIR" "$COMPOSE_FILE"; do
  [ -e "$path" ] || fail "$path est absent"
  if [ -n "$(find "$path" -maxdepth 0 \( ! -user root -o -perm /022 \))" ]; then
    fail "$path doit être root:root et non inscriptible par groupe/autres"
  fi
done
```

`docker-compose.prod.yml` est pour cette raison un fichier **autonome**, sans
section `build`, sans montage bind et sans chemin relatif : il ne lit rien qui
soit modifiable par le runner.

**L'argument est validé.** Le script n'accepte qu'un SHA Git de 40 caractères
hexadécimaux, ce qui bloque autant une injection shell qu'un `latest` qui
déploierait une image non vérifiée.

**Le conteneur backend tourne en non-root.** L'image crée un utilisateur
`appuser` (UID 1000) et lui donne la propriété de `/data` avant le montage du
volume, car Docker reprend ces permissions à l'initialisation d'un volume
nommé.

### Installation des éléments privilégiés sur l'EC2

```bash
cd /home/ubuntu/test-devops
git pull origin main

sudo install -o root -g root -m 0755 -d /opt/test-devops
sudo install -o root -g root -m 0644 docker-compose.prod.yml /opt/test-devops/
sudo install -o root -g root -m 0755 deploy/test-devops-deploy.sh \
  /usr/local/sbin/test-devops-deploy

sudo cp deploy/test-devops-deploy.sudoers /tmp/sudoers-check
sudo visudo -c -f /tmp/sudoers-check          # doit afficher "parsed OK"
sudo install -o root -g root -m 0440 deploy/test-devops-deploy.sudoers \
  /etc/sudoers.d/test-devops-deploy
sudo rm /tmp/sudoers-check && sudo visudo -c
```

### Vérifications de sécurité

```bash
sudo -l -U gha-runner            # un seul droit : test-devops-deploy
groups gha-runner                # ne doit pas contenir "docker"
sudo -u gha-runner docker ps     # doit échouer : permission denied

for f in /opt/test-devops /opt/test-devops/docker-compose.prod.yml \
         /usr/local/sbin/test-devops-deploy; do
  sudo -u gha-runner test -w "$f" && echo "DANGER inscriptible: $f" \
    || echo "OK: $f"
done

# Le script doit refuser ces trois appels
sudo -u gha-runner sudo -n /usr/local/sbin/test-devops-deploy
sudo -u gha-runner sudo -n /usr/local/sbin/test-devops-deploy latest
sudo -u gha-runner sudo -n /usr/local/sbin/test-devops-deploy '; id'
```

### Point d'attention sur le dépôt public

GitHub déconseille les runners auto-hébergés sur les dépôts publics : une Pull
Request issue d'un fork peut y faire exécuter du code arbitraire. La
configuration actuelle n'est pas exposée, car le job de déploiement exige
`github.ref == 'refs/heads/main'` et exclut les événements `pull_request`,
mais cette protection tomberait si la condition était assouplie. Il est
recommandé de régler « Fork pull request workflows » sur approbation requise
pour tous les contributeurs externes, ou de passer le dépôt en privé.

## Persistance SQLite

La base vit dans le volume nommé **`test-devops_tasks-data`**, monté sur
`/data` dans le conteneur backend, avec `DATABASE_PATH=/data/tasks.db`.

Un conteneur est jetable : tout ce qu'il écrit dans son propre système de
fichiers disparaît avec lui. Le volume, lui, existe indépendamment du cycle de
vie des conteneurs. Aucune ligne de code Python n'a eu besoin de changer entre
le développement local et la production, précisément parce que le chemin passe
par une variable d'environnement.

Le nom du volume est figé explicitement dans `docker-compose.prod.yml` :

```58:62:docker-compose.prod.yml
volumes:
  tasks-data:
    # Nom explicite : cible le volume SQLite déjà en service et reste le même
    # quel que soit le nom de projet. Aucun « down -v » n'est exécuté.
    name: test-devops_tasks-data
```

C'est une précaution nécessaire : par défaut Compose préfixe le nom du volume
avec le nom de projet, lui-même déduit du nom du dossier. Un dossier renommé
pointerait donc vers un volume vide, en donnant l'illusion d'une perte de
données. Le nom de projet est également figé à `test-devops`.

Le script de déploiement ne fait **jamais** `docker compose down` ni
`down -v` : il appelle `up -d`, qui recrée les conteneurs en place et laisse le
volume intact.

### À valider

**La conservation des données après un redéploiement n'a pas encore été
testée.** Le mécanisme est en place et le script n'exécute aucune commande
destructrice, mais tant que la procédure suivante n'a pas été jouée, la
persistance ne doit pas être considérée comme vérifiée :

```bash
# 1. Créer une tâche repère
curl -X POST http://localhost/api/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"temoin-persistance"}'

# 2. Relancer un déploiement (push sur main, ou manuellement)
sudo /usr/local/sbin/test-devops-deploy <sha-du-commit>

# 3. La tâche doit toujours être présente
curl http://localhost/api/tasks

# 4. Confirmer que le volume n'a pas été recréé
docker volume inspect test-devops_tasks-data --format '{{.CreatedAt}}'
```

## Tests de charge k6

Les scripts sont dans `load-tests/` et se lancent **à la main** : aucun job
CI/CD ne les déclenche, pour ne pas allonger chaque push ni charger le serveur
de production sans décision explicite.

| Script | Utilisateurs | Durée | Seuil de latence |
|---|---|---|---|
| `smoke.js` | 1 | 30 s | p95 < 500 ms |
| `load.js` | 10 | 1 min | p95 < 500 ms, global et par endpoint |
| `stress.js` | 30 | 1 min | p95 < 1500 ms |

Les trois exigent un taux d'erreur HTTP inférieur à 1 %. Seuls `GET
/api/health` et `GET /api/tasks` sont sollicités : **aucune écriture, aucune
suppression**, la base n'est pas modifiée.

### Commandes

Sans installer k6, depuis la racine du dépôt :

```bash
docker run --rm --network host \
  -v "$PWD/load-tests:/scripts:ro" \
  grafana/k6:latest run /scripts/load.js
```

Variante sans mode host, en rejoignant le réseau Compose :

```bash
docker run --rm --network test-devops_default \
  -e BASE_URL=http://frontend/api \
  -v "$PWD/load-tests:/scripts:ro" \
  grafana/k6:latest run /scripts/stress.js
```

Avec k6 installé localement :

```bash
k6 run load-tests/smoke.js
k6 run -e BASE_URL=http://mon-ec2/api load-tests/load.js
```

`BASE_URL` désigne la racine de l'API et vaut `http://localhost/api` par
défaut. k6 sort en code 0 si tous les seuils sont respectés, et en code 99 si
au moins un seuil est dépassé.

### Résultats mesurés

Relevés le **22 octobre 2026**, sur l'instance EC2 Ubuntu 24.04, via Nginx.

| Scénario | VUs | Durée | Requêtes | Erreurs | p95 | Débit |
|---|---|---|---|---|---|---|
| Charge normale | 10 | 60 s | 1 200 | 0 % | 9,57 ms | 19,8 req/s |
| Stress | 30 | 60 s | 3 600 | 0 % | 11,8 ms | 59,2 req/s |

Les deux scénarios passent largement sous leurs seuils. Le point notable est
que le p95 n'augmente que de 9,57 ms à 11,8 ms alors que le débit triple : aux
volumes testés, l'application n'est pas sous contrainte et le point de
saturation n'a pas été atteint. Ces chiffres valident le bon fonctionnement de
la pile sous charge modérée, ils ne déterminent pas sa capacité maximale.

## Limites connues

Elles sont assumées dans le cadre d'un test technique, mais doivent être
explicites.

**Le générateur de charge tourne sur la même instance EC2 que
l'application.** k6 consomme donc du CPU qui aurait pu servir à l'API, et la
latence mesurée n'inclut aucune latence réseau réelle. Les chiffres sont
optimistes par rapport à ce qu'observerait un utilisateur distant.

**Seules des requêtes GET sont testées.** Les écritures, qui sont précisément
le point faible de SQLite puisqu'elles sérialisent les accès, ne sont pas
couvertes. Un test en écriture donnerait un profil très différent.

**SQLite est un fichier local.** Il convient à une application simple, mais
interdit de répartir le backend sur plusieurs instances : elles ne
partageraient pas la base. Le backend ne tourne qu'avec un seul worker
Uvicorn.

**Aucune haute disponibilité.** Une seule instance EC2, un seul conteneur par
service, aucun équilibreur de charge, aucun basculement. Toute indisponibilité
du serveur est une indisponibilité du service, et un redéploiement provoque
une courte coupure.

**Pas de HTTPS.** Le trafic circule en clair sur le port 80.

**Pas de sauvegarde automatisée** du volume SQLite, et pas de supervision ni
de centralisation des logs : le diagnostic repose sur `docker compose logs`.

## Dépannage

**Le frontend s'affiche mais les tâches ne se chargent pas.** Le message
« Impossible de contacter l'API » signale que `/api` ne répond pas. Vérifiez
la chaîne complète :

```bash
curl -i http://localhost/api/health     # doit renvoyer 200
docker compose ps                       # les deux conteneurs "healthy" ?
docker compose logs frontend --tail 50
```

**Nginx refuse de démarrer avec `host not found in upstream "backend"`.** Il a
tenté de résoudre le nom avant que le backend ne soit prêt. C'est ce que
`depends_on` avec `condition: service_healthy` doit empêcher ; relancez
`docker compose up -d` et vérifiez que le healthcheck du backend passe.

**Le backend n'est pas `healthy`.** Souvent un problème d'écriture dans
`/data`, le conteneur tournant en non-root :

```bash
docker compose logs backend --tail 50
docker compose exec backend ls -ld /data
docker volume inspect test-devops_tasks-data
```

**`sudo: a password is required` dans le job de déploiement.** La règle
sudoers est absente ou mal nommée. Contrôlez
`/etc/sudoers.d/test-devops-deploy` (mode 0440, `root:root`) puis
`sudo -l -U gha-runner`.

**Le script échoue avec « doit être root:root et non inscriptible ».** C'est
le contrôle de sécurité qui s'active : les permissions de
`/opt/test-devops/` ou du fichier Compose ont été modifiées. Réappliquez les
commandes d'installation.

**Le script échoue avec « tag invalide ».** Il n'accepte qu'un SHA de 40
caractères hexadécimaux, pas `latest` ni un tag abrégé.

**Le job de déploiement est ignoré.** La variable `DEPLOY_ENABLED` n'est pas à
`true`, ou le push ne vise pas `main`. C'est le comportement attendu sur une
Pull Request.

**Les tâches semblent avoir disparu après un déploiement.** Avant toute autre
hypothèse, vérifiez le nom du volume : un nom de projet différent crée un
volume neuf et vide.

```bash
docker volume ls | grep tasks-data
```

## Pistes d'amélioration

Par ordre de valeur apportée.

**HTTPS et nom de domaine**, via Let's Encrypt et un renouvellement
automatique. C'est le manque le plus visible aujourd'hui.

**Sauvegarde du volume SQLite**, par une tâche planifiée utilisant
`sqlite3 .backup` plutôt qu'une copie brute du fichier, afin d'obtenir un
instantané cohérent.

**Tests de charge en écriture**, avec nettoyage des données créées, pour
mesurer le vrai point de saturation. Et exécution du générateur depuis une
machine distincte de l'application.

**Supervision**, en exposant des métriques Prometheus et en centralisant les
logs, pour détecter une dégradation avant les utilisateurs.

**Migration vers PostgreSQL** si le besoin de répartir le backend sur
plusieurs instances apparaît. C'est le préalable technique à toute
scalabilité horizontale.

**Déploiement sans coupure**, par un basculement progressif entre deux jeux de
conteneurs, une fois la base externalisée.

**Analyse de vulnérabilités des images** dans la pipeline, avec Trivy ou
équivalent, et signature des images pour garantir leur provenance.
