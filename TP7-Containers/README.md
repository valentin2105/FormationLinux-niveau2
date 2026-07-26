# 🐳 TP7 — Conteneurs : Docker, Compose & Kubernetes

## 🎯 Objectifs

1. 🐋 Installer Docker sur Debian 13 (la méthode 2025, `apt-key` n'existe plus)
2. 🐍 Conteneuriser une application Python Flask et écrire un `Dockerfile` propre
3. 📦 Déployer un **registre privé** et y pousser son image
4. 🎛️ Gérer ses conteneurs avec **Portainer**
5. 🧩 Orchestrer une stack multi-services avec **Docker Compose**
6. ☸️ Découvrir Kubernetes avec **k3s / k3d**

💡 **Rappel du TP3 :** un conteneur, c'est un `chroot` (systèmes de fichiers) **+ namespaces**
(PID, réseau, utilisateurs, montages) **+ cgroups** (limites CPU/RAM). Il **partage le noyau
de l'hôte** — c'est ce qui le rend léger, et ce qui le distingue d'une machine virtuelle.

---

## 📋 Prérequis

- Debian 13, session **root** (ou un utilisateur `sudo`)
- 4 Go de RAM minimum, 10 Go d'espace disque libre
- Accès Internet (Docker Hub, ou le registre interne `docker.ntl.nc`)

> 💡 Les images `docker.ntl.nc/...` citées dans ce TP proviennent d'un **miroir interne**.
> Hors de ce réseau, remplacez-les par leur équivalent Docker Hub
> (`docker.ntl.nc/debian:buster` → `debian:trixie`, `docker.ntl.nc/nginx` → `nginx`, etc.).

---

## 1️⃣ 🐋 Installer Docker

### ⚠️ La méthode obsolète (ne fonctionne plus sur Debian 13)

On croise partout ces commandes. **Elles échouent toutes les deux sur Debian 13 :**

```bash
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -   # ❌
add-apt-repository "deb [arch=amd64] https://download.docker.com/..."          # ❌
```

| Commande | Pourquoi elle échoue |
|---|---|
| `apt-key` | **Supprimée** d'APT. Elle ajoutait les clés dans un trousseau global : *n'importe quel* dépôt pouvait alors signer *n'importe quel* paquet. |
| `add-apt-repository` | Fournie par `software-properties-common`, **retiré de Debian 13**. |

### ✅ La méthode actuelle : une clé par dépôt (`signed-by`)

```bash
apt-get update
apt-get install -y ca-certificates curl gnupg

# 1. La clé de signature, dans son propre fichier
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
     -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# 2. Le dépôt, explicitement lié à CETTE clé et à elle seule
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

# 3. Installation
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin
```

| Paquet | Rôle |
|---|---|
| `docker-ce` | Le démon `dockerd` |
| `docker-ce-cli` | La commande `docker` |
| `containerd.io` | Le moteur d'exécution de conteneurs sous-jacent |
| `docker-buildx-plugin` | `docker buildx` : construction multi-architecture |
| `docker-compose-plugin` | `docker compose` (**v2**, en sous-commande — l'ancien `docker-compose` en tiret est mort) |

```bash
systemctl enable --now docker

# ✅ Vérifications
systemctl status docker
docker version
docker info | head -20
docker run --rm hello-world
```

### Utiliser Docker sans `sudo`

```bash
usermod -aG docker VOTRE_UTILISATEUR
# Déconnexion / reconnexion, puis :
docker ps
```

> ⚠️ **C'est un privilège équivalent à root.** Le groupe `docker` permet de monter `/` dans un
> conteneur privilégié. Ne l'accordez qu'à des administrateurs.

### Premiers pas

```bash
# Un conteneur interactif, supprimé à la sortie
docker run --rm -it debian:trixie bash
  cat /etc/os-release
  ps aux              # 💡 seulement quelques processus : namespace PID
  ls /                # un rootfs Debian complet
  exit

# Les commandes de base
docker ps             # conteneurs en cours
docker ps -a          # y compris arrêtés
docker images         # images locales
docker logs NOM
docker exec -it NOM bash
docker stop NOM && docker rm NOM
docker system df      # espace disque consommé
```

---

## 2️⃣ 🐍 Conteneuriser l'application PyApp

📁 [`PyApp/`](PyApp/) — une petite API Flask.

### Étape 1 — La faire tourner « à la main » d'abord

**Toujours faire fonctionner l'application hors conteneur avant de la conteneuriser.** Sinon
vous déboguerez deux problèmes à la fois.

```bash
cd TP7-Containers/PyApp
cat hello.py

apt-get install -y python3 python3-flask
python3 hello.py
```

> ⚠️ **Deux pièges classiques ici :**
> 1. Le fichier s'appelle **`hello.py`**, pas `app.py`.
> 2. **`jsonify` n'est pas un paquet PyPI à installer.** C'est une fonction *de Flask*
>    (`from flask import jsonify`). Le paquet nommé `jsonify` sur PyPI est un convertisseur
>    CSV→JSON sans aucun rapport. `pip install flask jsonify` installe donc un paquet parasite.
> 3. Depuis Debian 12, `pip install` en dehors d'un venv est **bloqué** (PEP 668 :
>    `externally-managed-environment`). Utilisez le paquet Debian `python3-flask`, ou un
>    environnement virtuel : `python3 -m venv .venv && .venv/bin/pip install flask`.

✅ Dans un autre terminal : `curl localhost:5000` → `"Hello Formation Linux niveau 2 !"`

### Étape 2 — Le Dockerfile

📄 [`PyApp/Dockerfile`](PyApp/Dockerfile)

```dockerfile
FROM docker.ntl.nc/alpine:latest

RUN apk update && \
    apk add python3 && \
    pip3 install --upgrade pip

RUN pip3 install flask jsonify
ADD hello.py /
EXPOSE 5000
ENTRYPOINT ["python3", "/hello.py"]
```

🐛 **Ce Dockerfile ne construit plus.** Trouvez pourquoi avant de lire la suite :

<details>
<summary>Les quatre défauts</summary>

| # | Problème | Correction |
|---|---|---|
| 1 | `apk add python3` **ne fournit pas `pip3`** sur Alpine moderne | Ajouter `py3-pip` |
| 2 | Alpine applique **PEP 668** : `pip install` système est refusé | Installer `py3-flask` via `apk`, ou `--break-system-packages`, ou un venv |
| 3 | `jsonify` est un paquet PyPI **sans rapport** avec Flask | Le retirer |
| 4 | `FROM ...:latest` n'est pas reproductible ; `ADD` est à réserver aux archives/URL | Épingler la version ; utiliser `COPY` |

</details>

Version corrigée :

```dockerfile
FROM alpine:3.21

RUN apk add --no-cache python3 py3-flask

WORKDIR /app
COPY hello.py .

# 🔒 Ne jamais tourner en root sans raison
RUN adduser -D -u 10001 appuser
USER appuser

EXPOSE 5000
ENTRYPOINT ["python3", "/app/hello.py"]
```

### Étape 3 — Construire et lancer

```bash
docker build -t pyapp:v1 .

docker images | grep pyapp
docker history pyapp:v1        # 💡 voir le coût de chaque couche

docker run -d --name pyapp -p 5000:5000 pyapp:v1

# ✅ Vérifications
docker ps
docker logs pyapp
curl localhost:5000
```

### 📐 Les bonnes pratiques Dockerfile

📄 À analyser : [`Dockerfile_goodpractice`](Dockerfile_goodpractice) et
[`Dockerfile_scratch`](Dockerfile_scratch), ainsi que l'illustration
[`java-dualstep.jpg`](java-dualstep.jpg) sur la construction multi-étages.

| Règle | Pourquoi |
|---|---|
| **Une image de base minimale** (`alpine`, `-slim`, `distroless`) | Moins de code = moins de failles et une image plus légère |
| **Épingler les versions** (`alpine:3.21`, pas `latest`) | Reproductibilité des constructions |
| **Grouper les `RUN`** et nettoyer dans la **même** couche | Un `rm` dans une couche suivante ne récupère aucun espace |
| **`COPY` plutôt que `ADD`** | `ADD` décompresse et télécharge : effets de bord |
| **Dépendances d'abord, code ensuite** | Le cache des couches n'est pas invalidé à chaque modification de code |
| **`USER` non-root** | Limite l'impact d'une compromission |
| **`.dockerignore`** | Évite d'envoyer `.git`, `node_modules`… au démon |
| **Multi-étages** | On compile dans une image lourde, on n'expédie que le binaire |

🏋️ **Exercice :** [`Dockerfile_goodpractice`](Dockerfile_goodpractice) porte mal son nom.
Listez ses problèmes (base `buster` en fin de vie, Node.js 12 obsolète, `ADD`, `CMD` en forme
shell, exécution en root, dossier `app/` absent du dépôt…) puis réécrivez-le en multi-étages.

---

## 3️⃣ 📦 Registre privé

```bash
mkdir -p /mnt/registry

docker run -d \
  -p 5000:5000 \
  --restart=always \
  --name registry \
  -v /mnt/registry:/var/lib/registry \
  registry:2
```

⚠️ Le registre écoute sur le port **5000**, comme PyApp. Arrêtez PyApp
(`docker stop pyapp`) ou publiez le registre sur un autre port (`-p 5001:5000`).

Docker refuse le HTTP en clair par défaut. Il faut déclarer le registre comme *insecure* :

📄 [`daemon.json`](daemon.json) → à placer dans `/etc/docker/daemon.json`

```bash
cp daemon.json /etc/docker/daemon.json
cat /etc/docker/daemon.json
systemctl restart docker

# ✅ Vérification
docker info | grep -A2 "Insecure Registries"
```

> ⚠️ `insecure-registries` désactive TLS. Acceptable en TP ou sur un réseau d'administration
> isolé, **jamais** sur un réseau de production : les couches d'images transitent en clair et
> peuvent être altérées.

### Pousser et récupérer une image

```bash
# Le "tag" contient l'adresse du registre : c'est lui qui décide de la destination
docker tag pyapp:v1 localhost:5000/pyapp:v1
docker push localhost:5000/pyapp:v1

# ✅ Interroger l'API du registre
curl -s localhost:5000/v2/_catalog | jq
curl -s localhost:5000/v2/pyapp/tags/list | jq

# Test complet : on supprime l'image locale et on la retélécharge
docker rmi pyapp:v1 localhost:5000/pyapp:v1
docker pull localhost:5000/pyapp:v1
docker images
```

---

## 4️⃣ 🎛️ Portainer

Une interface web pour piloter Docker.

```bash
docker volume create portainer_data

docker run -d \
  --name portainer \
  --restart=always \
  -p 8000:8000 -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
```

🌐 `https://IP_DU_SERVEUR:9443` — créez le compte admin **dans les 5 minutes** (Portainer
verrouille l'initialisation au-delà, il faut alors redémarrer le conteneur).

> ⚠️ **`-v /var/run/docker.sock:...` donne à ce conteneur le contrôle total de l'hôte.**
> Quiconque accède à Portainer est root sur la machine. Ne l'exposez jamais sur Internet.

---

## 5️⃣ 🧩 Docker Compose

Compose décrit une stack multi-conteneurs dans un fichier YAML, versionnable.

### Stack simple : WordPress + MariaDB

📄 [`Compose/docker-compose.yml`](Compose/docker-compose.yml)

```bash
cd TP7-Containers/Compose
docker compose up -d           # ⚠️ "docker compose" (v2), pas "docker-compose"

docker compose ps
docker compose logs -f wordpress     # Ctrl+C pour quitter
```

> 🐛 Ce fichier commence par `version: '3.3'`. **Cette clé est obsolète** depuis Compose v2 et
> génère un avertissement. Supprimez-la : le format est désormais déduit automatiquement.

⚠️ Aucun port n'est publié dans ce fichier : WordPress n'est pas joignable en l'état.
🏋️ **Exercice :** ajoutez `ports: ["8080:80"]` au service `wordpress` et rechargez avec
`docker compose up -d`.

```bash
docker compose down            # arrêter (les volumes sont conservés)
docker compose down -v         # ⚠️ arrêter ET supprimer les données
```

### Stack complète : reverse proxy + WordPress + PyApp

📄 [`Compose/full/docker-compose.yml`](Compose/full/docker-compose.yml)

Cette stack ajoute **nginx-proxy**, qui lit le socket Docker, détecte la variable
`VIRTUAL_HOST` de chaque conteneur et génère automatiquement la configuration nginx.
Un seul port 80 exposé, plusieurs sites servis par nom de domaine.

**Architecture réseau — le point important :**

```
                    réseau "frontend"          réseau "backend"
Internet :80 → [nginx-proxy] ─┬─→ [wordpress] ─────→ [db]
                              └─→ [pyapp]

💡 "db" n'est PAS sur le réseau frontend : il est injoignable
   depuis le proxy et depuis pyapp. C'est de la segmentation réseau.
```

```bash
cd TP7-Containers/Compose/full

# L'image "hello:latest" attendue par le service pyapp doit exister localement
docker build -t hello:latest ../../PyApp/

# nginx-proxy route par nom d'hôte : il faut résoudre ces noms
# ⚠️ Sur VOTRE POSTE (pas sur le serveur), ajoutez à /etc/hosts :
#    IP_DU_SERVEUR   wordpress.nc pyapp.nc

docker compose up -d
docker compose ps
```

✅ Vérifications :

```bash
# Le routage par nom d'hôte, sans toucher à /etc/hosts
curl -H "Host: pyapp.nc"     http://IP_DU_SERVEUR/
curl -H "Host: wordpress.nc" http://IP_DU_SERVEUR/

# La segmentation réseau : pyapp ne DOIT PAS joindre la base
docker compose exec pyapp ping -c1 db      # -> échec attendu ✅
docker network inspect full_backend
```

> 🐛 **Incohérence à corriger :** le service `pyapp` monte `./hello.py:/app/hello.py`, alors que
> le `Dockerfile` de PyApp place le script à la racine (`/hello.py`) et l'`ENTRYPOINT` pointe
> sur `/hello.py`. Le montage est donc **sans effet**. Corrigez le Dockerfile (`WORKDIR /app`)
> ou le chemin de montage pour qu'ils concordent.

> ⚠️ **Sécurité :** les mots de passe sont en clair dans le YAML versionné. En production :
> fichier `.env` hors dépôt, ou Docker secrets.

---

## 6️⃣ ☸️ Kubernetes avec k3s / k3d

**k3s** est une distribution Kubernetes allégée (un seul binaire ~70 Mo).
**k3d** fait tourner des clusters k3s **dans des conteneurs Docker** — idéal pour un TP :
créer et détruire des clusters coûte quelques secondes.

### Installer `kubectl`

> ⚠️ Le dépôt `apt.kubernetes.io` / `kubernetes-xenial` que l'on trouve dans les vieux
> tutoriels est **hors service depuis mars 2024** (il renvoie 404). Le dépôt actuel est
> `pkgs.k8s.io`.

```bash
apt-get install -y apt-transport-https ca-certificates curl gnupg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update && apt-get install -y kubectl
kubectl version --client
```

### Créer un cluster avec k3d

```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d version
```

> ⚠️ **La syntaxe de k3d a changé.** Les commandes de la v1 (`k3d create --name dev`,
> `k3d get-kubeconfig`) n'existent plus. Depuis la v3, tout passe par des sous-commandes :

```bash
# Créer un cluster nommé "dev", avec le port 80 du cluster publié sur le 8081 de l'hôte
k3d cluster create dev --api-port 6551 -p "8081:80@loadbalancer"

k3d cluster list
kubectl config get-contexts          # k3d configure kubectl automatiquement

# ✅ Vérifications
kubectl get nodes
kubectl get pods -A
kubectl cluster-info
```

<details>
<summary>Variante : k3s directement sur l'hôte (sans Docker)</summary>

```bash
curl -sfL https://get.k3s.io | sh -

systemctl status k3s
k3s kubectl get node

# kubectl standard : la kubeconfig est dans /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes

# Ajouter un nœud agent depuis une AUTRE machine
# (le jeton se trouve dans /var/lib/rancher/k3s/server/node-token du serveur)
curl -sfL https://get.k3s.io | K3S_URL=https://SERVEUR:6443 K3S_TOKEN=LE_JETON sh -
```
</details>

### Déployer une application

📄 [`k3s/nginx-manifest.yaml`](k3s/nginx-manifest.yaml) et [`k3s/pyapp.yml`](k3s/pyapp.yml)

> 🐛 **Ces deux manifestes ne s'appliquent plus tels quels.** Ils déclarent leur Ingress en
> `apiVersion: extensions/v1beta1`, **supprimée de Kubernetes en 1.22** (2021). L'API actuelle
> est `networking.k8s.io/v1`, avec une structure de `backend` différente.

Ingress au format actuel :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: traefik          # l'Ingress Controller livré avec k3s
  rules:
  - host: nginx.nc
    http:
      paths:
      - path: /
        pathType: Prefix             # champ désormais obligatoire
        backend:
          service:
            name: nginx              # anciennement serviceName
            port:
              number: 80             # anciennement servicePort
```

```bash
cd TP7-Containers/k3s

# ⚠️ pyapp.yml déclare "namespace: pyapp" sans jamais le créer
kubectl create namespace pyapp

kubectl apply -f nginx-manifest.yaml

# ✅ Vérifications
kubectl get deploy,pods,svc,ingress
kubectl describe deployment nginx
kubectl logs -l app=nginx

curl -H "Host: nginx.nc" http://localhost:8081/
```

### Les objets Kubernetes à retenir

| Objet | Rôle |
|---|---|
| **Pod** | La plus petite unité déployable : un ou plusieurs conteneurs partageant réseau et volumes |
| **Deployment** | Maintient N réplicas d'un Pod, gère les mises à jour progressives et les retours arrière |
| **Service** | IP et nom DNS stables devant un ensemble de Pods éphémères, avec répartition de charge |
| **Ingress** | Routage HTTP entrant (par nom d'hôte / chemin) vers les Services |
| **Namespace** | Cloisonnement logique des ressources |
| **ConfigMap / Secret** | Configuration et données sensibles, découplées de l'image |

### Exercices

```bash
# Montée en charge
kubectl scale deployment nginx --replicas=5
kubectl get pods -w                     # Ctrl+C pour quitter

# Auto-réparation : supprimez un pod, observez son remplacement immédiat
kubectl delete pod -l app=nginx --wait=false
kubectl get pods -w

# Mise à jour progressive et retour arrière
kubectl set image deployment/nginx nginx=nginx:1.27
kubectl rollout status deployment/nginx
kubectl rollout undo deployment/nginx
```

🏋️ **Exercice final :** poussez votre image `pyapp:v1` dans le cluster
(`k3d image import pyapp:v1 -c dev`), corrigez [`pyapp.yml`](k3s/pyapp.yml)
(Ingress v1 + namespace + nom d'image), déployez, et joignez l'application via son Ingress.

---

## 🧹 Nettoyage

```bash
# Kubernetes
k3d cluster delete dev

# Compose
cd TP7-Containers/Compose/full && docker compose down -v
cd ../ && docker compose down -v

# Conteneurs et images
docker rm -f pyapp registry portainer
docker system prune -a --volumes        # ⚠️ supprime TOUT ce qui n'est pas utilisé
docker system df
```

---

## 🆘 Dépannage

| Problème | Cause | Solution |
|---|---|---|
| `apt-key: command not found` | Retiré de Debian 13 | Utiliser la méthode `signed-by` (§1) |
| `add-apt-repository: command not found` | `software-properties-common` absent de Debian 13 | Écrire le fichier `.list` à la main |
| `permission denied ... /var/run/docker.sock` | Utilisateur hors du groupe `docker` | `usermod -aG docker $USER` + reconnexion |
| `port is already allocated` | Port déjà pris (5000 : registre vs PyApp) | `ss -tlnp`, changer le port publié |
| `http: server gave HTTP response to HTTPS client` | Registre en clair non déclaré | `/etc/docker/daemon.json` + `systemctl restart docker` |
| `externally-managed-environment` | PEP 668 | Paquet système ou venv, pas `pip install` global |
| `no matches for kind "Ingress" in version "extensions/v1beta1"` | API supprimée en k8s 1.22 | Migrer vers `networking.k8s.io/v1` |
| `namespaces "pyapp" not found` | Namespace non créé | `kubectl create namespace pyapp` |
| `ImagePullBackOff` | Image absente du registre du cluster | `k3d image import IMAGE -c dev` |
| `unknown shorthand flag` avec k3d | Syntaxe k3d v1 | `k3d cluster create ...` (v5) |
