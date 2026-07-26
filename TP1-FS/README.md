# 💾 TP1 — Systèmes de fichiers : RAID, LVM & BTRFS

## 🎯 Objectif

Construire une chaîne de stockage complète et résiliente :

```
2 disques physiques  →  RAID 1 (mdadm)  →  PV → VG → LV (LVM)  →  BTRFS  →  /mnt/lvbtrfs
   /dev/sdb1
   /dev/sdc1              /dev/md0          deb / lvbtrfs
```

Puis **simuler la panne d'un disque** et le remplacer à chaud, sans perdre de données.

💡 **Pourquoi empiler RAID + LVM ?** Le RAID apporte la *tolérance de panne* (un disque meurt, le
service continue). LVM apporte la *souplesse* (redimensionner, ajouter des volumes, faire des
snapshots sans repartitionner). Les deux sont complémentaires, pas concurrents.

---

## 📋 Prérequis

- Debian 13 avec **deux disques vierges supplémentaires** (`/dev/sdb` et `/dev/sdc`, 2 Go suffisent)
- Session **root**
- ⚠️ Un snapshot de la VM : ce TP détruit le contenu de `sdb` et `sdc`

```bash
apt update && apt install -y mdadm lvm2 btrfs-progs
```

> 💡 Sur Debian 13 le paquet des outils BTRFS s'appelle **`btrfs-progs`**
> (l'ancien nom `btrfs-tools` a disparu depuis Debian 9).

---

## 1️⃣ Reconnaître le matériel

Avant de toucher à quoi que ce soit, on regarde ce qu'on a.

```bash
# Vue d'ensemble arborescente : la commande à retenir
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

# Détail des tables de partitions
fdisk -l

# État des RAID logiciels déjà présents (doit être vide pour l'instant)
cat /proc/mdstat
```

✅ Vous devez voir `sdb` et `sdc` **sans** `FSTYPE` ni point de montage.

⚠️ **Vérifiez trois fois le nom des disques.** Se tromper et partitionner `/dev/sda`
(le disque système) détruit la machine. `lsblk` montre les points de montage : le disque
qui porte `/` est celui à ne PAS toucher.

---

## 2️⃣ Partitionner les disques en type « Linux RAID »

### Avec `fdisk` (interactif, disque 1)

```bash
fdisk /dev/sdb
```

Séquence de touches :

| Touche | Action |
|---|---|
| `n` | Nouvelle partition |
| `p` | Primaire |
| `1` | Numéro de partition |
| `Entrée` | Premier secteur (défaut) |
| `Entrée` | Dernier secteur (défaut = tout le disque) |
| `t` | Changer le type de partition |
| `fd` | Type `Linux raid autodetect` |
| `p` | Afficher pour vérifier |
| `w` | **Écrire** sur le disque et quitter |

> 💡 `q` quitte **sans** enregistrer — votre filet de sécurité tant que vous n'avez pas tapé `w`.

### Avec `cfdisk` (semi-graphique, disque 2)

```bash
cfdisk /dev/sdc
```

Même résultat, interface à base de menus : `New` → taille par défaut → `Type` → `Linux RAID` → `Write` → `Quit`.

✅ Vérification :

```bash
lsblk -o NAME,SIZE,FSTYPE,TYPE
# sdb1 et sdc1 doivent apparaître, de taille identique
```

---

## 3️⃣ Créer le RAID 1 (miroir)

```bash
mdadm --create /dev/md0 --level=mirror --raid-devices=2 /dev/sdb1 /dev/sdc1
```

> `mdadm` demande confirmation (`Continue creating array?`) → répondre `y`.

```bash
# Suivre la resynchronisation initiale (les deux disques se recopient)
cat /proc/mdstat
watch -n1 cat /proc/mdstat     # Ctrl+C pour quitter

# Détail complet de la grappe
mdadm --detail /dev/md0
```

✅ Attendez `State : clean` et `[UU]` dans `/proc/mdstat` (les deux `U` = les deux disques **U**p).

### 🔒 Rendre le RAID persistant au redémarrage

**Étape indispensable, souvent oubliée.** Sans elle, la grappe peut être réassemblée sous un
autre nom (`/dev/md127`) au prochain boot, et le montage `fstab` échouera.

```bash
# On enregistre la définition de la grappe
mdadm --detail --scan >> /etc/mdadm/mdadm.conf

# On vérifie ce qui a été écrit (une ligne ARRAY /dev/md0 ... UUID=...)
tail -n 3 /etc/mdadm/mdadm.conf

# On régénère l'initramfs pour que le noyau connaisse la grappe dès le démarrage
update-initramfs -u
```

---

## 4️⃣ Empiler LVM par-dessus le RAID

Trois couches à connaître :

| Couche | Sigle | Commande | Rôle |
|---|---|---|---|
| Physical Volume | **PV** | `pvcreate` | Déclare un disque/partition comme utilisable par LVM |
| Volume Group | **VG** | `vgcreate` | Regroupe des PV en un « pool » d'espace |
| Logical Volume | **LV** | `lvcreate` | Découpe le pool en volumes utilisables |

```bash
# PV : on offre notre grappe RAID à LVM
pvcreate /dev/md0
pvs                      # vue courte
pvdisplay                # vue détaillée

# VG : on crée un groupe nommé "deb"
vgcreate deb /dev/md0
vgs
vgdisplay

# LV : on taille un volume logique de 1 Go nommé "lvbtrfs"
lvcreate -L 1G deb -n lvbtrfs
lvs
lvdisplay
```

✅ Le volume est accessible via **deux chemins équivalents** (ce sont des liens symboliques
vers le même `/dev/dm-*`) :

```bash
ls -l /dev/deb/lvbtrfs /dev/mapper/deb-lvbtrfs
```

---

## 5️⃣ Formater en BTRFS et monter

```bash
# Formatage
mkfs.btrfs /dev/mapper/deb-lvbtrfs

# Point de montage
mkdir -p /mnt/lvbtrfs
```

Ajoutez la ligne suivante à `/etc/fstab` :

```fstab
/dev/deb/lvbtrfs   /mnt/lvbtrfs   btrfs   defaults,noatime   0   0
```

| Champ | Valeur | Pourquoi |
|---|---|---|
| Options | `noatime` | N'écrit pas la date d'accès à chaque lecture → moins d'I/O |
| Dump | `0` | Inutilisé aujourd'hui |
| Pass (fsck) | **`0`** | ⚠️ BTRFS n'a **pas** de `fsck` au boot : mettre `2` génère une erreur au démarrage |

> 💡 Les options `ssd`, `discard` et `autodefrag` que l'on croise souvent sur Internet :
> `ssd` est **détecté automatiquement**, `discard` est déconseillé au profit de `discard=async`,
> et `autodefrag` est contre-productif sur SSD. Sur une VM, `defaults,noatime` est le bon choix.

```bash
# Monter tout ce qui est déclaré dans fstab
mount -a

# ✅ Vérifications
df -h /mnt/lvbtrfs
findmnt /mnt/lvbtrfs
btrfs filesystem show
btrfs filesystem usage /mnt/lvbtrfs
```

⚠️ **Testez `mount -a` AVANT de redémarrer.** Une faute de frappe dans `fstab` peut empêcher
le système de démarrer. Si `mount -a` passe sans erreur, le boot passera aussi.

```bash
# On écrit un fichier témoin pour la suite du TP
echo "Fichier temoin TP1" > /mnt/lvbtrfs/temoin.txt
cat /mnt/lvbtrfs/temoin.txt
```

---

## 6️⃣ ⚠️ Simuler la panne d'un disque

C'est là que le RAID prouve son intérêt : on va « tuer » un disque et **le service doit continuer**.

```bash
# On détruit le début du disque sdc (table de partition + superblock RAID)
# Laissez tourner 3-4 secondes puis Ctrl+C
shred -v -n 1 -s 10M /dev/sdc

# On signale au RAID que le disque est défaillant
mdadm --manage /dev/md0 --fail /dev/sdc1

# 🔎 Observation
cat /proc/mdstat          # affiche [U_] : un seul disque actif
mdadm --detail /dev/md0   # State : clean, degraded
```

✅ **Le point clé du TP :** malgré le disque mort, le fichier témoin est toujours lisible.

```bash
cat /mnt/lvbtrfs/temoin.txt     # -> "Fichier temoin TP1"
df -h /mnt/lvbtrfs              # -> toujours monté
```

Les journaux le racontent aussi :

```bash
journalctl -k | grep -i md0
dmesg | tail -20
```

---

## 7️⃣ Remplacer le disque à chaud

```bash
# 1. On retire le disque défaillant de la grappe
mdadm --manage /dev/md0 --remove /dev/sdc1
cat /proc/mdstat

# 2. (Dans la vraie vie) on débranche le disque mort et on en branche un neuf.
#    En VM : supprimez le disque sdc dans les paramètres, ajoutez-en un vierge.
#    Pour ce TP on réutilise simplement sdc, désormais vide.

# 3. On recopie la table de partition du disque sain vers le neuf
sfdisk -d /dev/sdb | sfdisk --force /dev/sdc
lsblk -o NAME,SIZE,FSTYPE,TYPE      # sdc1 réapparaît

# 4. On réintègre le disque dans la grappe
mdadm --manage /dev/md0 --add /dev/sdc1

# 5. On regarde la reconstruction en direct
watch -n1 cat /proc/mdstat
```

✅ Vous devez voir la barre de progression `[===>.................]  recovery = 23.4%`,
puis à la fin `[UU]` et `State : clean`. La grappe est de nouveau redondante.

```bash
mdadm --detail /dev/md0
cat /mnt/lvbtrfs/temoin.txt     # les données n'ont jamais bougé
```

> 💡 Pensez à mettre à jour `/etc/mdadm/mdadm.conf` si l'UUID de la grappe a changé,
> puis `update-initramfs -u`.

---

## 🏋️ Pour aller plus loin

1. **Notification de panne** — configurez `MAILADDR` dans `/etc/mdadm/mdadm.conf` puis testez
   avec `mdadm --monitor --scan --test --oneshot`.
2. **Agrandir le volume à chaud** — BTRFS sait grandir sans démonter :
   ```bash
   lvextend -L +500M /dev/deb/lvbtrfs
   btrfs filesystem resize max /mnt/lvbtrfs
   df -h /mnt/lvbtrfs
   ```
3. **Snapshots BTRFS** — créez un sous-volume, un snapshot, supprimez des fichiers, restaurez :
   ```bash
   btrfs subvolume create /mnt/lvbtrfs/data
   btrfs subvolume snapshot -r /mnt/lvbtrfs/data /mnt/lvbtrfs/data-snap
   btrfs subvolume list /mnt/lvbtrfs
   ```
4. **Comparez** RAID 1 / RAID 5 / RAID 10 : combien de disques, quelle capacité utile,
   combien de pannes tolérées ?

---

## 🆘 Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `mdadm: Device or resource busy` | Le disque est déjà utilisé (montage, autre grappe) | `umount`, puis `mdadm --zero-superblock /dev/sdX1` |
| La grappe devient `/dev/md127` au reboot | `mdadm.conf` non renseigné | Refaire l'étape « persistance » puis `update-initramfs -u` |
| `mount -a` : `unknown filesystem type 'btrfs'` | `btrfs-progs` absent | `apt install btrfs-progs` |
| Boot bloqué en mode maintenance | Ligne `fstab` fautive | Se connecter en root, corriger `/etc/fstab`, `mount -a` pour valider |
| `lvcreate: Volume group "deb" not found` | Le PV n'a pas été créé sur `/dev/md0` | Reprendre à l'étape 4 |

## 🧹 Remise à zéro

```bash
umount /mnt/lvbtrfs
sed -i '\|/mnt/lvbtrfs|d' /etc/fstab
lvremove -f /dev/deb/lvbtrfs
vgremove -f deb
pvremove -f /dev/md0
mdadm --stop /dev/md0
mdadm --zero-superblock /dev/sdb1 /dev/sdc1
```
