# 📦 TP3 — Installation d'un système avec `debootstrap` & `chroot`

## 🎯 Objectif

Construire **un système Ubuntu complet à l'intérieur d'un dossier** de notre Debian, s'y
« enfermer » avec `chroot`, y installer et y lancer un serveur web, puis vérifier depuis l'hôte
que c'est bien le système invité qui répond.

💡 **Pourquoi c'est important ?** C'est la brique de base derrière :
la construction d'images (`docker build` part exactement de ce principe),
les environnements de compilation reproductibles (`sbuild`, `pbuilder`),
le dépannage d'un système cassé depuis un live-CD, et les *rootfs* embarqués.
Comprendre `chroot`, c'est comprendre ce qu'un conteneur ajoute *par-dessus*.

---

## 📋 Prérequis

- Debian 13, session **root**, ~1 Go d'espace libre
- Accès Internet vers un miroir Ubuntu
- ⚠️ Le port **80** doit être libre (si vous avez déjà joué le TP4 : `systemctl stop nginx apache2`)

```bash
apt update
apt install -y debootstrap ubuntu-keyring curl
```

> 💡 **`ubuntu-keyring` est indispensable.** Debian ne connaît pas les clés de signature des
> dépôts Ubuntu. Sans ce paquet, `debootstrap` s'arrête sur
> `Release signed by unknown key` / `Invalid Release signature`.

---

## 1️⃣ Comprendre `chroot` avant de l'utiliser

`chroot` (*change root*) change la racine `/` vue par un processus et ses enfants.

```
Hôte Debian                          Vue depuis le chroot
/                                    (inaccessible)
├── etc/                             
├── home/                            
└── ubuntu/          ← nouvelle racine →   /
    ├── etc/                              ├── etc/
    ├── usr/                              ├── usr/
    └── var/www/html/index.html           └── var/www/html/index.html
```

**Ce que `chroot` isole :** l'arborescence de fichiers. **C'est tout.**

| | Isolé par `chroot` ? | Isolé par un conteneur ? |
|---|---|---|
| Système de fichiers | ✅ | ✅ |
| Processus (PID) | ❌ | ✅ (namespace PID) |
| Réseau / ports | ❌ | ✅ (namespace net) |
| Utilisateurs | ❌ | ✅ (namespace user) |
| Ressources CPU/RAM | ❌ | ✅ (cgroups) |
| Noyau | ❌ partagé | ❌ partagé |

⚠️ **`chroot` n'est PAS une frontière de sécurité.** Un root dans un chroot peut en sortir.
C'est un outil de *construction*, pas de *confinement*.

---

## 2️⃣ Créer le système invité

```bash
mkdir -p /root/ubuntu
cd /root

debootstrap --arch=amd64 noble /root/ubuntu http://ubuntu.nautile.nc/ubuntu/
```

Décomposition de la commande :

| Argument | Signification |
|---|---|
| `--arch=amd64` | Architecture cible |
| `noble` | Nom de code de la version : **Ubuntu 24.04 LTS « Noble Numbat »** |
| `/root/ubuntu` | Dossier de destination (créé s'il n'existe pas) |
| `http://ubuntu.nautile.nc/ubuntu/` | Miroir APT — celui-ci est **local à la Nouvelle-Calédonie**, donc rapide. Miroir générique : `http://archive.ubuntu.com/ubuntu/` |

> ⚠️ N'utilisez **pas** `bionic` (Ubuntu 18.04) : sa fin de support standard remonte à 2023, elle
> n'est plus sur les miroirs classiques et `debootstrap` échouera. Suites disponibles :
> `ls /usr/share/debootstrap/scripts/`

L'opération prend 2 à 5 minutes. Elle se déroule en deux temps :
1. **Téléchargement** des paquets `Priority: required` (`.deb` bruts)
2. **Dépaquetage puis configuration** dans un environnement minimal

✅ Vérifications :

```bash
du -sh /root/ubuntu                        # ~350-450 Mo
ls /root/ubuntu                            # une arborescence Linux complète
cat /root/ubuntu/etc/os-release | head -3  # -> Ubuntu 24.04 LTS
```

---

## 3️⃣ Préparer les montages système

Le système invité a besoin des pseudo-systèmes de fichiers du noyau. Sans eux, APT, `ps`,
et beaucoup de scripts postinst échouent de façon obscure.

```bash
mount --bind /dev     /root/ubuntu/dev
mount --bind /dev/pts /root/ubuntu/dev/pts
mount -t proc  proc   /root/ubuntu/proc
mount -t sysfs sys    /root/ubuntu/sys

# Résolution DNS depuis l'invité
cp /etc/resolv.conf /root/ubuntu/etc/resolv.conf

# ✅ Contrôle
findmnt | grep ubuntu
```

---

## 4️⃣ Entrer dans le chroot et installer Apache

```bash
chroot /root/ubuntu /bin/bash
```

Votre invite change. **Vous êtes maintenant dans Ubuntu.** Constatez-le :

```bash
cat /etc/os-release          # Ubuntu 24.04
ls /                         # l'arborescence de l'invité
ls /root                     # vide : le /root de l'hôte est invisible
```

