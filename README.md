# 🐧 Formation Linux — Niveau 2

> Travaux pratiques d'administration système Linux avancée, orientés **Debian 13 « Trixie »** (noyau 6.12 LTS).

Cette formation part du principe que les bases (navigation shell, `apt`, permissions, éditeur de texte, SSH)
sont acquises. On attaque ici le stockage, le noyau, la construction de systèmes, le diagnostic,
la supervision et l'environnement de travail.

---

## 🎯 Ce que vous allez apprendre

À l'issue de la formation, vous saurez :

- 💾 Construire un stockage résilient : RAID logiciel, LVM, systèmes de fichiers modernes
- 🧩 Écrire, compiler et charger un module du noyau, et exposer un périphérique dans `/dev`
- 📦 Créer un système Linux minimaliste from scratch avec `debootstrap` et l'isoler en `chroot`
- 🔎 Diagnostiquer méthodiquement une panne (logs, ressources, services, réseau, firewall, droits)
- 📊 Superviser un serveur et mettre en place une stratégie de sauvegarde incrémentale et chiffrée
- 🖥️ Monter un environnement de travail graphique et un shell productif
- 🧱 Industrialiser le déploiement de VM sur Proxmox : image cloud, template, clones cloud-init

---

## 🧰 Prérequis

### Machine de TP

| Élément | Recommandation |
|---|---|
| OS | Debian 13 « Trixie » (netinstall, **sans** environnement de bureau) |
| Type | VM (VirtualBox / VMware / Proxmox / libvirt) — les TP sont destructifs |
| CPU / RAM | 2 vCPU / 2 Go minimum (4 Go confortable) |
| Disque système | 20 Go |
| **Disques supplémentaires** | **2 disques de 2 Go** (`/dev/sdb`, `/dev/sdc`) — requis par le TP1 |
| Réseau | Une IP joignable depuis votre poste (bridge ou NAT + port forwarding) |
| Accès | Compte utilisateur avec `sudo`, accès SSH |

> ⚠️ **Faites un snapshot de la VM avant chaque TP.** Plusieurs TP cassent volontairement le
> système (TP4) ou détruisent des disques (TP1). Le snapshot est votre bouton « annuler ».

### Connaissances attendues

- Se déplacer et manipuler des fichiers en ligne de commande
- Comprendre les permissions Unix (`chmod`, `chown`, utilisateur / groupe / autres)
- Installer un paquet avec `apt`, lire un fichier de configuration
- Utiliser `vim` ou `nano` (un `vimtutor` en français est fourni dans le TP6)

---

## 🗺️ Parcours des TP

| # | TP | Thème | Durée | Difficulté |
|---|---|---|---|---|
| 1 | [**TP1-FS**](TP1-FS/) 💾 | RAID 1 logiciel (`mdadm`), LVM, BTRFS, simulation de panne disque | ~2 h | ⭐⭐ |
| 2 | [**TP2-Kernel**](TP2-Kernel/) 🧩 | Modules noyau en C, périphérique caractère dans `/dev`, paramètres de module | ~2 h | ⭐⭐⭐⭐ |
| 3 | [**TP3-Installation**](TP3-Installation/) 📦 | `debootstrap`, `chroot`, exécuter un service dans un système invité | ~1 h 30 | ⭐⭐ |
| 4 | [**TP4-Analyse**](TP4-Analyse/) 🔎 | Diagnostic de panne : le système est cassé, à vous de le réparer | ~2 h | ⭐⭐⭐ |
| 5 | [**TP5-Supervision**](TP5-Supervision/) 📊 | Netdata, Monit, sauvegardes `rsnapshot` et `restic` | ~2 h | ⭐⭐ |
| 6 | [**TP6-TerminalX11**](TP6-TerminalX11/) 🖥️ | X11, i3wm, tmux, zsh, fzf — l'environnement de l'admin sys | ~1 h 30 | ⭐ |
| 7 | [**TP7-Proxmox**](TP7-Proxmox/) 🧱 | Image cloud Debian 13, template Proxmox, clones cloud-init (user / SSH / IP) | ~2 h | ⭐⭐⭐ |

**Ordre conseillé : 1 → 2 → 3 → 4 → 5 → 6 → 7.**
Le TP5 réutilise le volume RAID du TP1, et le TP4 doit être joué sur un système encore sain.
Le TP6 est indépendant : vous pouvez le jouer à n'importe quel moment.

> ⚠️ **Le TP7 est le seul à ne pas se jouer sur la VM de TP** : il s'exécute en `root` **sur
> l'hyperviseur Proxmox** (PVE 8 ou 9), avec le bridge `vmbr0` et le stockage `local-lvm`.
> Il est indépendant des TP 1 à 6.

---

## 📁 Structure du dépôt

```
FormationLinux-niveau2/
├── README.md                  # Ce fichier
├── POST_INSTALL.md            # ⚙️  Configuration post-installation de Debian
├── RESSOURCES.md              # 🔗 Liens, antisèches et documentation externe
│
├── TP1-FS/                    # 💾 RAID + LVM + BTRFS
├── TP2-Kernel/                # 🧩 Modules noyau
│   ├── Module1/               #    « Hello World » noyau
│   └── Module2/               #    Périphérique caractère /dev
├── TP3-Installation/          # 📦 debootstrap + chroot
├── TP4-Analyse/               # 🔎 Diagnostic
│   └── install.sh             #    Script qui « casse » le système
├── TP5-Supervision/           # 📊 Monitoring + backup
├── TP6-TerminalX11/           # 🖥️  Bureau et shell
│   ├── crazy-shell.sh         #    Installation zsh + oh-my-zsh + fzf
│   └── vimtutor.fr            #    Tutoriel vim en français
└── TP7-Proxmox/               # 🧱 Template Proxmox + cloud-init
    ├── build-template.sh      #    Création automatisée du template
    └── user-data-exemple.yaml #    user-data cloud-init commenté
```

---

## 🚀 Démarrage

```bash
# 1. Récupérer le dépôt sur la machine de TP
sudo apt update && sudo apt install -y git
git clone <URL_DU_DEPOT> ~/FormationLinux-niveau2
cd ~/FormationLinux-niveau2

# 2. Appliquer la configuration post-installation
less POST_INSTALL.md

# 3. Passer root pour la durée du TP (la plupart des commandes en ont besoin)
sudo -i
```

---

## 📖 Conventions de lecture

| Symbole | Signification |
|---|---|
| 🎯 | Objectif de l'exercice |
| 📋 | Prérequis / étape préparatoire |
| ✅ | Point de vérification — ne passez pas à la suite si ça échoue |
| 💡 | Explication ou astuce |
| ⚠️ | Opération destructive ou piège classique |
| 🏋️ | À vous de jouer — exercice sans corrigé |

Les blocs de commandes sont **à exécuter en root** sauf mention contraire.
Les valeurs à adapter à votre machine sont en `MAJUSCULES`.

---

## 🔗 Ressources

Antisèches et documentation externe : [**RESSOURCES.md**](RESSOURCES.md).
</content>
