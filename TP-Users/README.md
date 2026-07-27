# 👥 TP — Utilisateurs, groupes, `sudo` et permissions

## 🎯 Objectif

Construire une **délégation de droits réaliste** : deux profils, deux niveaux de privilèges,
un répertoire de travail partagé.

```
            ┌──────────────────────────────────────────────────────────┐
  alice ──▶ │ groupe admin      → sudo TOUT (dont « sudo su »)         │
            ├──────────────────────────────────────────────────────────┤
  bob   ──▶ │ groupe developer  → sudo LIMITÉ (systemctl, journalctl)  │
            └──────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                  /opt/appli-dev   root:developer   2775
                  (setgid + umask + ACL = écriture collaborative)
```

| Volet | Ce que vous apprenez |
|---|---|
| 🗂️ **Identités** | Ce que contiennent réellement `/etc/passwd`, `/etc/shadow`, `/etc/group` |
| 👤 **Comptes** | `groupadd`, `useradd`, groupe **principal** vs **secondaire**, `id` |
| 🔑 **`sudo`** | Anatomie d'une règle, `sudoers.d`, `visudo`, restriction par commande |
| ⚠️ **Évasions** | Pourquoi `sudo systemctl` **sans restriction = root complet** |
| 🔒 **Permissions** | `chmod` / `chown`, bits spéciaux **setgid** et **sticky**, `umask`, ACL POSIX |

💡 **Le fil rouge du TP.** Sous Linux, un droit n'est jamais accordé à une *personne* mais à un
**UID** et à un **jeu de GID**. Tout ce qui suit — `sudo` compris — n'est qu'une manière
d'exprimer des règles sur ces nombres.

---

## 📋 Prérequis

- Debian 13, session **root** (`sudo -i`)
- ⚠️ Un **snapshot de la VM** : on modifie `/etc/passwd`, `/etc/sudoers.d` et `/opt`.
  Une erreur de syntaxe dans `sudoers` peut vous **verrouiller hors de `sudo`**.
- Deux terminaux, c'est plus confortable : un en `root`, un pour tester en tant qu'`alice` / `bob`

```bash
apt update
apt install -y sudo acl members
```

| Paquet | Rôle |
|---|---|
| `sudo` | L'outil de délégation lui-même |
| `acl` | `getfacl` / `setfacl` — permissions fines de la partie 5 |
| `members` | Liste les membres d'un groupe (pratique, pas indispensable) |

> ⚠️ **Filet de sécurité.** Avant de toucher à `sudo`, gardez **un shell root déjà ouvert**
> pendant tout le TP. Si vous cassez `sudoers`, c'est votre seule porte d'entrée — hormis le
> mode de secours (`single`) au démarrage.

---

# 🗂️ Partie 1 — Où Linux stocke-t-il les identités ?

Avant de créer quoi que ce soit, il faut savoir ce qu'on modifie. Quatre fichiers texte, pas
de base de données.

## 1.1 — `/etc/passwd` : les comptes (lisible par tous)

```bash
grep -E '^(root|nobody):' /etc/passwd
```

```
root:x:0:0:root:/root:/bin/bash
│    │ │ │ │    │     └─ 7. shell de connexion
│    │ │ │ │    └─────── 6. répertoire personnel
│    │ │ │ └──────────── 5. champ GECOS (nom complet, bureau, téléphone…)
│    │ │ └────────────── 4. GID du groupe PRINCIPAL
│    │ └──────────────── 3. UID
│    └────────────────── 2. mot de passe — « x » = déporté dans /etc/shadow
└─────────────────────── 1. nom de connexion
```

💡 **Pourquoi `x` ?** `/etc/passwd` doit être lisible par tous (pour que `ls -l` affiche des
noms plutôt que des numéros). Y laisser les empreintes de mots de passe permettrait à
n'importe qui de les attaquer hors ligne. Elles ont donc été déplacées vers `/etc/shadow`.

## 1.2 — `/etc/shadow` : les mots de passe (root uniquement)

```bash
ls -l /etc/shadow          # -rw-r----- 1 root shadow  → personne d'autre ne lit
grep '^root:' /etc/shadow
```

```
root:$y$j9T$abc…$def…:19845:0:99999:7:::
│    │                │     │ │     │ └─ 7-9. inactivité, expiration, réservé
│    │                │     │ └─────── 5-6. validité max (jours), avertissement
│    │                │     └───────── 4. délai mini entre 2 changements
│    │                └─────────────── 3. dernier changement (jours depuis 1970-01-01)
│    └──────────────────────────────── 2. empreinte du mot de passe
└───────────────────────────────────── 1. nom de connexion
```

| Champ 2 | Signification |
|---|---|
| `$y$…` | Empreinte **yescrypt** (défaut Debian 12+) |
| `$6$…` | Empreinte SHA-512 (ancien défaut, toujours accepté) |
| `!` ou `!$y$…` | Compte **verrouillé** (`passwd -l`) — le `!` invalide l'empreinte |
| `*` | Aucune connexion par mot de passe possible (comptes de service) |
| *(vide)* | ⚠️ **Connexion sans mot de passe** — jamais volontaire |

## 1.3 — `/etc/group` et `/etc/gshadow`

```bash
grep -E '^(sudo|adm):' /etc/group
```

```
sudo:x:27:valentin
│    │ │  └─ 4. membres SECONDAIRES (liste séparée par des virgules)
│    │ └──── 3. GID
│    └─────── 2. mot de passe de groupe (dans /etc/gshadow) — quasi inutilisé
└──────────── 1. nom du groupe
```

⚠️ **Le piège n°1 des groupes.** Le champ 4 ne liste que les membres **secondaires**. Un
utilisateur dont c'est le groupe **principal** (champ 4 de `/etc/passwd`) n'y apparaît **pas**.
`grep developer /etc/group` peut donc renvoyer une liste vide alors que dix utilisateurs en
font partie. La bonne commande est `id UTILISATEUR`, jamais un `grep`.

## 1.4 — Les plages de numéros

```bash
grep -E '^(UID|GID|SYS_UID|SYS_GID)_(MIN|MAX)' /etc/login.defs
grep -E '^(UMASK|HOME_MODE|USERGROUPS_ENAB|ENCRYPT_METHOD)' /etc/login.defs
```

| Plage | Usage |
|---|---|
| `0` | **root** — un UID, pas un nom. Tout compte d'UID 0 **est** root |
| `1` – `99` | Comptes système historiques, réservés à la distribution |
| `100` – `999` | Comptes de service créés par les paquets (`useradd --system`) |
| **`1000` – `60000`** | **Comptes humains** — c'est notre zone |
| `65534` | `nobody` / `nogroup` |

💡 **Ne cherchez pas ces fichiers directement dans vos scripts.** Utilisez `getent`, qui
interroge **NSS** (`/etc/nsswitch.conf`) et voit donc aussi LDAP, SSSD ou les comptes réseau :

```bash
getent passwd root        # équivalent à grep, mais fonctionne aussi avec un annuaire
getent group sudo
getent passwd 0
```

✅ **Point de contrôle.** Vous savez dire, pour un compte donné : son UID, son groupe
principal, ses groupes secondaires, et si son mot de passe est verrouillé.

