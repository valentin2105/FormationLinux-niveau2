# 🧩 TP2 — Modules du noyau Linux

## 🎯 Objectif

1. Écrire, compiler et charger un **module noyau minimal** (`Hello World` côté kernel)
2. Aller plus loin avec un **périphérique caractère** exposé dans `/dev`
3. Empaqueter un pilote réseau Intel en **paquet Debian `.deb` compilé par DKMS**

💡 **Un module noyau, c'est quoi ?** Du code qui s'exécute en *espace noyau* (ring 0), chargeable
et déchargeable à chaud, sans redémarrer. C'est ainsi que sont livrés les pilotes matériels,
les systèmes de fichiers, les modules réseau… Une erreur dans un module ne provoque pas un
segfault mais un **kernel panic** : on travaille en VM.

---

## 📋 Prérequis

- Debian 13 (noyau 6.12), session **root**
- Snapshot de la VM ⚠️ (un module bugué peut figer la machine)

```bash
apt update
apt install -y build-essential linux-headers-$(uname -r)

# Vérifier que les en-têtes correspondent bien au noyau qui tourne
uname -r
ls -d /lib/modules/$(uname -r)/build
```

> ⚠️ **Secure Boot.** Si votre machine démarre en UEFI avec Secure Boot **activé**, le noyau
> refusera de charger un module non signé : `insmod: ERROR: could not insert module: Key was
> rejected by service`. Vérifiez avec `mokutil --sb-state`. Pour ce TP, désactivez Secure Boot
> dans le firmware de la VM (ou signez les modules avec une clé MOK — hors périmètre).

---

## 1️⃣ Module 1 — « Hello World » noyau

📄 Sources : [`Module1/lkm1.c`](Module1/lkm1.c) et [`Module1/Makefile`](Module1/Makefile)

### Anatomie du code

```c
MODULE_LICENSE("GPL");        // Obligatoire : sans licence GPL, le noyau est "tainted"
MODULE_AUTHOR(...);           // Métadonnées visibles avec modinfo
MODULE_DESCRIPTION(...);      // ⚠️ Obligatoire depuis le noyau 6.11 (avertissement modpost)
MODULE_VERSION("0.01");

static int  __init lkm_example_init(void) { ... }   // Appelée au chargement (insmod)
static void __exit lkm_example_exit(void) { ... }   // Appelée au déchargement (rmmod)

module_init(lkm_example_init);
module_exit(lkm_example_exit);
```

| Élément | Rôle |
|---|---|
| `printk(KERN_INFO ...)` | L'équivalent noyau de `printf`. Pas de `stdout` en ring 0 : la sortie va dans le *ring buffer* du noyau, lisible avec `dmesg`. |
| `__init` | Indique au noyau qu'il peut libérer cette fonction de la mémoire après le chargement. |
| `__exit` | Code supprimé à la compilation si le module est intégré en statique. |
| `obj-m += lkm1.o` | Dit à Kbuild : « construis `lkm1.o` comme **m**odule ». |

### Compilation

```bash
cd TP2-Kernel/Module1
make
```

Le `Makefile` délègue à l'arbre de compilation du noyau installé :
`make -C /lib/modules/$(uname -r)/build M=$(PWD) modules`

✅ Vous devez obtenir **`lkm1.ko`** (`.ko` = *kernel object*) :

```bash
ls -alh
modinfo ./lkm1.ko          # métadonnées + vermagic (version de noyau ciblée)
```

### Chargement / déchargement

```bash
# On vide le buffer noyau pour y voir clair
dmesg -C

# Chargement
insmod lkm1.ko

# ✅ Vérifications
dmesg                      # -> "Hello, World! from the Linux Kernel"
lsmod | grep lkm           # le module apparaît, refcount à 0
ls /sys/module/lkm1/

# Déchargement
rmmod lkm1
dmesg                      # -> "Goodbye, World!"
lsmod | grep lkm           # plus rien
```

