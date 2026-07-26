# 📊 TP5 — Supervision & sauvegarde

## 🎯 Objectif

| Volet | Outil | Rôle |
|---|---|---|
| 📈 **Métriques** | **Netdata** | Observer : des milliers de métriques temps réel, tableau de bord web |
| 🚨 **Services** | **Monit** | Réagir : surveille les processus et **les redémarre** automatiquement |
| 💾 **Sauvegarde locale** | **Rsnapshot** | Sauvegardes incrémentales par rotation, restauration par simple `cp` |
| 🔐 **Sauvegarde chiffrée** | **Restic** | Sauvegarde dédupliquée et chiffrée, prête pour un stockage distant |

💡 **Supervision ≠ monitoring.** *Monitorer*, c'est mesurer et afficher (Netdata). *Superviser*,
c'est décider et agir sur ce qui est mesuré (Monit). Les deux sont complémentaires.

---

## 📋 Prérequis

- Debian 13, session **root**
- Le TP1 joué (le volume `/mnt/lvbtrfs` sert de destination de sauvegarde) — sinon, adaptez les chemins
- Un port web joignable depuis votre poste (19999 pour Netdata, 2812 pour Monit)

```bash
apt update
apt install -y curl rsync
```

---

# 📈 Partie 1 — Netdata (métriques)

Netdata **n'est pas empaqueté dans Debian 13**. On passe par le script officiel.

```bash
curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh

# 💡 Bonne pratique : on LIT un script avant de l'exécuter en root
less /tmp/netdata-kickstart.sh

sh /tmp/netdata-kickstart.sh --stable-channel --disable-telemetry
```

| Option | Effet |
|---|---|
| `--stable-channel` | Version stable plutôt que *nightly* |
| `--disable-telemetry` | Pas de remontée anonyme vers Netdata Cloud |
| `--dont-start-it` | Installe sans démarrer (utile pour préconfigurer) |

✅ Vérifications :

```bash
systemctl status netdata
ss -tlnp | grep 19999
curl -s localhost:19999/api/v1/info | head -20
```

🌐 **Tableau de bord :** `http://IP_DU_SERVEUR:19999`

Explorez : CPU, RAM, disques, réseau, et surtout la section **Applications** — Netdata
détecte automatiquement nginx, systemd, et les services installés.

> ⚠️ **Netdata écoute sur toutes les interfaces sans authentification.** En production, on le
> restreint à `localhost` et on le publie derrière un reverse proxy authentifié :
> ```
> # /etc/netdata/netdata.conf
> [web]
>     bind to = 127.0.0.1
> ```
> puis `systemctl restart netdata`.

---

# 🚨 Partie 2 — Monit (supervision active)

```bash
apt install -y monit
```

### Configuration de l'interface web

```bash
nano /etc/monit/monitrc
```

Ajoutez **à la fin** du fichier :

```monit
set httpd port 2812
    use address 0.0.0.0
    allow 0.0.0.0/0
    allow admin:monit
```

| Directive | Rôle |
|---|---|
| `set httpd port 2812` | Active l'interface web ET l'API locale utilisée par `monit status` |
| `use address` | Interface d'écoute (`localhost` pour restreindre) |
| `allow RESEAU` | Liste blanche d'adresses |
| `allow user:pass` | Authentification HTTP |

> ⚠️ `admin:monit` est un couple d'identifiants de démonstration. **Changez-le.** Et en
> production, préférez `use address localhost` + tunnel SSH plutôt qu'une exposition publique.

Par défaut, Monit vérifie tout **toutes les 30 secondes** (`set daemon 30` en haut du fichier).

```bash
# ✅ Valider la syntaxe AVANT de redémarrer
monit -t

systemctl restart monit
monit summary
monit status
```

### Surveiller un service

Monit range ses règles dans `/etc/monit/conf.d/`. Créons une surveillance de nginx :

```bash
cat > /etc/monit/conf.d/nginx <<'EOF'
check process nginx with pidfile /run/nginx.pid
    start program = "/bin/systemctl start nginx"
    stop  program = "/bin/systemctl stop nginx"
    restart program = "/bin/systemctl restart nginx"

    # Si le port 80 ne répond pas en HTTP -> redémarrage
    if failed host 127.0.0.1 port 80 protocol http
        with timeout 10 seconds
        for 2 cycles
    then restart

    # Trop de redémarrages : on arrête d'insister et on alerte
    if 3 restarts within 5 cycles then unmonitor
EOF

monit -t                    # validation syntaxique
systemctl restart monit
```

✅ Vérification :

```bash
monit summary               # nginx doit apparaître en "OK"
monit status nginx
```

🌐 **Interface web :** `http://IP_DU_SERVEUR:2812` (admin / monit)