---

# 👤 Partie 2 — Créer les groupes et les utilisateurs

## 2.1 — Les deux groupes

```bash
groupadd admin
groupadd developer

getent group admin developer
```

```
admin:x:1001:
developer:x:1002:
```

> ⚠️ **`admin` n'est pas un groupe privilégié sous Debian.** Sous Debian, le groupe qui donne
> `sudo` s'appelle… `sudo`. Notre groupe `admin` est, à cet instant, **un groupe ordinaire
> sans aucun pouvoir**. Ce sont les règles de la partie 3 qui lui en donneront. C'est
> exactement l'inverse de l'intuition : le nom ne fait rien, la règle fait tout.

## 2.2 — `adduser` ou `useradd` ?

| Outil | Nature | Comportement |
|---|---|---|
| **`adduser`** | Script Perl **Debian**, interactif | Crée le home, copie `/etc/skel`, demande le mot de passe, applique `/etc/adduser.conf`. **Recommandé en interactif** |
| **`useradd`** | Binaire bas niveau (`shadow-utils`), POSIX | Ne fait **que** ce qu'on lui demande. **Recommandé en script** |

⚠️ **Le piège classique de `useradd` :** sans `-m`, **aucun répertoire personnel n'est créé**.
L'utilisateur se connecte, atterrit dans un `$HOME` inexistant, et rien ne fonctionne
normalement. `adduser` le crée toujours.

## 2.3 — Créer alice (groupe `admin`)

```bash
useradd \
  --create-home \
  --shell /bin/bash \
  --comment "Alice Martin,Administratrice systeme" \
  --groups admin \
  alice

passwd alice          # saisie interactive du mot de passe
```

| Option | Effet |
|---|---|
| `-m`, `--create-home` | Crée `/home/alice` et y copie `/etc/skel` |
| `-s`, `--shell` | Shell de connexion (`/usr/sbin/nologin` pour interdire la connexion) |
| `-c`, `--comment` | Champ GECOS |
| **`-G`, `--groups`** | Groupes **secondaires** (liste) |
| **`-g`, `--gid`** | Groupe **principal** (un seul) |
| `-u`, `--uid` | UID imposé — utile pour aligner un UID entre plusieurs machines (NFS !) |
| `-e`, `--expiredate` | Date d'expiration du compte (prestataires, stagiaires) |

## 2.4 — Créer bob (groupe `developer`)

```bash
useradd -m -s /bin/bash -c "Bob Durand,Developpeur" -G developer bob
passwd bob
```

## 2.5 — ✅ Vérifier, et comprendre `id`

```bash
id alice
id bob
```

```
uid=1001(alice) gid=1001(alice) groups=1001(alice),1001(admin)
                └──────┬──────┘ └────────────┬──────────────┘
              groupe PRINCIPAL        TOUS les groupes
```

💡 **Groupe principal vs groupe secondaire — la distinction qui compte :**

| | Groupe **principal** (`gid=`) | Groupes **secondaires** (`groups=`) |
|---|---|---|
| Combien ? | **Exactement un** | Autant qu'on veut (65 535 max) |
| Où c'est stocké | Champ 4 de `/etc/passwd` | Champ 4 de `/etc/group` |
| Rôle | Groupe **propriétaire des fichiers créés** par défaut | Sert uniquement aux **contrôles d'accès** |
| On le change avec | `usermod -g` | `usermod -aG` / `gpasswd -a` |

⚠️ **`usermod -G` sans le `-a` REMPLACE toute la liste des groupes secondaires.** C'est la
façon la plus courante de retirer accidentellement un collègue du groupe `sudo` :

```bash
usermod -G developer bob      # ⚠️ bob n'est PLUS que dans developer
usermod -aG developer bob     # ✅ AJOUTE developer, conserve le reste
```

**Pourquoi Debian crée-t-il un groupe `alice` pour l'utilisatrice `alice` ?** C'est le schéma
**UPG** (*User Private Group*), activé par `USERGROUPS_ENAB yes` dans `/etc/login.defs`. Chaque
utilisateur a un groupe personnel dont il est seul membre. Conséquence : un `umask` de `002`
(groupe autorisé à écrire) reste **sûr** puisque le groupe ne contient qu'une personne. C'est
la condition qui rend possible le travail collaboratif de la partie 5.

**Autres vérifications utiles :**

```bash
groups bob                    # les groupes de bob
members developer             # les membres du groupe (paquet 'members')
getent group developer        # la ligne brute de /etc/group
lslogins -u                   # tableau de tous les comptes humains
ls -la /home/bob              # ✅ le home existe, avec les fichiers de /etc/skel
stat -c '%U:%G %a' /home/bob  # -> bob:bob 700  (HOME_MODE dans login.defs)
```

## 2.6 — Politique de mot de passe (`chage`)

```bash
chage -l bob                            # état actuel

chage -M 90 -m 7 -W 14 -I 30 bob        # politique
chage -d 0 bob                          # 💡 force le changement à la 1re connexion
chage -l bob
```

