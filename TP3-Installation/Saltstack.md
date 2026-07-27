# 🧂 TP — Gestion de configuration avec **SaltStack**

## 🎯 Objectif

Piloter **deux serveurs Debian 13** depuis un poste de contrôle, sans jamais s'y connecter en SSH.

```
                  ┌──────────────────────────────────────────┐
                  │  Poste de travail — Ubuntu 26.04         │
                  │  192.168.56.1                            │
                  │  salt-master   (ports 4505 / 4506)       │
                  │  /srv/salt/    ← les states (le code)    │
                  └──────────────┬───────────────────────────┘
                                 │  ZeroMQ (les minions appellent le master)
                 ┌───────────────┴────────────────┐
                 ▼                                ▼
        ┌──────────────────┐            ┌──────────────────┐
        │ box01            │            │ box02            │
        │ 192.168.56.10    │            │ 192.168.56.20    │
        │ Debian 13        │            │ Debian 13        │
        │ salt-minion      │            │ salt-minion      │
        │ grain role:      │            │                  │
        │   webserver      │            │                  │
        └──────────────────┘            └──────────────────┘
             + nginx                       socle commun seul
```

| Volet | Ce que vous apprenez |
|---|---|
| 🏗️ **Architecture** | Master / minion, modèle *pull*, ports 4505 / 4506 |
| 🔑 **Confiance** | Échange et acceptation des clés (`salt-key`) |
| 🔎 **Grains** | Les faits remontés par la machine — et comment cibler avec |
| 📜 **States** | Décrire l'état voulu en YAML, l'appliquer avec `state.apply` |
| 🎯 **Ciblage** | `top.sls`, match par glob et par **grain** |

💡 **L'idée centrale.** On ne décrit **jamais des commandes à exécuter**, mais **l'état
souhaité** de la machine (« ce paquet est installé », « ce fichier a ce contenu »). Salt
compare l'état réel à l'état voulu et n'agit **que sur l'écart**. C'est l'*idempotence* :
appliquer dix fois le même state donne le même résultat qu'une seule fois.

---

## 📋 Prérequis

| Rôle | Machine | IP | OS |
|---|---|---|---|
| Master | Votre poste | `192.168.56.1` | Ubuntu 26.04 |
| Minion | `box01` | `192.168.56.10` | Debian 13 |
| Minion | `box02` | `192.168.56.20` | Debian 13 |

Le réseau `192.168.56.0/24` est le **host-only** par défaut de VirtualBox : votre poste y
possède l'adresse `.1`, ce qui en fait un master naturellement joignable par les VM.

### Les deux VM avec Vagrant

```ruby
# Vagrantfile
Vagrant.configure("2") do |config|
  config.vm.box = "debian/trixie64"

  { "box01" => "192.168.56.10", "box02" => "192.168.56.20" }.each do |name, ip|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip
      node.vm.provider "virtualbox" do |vb|
        vb.memory = 1024
        vb.cpus   = 1
      end
    end
  end
end
```

```bash
vagrant up
vagrant status
```

✅ Contrôle depuis votre poste — les deux VM doivent répondre :

```bash
ping -c1 192.168.56.10 && ping -c1 192.168.56.20
```

> 💡 Pour entrer dans une VM : `vagrant ssh box01`. Pour passer root une fois dedans :
> `sudo -i`. Tout le TP se joue en **root**, des deux côtés.

---

# 1️⃣ Le master (Ubuntu 26.04)

## 1.1 — Ajouter le dépôt officiel Salt

Les paquets Salt ne sont pas dans les dépôts de la distribution (ou dans une version
ancienne). On utilise le dépôt du projet, hébergé par Broadcom.

```bash
mkdir -p /etc/apt/keyrings

# Clé de signature du dépôt
curl -fsSL https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public \
  -o /etc/apt/keyrings/salt-archive-keyring.pgp

# Définition du dépôt (format deb822)
curl -fsSL https://github.com/saltstack/salt-install-guide/releases/latest/download/salt.sources \
  -o /etc/apt/sources.list.d/salt.sources

apt update
apt-cache policy salt-master        # ✅ une version doit apparaître
```

Épinglez la version majeure pour ne pas migrer par accident lors d'un `apt upgrade` :

```bash
cat > /etc/apt/preferences.d/salt-pin-1001 <<'EOF'
Package: salt-*
Pin: version 3007.*
Pin-Priority: 1001
EOF
```

> ⚠️ Adaptez `3007.*` à la version majeure que vous installez (`apt-cache policy salt-master`).

## 1.2 — Installer et configurer