### 🧪 Expérimentez

```bash
make clean && make
# Modifiez le message dans lkm1.c, recompilez, rechargez.
# Que se passe-t-il si vous faites deux "insmod lkm1.ko" d'affilée ?
# Et si vous "rmmod" un module non chargé ?
```

> 💡 `insmod` charge **un fichier précis**. `modprobe` charge **un module par son nom** depuis
> `/lib/modules/...` et résout automatiquement les dépendances. En production, on utilise `modprobe`.

---

## 2️⃣ Module 2 — Un périphérique caractère

📄 Sources : [`Module2/lkm2.c`](Module2/lkm2.c) et [`Module2/Makefile`](Module2/Makefile)

Ce module enregistre un **character device** : un fichier spécial dans `/dev` que l'on peut
lire, et dont la lecture est servie par notre code noyau. C'est le mécanisme derrière
`/dev/null`, `/dev/random`, `/dev/ttyS0`…

### Ce que fait le code

```c
static struct file_operations file_ops = {
  .read    = device_read,      // appelée sur read()  / cat
  .write   = device_write,     // appelée sur write() -> renvoie -EINVAL (lecture seule)
  .open    = device_open,      // refuse un 2e ouvrant (-EBUSY)
  .release = device_release
};

major_num = register_chrdev(0, "lkm_example", &file_ops);  // 0 = "alloue-moi un majeur libre"
```

| Notion | Explication |
|---|---|
| **Numéro majeur** | Identifie le *pilote* auprès du noyau. `0` en argument = allocation dynamique, le numéro attribué est affiché dans `dmesg`. |
| **Numéro mineur** | Identifie l'*instance* du périphérique gérée par ce pilote. |
| `put_user()` | Copie un octet de l'espace noyau vers l'espace utilisateur. On ne peut **pas** déréférencer directement un pointeur utilisateur depuis le noyau. |

### Compilation et test

```bash
cd ../Module2
make

# La cible "test" vide dmesg, charge le module, et affiche le log
make test
```

✅ Relevez le **numéro majeur** dans la sortie :
`lkm_example module loaded with device major number 236`

### Créer le fichier de périphérique

```bash
# Remplacez NUM_MAJOR par la valeur relevée ci-dessus
mknod /dev/lkm2 c NUM_MAJOR 0
#            ^ c = character device (b = block device)

ls -l /dev/lkm2        # la colonne "taille" affiche "majeur, mineur"
```

Une alternative sans copier-coller manuel :

```bash
MAJOR=$(awk '/lkm_example/ {print $1}' /proc/devices)
mknod /dev/lkm2 c "$MAJOR" 0
```

### Utilisation

```bash
# ✅ Le noyau nous répond
cat /dev/lkm2                    # -> "Hello, World!" en boucle (Ctrl+C pour arrêter)
head -c 14 /dev/lkm2 ; echo

# Le périphérique est en lecture seule
echo "test" > /dev/lkm2          # -> "Invalid argument" (-EINVAL)
dmesg | tail -1                  # -> "This operation is not supported."

# Une seule ouverture simultanée (-EBUSY)
cat /dev/lkm2 &
cat /dev/lkm2                    # -> "Device or resource busy"
kill %1
```

### Nettoyage

```bash
rm /dev/lkm2
rmmod lkm2
dmesg | tail -2
```

> ⚠️ **Bug pédagogique à repérer :** `file_ops` ne définit pas `.owner = THIS_MODULE`. Le module
> compense avec `try_module_get()` dans `device_open()`, ce qui est la façon fragile de faire.
> Retirez le `mknod` **avant** le `rmmod` : décharger un module dont le périphérique est ouvert
> est le meilleur moyen de provoquer un *kernel oops*. Sauriez-vous corriger le module ?

---

## 3️⃣ Cas concret — Paquet DKMS pour le pilote Intel i40e

### Le problème

