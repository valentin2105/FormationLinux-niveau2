# 🧩 TP2 — Modules du noyau Linux

## 🎯 Objectif

1. Écrire, compiler et charger un **module noyau minimal** (`Hello World` côté kernel)
2. Aller plus loin avec un **périphérique caractère** exposé dans `/dev`, que l'on interroge
   depuis l'espace utilisateur

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
> refusera de charger un module non signé :
> `insmod: ERROR: could not insert module: Key was rejected by service`.
> Vérifiez l'état avec `mokutil --sb-state`. Pour ce TP, désactivez Secure Boot dans le
> firmware de la VM.

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

### 🧪 À expérimenter

```bash
make clean && make
```

- Modifiez le message dans `lkm1.c`, recompilez, rechargez. Le nouveau texte apparaît-il ?
- Que se passe-t-il si vous faites deux `insmod lkm1.ko` d'affilée ?
- Et si vous faites `rmmod` sur un module qui n'est pas chargé ?
- Renommez `lkm1.ko` en `autre.ko` et chargez-le : sous quel nom apparaît-il dans `lsmod` ?

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

⚠️ **Retirez toujours le `mknod` AVANT le `rmmod`.** Décharger un module dont le périphérique
est encore ouvert est le meilleur moyen de provoquer un *kernel oops*.

### 🏋️ Exercice — corriger un défaut du module

`file_ops` ne définit pas `.owner = THIS_MODULE`. Le module compense avec `try_module_get()`
dans `device_open()`, ce qui est la façon fragile de faire : le compteur de références n'est
tenu à jour que si l'ouverture réussit.

Reproduisez le problème, puis corrigez-le :

```bash
# 1. Chargez le module et ouvrez le périphérique en continu
insmod lkm2.ko
MAJOR=$(awk '/lkm_example/ {print $1}' /proc/devices)
mknod /dev/lkm2 c "$MAJOR" 0
cat /dev/lkm2 > /dev/null &

# 2. Observez le compteur de références
lsmod | grep lkm2

# 3. Nettoyez proprement
kill %1 ; rm /dev/lkm2 ; rmmod lkm2
```

Ajoutez `.owner = THIS_MODULE,` dans la structure `file_ops`, retirez les appels à
`try_module_get()` / `module_put()`, recompilez et vérifiez que le comportement de `lsmod`
est identique — c'est désormais le VFS qui tient le compteur pour vous.

---

## 3️⃣ 🏋️ Pour aller plus loin

### Paramètres de module

Un module peut recevoir des options au chargement. Ajoutez dans `lkm1.c` :

```c
#include <linux/moduleparam.h>

static char *nom = "monde";
module_param(nom, charp, 0644);
MODULE_PARM_DESC(nom, "Nom a saluer");
```

Puis utilisez `nom` dans le `printk`, recompilez et testez :

```bash
insmod lkm1.ko nom="Formation"
dmesg | tail -1
cat /sys/module/lkm1/parameters/nom     # le paramètre est lisible à chaud
rmmod lkm1
```

### Installer le module dans le système

Jusqu'ici on chargeait un fichier local. Pour que `modprobe` le trouve :

```bash
mkdir -p /lib/modules/$(uname -r)/extra
cp lkm1.ko /lib/modules/$(uname -r)/extra/
depmod -a

modprobe lkm1                # plus besoin du chemin
lsmod | grep lkm1
modprobe -r lkm1

# Chargement automatique au démarrage
echo lkm1 > /etc/modules-load.d/lkm1.conf
```

### Explorer les modules du système

```bash
lsmod | head -20                        # les modules chargés, triés par usage
modinfo ext4 | head                     # métadonnées d'un vrai module
systool -vm ext4                        # nécessite sysfsutils
cat /proc/modules                       # la source brute de lsmod
ls /sys/module/                         # chaque module expose ses paramètres ici
```

### Voir ce que fait un module au chargement

```bash
dmesg -C
modprobe -v loop                        # -v montre les dépendances résolues
dmesg
modprobe -r loop
```

---

## ✅ Récapitulatif des commandes

| Commande | Usage |
|---|---|
| `insmod fichier.ko` / `rmmod nom` | Charger / décharger un module par fichier |
| `modprobe nom` / `modprobe -r nom` | Idem par nom, avec résolution des dépendances |
| `depmod -a` | Recalculer la table des dépendances de modules |
| `lsmod` | Modules chargés et leur compteur de références |
| `modinfo nom` | Métadonnées, paramètres, `vermagic` |
| `dmesg` / `journalctl -k` | Journal du noyau |
| `mknod /dev/x c MAJ MIN` | Créer un fichier de périphérique caractère |
| `/proc/devices` | Numéros majeurs enregistrés |
| `/sys/module/` | Paramètres et état des modules chargés |

---

## 🆘 Dépannage

| Erreur | Cause | Solution |
|---|---|---|
| `make: *** /lib/modules/.../build: Aucun fichier` | En-têtes absents ou décalés du noyau courant | `apt install linux-headers-$(uname -r)`, puis rebooter si le noyau vient d'être mis à jour |
| `Key was rejected by service` | Secure Boot actif | Le désactiver dans le firmware de la VM |
| `Invalid module format` | Module compilé pour un autre noyau | `modinfo ./x.ko` → comparer `vermagic` avec `uname -r`, puis recompiler |
| `File exists` au `insmod` | Le module est déjà chargé | `rmmod` d'abord, ou `lsmod \| grep lkm` pour vérifier |
| `Module lkm2 is in use` | Un `cat /dev/lkm2` tourne encore | Fermer le processus, `rm /dev/lkm2`, puis `rmmod` |
| `mknod: opération non permise` | Pas root | `sudo -i` |
| `cat /dev/lkm2` ne renvoie rien | Mauvais numéro majeur | Le relire dans `/proc/devices`, recréer le nœud |