```bash
apt install -y salt-master
```

La configuration ne se modifie **jamais** dans `/etc/salt/master` : on dépose un fragment
dans `/etc/salt/master.d/`, ce qui survit aux mises à jour du paquet.

```bash
mkdir -p /srv/salt

cat > /etc/salt/master.d/tp.conf <<'EOF'
interface: 192.168.56.1

file_roots:
  base:
    - /srv/salt
EOF

systemctl restart salt-master
systemctl status salt-master --no-pager
```

| Directive | Rôle |
|---|---|
| `interface` | Adresse d'écoute. Ici on **n'expose pas** le master sur le réseau public |
| `file_roots` | Où le master va chercher les states de l'environnement `base` |

✅ Les deux ports doivent être ouverts :

```bash
ss -tlnp | grep -E '4505|4506'
```

| Port | Sens | Usage |
|---|---|---|
| **4505** | minion → master | Bus de publication : le master y **diffuse** les ordres |
| **4506** | minion → master | Canal de retour : résultats, transfert de fichiers |

> 💡 **Modèle *pull*.** Le master n'ouvre **aucune** connexion vers les minions : ce sont
> eux qui se connectent et restent à l'écoute. Un minion derrière un NAT fonctionne donc
> sans aucun port ouvert de son côté — l'inverse exact de ce que fait Ansible en SSH.

Si `ufw` est actif sur votre poste :

```bash
ufw allow from 192.168.56.0/24 to any port 4505,4506 proto tcp
```

---

# 2️⃣ Les minions (box01 et box02)

**À faire sur `box01` puis sur `box02`**, en root (`vagrant ssh box01` → `sudo -i`).

```bash
apt update && apt install -y curl

mkdir -p /etc/apt/keyrings
curl -fsSL https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public \
  -o /etc/apt/keyrings/salt-archive-keyring.pgp
curl -fsSL https://github.com/saltstack/salt-install-guide/releases/latest/download/salt.sources \
  -o /etc/apt/sources.list.d/salt.sources

apt update
apt install -y salt-minion
```

Pointer le minion vers le master, et lui donner un **identifiant stable** :

```bash
cat > /etc/salt/minion.d/master.conf <<'EOF'
master: 192.168.56.1
id: box01
EOF

systemctl restart salt-minion
```

> ⚠️ Sur `box02`, mettez bien `id: box02`. Sans directive `id`, Salt utilise le nom d'hôte
> — ce qui marcherait ici, mais un ID explicite évite qu'un renommage de la machine crée un
> **nouveau** minion (et une nouvelle clé à accepter).

✅ Le minion doit avoir joint le master :

```bash
journalctl -u salt-minion -n 20 --no-pager
# On cherche : « Minion is starting as user 'root' » puis l'attente d'acceptation de clé
```

---

# 3️⃣ Accepter les clés

À la première connexion, le minion envoie sa clé publique au master, qui la met **en
attente**. Rien ne passe tant qu'un humain n'a pas validé.

**Sur le master :**

```bash
salt-key -L
```

```
Accepted Keys:
Denied Keys:
Unaccepted Keys:
box01
box02
Rejected Keys:
```

Avant d'accepter, on **compare les empreintes** — c'est ce contrôle qui empêche une machine
inconnue de se faire passer pour `box01` :

```bash
# Sur le master
salt-key -f box01

# Sur box01
salt-call --local key.finger
```

Les deux empreintes doivent être identiques. On accepte alors :

```bash
salt-key -a box01        # une clé nommée
salt-key -A -y           # ou toutes les clés en attente, sans confirmation
salt-key -L              # ✅ box01 et box02 sont dans « Accepted Keys »
```

✅ Premier ordre distant :

```bash
salt '*' test.ping
```

```
box01:
    True
box02:
    True
```

Quelques commandes ponctuelles pour prendre en main la syntaxe `salt <cible> <fonction> [args]` :

```bash
salt '*' cmd.run 'uptime'
salt '*' disk.usage
salt 'box01' pkg.version bash
```

> 💡 **`salt` vs `salt-call`.** `salt` s'exécute **sur le master** et cible des minions.
> `salt-call` s'exécute **sur le minion** et ne concerne que lui — indispensable pour
> déboguer : `salt-call -l debug state.apply` affiche tout ce que le minion fait vraiment.

---

# 4️⃣ Les grains — ce que la machine sait d'elle-même

Un **grain** est un fait statique découvert au démarrage du minion : OS, version, CPU,
mémoire, IP, virtualisation…