Vous déployez une carte réseau **Intel XXV710-DA2** dont le pilote `i40e` fourni par le noyau est
trop ancien (bug, fonctionnalité manquante). Intel publie un pilote *out-of-tree* à compiler
soi-même. Mais **à chaque mise à jour du noyau, il faut recompiler**.

### La solution : DKMS

**D**ynamic **K**ernel **M**odule **S**upport stocke les sources dans `/usr/src/<paquet>-<version>/`
et **recompile automatiquement** le module à chaque installation d'un nouveau noyau, via un hook APT.
On l'empaquette en `.deb` pour le déployer proprement sur un parc.

### Anatomie du paquet

📁 [`ModuleDKMS/debian/`](ModuleDKMS/debian/)

| Fichier | Rôle |
|---|---|
| `control` | Métadonnées du paquet : nom, mainteneur, **dépendances de construction** |
| `changelog` | Historique **et source de la version** du paquet (lue par `dpkg-buildpackage`) |
| `rules` | Le « Makefile » de la construction. `dh $@ --with dkms` active l'automatisation debhelper. |
| `i40e-dkms.dkms` | Le fichier `dkms.conf` : quel module construire, où l'installer, faut-il régénérer l'initramfs |

```bash
cat debian/control debian/rules debian/i40e-dkms.dkms
```

### 🚨 Adaptations obligatoires pour Debian 13

Ce paquet a été écrit à l'époque de Debian 10 « Buster ». **Trois choses ont changé** :

**a) L'extension debhelper DKMS a été sortie du paquet `dkms`**

Depuis DKMS 3.x, le greffon `dh --with dkms` vit dans un paquet séparé : **`dh-dkms`**.
Sans lui, la construction échoue immédiatement :

```
dh: error: unable to load addon dkms: Can't locate Debian/Debhelper/Sequence/dkms.pm in @INC
```

**b) Le niveau de compatibilité debhelper 9 est déprécié**

`dh: warning: Compatibility levels before 10 are deprecated (level 9 in use)`

**c) `debian/files` est un artefact de build** — il ne devrait pas être versionné, `dpkg` le régénère.

Appliquez donc :

```bash
cd TP2-Kernel/ModuleDKMS

# Corriger les dépendances de construction et le niveau de compat
sed -i 's/^Build-Depends:.*/Build-Depends: debhelper-compat (= 13), dh-dkms/' debian/control
rm -f debian/compat debian/files
```

### Construction

```bash
# Dépendances de construction (noter dh-dkms)
apt update && apt install -y build-essential fakeroot debhelper dkms dh-dkms

# Décompression des sources du pilote
tar -zxvf i40e-2.10.19.30.tar.gz

# La définition du paquet doit se trouver DANS le dossier des sources
cp -r debian/ i40e-2.10.19.30/
cd i40e-2.10.19.30/

# Construction (--no-sign : on ne signe pas avec une clé GPG)
dpkg-buildpackage --no-sign
```

✅ Le paquet est produit **dans le dossier parent** :

```bash
cd ..
ls -lh *.deb                        # -> i40e-dkms_2.4.6-0_all.deb
dpkg -c i40e-dkms_2.4.6-0_all.deb   # contenu : les sources dans /usr/src/i40e-2.4.6/
dpkg -I i40e-dkms_2.4.6-0_all.deb   # métadonnées
```

> 💡 **Incohérence à relever :** le `changelog` annonce la version `2.4.6` alors que l'archive
> contient le pilote `2.10.19.30`. C'est le `changelog` qui fait foi pour `dpkg` et pour
> `dh_dkms -V`. Corrigez-le avec `dch -v 2.10.19.30-1` pour un paquet honnête.

### Installation

```bash
dpkg -i i40e-dkms_2.4.6-0_all.deb

# ✅ Vérifications
dkms status                    # état de compilation par version de noyau
ls /usr/src/i40e-*/            # les sources déposées par le paquet
modinfo i40e                   # infos du pilote actuellement disponible
```