### 🧪 Le test qui prouve que ça marche

```bash
# On tue nginx brutalement
systemctl stop nginx
ss -tlnp | grep :80          # plus rien

# On attend deux cycles (~60 s)
sleep 70

# ✅ Monit l'a relancé tout seul
systemctl is-active nginx
ss -tlnp | grep :80
journalctl -u monit -n 20 --no-pager
```

### Autres sondes utiles

```monit
check system $HOST
    if loadavg (5min) > 4 for 3 cycles then alert
    if memory usage > 85% for 5 cycles then alert
    if cpu usage (user) > 90% for 5 cycles then alert

check filesystem rootfs with path /
    if space usage > 85% then alert
    if inode usage > 85% then alert

check host site with address exemple.nc
    if failed port 443 protocol https for 3 cycles then alert
```

### Activer au démarrage

```bash
systemctl enable monit
systemctl enable netdata
systemctl is-enabled monit netdata      # ✅ enabled / enabled
```

---

# 💾 Partie 3 — Rsnapshot (sauvegarde incrémentale)

💡 **Le principe (et sa beauté) :** rsnapshot combine `rsync` et les **liens physiques**
(*hard links*). Un fichier inchangé entre deux sauvegardes n'est pas recopié : c'est le même
inode, référencé deux fois. Résultat : **N sauvegardes complètes, pour le coût disque d'une
seule + les deltas.** Et comme chaque sauvegarde est une arborescence normale, la restauration
se fait avec un simple `cp`.

```bash
apt install -y rsnapshot
mkdir -p /mnt/lvbtrfs/backups
```

### Configuration

```bash
cp /etc/rsnapshot.conf /etc/rsnapshot.conf.orig
nano /etc/rsnapshot.conf
```

⚠️ **Le piège n°1 de rsnapshot : le fichier utilise des TABULATIONS**, pas des espaces, comme
séparateurs de champs. Une seule espace et c'est `ERROR: /etc/rsnapshot.conf on line X`.

Points à régler :

```conf
snapshot_root	/mnt/lvbtrfs/backups/

retain	alpha	6      # 6 sauvegardes "alpha"  (ex. toutes les 4 h)
retain	beta	7      # 7 "beta"                (quotidiennes)
retain	gamma	4      # 4 "gamma"               (hebdomadaires)

backup	/var/www/html/	localhost/
backup	/etc/	localhost/
```

> 💡 `alpha`, `beta`, `gamma` sont de simples **noms de niveaux de rotation**. C'est le
> planificateur (cron/systemd timer) qui décide de leur fréquence réelle.

```bash
# ✅ Valider la configuration (détecte les erreurs de tabulation)
rsnapshot configtest        # -> "Syntax OK"

# Simulation : affiche ce qui serait fait, sans rien écrire
rsnapshot -t alpha
```

### Exécution

```bash
rsnapshot alpha

# ✅ Vérifications
ls -l /mnt/lvbtrfs/backups/                     # -> alpha.0/
du -sh /mnt/lvbtrfs/backups/alpha.0/
ls /mnt/lvbtrfs/backups/alpha.0/localhost/
```

**La démonstration des liens physiques :**

```bash
rsnapshot alpha            # 2e passage : alpha.0 devient alpha.1, un nouveau alpha.0 est créé

ls -l /mnt/lvbtrfs/backups/                     # alpha.0 ET alpha.1

# Deux sauvegardes complètes, mais le même inode pour un fichier inchangé
ls -i /mnt/lvbtrfs/backups/alpha.{0,1}/localhost/var/www/html/index.html
# -> même numéro d'inode = zéro octet consommé en double

du -sh /mnt/lvbtrfs/backups/alpha.0 /mnt/lvbtrfs/backups/alpha.1
du -sh /mnt/lvbtrfs/backups/          # le total ≈ une seule sauvegarde
```

### Automatisation

```bash
crontab -e
```

```cron
0  */4  *  *  *   /usr/bin/rsnapshot alpha
30  3   *  *  *   /usr/bin/rsnapshot beta
0   3   *  *  1   /usr/bin/rsnapshot gamma
```

⚠️ **Décalez les horaires.** Si `alpha` et `beta` démarrent à la même minute, les rotations se
marchent dessus.

