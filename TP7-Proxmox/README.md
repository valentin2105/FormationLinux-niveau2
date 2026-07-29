# 🧱 TP7 — Proxmox : image cloud Debian 13, template & clones cloud-init

## 🎯 Objectif

Arrêter d'installer les VM à la main. À la fin de ce TP, vous produisez une VM Debian 13
prête à l'emploi **en moins de 30 secondes**, avec son utilisateur, sa clé SSH et son IP,
sans jamais toucher un installateur.

| Étape | Ce que vous faites | Outil |
|---|---|---|
| 1️⃣ **Récupérer** | Télécharger et vérifier l'image cloud officielle Debian 13 | `wget`, `sha512sum` |
| 2️⃣ **Préparer** | Injecter `qemu-guest-agent` dans l'image *avant* le premier démarrage | `virt-customize` |
| 3️⃣ **Importer** | Créer une VM et y importer le disque qcow2 sur `local-lvm` | `qm create`, `qm set` |
| 4️⃣ **Figer** | Convertir la VM en **template** (modèle non démarrable) | `qm template` |
| 5️⃣ **Cloner** | Dériver des VM du template | `qm clone` |
| 6️⃣ **Configurer** | Utilisateur, clé SSH, IP statique au premier boot | **cloud-init** |
| 7️⃣ **Enrôler** | Le clone rejoint le master Salt et s'auto-configure au boot | `salt-minion` |

💡 **Le principe.** Une image cloud est un disque déjà installé, sans configuration :
pas de nom d'hôte, pas d'utilisateur, pas d'IP, pas de clés SSH d'hôte. Au premier
démarrage, **cloud-init** lit une source de données (ici un CD-ROM virtuel généré par
Proxmox) et se configure. C'est le modèle « *une image, mille machines* ».

---

## 📋 Prérequis

> ⚠️ **Ce TP ne se joue pas sur la VM de TP** : il se joue **sur l'hyperviseur Proxmox
> lui-même**, en `root`, via SSH ou le *Shell* de l'interface web.