### ⚠️ Ce pilote ne compile PAS sur Debian 13 — et c'est l'exercice

À l'installation, DKMS tente la compilation contre le noyau 6.12 et **échoue** :

```
/usr/src/i40e-2.4.6/kcompat.h:2778:10: fatal error: linux/pci-aspm.h: No such file or directory
```

**Diagnostic à faire faire aux stagiaires :**

```bash
# Le journal de compilation DKMS dit tout
cat /var/lib/dkms/i40e/*/build/make.log
```

L'en-tête `linux/pci-aspm.h` a été **supprimé du noyau Linux en 5.5** (son contenu a été fusionné
dans `linux/pci.h`). Or la couche de compatibilité de cette version du pilote, `kcompat.h`, ne
gère les noyaux que **jusqu'à 5.4** :

```bash
grep -n 'KERNEL_VERSION(5,' i40e-2.10.19.30/src/kcompat.h | tail -5
# -> le test le plus récent est KERNEL_VERSION(5,4,0)
```

**Conclusion :** un pilote *out-of-tree* n'est utilisable **que sur la plage de noyaux prévue
par son éditeur**. C'est le principal coût caché de cette approche.

**Les trois issues possibles :**

| Option | Quand ? |
|---|---|
| Utiliser le pilote **in-tree** du noyau | Presque toujours le bon choix. Le noyau 6.12 embarque un `i40e` bien plus récent que 2.10 → `modinfo i40e` |
| Prendre une version **récente** du pilote Intel | Si vous avez besoin d'une fonctionnalité absente du noyau. Dernière version : [intel/ethernet-linux-i40e](https://github.com/intel/ethernet-linux-i40e/releases) (v2.30.x) |
| Rétroporter `kcompat.h` | À éviter : maintenance sans fin |

```bash
# Le pilote fourni par Debian 13, à comparer avec le nôtre
modinfo i40e | head -8
```

🏋️ **Exercice :** téléchargez la dernière version du pilote sur le dépôt Intel, remplacez
l'archive, adaptez le `changelog`, et refaites le paquet. Vérifiez que `dkms status`
affiche bien `installed` pour le noyau 6.12.

### Nettoyage

```bash
dpkg -r i40e-dkms
dkms status
```

---

## ✅ Récapitulatif des commandes

| Commande | Usage |
|---|---|
| `insmod fichier.ko` / `rmmod nom` | Charger / décharger un module par fichier |
| `modprobe nom` / `modprobe -r nom` | Idem par nom, avec résolution des dépendances |
| `lsmod` | Modules chargés et leur compteur de références |
| `modinfo nom` | Métadonnées, paramètres, `vermagic` |
| `dmesg` / `journalctl -k` | Journal du noyau |
| `dkms status` / `dkms build` / `dkms install` | Gestion des modules DKMS |
| `/proc/devices` | Numéros majeurs enregistrés |

## 🆘 Dépannage

| Erreur | Cause | Solution |
|---|---|---|
| `make: *** /lib/modules/.../build: Aucun fichier` | En-têtes absents ou décalés du noyau courant | `apt install linux-headers-$(uname -r)` puis rebooter si le noyau a été mis à jour |
| `Key was rejected by service` | Secure Boot actif | Le désactiver dans le firmware, ou signer le module |
| `Invalid module format` | Module compilé pour un autre noyau | `modinfo ./x.ko` → comparer `vermagic` avec `uname -r`, recompiler |
| `Module lkm2 is in use` | Un `cat /dev/lkm2` tourne encore | Fermer le processus, `rm /dev/lkm2`, puis `rmmod` |
| `unable to load addon dkms` | Paquet `dh-dkms` manquant | `apt install dh-dkms` |
| DKMS : `Bad return status for module build` | Pilote incompatible avec le noyau | Lire `/var/lib/dkms/<pkg>/<ver>/build/make.log` |