Installez le serveur web :

```bash
# Activer les dépôts complets (debootstrap ne met que "main")
cat > /etc/apt/sources.list <<'EOF'
deb http://ubuntu.nautile.nc/ubuntu/ noble main restricted universe multiverse
deb http://ubuntu.nautile.nc/ubuntu/ noble-updates main restricted universe multiverse
deb http://ubuntu.nautile.nc/ubuntu/ noble-security main restricted universe multiverse
EOF

apt-get update
apt-get install -y apache2

# systemd n'est pas PID 1 ici : on démarre via le script SysV
/etc/init.d/apache2 start
/etc/init.d/apache2 status

# On sort du chroot
exit
```

> 💡 **Pourquoi `/etc/init.d/apache2` et pas `systemctl` ?** Un chroot partage le PID 1 de l'hôte.
> `systemctl` parlerait au systemd de **Debian**, qui ne connaît pas les services de l'invité.
> Les scripts SysV, eux, sont de simples scripts shell qui lancent le binaire directement.

---

## 5️⃣ Vérifier depuis l'hôte

C'est ici que tout se joue : le processus tourne dans le chroot, mais **le réseau est partagé**.

```bash
# ✅ Le serveur du chroot répond sur le port 80 de l'hôte
curl localhost

# Le processus est visible depuis l'hôte : chroot n'isole pas les PID
ps aux | grep apache2

# Et sa racine pointe vers notre dossier — la preuve du chroot
ls -l /proc/$(pgrep -f apache2 | head -1)/root
# -> /proc/1234/root -> /root/ubuntu

# Le port est bien détenu par ce processus
ss -tlnp | grep :80
```

Modifions la page **depuis l'hôte**, dans le dossier de l'invité :

```bash
echo "Hello World depuis le chroot Ubuntu" > /root/ubuntu/var/www/html/index.html

# ✅ Le serveur sert bien les fichiers du chroot
curl localhost
```

On peut aussi exécuter une commande ponctuelle dans le chroot sans y entrer :

```bash
chroot /root/ubuntu /etc/init.d/apache2 status
chroot /root/ubuntu apt list --installed 2>/dev/null | wc -l
```

---

## 6️⃣ 🧹 Nettoyage — l'étape la plus dangereuse du TP

⚠️ **Démontez AVANT de supprimer.** Un `rm -rf /root/ubuntu` alors que `/dev` y est monté en
bind supprime le contenu du **`/dev` de l'hôte** et casse la machine.

```bash
# 1. Arrêter le service
chroot /root/ubuntu /etc/init.d/apache2 stop

# 2. Démonter, dans l'ordre inverse du montage
umount /root/ubuntu/dev/pts
umount /root/ubuntu/dev
umount /root/ubuntu/proc
umount /root/ubuntu/sys

# 3. ✅ CONTRÔLE OBLIGATOIRE : cette commande ne doit RIEN afficher
findmnt | grep ubuntu

# 4. Seulement maintenant
rm -rf /root/ubuntu
```

> 💡 En cas de doute, `umount -R /root/ubuntu` démonte récursivement. Si un `umount` renvoie
> `target is busy`, cherchez le coupable avec `lsof +D /root/ubuntu` ou `fuser -vm /root/ubuntu`.

---

## 🏋️ Pour aller plus loin

1. **Gain de place** — refaites un debootstrap avec `--variant=minbase` et comparez les tailles.
2. **Deux étapes** — utilisez `--foreign` / `--second-stage` : c'est la technique pour construire
   un rootfs ARM sur une machine x86 (avec `qemu-user-static`).
3. **`systemd-nspawn`** — le chroot moderne, avec vrais namespaces et un systemd invité :
   ```bash
   apt install -y systemd-container
   systemd-nspawn -D /root/ubuntu --boot
   ```
   Comparez `ps aux` à l'intérieur avec ce que donnait `chroot`.
4. **Le lien avec Docker** — exportez votre rootfs en image :
   ```bash
   tar -C /root/ubuntu -c . | docker import - mon-ubuntu:tp3
   docker run --rm -it mon-ubuntu:tp3 cat /etc/os-release
   ```

---

## 🆘 Dépannage

| Erreur | Cause | Solution |
|---|---|---|
| `Release signed by unknown key` | Trousseau Ubuntu absent | `apt install ubuntu-keyring` |
| `E: Invalid Release file` | Suite inexistante ou EOL (ex. `bionic`) | Utiliser `noble` ; vérifier `ls /usr/share/debootstrap/scripts/` |
| `chroot: failed to run /bin/bash: Exec format error` | Architecture incompatible | Vérifier `--arch`, ou installer `qemu-user-static` |
| `apt-get update` sans réseau dans le chroot | `resolv.conf` non copié | `cp /etc/resolv.conf /root/ubuntu/etc/` |
| `Address already in use` sur le port 80 | Un serveur tourne déjà sur l'hôte | `ss -tlnp \| grep :80` puis arrêter le service |
| `umount: target is busy` | Un processus est encore dans le chroot | `fuser -vm /root/ubuntu`, tuer, puis `umount -R` |