| Élément | Valeur attendue |
|---|---|
| Hyperviseur | Proxmox VE 8 ou 9 (PVE 9 est basé sur Debian 13 « Trixie ») |
| Accès | `root` sur le nœud (SSH ou Shell de l'interface web) |
| Bridge réseau | **`vmbr0`** (le bridge par défaut, relié au réseau physique) |
| Stockage disques | **`local-lvm`** (LVM-thin, créé par l'installateur Proxmox) |
| Stockage fichiers | `local` (`/var/lib/vz`) pour l'image téléchargée et les *snippets* |
| Espace libre | ~25 Go sur `local-lvm`, ~5 Go sur `local` |
| Internet | Sortie HTTPS vers `cloud.debian.org` |

### Vérifier son environnement

```bash
pveversion                       # pve-manager/9.x  (ou 8.x)
ip -br link show vmbr0           # vmbr0 doit être UP
pvesm status                     # local (dir) + local-lvm (lvmthin) en 'active'
```

Sortie attendue de `pvesm status` :

```
Name         Type     Status   Total      Used     Available   %
local        dir      active   98559220   4212344  89294764    4.27%
local-lvm    lvmthin  active   350224384  0        350224384   0.00%
```

✅ Si `local-lvm` est absent, votre nœud utilise un autre schéma de stockage
(ZFS, Ceph, LVM *thick*…). Remplacez `local-lvm` par le nom de votre stockage dans
**toutes** les commandes du TP — et lisez l'encadré ⚠️ de la [partie 5](#-partie-5--cloner-le-template).

### Variables du TP

On les pose une fois pour toutes, elles sont réutilisées partout :

```bash
export TPL_ID=9000                            # VMID du template
export TPL_NAME=debian13-cloud
export STORAGE=local-lvm                      # stockage des disques de VM
export BRIDGE=vmbr0                           # bridge réseau
export IMG_DIR=/var/lib/vz/template/iso       # où stocker l'image téléchargée
export IMG=debian-13-genericcloud-amd64.qcow2
```

> 💡 `export` ne survit pas à une déconnexion SSH. Si vous reprenez le TP plus tard,
> rejouez ce bloc.

---

# 📥 Partie 1 — Récupérer l'image cloud Debian 13

## 1.1 — Choisir la bonne image

Debian publie plusieurs variantes. Se tromper est le premier piège du TP :

| Variante | Contenu | Usage |
|---|---|---|
| **`genericcloud`** ✅ | Noyau + `cloud-init`, pilotes **virtuels uniquement** (virtio) | **Ce qu'il faut ici** : KVM/Proxmox, OpenStack, libvirt |
| `generic` | Idem + tous les pilotes matériels | Machines physiques, hyperviseurs exotiques |
| `nocloud` | **Sans** `cloud-init`, root sans mot de passe | Tests locaux, conteneurs, débogage |
| `azure` / `ec2` / `gce` | Agents spécifiques au cloud public | Hors sujet |

⚠️ **`nocloud` est le piège classique** : l'image démarre, mais aucune de vos options
cloud-init n'est appliquée — parce que cloud-init n'y est simplement pas installé.

## 1.2 — Télécharger et vérifier

Une image système téléchargée sur Internet et déployée sur tout un parc **se vérifie**.

```bash
mkdir -p "$IMG_DIR" && cd "$IMG_DIR"

BASE=https://cloud.debian.org/images/cloud/trixie/latest

wget "$BASE/$IMG"
wget "$BASE/SHA512SUMS"
wget "$BASE/SHA512SUMS.sign"
```

**Étape 1 — l'empreinte de l'image correspond-elle à celle annoncée ?**

```bash
grep " $IMG\$" SHA512SUMS | sha512sum -c -
```

✅ Sortie attendue : `debian-13-genericcloud-amd64.qcow2: OK`

**Étape 2 — le fichier d'empreintes est-il bien signé par Debian ?**

💡 Vérifier l'empreinte seule ne protège de rien si `SHA512SUMS` a été falsifié en même
temps que l'image. La signature GPG est le maillon qui ancre la confiance.

```bash
apt install -y gnupg

# Récupérer la clé de l'équipe Debian Cloud depuis le trousseau officiel Debian
gpg --keyserver keyring.debian.org --search-keys debian-cloud@debian.org

gpg --verify SHA512SUMS.sign SHA512SUMS
```

Cherchez la ligne `Good signature from "Debian Cloud Team ..."`.

> ⚠️ **Une signature valide ne suffit pas** : n'importe qui peut signer un fichier. Comparez
> l'empreinte affichée par `gpg --verify` avec celle publiée par l'équipe Debian Cloud
> (<https://wiki.debian.org/Teams/Cloud>). C'est cette comparaison qui a de la valeur.

> 💡 L'avertissement `WARNING: This key is not certified with a trusted signature` est
> normal : vous n'avez pas signé la clé dans votre trousseau. Ce qui compte, c'est
> `Good signature` **et** la bonne empreinte.

**Inspecter l'image :**

```bash
qemu-img info "$IMG"
```

```
file format: qcow2
virtual size: 3 GiB (3221225472 bytes)
disk size: 347 MiB
```

💡 3 GiB de taille virtuelle, ~350 Mio réels : le qcow2 est *creux* (sparse). On agrandira
le disque à la partie 3 — cloud-init étendra la partition racine tout seul au boot.

---

# 🔧 Partie 2 — Préparer l'image (virt-customize)

## 2.1 — Pourquoi modifier l'image maintenant ?

L'image officielle **ne contient pas `qemu-guest-agent`**. Sans lui :

- Proxmox n'affiche pas l'IP de la VM dans l'interface
- `Shutdown` envoie un ACPI brutal au lieu d'un arrêt propre
- les snapshots ne peuvent pas geler les systèmes de fichiers (`fsfreeze`)
- `qm guest exec` ne fonctionne pas

On pourrait l'installer via cloud-init à chaque clone… ou **une seule fois dans l'image**.
La seconde option est plus rapide au boot et fonctionne même sans accès Internet.

## 2.2 — virt-customize

`virt-customize` monte le qcow2 sans le démarrer et exécute des commandes dedans.

```bash
apt install -y libguestfs-tools

# ⚠️ Obligatoire sur Proxmox : le noyau PVE n'est pas lisible par l'appliance libguestfs
export LIBGUESTFS_BACKEND=direct

cd "$IMG_DIR"

# 💡 On travaille sur une COPIE : l'original vérifié reste intact
cp "$IMG" "custom-$IMG"

virt-customize -a "custom-$IMG" \
  --install qemu-guest-agent,htop,vim,curl \
  --run-command 'systemctl enable qemu-guest-agent' \
  --timezone Pacific/Noumea \
  --truncate /etc/machine-id
```

| Option | Rôle |
|---|---|
| `--install PKG,PKG` | `apt install` hors ligne dans l'image |
| `--run-command` | Commande arbitraire dans le chroot de l'image |
| `--timezone` | Fuseau horaire par défaut |
| `--truncate /etc/machine-id` | ⚠️ **Crucial** : voir ci-dessous |
| `--root-password password:XXX` | Mot de passe root (déconseillé : préférez cloud-init) |
| `--firstboot-command` | Commande jouée au tout premier démarrage |

⚠️ **`/etc/machine-id` : le bug qui vous fera perdre une heure.** Ce fichier identifie de
façon unique une installation. S'il est identique sur toutes les VM clonées, `systemd-networkd`
et le serveur DHCP les confondent : deux VM différentes reçoivent la **même IP**.
Le vider force sa régénération à chaque premier boot.

✅ Vérification :

```bash
virt-cat -a "custom-$IMG" /etc/timezone            # -> Pacific/Noumea
virt-ls  -a "custom-$IMG" /usr/bin | grep qemu-ga  # -> qemu-ga
```

---

# 💿 Partie 3 — Créer la VM et importer le disque

## 3.1 — Créer la coquille de VM

```bash
qm create "$TPL_ID" \
  --name "$TPL_NAME" \
  --ostype l26 \
  --cpu host \
  --sockets 1 --cores 2 \
  --memory 2048 --balloon 1024 \
  --numa 0 \
  --net0 "virtio,bridge=$BRIDGE" \
  --scsihw virtio-scsi-single \
  --serial0 socket --vga serial0 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --tablet 0 \
  --onboot 1
```

Chaque option compte — c'est la partie à comprendre du TP :

| Option | Pourquoi |
|---|---|
| `--ostype l26` | Famille Linux 2.6+ : ajuste les options KVM proposées |
| `--cpu host` | Expose toutes les instructions du CPU physique (⚠️ empêche la migration à chaud vers un CPU différent — utilisez `x86-64-v2-AES` sur un cluster hétérogène) |
| `--balloon 1024` | Mémoire minimale garantie ; l'hôte peut reprendre le reste |
| `--net0 virtio,bridge=vmbr0` | Carte paravirtualisée (~10 Gb/s) sur le bridge physique |
| `--scsihw virtio-scsi-single` | Un contrôleur SCSI par disque : requis pour `iothread` et le TRIM |
| `--serial0 socket --vga serial0` | ⚠️ **Indispensable** : les images cloud logguent sur `ttyS0`. Sans ça, la console web reste noire |
| `--agent enabled=1` | Active le canal vers `qemu-guest-agent` |
| `fstrim_cloned_disks=1` | TRIM automatique après un clone : rend l'espace au LVM-thin |
| `--onboot 1` | La VM redémarre avec l'hôte (hérité par les clones) |

## 3.2 — Importer le disque qcow2 vers local-lvm

**Méthode moderne (Proxmox ≥ 8.0)** — import et attachement en une commande :

```bash
qm set "$TPL_ID" \
  --scsi0 "$STORAGE:0,import-from=$IMG_DIR/custom-$IMG,discard=on,ssd=1,iothread=1"
```

💡 Le `:0` signifie « taille déduite du fichier source ».

<details>
<summary>Méthode historique en deux temps (<code>qm importdisk</code>) — fonctionne partout</summary>

```bash
qm importdisk "$TPL_ID" "$IMG_DIR/custom-$IMG" "$STORAGE"
# -> "Successfully imported disk as 'unused0:vm-9000-disk-0'"

qm set "$TPL_ID" --scsi0 "$STORAGE:vm-$TPL_ID-disk-0,discard=on,ssd=1,iothread=1"
```
</details>

| Option de disque | Rôle |
|---|---|
| `discard=on` | Propage le TRIM de l'invité au LVM-thin : l'espace supprimé est **réellement** libéré |
| `ssd=1` | Annonce un disque non rotatif à l'invité (désactive les optimisations inutiles) |
| `iothread=1` | Thread d'I/O dédié : moins de contention sur le thread principal de QEMU |

⚠️ **Conversion silencieuse.** `local-lvm` est un stockage *bloc* : le qcow2 est converti en
**volume LVM brut (raw)**. Vous perdez les fonctionnalités qcow2 (snapshots internes) — mais
LVM-thin fournit ses propres snapshots. C'est un bon compromis, pas une perte.

## 3.3 — Disque cloud-init, ordre de boot, taille

```bash
# Lecteur CD-ROM virtuel qui portera la configuration cloud-init
qm set "$TPL_ID" --ide2 "$STORAGE:cloudinit"

# Démarrer sur le disque système, et seulement lui
qm set "$TPL_ID" --boot order=scsi0

# 20 Go au lieu de 3 : cloud-init étendra la partition au premier boot
qm resize "$TPL_ID" scsi0 20G
```

💡 **Comment cloud-init reçoit-il sa configuration ?** Proxmox génère à la volée une image
ISO contenant `user-data`, `meta-data` et `network-config`, et la présente sur `ide2`.
Au boot, cloud-init détecte cette source (`NoCloud`), la lit, s'applique. La *datasource*
est reconstruite à chaque démarrage : modifier un paramètre `qm set --ci*` suffit.

✅ Vérifications :

```bash
qm config "$TPL_ID"
lvs pve                                 # -> vm-9000-disk-0, 20.00g
```

Vous devez voir `scsi0: local-lvm:vm-9000-disk-0,discard=on,...,size=20G` et
`ide2: local-lvm:vm-9000-cloudinit,media=cdrom`.

---

# ☁️ Partie 4 — Cloud-init : les valeurs par défaut du template

Deux niveaux de configuration :

- **sur le template** → les valeurs *communes* à toutes les VM (utilisateur, clé SSH, DNS)
- **sur chaque clone** → ce qui est *spécifique* (nom d'hôte, IP)

## 4.1 — Une clé SSH sur le nœud Proxmox

```bash
[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -C "proxmox-$(hostname)" -N '' -f /root/.ssh/id_ed25519
cat /root/.ssh/id_ed25519.pub
```

## 4.2 — Appliquer les valeurs par défaut

```bash
qm set "$TPL_ID" \
  --ciuser formation \
  --cipassword "$(openssl passwd -6 'FormationNC2026!')" \
  --sshkeys /root/.ssh/id_ed25519.pub \
  --nameserver "1.1.1.1 9.9.9.9" \
  --searchdomain lan \
  --ipconfig0 ip=dhcp \
  --ciupgrade 0
```

| Paramètre | Effet dans l'invité |
|---|---|
| `--ciuser` | Crée l'utilisateur, avec `sudo` **sans mot de passe** |
| `--cipassword` | ⚠️ Attend un **hash**. Une chaîne en clair est stockée en clair dans la config de la VM |
| `--sshkeys FICHIER` | Injecte les clés dans `~/.ssh/authorized_keys` (plusieurs clés = plusieurs lignes) |
| `--nameserver` / `--searchdomain` | Écrit `/etc/resolv.conf` |
| `--ipconfig0` | Réseau de `net0` : `ip=dhcp` ou `ip=A.B.C.D/CIDR,gw=A.B.C.1` |
| `--ciupgrade 0` | ⚠️ Désactive l'`apt upgrade` au premier boot : gain de 1 à 3 minutes, et pas de dérive entre clones (option disponible depuis PVE 8.2 — retirez-la sur une version antérieure) |

> 💡 **`--cipassword` : pourquoi un hash ?** `qm config` est lisible par tout utilisateur
> ayant `VM.Audit`, et la config est écrite en clair dans `/etc/pve/qemu-server/`.
> `openssl passwd -6` produit un hash SHA-512 (`$6$...`) — le même format que `/etc/shadow`.
> **En production, on ne met aucun mot de passe : clé SSH uniquement.**

## 4.3 — Lire ce que cloud-init va recevoir

```bash
qm cloudinit dump "$TPL_ID" user       # user-data (utilisateur, clés, paquets)
qm cloudinit dump "$TPL_ID" network    # network-config (IP, routes)
qm cloudinit dump "$TPL_ID" meta       # meta-data (instance-id)
```

✅ Prenez le temps de lire cette sortie : c'est du YAML cloud-init standard. Vous venez de
comprendre ce que Proxmox fait vraiment derrière ses champs de formulaire.

## 4.4 — Figer la VM en template

```bash
qm template "$TPL_ID"
```

⚠️ **Opération irréversible.** Une fois la VM convertie :
- elle ne peut plus démarrer,
- ses disques passent en **lecture seule**,
- il n'existe pas de commande `qm untemplate`.

Pour faire évoluer le modèle plus tard : cloner le template en VM normale, modifier, et
recréer un nouveau template (`9001`, `9002`…). Gardez toujours l'ancien pendant la transition.

✅ Vérification :

```bash
qm list | grep "$TPL_ID"      # colonne STATUS -> 'stopped', et l'icône change dans l'interface
qm config "$TPL_ID" | grep template   # -> template: 1
```

---

# 🐣 Partie 5 — Cloner le template

## 5.1 — Clone complet vs clone lié

| Type | Commande | Espace disque | Dépendance au template |
|---|---|---|---|
| **Complet** (*full*) | `qm clone ... --full` | Copie entière | ❌ Aucune — VM autonome |
| **Lié** (*linked*) | `qm clone ...` (défaut sur stockage compatible) | Quasi nul au départ | ⚠️ **Le template devient indestructible** |

⚠️ **Le clone lié n'est possible que sur un stockage qui gère les snapshots** :
`local-lvm` (LVM-**thin**) ✅, ZFS ✅, qcow2 sur répertoire ✅ — mais **LVM classique
(*thick*) ❌ et iSCSI ❌**. Sur ces derniers, `--full` est imposé.

💡 **Le compromis.** Le clone lié est instantané et gratuit en espace, mais toutes les VM
lisent les blocs communs du même volume : le template ne peut plus être supprimé, et vous
créez un point de contention I/O. Pour un lab : lié. Pour de la production : complet.

## 5.2 — Cloner et personnaliser

```bash
# Clone complet, VMID 201
qm clone "$TPL_ID" 201 \
  --name web01 \
  --full \
  --storage "$STORAGE" \
  --description "Serveur web — TP7"

# Ce qui est propre à CETTE VM
qm set 201 \
  --ipconfig0 ip=192.168.1.201/24,gw=192.168.1.1 \
  --cores 2 --memory 2048

qm start 201
```

⚠️ **Adaptez `192.168.1.201/24` et la passerelle à votre réseau.** Le sous-réseau doit être
celui de `vmbr0` — sinon la VM démarre mais reste injoignable.

Pour connaître le réseau de `vmbr0` :

```bash
ip -4 addr show vmbr0        # ex. inet 192.168.1.10/24
ip route show default        # ex. default via 192.168.1.1 dev vmbr0
```

💡 **Le nom d'hôte est déduit du nom de la VM** (`--name web01` → `hostname web01`). Pas
besoin de le fixer séparément.

## 5.3 — ✅ Le test qui prouve que ça marche

```bash
# 1. La VM tourne
qm status 201                                  # -> status: running

# 2. Suivre le premier boot sur la console série (Ctrl-O pour quitter)
qm terminal 201

# 3. L'agent invité répond -> cloud-init est allé au bout
qm agent 201 ping && echo "agent OK"

# 4. Proxmox voit l'IP configurée par cloud-init
qm guest cmd 201 network-get-interfaces | grep -A2 ip-address

# 5. La connexion SSH par clé fonctionne, sans mot de passe
ssh formation@192.168.1.201 'hostname; whoami; ip -br -4 a; free -h; df -h /'
```

Dans la VM, l'audit de cloud-init :

```bash
cloud-init status --long           # -> status: done
cloud-init schema --system         # valide la configuration reçue
sudo cloud-init query ds           # la datasource utilisée -> NoCloud
lsblk                             # ✅ la racine occupe bien 20 Go (growpart a fait son travail)
sudo journalctl -u cloud-init --no-pager | tail -30
```

✅ **Trois preuves à obtenir :** `cloud-init status` = `done`, l'utilisateur `formation`
existe avec sa clé, et `df -h /` montre ~20 Go et non 3.

## 5.4 — Le vrai bénéfice : cloner en série

```bash
for i in 1 2 3; do
  VMID=$((210 + i))
  qm clone "$TPL_ID" "$VMID" --name "node0$i" --full --storage "$STORAGE"
  qm set "$VMID" --ipconfig0 "ip=192.168.1.$VMID/24,gw=192.168.1.1"
  qm start "$VMID"
done

qm list
```

🏋️ **Chronométrez-le** (`time` devant la boucle) et comparez à trois installations
manuelles depuis l'ISO Debian. C'est tout l'intérêt du TP.

---

# 🧪 Partie 6 — Aller plus loin avec cloud-init

## 6.1 — Injecter un `user-data` complet (`--cicustom`)

Les champs `--ciuser` / `--sshkeys` couvrent 80 % des besoins. Pour le reste (paquets,
fichiers, commandes, plusieurs utilisateurs), on fournit **son propre YAML** via un *snippet*.

**Étape 1 — autoriser les snippets sur le stockage `local` :**

```bash
pvesm set local --content iso,vztmpl,backup,snippets
mkdir -p /var/lib/vz/snippets
```

**Étape 2 — écrire le fichier** (un exemple complet est fourni :
[`user-data-exemple.yaml`](user-data-exemple.yaml)) :

```bash
cp user-data-exemple.yaml /var/lib/vz/snippets/user-web01.yaml
```

**Étape 3 — le rattacher à la VM :**

```bash
qm set 201 --cicustom "user=local:snippets/user-web01.yaml"

# ✅ Vérifier ce qui sera réellement injecté
qm cloudinit dump 201 user
```

⚠️ **`user=` remplace *entièrement* le `user-data` généré par Proxmox.** `--ciuser`,
`--cipassword` et `--sshkeys` sont **ignorés** : votre YAML doit redéclarer l'utilisateur
et les clés, sinon la VM démarre sans aucun accès.

💡 Les autres clés de `--cicustom` sont plus sûres car complémentaires :
`network=` (remplace `network-config`), `meta=` (remplace `meta-data`) et surtout
`vendor=` — **qui s'ajoute** au `user-data` de Proxmox au lieu de l'écraser. Pour ajouter
des paquets tout en gardant les champs de l'interface, `vendor=` est le bon choix.

## 6.2 — Rejouer cloud-init sur une VM existante

```bash
qm set 201 --ipconfig0 ip=192.168.1.231/24,gw=192.168.1.1
qm cloudinit update 201        # régénère l'ISO cloud-init
qm reboot 201
```

⚠️ **Tout n'est pas rejouable.** Cloud-init distingue trois étapes selon la fréquence :

| Module | Fréquence | Rejoué au reboot ? |
|---|---|---|
| Réseau (`network-config`) | à chaque boot | ✅ Oui |
| Création d'utilisateurs, clés SSH | `once-per-instance` | ❌ Non |
| `runcmd`, `packages` | `once-per-instance` | ❌ Non |

Pour forcer un rejeu complet **dans la VM** (à réserver au débogage) :

```bash
sudo cloud-init clean --logs --reboot
```

## 6.3 — Automatiser la création du template

Tout ce que vous venez de faire à la main tient dans un script fourni :
[`build-template.sh`](build-template.sh).

```bash
# Lire AVANT d'exécuter en root (réflexe du TP5)
less build-template.sh

./build-template.sh --help
./build-template.sh --vmid 9001 --name debian13-tpl-v2
```

🏋️ **Exercices**

1. **Deux gabarits** — produisez un template `debian13-small` (1 vCPU / 1 Go) et un
   `debian13-large` (4 vCPU / 8 Go). Que partagent-ils ? Que faudrait-il factoriser ?
2. **Nginx sans intervention** — écrivez un `user-data` qui installe nginx et écrit un
   `index.html` contenant le nom d'hôte. Clonez, et vérifiez avec `curl` depuis l'hôte
   *sans jamais vous connecter en SSH*.
3. **Réseau `vmbr0` en VLAN** — ajoutez `--net0 virtio,bridge=vmbr0,tag=42`. Que faut-il
   activer sur `vmbr0` côté Proxmox (`/etc/network/interfaces`) pour que ça fonctionne ?
4. **Deuxième disque de données** — `qm set 201 --scsi1 local-lvm:10` puis faites formater
   et monter `/dev/sdb` par cloud-init (`disk_setup`, `fs_setup`, `mounts`).
5. **Sauvegarde du template** — un template se sauvegarde-t-il avec `vzdump` ? Testez, et
   mesurez la taille obtenue.
6. **Cluster** — un template est-il visible depuis les autres nœuds ? De quoi cela dépend-il ?

---

# 🧂 Partie 7 — Un template déjà sous SaltStack

Un clone qui démarre avec son utilisateur, sa clé SSH et son IP, c'est bien. Un clone qui,
en plus, **s'enregistre tout seul auprès du master Salt et applique son socle de
configuration**, c'est la chaîne complète : `qm clone` → machine conforme, sans une seule
connexion SSH.

> 💡 Cette partie suppose un `salt-master` déjà en place, joignable depuis le réseau des VM.
> Sa mise en œuvre et les states utilisés ici sont couverts par le TP
> [**Saltstack**](../TP3-Installation/Saltstack.md).

## 7.1 — Dans l'image ou dans le `user-data` ?

Deux endroits possibles pour installer le minion :

| Approche | Avantages | Inconvénients |
|---|---|---|
| `packages:` / `runcmd:` dans le **`user-data`** | Rien à reconstruire, modifiable par clone | Dépend d'Internet **à chaque** boot, rallonge le premier démarrage, échoue en réseau fermé |
| **`virt-customize`** dans l'image | Une seule fois, boot rapide, fonctionne hors ligne | Il faut refaire le template pour changer de version |

On choisit l'image : c'est exactement l'argument déjà retenu pour `qemu-guest-agent` en
partie 2.1 — un paquet dont **toutes** les VM ont besoin n'a rien à faire dans un
`user-data`.

## 7.2 — Préparer les fichiers à injecter

Tout ce qui doit atterrir dans l'image est d'abord assemblé sur le nœud Proxmox.

```bash
SALT_MASTER="192.168.1.10"      # ⚠️ l'IP ou le FQDN de VOTRE master
mkdir -p /root/salt-image
cd /root/salt-image
```

**1. Le dépôt Salt** (les paquets ne sont pas dans les dépôts Debian) :

```bash
curl -fsSL https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public \
  -o salt-archive-keyring.pgp

curl -fsSL https://github.com/saltstack/salt-install-guide/releases/latest/download/salt.sources \
  -o salt.sources

# Épinglage : un minion ne doit JAMAIS être plus récent que son master
cat > salt-pin-1001 <<'EOF'
Package: salt-*
Pin: version 3007.*
Pin-Priority: 1001
EOF
```

**2. La configuration du minion** :

```bash
cat > minion-tpl.conf <<EOF
master: $SALT_MASTER
startup_states: highstate
EOF
```

| Directive | Effet |
|---|---|
| `master:` | Qui contacter. Sans elle, le minion cherche l'hôte nommé `salt` — pratique si vous avez cet enregistrement DNS |
| `startup_states: highstate` | Le minion **applique le `top.sls` dès son démarrage**. C'est ce qui rend le clone conforme sans aucune action manuelle |

⚠️ **Aucun `id:` ici.** L'ID serait alors identique sur tous les clones. On laisse le minion
le déduire du nom d'hôte que cloud-init vient de poser.

**3. L'ordonnancement du service** — le point le plus subtil de cette partie :

```bash
mkdir -p dropin
cat > dropin/99-after-cloud-init.conf <<'EOF'
[Unit]
After=cloud-final.service
EOF
```

⚠️ **Pourquoi ce drop-in ?** Le minion fige son identité dans `/etc/salt/minion_id` **au
premier démarrage**. S'il démarre avant que cloud-init ait appliqué le nom d'hôte, il
s'enregistre sous le nom générique de l'image — et **tous vos clones s'appellent `debian`**.
Attendre `cloud-final.service` garantit que le hostname définitif est en place.

## 7.3 — Injecter le tout

```bash
export LIBGUESTFS_BACKEND=direct
cd "$IMG_DIR"
cp -f "$IMG" "custom-$IMG"

virt-customize -a "custom-$IMG" \
  --mkdir /etc/apt/keyrings \
  --copy-in /root/salt-image/salt-archive-keyring.pgp:/etc/apt/keyrings \
  --copy-in /root/salt-image/salt.sources:/etc/apt/sources.list.d \
  --copy-in /root/salt-image/salt-pin-1001:/etc/apt/preferences.d \
  --run-command 'apt-get update' \
  --install qemu-guest-agent,salt-minion,git,htop,vim,curl \
  --mkdir /etc/salt/minion.d \
  --copy-in /root/salt-image/minion-tpl.conf:/etc/salt/minion.d \
  --mkdir /etc/systemd/system/salt-minion.service.d \
  --copy-in /root/salt-image/dropin/99-after-cloud-init.conf:/etc/systemd/system/salt-minion.service.d \
  --run-command 'systemctl enable qemu-guest-agent salt-minion' \
  --delete '/etc/salt/pki/minion/*' \
  --delete /etc/salt/minion_id \
  --run-command 'apt-get clean' \
  --timezone Pacific/Noumea \
  --truncate /etc/machine-id
```

> 💡 **L'ordre de la ligne de commande est l'ordre d'exécution.** C'est ce qui permet de
> déposer le dépôt *avant* le `--install`, et la configuration *après*.

Les options utiles au-delà de celles vues en partie 2.2 :

| Option | Rôle |
|---|---|
| `--mkdir DIR` | `mkdir -p` dans l'image — obligatoire : `--copy-in` exige un répertoire **existant** |
| `--copy-in LOCAL:DIR_DISTANT` | Copie un fichier de l'hôte vers l'image |
| `--write FICHIER:CONTENU` | Écrit un fichier court. ⚠️ N'interprète pas `\n` : pour du multi-ligne, `--copy-in` |
| `--delete CHEMIN` | Supprime (accepte les jokers, à protéger par des quotes) |
| `--firstboot-command 'CMD'` | Commande jouée au tout premier démarrage seulement |

## 7.4 — Les trois pièges à connaître

| Piège | Conséquence | Parade appliquée ci-dessus |
|---|---|---|
| Le minion a **démarré** dans l'image | `/etc/salt/pki/minion/minion.pem` est figé : tous les clones partagent la **même clé** et se volent leur identité sur le master | `--install` ne démarre rien ; `--delete '/etc/salt/pki/minion/*'` par sécurité |
| `/etc/salt/minion_id` présent | Tous les clones s'enregistrent sous le même nom | `--delete /etc/salt/minion_id` + drop-in `After=cloud-final.service` |
| Minion **plus récent** que le master | Combinaison non supportée, erreurs incompréhensibles | Fichier de *pin* `salt-*` posé dans l'image |

## 7.5 — Vérifier avant même de créer la VM

Inutile de démarrer quoi que ce soit : on inspecte le disque.

```bash
virt-cat -a "custom-$IMG" /etc/salt/minion.d/minion-tpl.conf   # -> master: 192.168.1.10
virt-ls  -a "custom-$IMG" /etc/salt                            # ✅ PAS de minion_id
virt-ls  -a "custom-$IMG" /etc/salt/pki/minion                 # ✅ vide
virt-ls  -a "custom-$IMG" /etc/systemd/system/multi-user.target.wants | grep salt
```

Reprenez ensuite les parties 3 à 4 à l'identique (`qm create`, import, cloud-init,
`qm template`) : rien ne change côté Proxmox.

## 7.6 — Le clone s'enregistre tout seul

```bash
qm clone 9000 220 --name salt-web01 --full --storage local-lvm
qm set 220 --ipconfig0 ip=192.168.1.220/24,gw=192.168.1.1
qm start 220
```

**Sur le master**, sans avoir touché à la VM :

```bash
watch salt-key -L          # ✅ « salt-web01 » apparaît dans les clés en attente
salt-key -a salt-web01 -y
salt 'salt-web01' test.ping
salt 'salt-web01' grains.item id fqdn os
```

Grâce à `startup_states: highstate`, le socle s'est déjà appliqué au démarrage du minion —
mais **après** l'acceptation de la clé seulement. Pour un enregistrement 100 % automatique,
le master sait valider seul un minion qui présente un grain attendu :

```yaml
# /etc/salt/master.d/autosign.conf  (SUR LE MASTER)
autosign_grains_dir: /etc/salt/autosign_grains
```

```bash
mkdir -p /etc/salt/autosign_grains
echo "proxmox-tpl-9000" > /etc/salt/autosign_grains/deployment
systemctl restart salt-master
```

…et côté image, un grain `deployment: proxmox-tpl-9000` (via `--copy-in` d'un
`/etc/salt/grains`) plus `autosign_grains: [deployment]` dans la conf du minion.

> ⚠️ **L'auto-signature est un compromis de sécurité.** Toute machine capable de deviner la
> valeur du grain entre dans votre parc et reçoit vos states — donc vos secrets de pillar.
> Réservez-la à un réseau d'administration fermé, et préférez un grain à valeur aléatoire
> plutôt qu'un nom devinable.

🏋️ **Exercices**

1. **Bout en bout** — posez un grain `role: webserver` via un snippet cloud-init
   (`write_files:` vers `/etc/salt/grains`), clonez, et vérifiez avec `curl` que nginx sert
   la bonne page **sans jamais vous être connecté à la VM**.
2. **Sans Internet** — coupez la sortie WAN de la VM clonée. Le minion démarre-t-il quand
   même ? Comparez avec ce qu'aurait donné une installation par `packages:` cloud-init.
3. **Retrait propre** — détruisez le clone, puis `salt-key -L`. Que reste-t-il sur le
   master, et quelle commande nettoie l'orphelin ?

---

## 🧹 Nettoyage

```bash
# ⚠️ Détruit les VM ET leurs disques, sans confirmation
for VMID in 201 211 212 213 220; do
  qm stop "$VMID" 2>/dev/null
  qm destroy "$VMID" --purge --destroy-unreferenced-disks 1
done

# Le template (échoue si des clones LIÉS existent encore — c'est voulu)
qm destroy "$TPL_ID" --purge

# Les images téléchargées
rm -f "$IMG_DIR"/debian-13-genericcloud-amd64.qcow2 \
      "$IMG_DIR"/custom-debian-13-genericcloud-amd64.qcow2 \
      "$IMG_DIR"/SHA512SUMS*

# Partie 7 : les clés des minions détruits restent sur le MASTER
salt-key -d salt-web01 -y
```

`--purge` retire aussi la VM des tâches de sauvegarde et des règles de réplication —
sans lui, vous laissez des références mortes derrière vous.

---

## 🆘 Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| Console web noire, pas de log de boot | `serial0` absent, ou `--vga` non réglé sur `serial0` | `qm set VMID --serial0 socket --vga serial0` |
| VM démarre mais aucun utilisateur, aucune IP | Image **`nocloud`** au lieu de `genericcloud` | Retélécharger la bonne variante et refaire le template |
| `no bootdisk` / boot sur le réseau | Ordre de boot non fixé après l'import | `qm set VMID --boot order=scsi0` |
| SSH : `Permission denied (publickey)` | Fichier de clé absent ou mal lu par `--sshkeys` | `qm cloudinit dump VMID user` doit montrer votre clé ; sinon `qm set VMID --sshkeys /root/.ssh/id_ed25519.pub` |
| SSH par mot de passe refusé | Auth par mot de passe désactivée dans l'image cloud | `grep -r PasswordAuthentication /etc/ssh/sshd_config.d/` — ou (mieux) utiliser une clé |
| Le disque fait toujours 3 Go dans la VM | `qm resize` fait **après** le démarrage | `qm resize`, puis reboot ; ou dans la VM : `growpart /dev/sda 1 && resize2fs /dev/sda1` |
| L'interface n'affiche pas l'IP | `qemu-guest-agent` absent ou `--agent` non activé | Étape 2.2 (`virt-customize`) + `qm set VMID --agent enabled=1` |
| Deux clones avec la **même IP** en DHCP | `/etc/machine-id` identique | `--truncate /etc/machine-id` dans `virt-customize`, refaire le template |
| `qm clone` : `linked clone feature is not supported` | Stockage sans snapshots (LVM *thick*, iSCSI) | Ajouter `--full` |
| `qm destroy` du template refusé | Des clones **liés** en dépendent | Les convertir en clones complets (`Full Clone` dans l'interface) ou les détruire |
| `virt-customize` : `libguestfs: error: ... appliance` | Noyau PVE non lisible par libguestfs | `export LIBGUESTFS_BACKEND=direct` |
| `cloud-init status` → `error` | YAML invalide dans le snippet | Dans la VM : `cloud-init schema --system` puis `journalctl -u cloud-init` |
| Modification `--ci*` sans effet après reboot | Module en `once-per-instance` | `qm cloudinit update VMID` ; si besoin `cloud-init clean --reboot` dans la VM |
| `TASK ERROR: storage 'local' does not support content type 'snippets'` | Type de contenu non activé | `pvesm set local --content iso,vztmpl,backup,snippets` |
| `virt-customize` : `copy-in: target directory ... does not exist` | `--copy-in` ne crée pas le répertoire de destination | Le précéder d'un `--mkdir` (partie 7.3) |
| Tous les clones apparaissent sous le **même** nom dans `salt-key -L` | `/etc/salt/minion_id` figé dans l'image, ou minion démarré avant cloud-init | `--delete /etc/salt/minion_id` + drop-in `After=cloud-final.service` (partie 7.2) |
| Un clone « vole » l'identité d'un autre sur le master | Clé privée du minion présente dans l'image | `--delete '/etc/salt/pki/minion/*'`, refaire le template |
| Le minion ne joint pas le master | `master:` absent (le minion cherche l'hôte `salt`), ou ports 4505/4506 filtrés | `virt-cat -a IMG /etc/salt/minion.d/minion-tpl.conf` ; dans la VM : `salt-call -l debug test.ping` |

---

## 📌 Ce qu'il faut retenir

1. **`genericcloud`**, pas `generic`, pas `nocloud`.
2. Une image téléchargée se **vérifie** : empreinte **et** signature.
3. `--serial0 socket --vga serial0` : sinon vous déboguez à l'aveugle.
4. `--truncate /etc/machine-id` : sinon vos clones se battent pour la même IP.
5. `qm template` est **irréversible** — versionnez vos templates (`9000`, `9001`, …).
6. Sur `local-lvm`, `discard=on` est ce qui rend réellement l'espace au LVM-thin.
7. `--cicustom user=` **écrase** le `user-data` de Proxmox ; `vendor=` s'y **ajoute**.
8. Un template est du code : le [script](build-template.sh) le prouve mieux qu'un clic.
9. Un paquet dont **toutes** les VM ont besoin va dans l'image, pas dans le `user-data`.
10. Une image contenant un `salt-minion` ne doit embarquer **ni clé** (`/etc/salt/pki/minion/`)
    **ni identité** (`/etc/salt/minion_id`) : ce sont les deux seules choses qui doivent rester
    propres à chaque clone.