| Option | Signification |
|---|---|
| `-M 90` | Validité maximale : 90 jours |
| `-m 7` | Minimum 7 jours entre deux changements (évite de « tourner » pour revenir à l'ancien) |
| `-W 14` | Avertir 14 jours avant expiration |
| `-I 30` | Compte désactivé 30 jours après expiration du mot de passe |
| `-E 2026-12-31` | Expiration du **compte** (≠ du mot de passe) |
| `-d 0` | « Dernier changement = epoch » → changement imposé à la connexion suivante |

💡 **Verrouiller ≠ supprimer.** Trois niveaux, du plus réversible au plus définitif :

```bash
passwd -l bob            # verrouille le MOT DE PASSE (préfixe '!' dans shadow) — la clé SSH marche encore !
usermod -L -e 1 bob      # verrouille ET expire le COMPTE → plus aucune connexion
usermod -s /usr/sbin/nologin bob   # interdit le shell de connexion
userdel -r bob           # ⚠️ supprime le compte ET le home. Irréversible
```

⚠️ **`passwd -l` ne bloque pas SSH par clé publique.** Pour un départ d'employé, c'est
`usermod -L -e 1` (ou la suppression de `~/.ssh/authorized_keys`) qui compte.

---

# 🔑 Partie 3 — `sudo` : comment ça fonctionne vraiment

## 3.1 — Le mécanisme

```bash
ls -l "$(command -v sudo)"
```

```
-rwsr-xr-x 1 root root 281464 … /usr/bin/sudo
   ↑
   bit setuid : le programme s'exécute avec l'identité de son PROPRIÉTAIRE (root),
                pas celle de l'utilisateur qui le lance
```

**La séquence complète d'un `sudo systemctl restart nginx` :**

1. bob lance `sudo`. Grâce au bit **setuid**, le processus tourne immédiatement en `root`.
2. `sudo` lit `/etc/sudoers` (+ `/etc/sudoers.d/`) et cherche une règle correspondant à
   *(utilisateur, machine, identité cible, commande)*.
3. Aucune règle ne correspond → refus, journalisation, et un message envoyé à l'administrateur.
4. Une règle correspond → `sudo` demande le **mot de passe de bob** (pas celui de root),
   sauf `NOPASSWD`.
5. Succès → un **jeton** est posé dans `/run/sudo/ts/bob` : plus de mot de passe pendant
   15 minutes (`timestamp_timeout`), **par terminal**.
6. `sudo` **réinitialise l'environnement** (`env_reset`), impose `secure_path`, puis
   `execve()` la commande demandée avec l'UID cible.
7. Tout est journalisé : `journalctl -t sudo`.

💡 **Le point non intuitif :** `sudo` ne demande jamais le mot de passe de root. Sous Debian,
le compte root n'a **même pas** de mot de passe utilisable si l'installateur en a créé un
utilisateur `sudo`. C'est tout l'intérêt du modèle : **aucun secret partagé**, et une trace
nominative de chaque action.

## 3.2 — Anatomie d'une règle

```
%developer   ALL   = (root : root)   NOPASSWD:  /usr/bin/systemctl status *
└────┬────┘  └┬─┘    └──┬──┘ └─┬─┘   └───┬───┘  └──────────────┬──────────┘
     │        │         │      │         │                     │
   QUI ?   Depuis    En tant  En tant  Étiquettes         QUOI ? (chemin ABSOLU)
 (%=groupe) quelle   que quel  que quel
            machine  UTILISA-  GROUPE
                     TEUR
```

| Élément | Détail |
|---|---|
| **Qui** | `bob` (utilisateur), `%developer` (groupe), `%#1002` (par GID), `+netgroup` |
| **Depuis** | `ALL` = depuis n'importe quel hôte. Utile seulement si vous distribuez un `sudoers` commun à un parc |
| **`(utilisateur:groupe)`** | Identité cible. `(ALL:ALL)` = n'importe qui. `(www-data)` = seulement cet utilisateur |
| **Étiquettes** | `NOPASSWD:`, `PASSWD:`, `NOEXEC:`, `SETENV:`, `LOG_OUTPUT:` |
| **Quoi** | Un ou plusieurs **chemins absolus**. `ALL` = toutes les commandes |

⚠️ **Un chemin relatif dans `sudoers` ne fonctionne pas.** `systemctl` ne correspond à rien :
il faut `/usr/bin/systemctl`. Et vérifiez le vrai chemin — sous Debian 13, `/bin` et `/sbin`
sont des **liens symboliques** vers `/usr/bin` et `/usr/sbin` (*merged-`/usr`*) :

```bash
command -v systemctl journalctl su       # -> /usr/bin/systemctl, /usr/bin/journalctl, /usr/bin/su
```

## 3.3 — On n'édite JAMAIS `/etc/sudoers` directement

```bash
visudo                                    # /etc/sudoers, avec contrôle de syntaxe à la sortie
visudo -f /etc/sudoers.d/20-developer     # un fichier de /etc/sudoers.d
visudo -c                                 # ✅ vérifie TOUTE la configuration
```

💡 **Ce que `visudo` fait et qu'un `nano` ne fait pas :** il verrouille le fichier, l'édite
dans une copie temporaire, **valide la syntaxe** et refuse d'installer un fichier invalide.
Sans lui, une virgule oubliée rend `sudo` inutilisable pour **tout le monde**, y compris vous.

**Regardez la fin de `/etc/sudoers` :**

```bash
grep -E '^@?include' /etc/sudoers
# -> @includedir /etc/sudoers.d
```

⚠️ Trois règles pour les fichiers de `/etc/sudoers.d/` — sinon ils sont **ignorés en silence** :

| Règle | Pourquoi |
|---|---|
| Permissions **`0440`**, propriétaire `root:root` | `sudo` refuse tout fichier accessible en écriture par autre chose que root |
| **Aucun `.` ni `~`** dans le nom | Convention `run-parts` : `20-dev.bak` et `20-dev~` sont ignorés |
| Préfixe numérique | L'ordre alphabétique décide, et **la dernière règle qui correspond gagne** |

## 3.4 — Le groupe `admin` : privilèges complets

```bash
cat > /etc/sudoers.d/10-admin <<'EOF'
# ── Groupe admin : privilèges complets ───────────────────────────────────────
# (ALL:ALL) = peut devenir n'importe quel utilisateur ET n'importe quel groupe.
# La dernière colonne ALL = n'importe quelle commande, « su » et « -i » compris.
%admin ALL=(ALL:ALL) ALL

# Le mot de passe n'est redemandé qu'après 5 minutes d'inactivité (défaut : 15).
Defaults:%admin timestamp_timeout=5

# Journaliser la SORTIE des commandes de ce groupe (traçabilité).
# Rejouable avec : sudoreplay -l
Defaults:%admin log_output
EOF

chmod 0440 /etc/sudoers.d/10-admin
chown root:root /etc/sudoers.d/10-admin

# ✅ Validation OBLIGATOIRE
visudo -c
```

Sortie attendue :

```
/etc/sudoers: parsed OK
/etc/sudoers.d/10-admin: parsed OK
```

### Ce que `%admin ALL=(ALL:ALL) ALL` permet — et les nuances

Ouvrez un second terminal :

```bash
su - alice          # depuis root, aucun mot de passe demandé

sudo -l             # ✅ « (ALL : ALL) ALL »
sudo whoami         # -> root
sudo su             # ✅ shell root  (Ctrl-D pour sortir)
sudo su -           # ✅ shell root de CONNEXION
sudo -i             # ✅ l'équivalent moderne et recommandé
sudo -u bob whoami  # -> bob  (grâce à (ALL:ALL), pas seulement (root))
```

💡 **`sudo su` vs `sudo -s` vs `sudo -i` — trois shells, trois environnements :**

| Commande | Environnement | `$HOME` | Fichiers lus |
|---|---|---|---|
| `sudo su` | Hérité (partiellement) | `/root` | `~/.bashrc` de root |
| `sudo -s` | **Celui de l'appelant** | Celui de l'appelant ⚠️ | `~/.bashrc` de l'appelant |
| **`sudo -i`** | **Propre, comme une vraie connexion root** | `/root` | `/etc/profile`, `/root/.profile` |

⚠️ **`sudo -s` est un piège** : vous êtes root, mais avec le `$HOME` et le `$PATH` de
l'utilisateur. Un `~/.bashrc` piégé par un attaquant s'exécute alors **en root**. Préférez
toujours **`sudo -i`**.

💡 **Et pourquoi ne pas simplement ajouter alice au groupe `sudo` de Debian ?** On aurait pu
(`usermod -aG sudo alice`). Créer notre propre groupe `admin` avec sa propre règle rend la
politique **explicite et lisible dans un fichier versionnable**, au lieu d'être cachée dans
l'appartenance à un groupe. C'est la pratique en environnement géré par Ansible/Puppet.

## 3.5 — Le groupe `developer` : privilèges limités

Voici l'objectif : bob doit pouvoir **redémarrer un service et lire ses journaux**, sans
jamais devenir root.

### ❌ La version naïve — et pourquoi elle est fausse

```sudoers
# ⚠️ NE FAITES PAS ÇA
%developer ALL=(root) /usr/bin/systemctl, /usr/bin/journalctl
```

Cette règle donne **root complet** à bob. Trois évasions, toutes triviales :

| Évasion | Comment | Pourquoi ça marche |
|---|---|---|
| `sudo systemctl edit nginx` | Ouvre un éditeur **en root**, puis `:!/bin/bash` dans vim | `systemctl edit` lance `$EDITOR` avec les droits root |
| `sudo systemctl link /home/bob/piege.service` puis `start` | bob écrit lui-même une unité contenant `ExecStart=/bin/bash` | `link` accepte un chemin **arbitraire**, y compris dans son `$HOME` |
| `sudo journalctl` puis `!/bin/sh` dans le pager | Le pager `less` sait lancer des commandes | Vecteur classique de tous les outils qui paginent |

> 💡 **Une nuance honnête sur le pager :** systemd positionne `LESSSECURE=1` quand il invoque
> `less`, ce qui **désactive** le `!`. Cette évasion précise est donc bloquée sur un système à
> jour. Mais elle illustre une règle générale : **toute commande capable de lancer un éditeur,
> un pager ou un sous-processus est un shell root déguisé.** `vim`, `less`, `awk`, `find -exec`,
> `tar --to-command`, `git -c core.pager`, `apt` avec ses *hooks*… La liste est longue. Ne vous
> reposez pas sur la protection d'un outil : restreignez les **sous-commandes**.

### ✅ La version correcte

```bash
cat > /etc/sudoers.d/20-developer <<'EOF'
# ── Groupe developer : administration de services, sans privilèges root ──────
#
# Principe : on n'autorise pas « systemctl », on autorise des COUPLES
# (sous-commande, unité) précis. Toute sous-commande non listée est refusée,
# ce qui exclut « edit », « link », « mask », « set-property »…

# --- Consultation : sans danger, donc sans mot de passe ----------------------
Cmnd_Alias DEV_LECTURE = /usr/bin/systemctl status *,        \
                         /usr/bin/systemctl is-active *,     \
                         /usr/bin/systemctl is-enabled *,    \
                         /usr/bin/systemctl list-units *,    \
                         /usr/bin/systemctl show *,          \
                         /usr/bin/systemctl cat *

# --- Journaux : --no-pager IMPOSÉ, donc aucun sous-processus possible --------
Cmnd_Alias DEV_JOURNAUX = /usr/bin/journalctl --no-pager *,  \
                          /usr/bin/journalctl -n *,          \
                          /usr/bin/journalctl -f -u *,       \
                          /usr/bin/journalctl -u * --no-pager *

# --- Actions : le mot de passe reste exigé ----------------------------------
Cmnd_Alias DEV_ACTIONS = /usr/bin/systemctl start nginx,     \
                         /usr/bin/systemctl stop nginx,      \
                         /usr/bin/systemctl restart nginx,   \
                         /usr/bin/systemctl reload nginx,    \
                         /usr/bin/systemctl start appli-dev, \
                         /usr/bin/systemctl stop appli-dev,  \
                         /usr/bin/systemctl restart appli-dev

# --- Application des règles -------------------------------------------------
%developer ALL=(root) NOPASSWD: DEV_LECTURE, DEV_JOURNAUX
%developer ALL=(root) PASSWD:   DEV_ACTIONS

# --- Durcissement du groupe -------------------------------------------------
# requiretty     : refuse l'exécution hors d'un vrai terminal (bloque une
#                  partie des usages détournés depuis un script distant)
# !visiblepw     : refuse de taper le mot de passe si l'écho n'est pas masqué
# timestamp_timeout=1 : le jeton n'est valable qu'une minute
Defaults:%developer requiretty, !visiblepw, timestamp_timeout=1
EOF

chmod 0440 /etc/sudoers.d/20-developer
visudo -c
```

| Élément de syntaxe | Rôle |
|---|---|
| `Cmnd_Alias NOM = ...` | Une liste de commandes nommée, réutilisable. Le nom **doit être en MAJUSCULES** |
| `\` en fin de ligne | Continuation — indispensable pour rester lisible |
| `*` | Joker : correspond à n'importe quels caractères **dans les arguments** |
| `NOPASSWD:` / `PASSWD:` | S'appliquent à toutes les commandes qui suivent, sur la ligne |
| `Defaults:%groupe` | Réglages ciblés sur un groupe |

⚠️ **Le joker `*` mérite votre méfiance.** `systemctl status *` autorise n'importe quel
argument après `status` — y compris plusieurs arguments. Ce n'est pas grave pour `status`
(lecture seule), mais ce serait catastrophique pour `chown *` (qui accepte `--reference`) ou
`/bin/cp * /etc/` (qui permet d'écraser `/etc/shadow`). **Règle : plus la commande est
puissante, moins de jokers.**

💡 **La règle négative est un leurre.** On voit souvent :

```sudoers
%developer ALL=(ALL) ALL, !/usr/bin/su, !/usr/bin/passwd    # ⚠️ INEFFICACE
```

C'est une **liste noire**, et une liste noire de commandes ne tient jamais : bob copie `/usr/bin/su`
vers `/tmp/monsu` et l'exécute — le chemin ne correspond plus à l'interdiction. Ou il lance
`sudo vim` puis `:!sh`. **Une politique `sudo` s'écrit en liste blanche, jamais autrement.**

## 3.6 — 🧪 Démonstration : bob utilise `sudo`

Préparons un service à administrer :

```bash
apt install -y nginx
systemctl enable --now nginx
```

Puis, dans le second terminal :

```bash
su - bob
```

### ✅ Ce qui doit fonctionner

```bash
# 1. Découvrir ses propres droits — la première commande à connaître
sudo -l
```

```
User bob may run the following commands on debian:
    (root) NOPASSWD: /usr/bin/systemctl status *, ...
    (root) PASSWD: /usr/bin/systemctl start nginx, ...
```

```bash
# 2. Consultation — aucun mot de passe demandé
sudo systemctl status nginx
sudo systemctl is-active nginx                  # -> active

# 3. Journaux
sudo journalctl -u nginx --no-pager -n 20
sudo journalctl --no-pager -p err -n 10

# 4. Action — le mot de passe de BOB est demandé
sudo systemctl restart nginx
sudo systemctl is-active nginx                  # -> active
```

### ❌ Ce qui doit échouer

```bash
sudo su                    # Sorry, user bob is not allowed to execute '/usr/bin/su' …
sudo -i                    # refusé
sudo cat /etc/shadow       # refusé
sudo systemctl edit nginx  # refusé  ← l'évasion par l'éditeur est fermée
sudo systemctl restart ssh # refusé  ← nginx était autorisé, ssh non
sudo journalctl            # refusé  ← --no-pager n'a pas été fourni
sudo -u alice whoami       # refusé  ← la règle dit (root), pas (ALL)
```

Message type :

```
Sorry, user bob is not allowed to execute '/usr/bin/su' as root on debian.
```

✅ **Ces sept refus sont le vrai résultat du TP.** Une politique `sudo` ne se juge pas à ce
qu'elle autorise, mais à ce qu'elle **refuse**.

### La trace : chaque tentative est journalisée

Retour dans le terminal root :

```bash
journalctl -t sudo --no-pager -n 30
grep sudo /var/log/auth.log | tail -20
```

```
sudo: bob : TTY=pts/1 ; PWD=/home/bob ; USER=root ; COMMAND=/usr/bin/systemctl restart nginx
sudo: bob : command not allowed ; TTY=pts/1 ; PWD=/home/bob ; USER=root ; COMMAND=/usr/bin/su
```

💡 `command not allowed` : voilà ce qu'un audit de sécurité recherche. Un pic de ces lignes
signale soit une politique trop stricte, soit un compte compromis.

### Bonus — rejouer une session `admin`

`Defaults:%admin log_output` enregistre la **sortie** des commandes d'alice :

```bash
sudoreplay -l                     # liste les sessions enregistrées
sudoreplay -l user alice
sudoreplay ID_DE_SESSION          # rejoue la session comme un film
```

## 3.7 — Antisèche de diagnostic `sudo`

```bash
visudo -c                            # valider TOUTE la configuration
sudo -l -U bob                       # (en root) lister les droits de bob
sudo -ll                             # affichage détaillé, règle par règle
sudo -k                              # oublier le jeton (retester la demande de mot de passe)
sudo -v                              # prolonger le jeton sans lancer de commande
sudo -n true 2>&1                    # tester sans jamais demander de mot de passe
```

⚠️ **Une règle vous surprend ?** Rappelez-vous que **la dernière règle correspondante
l'emporte**, et que `/etc/sudoers.d` est lu dans l'ordre **alphabétique**. Un fichier
`99-tout-permis` annule tout ce qui précède.

---

# 🔒 Partie 4 — `chmod` / `chown` : les fondamentaux

## 4.1 — Lire une ligne de `ls -l`

```bash
ls -l /usr/bin/sudo /etc/shadow /tmp
```

```
-rwsr-xr-x  1 root root    281464 …  /usr/bin/sudo
drwxrwxrwt 15 root root      4096 …  /tmp
│└┬┘└┬┘└┬┘    └─┬┘ └─┬┘
│ │  │  │       │    └── groupe propriétaire
│ │  │  │       └─────── utilisateur propriétaire
│ │  │  └─────────────── droits des AUTRES  (o)
│ │  └────────────────── droits du GROUPE   (g)
│ └───────────────────── droits du PROPRIÉTAIRE (u)
└─────────────────────── type : -=fichier  d=répertoire  l=lien  c/b=périphérique  s=socket
```

**Comment le noyau décide, à chaque ouverture de fichier — dans cet ordre, et il s'arrête au
premier cas qui s'applique :**

1. UID = propriétaire du fichier ? → on applique les droits **`u`**, **et on s'arrête là**.
2. Sinon, un des GID de l'utilisateur = groupe du fichier ? → droits **`g`**, **stop**.
3. Sinon → droits **`o`**.

⚠️ **La conséquence contre-intuitive.** Un fichier `----rwxrwx alice:developer` est
**inaccessible à alice** — alors que tout le monde y a tous les droits. Elle est propriétaire,
donc le noyau applique `u` (`---`) et n'examine jamais `g` ni `o`. Les permissions ne
s'additionnent **pas**.

## 4.2 — `r`, `w`, `x` : le sens change sur un répertoire

| Bit | Sur un **fichier** | Sur un **répertoire** |
|---|---|---|
| **`r`** (4) | Lire le contenu | **Lister les noms** (`ls`) |
| **`w`** (2) | Modifier le contenu | **Créer, renommer, supprimer** des entrées |
| **`x`** (1) | Exécuter | **Traverser** (`cd`, accéder à un chemin *à travers* lui) |

💡 **Trois conséquences que tout administrateur doit connaître :**

- **`r` sans `x`** (`r--`) → `ls` affiche les noms mais tous les `stat` échouent : `ls -l`
  ne montre que des `?`.
- **`x` sans `r`** (`--x`) → on ne peut pas lister, mais on peut ouvrir un fichier **dont on
  connaît le nom**. C'est ainsi qu'est protégé `/home` chez certains hébergeurs.
- ⚠️ **Supprimer un fichier ne demande aucun droit sur le fichier**, seulement le `w` sur son
  **répertoire**. Un fichier en `r--------` root:root dans un répertoire `777` est
  supprimable par n'importe qui. C'est le problème que résout le *sticky bit* (§5.5).

## 4.3 — Notation octale et notation symbolique

```
   r  w  x
   4  2  1     ->  rwx = 7   r-x = 5   rw- = 6   r-- = 4
```

| Octal | Symbolique | Usage typique |
|---|---|---|
| `644` | `rw-r--r--` | Fichier de configuration lisible |
| `600` | `rw-------` | Clé privée, `~/.ssh/id_ed25519` |
| `755` | `rwxr-xr-x` | Programme, répertoire public |
| `750` | `rwxr-x---` | Répertoire réservé à un groupe |
| `775` | `rwxrwxr-x` | Répertoire partagé en écriture par un groupe |
| `440` | `r--r-----` | `/etc/sudoers.d/*` |

```bash
# Absolu : on écrase les droits existants
chmod 750 /opt/exemple

# Relatif : on ajoute / retire, sans toucher au reste  ← souvent plus sûr
chmod g+w   /opt/exemple      # ajoute w au groupe
chmod o-rwx /opt/exemple      # retire tout aux autres
chmod a+X   /opt/exemple      # 'X' majuscule : x SEULEMENT sur les répertoires
chmod u=rw,g=r,o= fichier     # affectation explicite
chmod --reference=/etc/hosts fichier   # copier les droits d'un autre fichier
```

💡 **`X` majuscule est la meilleure option de `chmod`.** `chmod -R a+x` rend *exécutables*
tous vos fichiers de données ; `chmod -R a+X` n'ajoute `x` qu'aux **répertoires** et aux
fichiers qui l'avaient déjà. C'est ce qu'on veut dans 99 % des `chmod -R`.

## 4.4 — `chown` et `chgrp` : qui a le droit de donner ?

```bash
chown alice fichier              # propriétaire
chown alice:developer fichier    # propriétaire + groupe
chown :developer fichier         # groupe seul (= chgrp)
chgrp developer fichier

chown -R alice:developer /opt/exemple      # récursif
chown -h alice lien_symbolique             # le LIEN, pas sa cible
chown --from=root:root alice fichier       # seulement si l'ancien propriétaire correspond
```

⚠️ **Deux règles asymétriques, souvent confondues :**

| Opération | Qui peut le faire ? |
|---|---|
| Changer le **propriétaire** | **root uniquement.** Jamais un utilisateur ordinaire |
| Changer le **groupe** | Le propriétaire du fichier, **s'il est membre du groupe cible** |

💡 **Pourquoi cette asymétrie ?** Si bob pouvait donner un fichier à alice, il pourrait
déposer dans son quota disque un fichier compromettant qu'elle n'a pas demandé — ou contourner
son propre quota. Le noyau interdit donc le « don » de fichier. On peut le vérifier :

```bash
su - bob -c 'touch /tmp/essai && chown alice /tmp/essai'
# -> chown: changing ownership of '/tmp/essai': Operation not permitted

su - bob -c 'chgrp developer /tmp/essai && ls -l /tmp/essai'
# -> ✅ fonctionne : bob est propriétaire ET membre de developer
```

---

# 🤝 Partie 5 — Un répertoire partagé dans `/opt`

## 5.1 — Le problème à résoudre

> Les développeurs (`developer`) travaillent à plusieurs dans `/opt/appli-dev`. Chacun doit
> pouvoir **modifier et supprimer les fichiers des autres**. Les administrateurs (`admin`)
> doivent pouvoir **tout lire** pour auditer, mais rien écrire. Personne d'autre n'entre.

💡 **Pourquoi `/opt` ?** La norme **FHS** réserve `/opt` aux logiciels « add-on » installés
hors gestionnaire de paquets — typiquement les applications maison. `/srv` est destiné aux
données servies (web, ftp), `/usr/local` aux programmes compilés localement. Un `apt upgrade`
ne touchera jamais à `/opt`.

## 5.2 — Création et attribution

```bash
mkdir -p /opt/appli-dev/{src,config,logs,releases}

# Propriétaire root (personne ne peut renommer/supprimer la racine du projet),
# groupe developer (c'est lui qui travaille dedans)
chown -R root:developer /opt/appli-dev

# 2775 : rwx pour root, rwx pour developer, r-x pour les autres, + SETGID
chmod 2775 /opt/appli-dev
find /opt/appli-dev -type d -exec chmod 2775 {} +

ls -ld /opt/appli-dev
```

```
drwxrwsr-x 6 root developer 4096 … /opt/appli-dev
      ↑
   's' à la place du 'x' du groupe = bit SETGID actif
```

## 5.3 — ⭐ Le bit setgid : la clé du partage

Sans setgid, chaque fichier créé appartient au **groupe principal de son créateur** —
`bob:bob` pour bob, `alice:alice` pour alice. Résultat : les membres de `developer` ne peuvent
pas modifier les fichiers les uns des autres. **C'est LE problème du travail collaboratif sous
Unix.**

**Setgid sur un répertoire change deux choses :**

1. Tout **fichier** créé dedans hérite du **groupe du répertoire** (`developer`), quel que
   soit le groupe principal de son créateur.
2. Tout **sous-répertoire** créé dedans hérite du groupe **et du bit setgid lui-même** →
   la propriété se propage automatiquement, à toute profondeur.

### 🧪 La démonstration

```bash
# Sans setgid, pour comparer
mkdir /tmp/sans-setgid && chown root:developer /tmp/sans-setgid && chmod 775 /tmp/sans-setgid

su - bob -c 'touch /tmp/sans-setgid/essai'
ls -l /tmp/sans-setgid/essai        # -> bob bob        ❌ groupe perdu

# Avec setgid
su - bob -c 'touch /opt/appli-dev/src/essai.py'
ls -l /opt/appli-dev/src/essai.py   # -> bob developer  ✅ groupe hérité
```

⚠️ **Setgid ne s'applique qu'aux fichiers créés APRÈS l'avoir posé.** Sur un répertoire
existant, il faut corriger l'historique :

```bash
chown -R :developer /opt/appli-dev       # groupe de tout l'existant
find /opt/appli-dev -type d -exec chmod g+s {} +   # setgid sur tous les répertoires
```

> 💡 **Setgid sur un *fichier* signifie tout autre chose** : le programme s'exécute avec le
> groupe du fichier (comme `setuid` avec l'utilisateur). C'est un mécanisme sensible, à
> auditer régulièrement :
> ```bash
> find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec ls -l {} + 2>/dev/null
> ```

## 5.4 — ⭐ Le `umask` : le setgid ne suffit pas

Le groupe est bon, mais est-il autorisé à **écrire** ?

```bash
ls -l /opt/appli-dev/src/essai.py
# -rw-r--r-- 1 bob developer …    ← ⚠️ le groupe n'a que 'r' : alice ne peut pas modifier
```

💡 **Le `umask` est un masque de bits *retirés*** aux permissions par défaut (`666` pour un
fichier, `777` pour un répertoire — un fichier n'est jamais créé exécutable) :

| `umask` | Fichier | Répertoire | Conséquence |
|---|---|---|---|
| `022` | `644` | `755` | Groupe en **lecture seule** → ❌ pas de partage possible |
| **`002`** | **`664`** | **`775`** | Groupe en **écriture** → ✅ partage |
| `007` | `660` | `770` | Groupe en écriture, **rien pour les autres** |
| `077` | `600` | `700` | Strictement privé |

```bash
su - bob -c 'umask'      # -> 0022 sur une Debian par défaut
```

**Appliquer `002` aux seuls développeurs :**

```bash
cat > /etc/profile.d/umask-developer.sh <<'EOF'
# Écriture collaborative pour les membres du groupe developer.
# Sûr grâce au schéma UPG (User Private Group) : le groupe principal de chaque
# utilisateur ne contient que lui-même, un umask 002 n'expose donc rien.
if id -nG | tr ' ' '\n' | grep -qx developer; then
    umask 002
fi
EOF
chmod 644 /etc/profile.d/umask-developer.sh
```

✅ Vérification :

```bash
su - bob -c 'umask; touch /opt/appli-dev/src/essai2.py'
ls -l /opt/appli-dev/src/essai2.py
# -> 0002  puis  -rw-rw-r-- 1 bob developer   ✅ le groupe peut écrire
```

⚠️ **Les limites de cette approche, à connaître :**

- `/etc/profile.d/` n'est lu que par les **shells de connexion**. Un service systemd, une
  tâche `cron` ou un `scp` n'en tiennent pas compte. Pour ces cas : `UMask=0002` dans l'unité
  systemd, ou `pam_umask`.
- Le `umask` est un réglage **par processus**, pas par répertoire. Un développeur peut le
  changer. C'est là qu'intervient l'ACL par défaut (§5.6), qui s'impose au système de fichiers
  et non au shell.

## 5.5 — Le sticky bit : un dépôt commun sans casse

Un répertoire ouvert en écriture à plusieurs pose un problème : **n'importe qui peut supprimer
le fichier de n'importe qui** (§4.2). D'où le *sticky bit* (`1`) : dans un répertoire qui le
porte, seuls le **propriétaire du fichier**, le **propriétaire du répertoire** et **root**
peuvent supprimer ou renommer.

```bash
ls -ld /tmp                # drwxrwxrwt  ← le 't' final
```

```bash
mkdir -p /opt/appli-dev/depot
chown root:developer /opt/appli-dev/depot
chmod 3775 /opt/appli-dev/depot          # 3 = setgid (2) + sticky (1)
ls -ld /opt/appli-dev/depot
```

```
drwxrwsr-t 2 root developer 4096 … /opt/appli-dev/depot
      ↑    ↑
      │    └─ 't' : sticky bit  → suppression réservée au propriétaire
      └────── 's' : setgid      → héritage du groupe developer
```

### 🧪 Démonstration

```bash
usermod -aG developer alice              # alice rejoint temporairement developer
su - bob   -c 'echo "à bob" > /opt/appli-dev/depot/fichier-bob.txt'

# alice peut LIRE et MODIFIER (groupe developer + umask 002)
su - alice -c 'cat /opt/appli-dev/depot/fichier-bob.txt'

# …mais pas SUPPRIMER : le sticky bit protège
su - alice -c 'rm /opt/appli-dev/depot/fichier-bob.txt'
# -> rm: cannot remove '…': Operation not permitted    ✅

su - bob -c 'rm /opt/appli-dev/depot/fichier-bob.txt'  # ✅ le propriétaire, oui

gpasswd -d alice developer               # on retire alice de developer
```

**Récapitulatif des trois bits spéciaux :**

| Bit | Octal | Affichage | Sur un répertoire | Sur un fichier |
|---|---|---|---|---|
| **setuid** | `4` | `s` sur `u` | *(ignoré sous Linux)* | Exécution avec l'UID du propriétaire (`sudo`, `passwd`) |
| **setgid** | `2` | `s` sur `g` | **Héritage du groupe** ⭐ | Exécution avec le GID du fichier |
| **sticky** | `1` | `t` sur `o` | **Suppression réservée au propriétaire** ⭐ | *(ignoré)* |

💡 **Comment lire `s` vs `S`, `t` vs `T` ?** Minuscule = le bit `x` sous-jacent est présent
aussi ; **majuscule = il est absent**. Un `drwxrwS--T` signale un setgid sur un répertoire non
traversable par son groupe : presque toujours une erreur.

## 5.6 — Les ACL POSIX : au-delà de `ugo`

Le modèle `ugo` n'a **qu'un seul groupe** par fichier. Or notre cahier des charges en demande
deux : `developer` en écriture **et** `admin` en lecture. Impossible avec `chmod` seul — c'est
précisément le cas d'usage des **ACL**.

```bash
# Le groupe developer : lecture + écriture (X = x seulement sur les répertoires)
setfacl -R -m g:developer:rwX /opt/appli-dev

# Le groupe admin : lecture seule, pour l'audit
setfacl -R -m g:admin:rX     /opt/appli-dev

# ⭐ Les ACL « par défaut » (-d) : héritées par tout ce qui SERA créé ensuite
setfacl -R -d -m g:developer:rwX /opt/appli-dev
setfacl -R -d -m g:admin:rX      /opt/appli-dev

getfacl /opt/appli-dev
```

```
# file: opt/appli-dev
# owner: root
# group: developer
# flags: -s-                       ← le setgid apparaît ici
user::rwx
group::rwx
group:developer:rwx                ← ACL nommée
group:admin:r-x                    ← ACL nommée
mask::rwx                          ← ⚠️ plafond des permissions effectives
other::r-x
default:group:developer:rwx        ← héritée par les nouveaux fichiers
default:group:admin:r-x
```

```bash
ls -ld /opt/appli-dev
# drwxrwsr-x+ ...
#           ↑ le '+' signale la présence d'ACL — c'est le seul indice dans un ls
```

⚠️ **Le `mask` est le piège n°1 des ACL.** C'est un **plafond** : la permission effective
d'une ACL nommée est l'intersection de l'ACL et du masque. Or… **`chmod g+X` ou `chmod 750`
réécrit le masque** et peut donc annuler silencieusement toutes vos ACL de groupe.
`getfacl` l'annonce alors explicitement :

```
group:developer:rwx        #effective:r-x
```

💡 **Après un `chmod` sur un répertoire porteur d'ACL, relisez toujours `getfacl`.**

**Les commandes ACL à retenir :**

```bash
getfacl -R /opt/appli-dev > /root/acl-appli-dev.txt   # sauvegarder
setfacl --restore=/root/acl-appli-dev.txt             # restaurer
setfacl -x  g:admin /opt/appli-dev                    # retirer une ACL
setfacl -b  -R /opt/appli-dev                         # tout effacer (back to ugo)
setfacl -k  -R /opt/appli-dev                         # effacer les ACL par défaut
```

> ⚠️ **`cp` et `tar` perdent les ACL par défaut.** Utilisez `cp -a` (ou `--preserve=all`),
> `rsync -aA`, `tar --acls`. Sinon votre restauration de sauvegarde effacera toute la
> configuration de cette partie — un incident classique.

## 5.7 — ✅ La matrice de validation

C'est le test qui prouve que le montage complet fonctionne :

```bash
# Vérification depuis le compte root
echo "contenu" > /opt/appli-dev/src/app.py
chown bob:developer /opt/appli-dev/src/app.py
chmod 664 /opt/appli-dev/src/app.py

echo "--- bob (developer) : doit pouvoir écrire ---"
su - bob   -c 'echo "# modif bob" >> /opt/appli-dev/src/app.py && echo OK-ecriture'
su - bob   -c 'mkdir -p /opt/appli-dev/src/module && ls -ld /opt/appli-dev/src/module'

echo "--- alice (admin) : doit pouvoir lire, PAS écrire ---"
su - alice -c 'cat /opt/appli-dev/src/app.py >/dev/null && echo OK-lecture'
su - alice -c 'echo "modif alice" >> /opt/appli-dev/src/app.py' \
  || echo "OK-ecriture-refusee (attendu)"

echo "--- nobody : ne doit rien pouvoir faire ---"
# Notre 2775 laissait 'r-x' aux autres. Le cahier des charges dit « personne
# d'autre n'entre » : on ferme donc les droits 'other'.
setfacl -m o::--- /opt/appli-dev
su -s /bin/bash nobody -c 'ls /opt/appli-dev' || echo "OK-acces-refuse (attendu)"
```

| Acteur | Lire | Écrire | Supprimer un fichier tiers | Entrer |
|---|---|---|---|---|
| `bob` (developer) | ✅ | ✅ | ✅ (sauf dans `depot/`) | ✅ |
| `alice` (admin) | ✅ | ❌ | ❌ | ✅ |
| `nobody` (autres) | ❌ | ❌ | ❌ | ❌ |
| `root` | ✅ | ✅ | ✅ | ✅ |

⚠️ **root ignore toutes les permissions** (capacités `CAP_DAC_OVERRIDE` /
`CAP_DAC_READ_SEARCH`). Un `chmod 000` n'a jamais protégé quoi que ce soit de root : la
protection vient de *l'accès restreint à root lui-même* — soit exactement le travail de la
partie 3.

## 5.8 — Diagnostiquer un « Permission denied »

Un refus vient **presque toujours d'un répertoire parent**, pas du fichier visé. L'outil
adapté :

```bash
namei -l /opt/appli-dev/src/app.py
```

```
f: /opt/appli-dev/src/app.py
 drwxr-xr-x root root      /
 drwxr-xr-x root root      opt
 drwxrwsr-x root developer appli-dev      ← chaque maillon doit être traversable (x)
 drwxrwsr-x root developer src
 -rw-rw-r-- bob  developer app.py
```

**La méthode, dans l'ordre :**

```bash
# 1. Le chemin entier est-il traversable ?
namei -l /opt/appli-dev/src/app.py

# 2. Les droits et bits spéciaux exacts
stat /opt/appli-dev/src/app.py

# 3. Des ACL entrent-elles en jeu ? (le '+' de ls -l)
getfacl /opt/appli-dev/src/app.py

# 4. L'utilisateur est-il vraiment dans le groupe ? ⚠️ voir l'encadré ci-dessous
id bob

# 5. Simuler l'accès réellement
sudo -u bob test -w /opt/appli-dev/src/app.py && echo accessible || echo refusé

# 6. Toujours refusé ? Chercher au-delà des permissions
lsattr /opt/appli-dev/src/app.py     # attribut 'i' (immuable) → même root est bloqué
mount | grep -E ' / | /opt '         # montage en 'ro' ? option 'noexec' ?
journalctl -k -n 20                  # AppArmor / SELinux ?
```

> ⚠️ **Le piège qui fait perdre le plus de temps de tout ce TP.** Les groupes d'un processus
> sont fixés **au moment de la connexion**. Après un `usermod -aG developer bob`, les sessions
> **déjà ouvertes** de bob n'en savent rien : `id bob` (interrogation de la base) montre le
> nouveau groupe, mais `id` (dans sa session) ne le montre pas. Il faut **se reconnecter** —
> ou, pour un test immédiat :
> ```bash
> newgrp developer     # nouveau shell avec developer comme groupe principal
> sg developer -c 'id' # exécute UNE commande avec ce groupe
> ```

---

## 🏋️ Exercices

1. **Le compte de service** — créez un compte `appli` sans mot de passe, sans shell
   (`--system --shell /usr/sbin/nologin`), propriétaire de `/opt/appli-dev/releases`.
   Écrivez une unité systemd `appli-dev.service` qui tourne sous cette identité avec
   `UMask=0002`. Vérifiez que bob peut la redémarrer via `sudo`, mais pas s'y connecter.
2. **Restreindre encore** — modifiez `20-developer` pour que bob ne puisse redémarrer
   **que** `appli-dev`, plus `nginx`. Prouvez-le par un refus.
3. **La rotation des journaux** — `logs/` doit être écrit par le service et lu par
   `developer` et `admin`, sans que personne d'autre y accède. Quels droits ? Quelles ACL ?
4. **L'audit** — écrivez une commande unique qui liste tous les fichiers de `/opt`
   accessibles en écriture par « les autres » (`find -perm -o+w`). Pourquoi est-ce grave ?
5. **Le départ de bob** — bob quitte l'entreprise. Établissez la procédure complète :
   sessions, clés SSH, `cron`, fichiers lui appartenant dans `/opt`, `sudo`. Que faire de
   ses fichiers, et pourquoi `userdel -r` est-il rarement la bonne réponse ?
6. **Sans `sudo su`** — le groupe `admin` ne doit plus pouvoir devenir root, seulement
   gérer les comptes et les services. Réécrivez `10-admin` en liste blanche. Combien de
   commandes faut-il ? Qu'est-ce que cela vous apprend sur le coût réel du moindre privilège ?
7. **`setuid` en pratique** — pourquoi `/usr/bin/passwd` est-il `setuid root` ? Que se
   passe-t-il si vous exécutez `chmod u-s /usr/bin/passwd` ? (⚠️ snapshot d'abord.)

---

## 🧹 Nettoyage

```bash
# ⚠️ Détruit les comptes, leurs fichiers personnels et les règles sudo
rm -f /etc/sudoers.d/10-admin /etc/sudoers.d/20-developer
rm -f /etc/profile.d/umask-developer.sh
visudo -c                       # ✅ toujours revalider après suppression

pkill -u alice ; pkill -u bob   # fermer les sessions ouvertes
userdel -r alice
userdel -r bob
groupdel admin
groupdel developer

rm -rf /opt/appli-dev /tmp/sans-setgid
```

💡 `userdel` refuse d'agir si l'utilisateur a des processus en cours — d'où le `pkill`.
Et il **ne supprime pas** les fichiers hors du home : `find / -xdev -nouser -o -nogroup`
révèle les orphelins laissés derrière.

---

## 🆘 Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `bob is not in the sudoers file` | Le fichier de `sudoers.d` est ignoré | Vérifier `chmod 0440`, `chown root:root`, et **aucun `.` ni `~` dans le nom** |
| `>>> /etc/sudoers.d/X: syntax error` | Erreur de syntaxe | `visudo -f` sur le fichier ; ne jamais l'éditer avec `nano` |
| `sudo` cassé, plus aucun accès root | `sudoers` invalide | Shell root déjà ouvert, ou démarrer en `single` / `init=/bin/bash` (GRUB) et corriger |
| `sudo: no tty present and no askpass program` | `requiretty` + exécution non interactive | Retirer `requiretty`, ou lancer avec `ssh -t` |
| Règle `sudo` ignorée | Une règle **ultérieure** l'écrase | `sudo -ll -U bob` ; se souvenir que **la dernière correspondance gagne** |
| `sudo systemctl restart nginx` refusé alors que la règle existe | Chemin non conforme (`/bin` vs `/usr/bin`) | `command -v systemctl` et aligner la règle |
| `id` ne montre pas le nouveau groupe | Groupes figés à la connexion | Se reconnecter, ou `newgrp GROUPE` |
| `grep developer /etc/group` ne montre personne | Ce sont des membres **principaux** | Utiliser `id UTILISATEUR` ou `getent group` |
| Fichiers créés avec le mauvais groupe | Setgid absent sur le répertoire | `chmod g+s RÉPERTOIRE` puis corriger l'existant (`chown -R :GROUPE`) |
| Groupe correct, mais écriture refusée | `umask` à `022` → fichiers en `644` | `umask 002` (voir §5.4) ou ACL par défaut (§5.6) |
| ACL présente mais sans effet | Le `mask` la plafonne | `getfacl` (voir `#effective:`) ; un `chmod` a réécrit le masque |
| ACL disparues après restauration | `cp` / `tar` sans option ACL | `cp -a`, `rsync -aA`, `tar --acls` |
| `Permission denied` incompréhensible | Un **répertoire parent** bloque | `namei -l CHEMIN` |
| Même root ne peut pas écrire | Attribut immuable, ou montage `ro` | `lsattr`, `chattr -i` ; vérifier `mount` |
| `userdel: user bob is currently used by process` | Sessions ou services actifs | `pkill -u bob`, `loginctl terminate-user bob` |

---

## 📌 Ce qu'il faut retenir

1. Un droit s'accorde à un **UID / GID**, jamais à un nom. `admin` n'est puissant que parce
   qu'une **règle** le dit.
2. Les permissions `ugo` ne s'**additionnent pas** : le noyau s'arrête au premier cas qui
   s'applique.
3. Sur un répertoire, `x` = **traverser** et `w` = **créer / supprimer des entrées**. La
   suppression d'un fichier ne dépend jamais des droits du fichier.
4. **`usermod -aG`**, jamais `usermod -G`.
5. Une politique `sudo` s'écrit en **liste blanche**. Une liste noire (`!/bin/su`) ne tient
   jamais.
6. **Autoriser `systemctl` ou tout outil qui lance un éditeur, un pager ou un sous-processus,
   c'est donner un shell root.** On restreint les **sous-commandes**.
7. `visudo -c` après **chaque** modification, et un shell root ouvert à côté.
8. Le partage de fichiers = **setgid** (le bon groupe) **+ `umask 002`** (le bon droit
   d'écriture). Les deux, pas l'un ou l'autre.
9. Deux groupes sur un même arbre → **ACL POSIX**, avec l'ACL `default:` pour l'héritage —
   et une relecture de `getfacl` après tout `chmod`.
10. Face à un `Permission denied` : **`namei -l`** avant toute chose.