🏋️ **Exercice :** supprimez `/var/www/html/index.html`, puis restaurez-le depuis `alpha.1`.
Combien de commandes ? (C'est le grand avantage de rsnapshot.)

---

# 🔐 Partie 4 — Restic (sauvegarde chiffrée et dédupliquée)

Là où rsnapshot fait du miroir local en clair, **restic chiffre tout** (AES-256), déduplique au
niveau des blocs et sait écrire vers S3, Backblaze, SFTP, rclone…

Restic **est packagé dans Debian 13** — inutile de le télécharger à la main :

```bash
apt install -y restic
restic version
```

<details>
<summary>Variante : installation manuelle de la dernière version depuis GitHub</summary>

```bash
cd /tmp
VERSION=0.18.0
wget "https://github.com/restic/restic/releases/download/v${VERSION}/restic_${VERSION}_linux_amd64.bz2"
bzip2 -d "restic_${VERSION}_linux_amd64.bz2"
chmod +x "restic_${VERSION}_linux_amd64"
mv "restic_${VERSION}_linux_amd64" /usr/local/bin/restic
restic version
```
</details>

### Initialiser le dépôt

```bash
restic init --repo /mnt/lvbtrfs/backups/restic
```

Restic demande **interactivement** un mot de passe (ce n'est pas une commande à taper) :

```
enter password for new repository:      ← saisir votre mot de passe
enter password again:                   ← le confirmer
```

⚠️ **Ce mot de passe est la seule clé de vos données.** Perdu = sauvegardes définitivement
irrécupérables. Aucun mécanisme de récupération n'existe. Stockez-le dans un gestionnaire de
mots de passe, **ailleurs que sur ce serveur**.

### Sauvegarder

Pour éviter de retaper le mot de passe à chaque commande :

```bash
export RESTIC_REPOSITORY=/mnt/lvbtrfs/backups/restic
export RESTIC_PASSWORD_FILE=/root/.restic-pass

echo "MonMotDePasseSolide" > /root/.restic-pass
chmod 600 /root/.restic-pass        # ⚠️ lisible par root seul
```

> 💡 `RESTIC_PASSWORD_FILE` plutôt que `RESTIC_PASSWORD` : un mot de passe passé en variable
> d'environnement est visible dans `/proc/PID/environ` et l'historique du shell.

```bash
restic backup /root /etc /var/www

# ✅ Vérifications
restic snapshots
restic stats
```

**La démonstration de la déduplication :**

```bash
restic backup /root /etc /var/www      # 2e sauvegarde, sans changement
restic snapshots                        # 2 instantanés
restic stats --mode raw-data            # la taille réelle a à peine bougé
```

### Restaurer

```bash
# Explorer un instantané
restic ls latest | head -20

# Restaurer un fichier précis
restic restore latest --target /tmp/restauration --include /var/www/html/index.html
cat /tmp/restauration/var/www/html/index.html

# Monter les sauvegardes comme un système de fichiers (magique)
apt install -y fuse3
mkdir -p /mnt/restic
restic mount /mnt/restic &
ls /mnt/restic/snapshots/            # navigable avec cd, cp, less…
umount /mnt/restic
```

### Entretien du dépôt

```bash
# Politique de rétention : 7 quotidiennes, 4 hebdo, 6 mensuelles
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# Vérifier l'intégrité (à planifier périodiquement)
restic check
restic check --read-data-subset=5%
```

---

## 🏋️ Pour aller plus loin

1. **Alertes e-mail Monit** — configurez `set mailserver` et `set alert` dans `monitrc`, puis
   déclenchez volontairement une panne.
2. **Sauvegarde distante restic** — vers un autre serveur en SFTP :
   `restic -r sftp:user@backup.local:/srv/restic init`
3. **La règle 3-2-1** — 3 copies, 2 supports différents, 1 hors site. Où en est votre montage ?
4. **⚠️ Le test qui compte** — une sauvegarde jamais restaurée n'est pas une sauvegarde.
   Planifiez une restauration mensuelle et documentez-la.
5. **Alertes Netdata** — `/etc/netdata/health.d/`, avec notification vers Slack ou e-mail.

---

## 🆘 Dépannage

| Problème | Cause | Solution |
|---|---|---|
| `monit: Cannot connect to the monit daemon` | `set httpd` absent de `monitrc` | Ajouter le bloc `set httpd`, `monit -t`, redémarrer |
| `rsnapshot: ERROR: ... on line N` | Espaces au lieu de tabulations | Corriger, puis `rsnapshot configtest` |
| `rsnapshot` : rien n'est sauvegardé | Chemin `backup` sans `/` final | Les sources doivent finir par `/` |
| `restic: wrong password or no key found` | Mauvais mot de passe ou mauvais dépôt | Vérifier `RESTIC_REPOSITORY` et le fichier de mot de passe |
| Netdata inaccessible depuis le poste | Pare-feu | `ufw allow 19999/tcp` (et `2812/tcp` pour Monit) |
| Monit redémarre nginx en boucle | Le service est réellement cassé | `journalctl -u nginx`, corriger la cause, `monit monitor nginx` |