```bash
salt 'box01' grains.items          # tout (long)
salt '*' grains.item os osrelease osarch
salt '*' grains.get ipv4
salt '*' grains.get virtual        # -> VirtualBox
```

Les grains servent surtout à **cibler** :

```bash
salt -G 'os:Debian' test.ping
salt -G 'osmajorrelease:13' cmd.run 'hostname'
```

| Option | Type de ciblage | Exemple |
|---|---|---|
| *(aucune)* | Glob sur l'ID | `salt 'box*' test.ping` |
| `-G` | Grain | `salt -G 'os:Debian' test.ping` |
| `-E` | Expression régulière | `salt -E 'box0[12]' test.ping` |
| `-L` | Liste explicite | `salt -L 'box01,box02' test.ping` |
| `-C` | Composé (ET / OU) | `salt -C 'G@os:Debian and box01' test.ping` |

---

# 5️⃣ Le socle commun — state `default-server`

On décrit maintenant l'état attendu de **tout** serveur du parc : un jeu d'outils et une
bannière SSH légale.

## 5.1 — Arborescence

**Sur le master :**

```bash
mkdir -p /srv/salt/default-server/files
```

```
/srv/salt/
├── top.sls                       # qui reçoit quoi
└── default-server/
    ├── init.sls                  # le state lui-même
    └── files/
        └── banner                # le contenu de la bannière
```

> 💡 Un dossier contenant un `init.sls` est appelable par son seul nom : `default-server`
> équivaut à `default-server.init`.

## 5.2 — La bannière

```bash
cat > /srv/salt/default-server/files/banner <<'EOF'
***************************************************************************
                          A T T E N T I O N
***************************************************************************
  Vous accedez a un systeme informatique protege appartenant a CORP.NC.

  L'acces est reserve aux personnes explicitement autorisees. Toute
  connexion et toute action realisee sur ce systeme sont enregistrees
  et susceptibles d'etre analysees.

  Tout acces ou maintien frauduleux dans ce systeme est passible de
  poursuites civiles et penales.

  Si vous n'etes pas un utilisateur autorise : deconnectez-vous
  immediatement.
***************************************************************************
EOF
```

> 💡 **Pas d'accents.** La bannière est envoyée **avant** toute négociation de session : le
> client l'affiche brute, sans garantie d'encodage. On reste en ASCII pur.

## 5.3 — Le state

```bash
cat > /srv/salt/default-server/init.sls <<'EOF'
# ---------------------------------------------------------------
# Socle commun a tous les serveurs CORP.NC
# ---------------------------------------------------------------

outils-de-base:
  pkg.installed:
    - pkgs:
      - git
      - htop
      - curl
      - wget
      - vim
      - tmux
      - rsync
      - tree
      - net-tools
      - dnsutils
      - unzip
      - ncdu

/etc/ssh/banner:
  file.managed:
    - source: salt://default-server/files/banner
    - user: root
    - group: root
    - mode: '0644'

/etc/ssh/sshd_config.d/99-banner.conf:
  file.managed:
    - contents: |
        Banner /etc/ssh/banner
    - user: root
    - group: root
    - mode: '0644'

recharger-sshd:
  cmd.run:
    - name: sshd -t && systemctl try-reload-or-restart ssh.service
    - onchanges:
      - file: /etc/ssh/banner
      - file: /etc/ssh/sshd_config.d/99-banner.conf
EOF
```

Lecture du fichier :

| Élément | Signification |
|---|---|
| `outils-de-base` | L'**ID** du bloc : libre, mais unique dans le state |
| `pkg.installed` | Module `pkg`, fonction `installed` → traduit en `apt` sur Debian |
| `salt://` | Chemin **relatif à `file_roots`**, donc `/srv/salt/…` sur le master |
| `contents` | Contenu inline, pour un fichier trop court pour justifier un `files/` |
| `onchanges` | Le bloc ne s'exécute **que si** un des fichiers surveillés a changé |

> 💡 **`onchanges` est la clé de l'idempotence.** Sans lui, `cmd.run` rechargerait sshd à
> **chaque** application. Avec, il ne se déclenche que sur un vrai changement.

> 💡 **`sshd -t &&`** valide la configuration *avant* de recharger. Si la syntaxe est
> cassée, le state échoue mais le démon en cours continue de tourner : vous gardez la main.
> `try-reload-or-restart` ne fait rien si le service n'est pas actif — ce qui est le cas
> quand SSH est démarré à la demande par `ssh.socket` (les nouvelles connexions relisent
> alors la config d'elles-mêmes).

## 5.4 — Le `top.sls`

Le *top file* est la table d'affectation : **quel state pour quelle cible**.

```bash
cat > /srv/salt/top.sls <<'EOF'
base:
  '*':
    - default-server
EOF
```

## 5.5 — Appliquer

**Toujours en simulation d'abord** :

```bash
salt '*' state.apply test=True
```

Chaque bloc affiche `Result: None` et un `Comment` décrivant ce qui *serait* fait. Rien
n'est modifié.

Puis pour de vrai :

```bash
salt '*' state.apply
```

```
box01:
----------
          ID: outils-de-base
    Function: pkg.installed
      Result: True
     Comment: 12 targeted packages were installed/updated.
     Changes:
              ----------
              git: ...
...
Summary for box01
------------
Succeeded: 4 (changed=3)
Failed:    0
```

✅ **Rejouez la commande immédiatement** :

```bash
salt '*' state.apply
```

Cette fois : `Succeeded: 4` avec **`changed=0`**. C'est la démonstration de l'idempotence —
rien à faire, donc rien de fait.

✅ Vérification finale, la vraie :

```bash
ssh vagrant@192.168.56.10
```

La bannière CORP.NC s'affiche **avant** la demande de mot de passe.

---

# 6️⃣ Cibler `box01` par un grain — le rôle `webserver`

Le socle est identique partout. On veut maintenant que **seule** `box01` soit un serveur
web — sans jamais écrire `box01` dans le `top.sls`, pour que le jour où `box07` doit servir
du web, il suffise de lui poser le même grain.

## 6.1 — Poser le grain sur box01

Les grains personnalisés se déclarent dans `/etc/salt/grains` (fichier YAML **sans** clé
`grains:` en tête).

**Sur `box01`, en root :**

```bash
cat > /etc/salt/grains <<'EOF'
role: webserver
env: production
EOF

systemctl restart salt-minion
```

✅ Depuis le master :

```bash
salt '*' grains.get role
```

```
box01:
    webserver
box02:
```

```bash
salt -G 'role:webserver' test.ping     # ✅ box01 uniquement
```

> 💡 **Alternative depuis le master** : `salt box01 grains.setval role webserver`.
> Pratique, mais le fichier `/etc/salt/grains` reste préférable — il est versionnable et
> visible à l'inspection de la VM. Attention aussi : les grains sont fournis par le
> **minion**, donc par une machine potentiellement compromise. Pour une donnée sensible
> (autorisation, secret), utilisez le **pillar**, qui vient du master.

## 6.2 — Le state `webserver`

**Sur le master :**

```bash
mkdir -p /srv/salt/webserver

cat > /srv/salt/webserver/init.sls <<'EOF'
# ---------------------------------------------------------------
# Serveur web nginx — applique aux minions grain role:webserver
# ---------------------------------------------------------------

nginx:
  pkg.installed: []
  service.running:
    - enable: True
    - require:
      - pkg: nginx

/var/www/html/index.html:
  file.managed:
    - source: salt://webserver/files/index.html.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - pkg: nginx
EOF
```

| Élément | Signification |
|---|---|
| `nginx:` puis deux fonctions | Un même ID peut porter plusieurs états (`pkg` + `service`) |
| `require` | Ordre d'exécution : le service ne démarre qu'après l'installation |
| `enable: True` | Le service est aussi activé au démarrage |
| `template: jinja` | Le fichier est un gabarit : les `{{ … }}` sont évalués **sur le master** |

La page, avec des données issues des grains du minion :

```bash
mkdir -p /srv/salt/webserver/files

cat > /srv/salt/webserver/files/index.html.jinja <<'EOF'
<!doctype html>
<html lang="fr">
  <head><meta charset="utf-8"><title>Welcome to {{ grains['id'] }}</title></head>
  <body>
    <h1>Welcome to {{ grains['id'] }}</h1>
    <p>Role  : {{ grains['role'] }}</p>
    <p>OS    : {{ grains['os'] }} {{ grains['osrelease'] }}</p>
    <p>IP    : {{ grains['fqdn_ip4'] | join(', ') }}</p>
    <p>Deploye par SaltStack — CORP.NC</p>
  </body>
</html>
EOF
```

> 💡 Le rendu Jinja a lieu **sur le master**, mais avec les grains **du minion destinataire**.
> Le même gabarit produit donc un fichier différent sur chaque machine.

## 6.3 — Brancher le state dans le `top.sls`

```bash
cat > /srv/salt/top.sls <<'EOF'
base:
  # Socle commun : toutes les machines
  '*':
    - default-server

  # Serveurs web : match par grain, pas par nom de machine
  'role:webserver':
    - match: grain
    - webserver
EOF
```

> ⚠️ La ligne `- match: grain` est **obligatoire** : sans elle, Salt interprète
> `role:webserver` comme un glob sur l'ID du minion et ne cible… rien.

## 6.4 — Appliquer et vérifier

```bash
salt '*' state.apply test=True     # ✅ box02 : aucun changement, box01 : nginx à installer
salt '*' state.apply
```

✅ Contrôles :

```bash
# La cible est bien la bonne
salt -G 'role:webserver' state.apply

# Depuis le master
curl http://192.168.56.10          # -> Welcome to box01
curl http://192.168.56.20          # -> Connection refused : box02 n'est pas un serveur web

salt 'box01' service.status nginx  # -> True
```

🏋️ **À vous.** Posez le grain `role: webserver` sur `box02`, relancez `salt 'box02'
state.apply`, et constatez que la page annonce `Welcome to box02` — sans avoir modifié une
seule ligne de state.

---

## 🧾 Récapitulatif des commandes

| Commande | Rôle |
|---|---|
| `salt-key -L` / `-a <id>` / `-A -y` / `-d <id>` | Lister / accepter / tout accepter / supprimer une clé |
| `salt '*' test.ping` | Les minions répondent-ils ? |
| `salt '*' grains.items` | Tous les faits d'une machine |
| `salt -G 'role:webserver' <fn>` | Cibler par grain |
| `salt '*' state.apply test=True` | **Simulation** — ne modifie rien |
| `salt '*' state.apply` | Appliquer le `top.sls` |
| `salt '*' state.apply webserver` | Appliquer **un seul** state, hors `top.sls` |
| `salt '*' state.show_sls default-server` | Voir le state compilé, sans l'appliquer |
| `salt-call -l debug state.apply` | Rejouer **depuis le minion**, en verbeux — le réflexe de debug |
| `salt '*' saltutil.sync_all` | Resynchroniser modules et grains personnalisés |
| `salt '*' cmd.run 'commande'` | Sortie de secours : exécuter une commande brute |

---

## 🆘 Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `Minion did not return. [No response]` | Minion arrêté, ou clé acceptée après son dernier démarrage | `systemctl restart salt-minion` sur la VM |
| Le minion n'apparaît pas dans `salt-key -L` | Master injoignable sur 4505/4506 | `ss -tlnp \| grep 450` sur le master ; pare-feu ; `interface:` mal réglé |
| `The Salt Master has cached the public key for this node` | ID réutilisé avec une nouvelle clé (VM recréée) | `salt-key -d box01` sur le master, puis `rm -f /etc/salt/pki/minion/minion_master.pub` sur le minion et redémarrer |
| `No Top file or master_tops data matches found` | `top.sls` absent, ou hors `file_roots` | Vérifier `/srv/salt/top.sls` et la conf `file_roots` |
| `Rendering SLS failed` | Erreur d'indentation YAML | Les tabulations sont interdites — 2 espaces ; `salt '*' state.show_sls <nom>` |
| Le grain `role` reste vide | `/etc/salt/grains` mal formé ou minion non relancé | Pas de clé `grains:` en tête ; `systemctl restart salt-minion` |
| `'role:webserver'` ne cible rien dans le top file | `- match: grain` oublié | L'ajouter sous la cible |
| Bannière SSH absente | Drop-in non relu, ou `Include` absent de `sshd_config` | `sshd -T \| grep -i banner` sur le minion |

---

## 🏋️ Pour aller plus loin

1. **Pillar** — déplacez les données (liste de paquets, nom de l'organisation) dans
   `/srv/pillar/`, hors des states. Contrairement aux grains, le pillar vient du **master**
   et n'est visible que du minion concerné : c'est là que vont les secrets.
2. **`highstate` planifié** — activez un appel périodique côté minion :
   `schedule: { highstate: { function: state.apply, minutes: 60 } }`. La dérive de
   configuration se corrige alors toute seule.
3. **Versionner `/srv/salt`** — un dépôt Git, une *pull request* par changement : c'est
   l'*Infrastructure as Code*. Salt sait même lire ses states directement depuis Git
   (`gitfs`).
4. **`salt-ssh`** — appliquer les mêmes states sur une machine **sans minion**, en SSH pur.
   Utile pour les équipements que l'on ne peut pas modifier.
5. **Reactor & beacons** — un *beacon* surveille un événement sur le minion (fichier modifié,
   service tombé), le *reactor* déclenche un state en réponse. On passe de la configuration
   à la **remédiation automatique**.
