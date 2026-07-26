# 🔗 Ressources & antisèches

Documentation, tutoriels et aide-mémoire pour accompagner les TP.

---

## 📚 Documentation de référence

| Ressource | Lien |
|---|---|
| 📕 Debian Administrator's Handbook (fr) | <https://debian-handbook.info/browse/fr-FR/stable/> |
| 📗 Wiki Debian | <https://wiki.debian.org/fr/FrontPage> |
| 📘 Notes de publication Debian 13 « Trixie » | <https://www.debian.org/releases/trixie/releasenotes> |
| 📙 The Linux Documentation Project | <https://tldp.org/> |
| 🔍 explainshell — décortique une ligne de commande | <https://explainshell.com/> |
| ⚠️ ShellCheck — analyse statique de scripts shell | <https://www.shellcheck.net/> |

---

## 💾 TP1 — Stockage

| Ressource | Lien |
|---|---|
| Wiki Debian — RAID logiciel | <https://wiki.debian.org/fr/SoftwareRAID> |
| Cheatsheet mdadm | <https://www.digitalocean.com/community/tutorials/how-to-manage-raid-arrays-with-mdadm-on-ubuntu-16-04> |
| Wiki Debian — LVM | <https://wiki.debian.org/LVM> |
| Documentation BTRFS officielle | <https://btrfs.readthedocs.io/> |
| BTRFS — statut des fonctionnalités ⚠️ (à lire avant la production) | <https://btrfs.readthedocs.io/en/latest/Status.html> |

---

## 🧩 TP2 — Noyau

| Ressource | Lien |
|---|---|
| The Linux Kernel Module Programming Guide | <https://sysprog21.github.io/lkmpg/> |
| Documentation du noyau — Kbuild modules | <https://docs.kernel.org/kbuild/modules.html> |
| Documentation du noyau — pilotes de périphériques caractère | <https://docs.kernel.org/driver-api/basics.html> |
| Paramètres de module (`module_param`) | <https://docs.kernel.org/admin-guide/kernel-parameters.html> |
| Signature de modules & Secure Boot | <https://wiki.debian.org/SecureBoot> |
| Manuel `modprobe` / `depmod` | <https://manpages.debian.org/stable/kmod/modprobe.8.en.html> |

---

## 📦 TP3 — debootstrap & chroot

| Ressource | Lien |
|---|---|
| Wiki Debian — Debootstrap | <https://wiki.debian.org/Debootstrap> |
| `man debootstrap` | <https://manpages.debian.org/stable/debootstrap/debootstrap.8.en.html> |
| systemd-nspawn (le chroot moderne) | <https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html> |

---

## 🔎 TP4 — Analyse & diagnostic

| Ressource | Lien |
|---|---|
| Brendan Gregg — Linux Performance (la référence) | <https://www.brendangregg.com/linuxperf.html> |
| Méthode USE (Utilization, Saturation, Errors) | <https://www.brendangregg.com/usemethod.html> |
| htop expliqué | <https://peteris.rocks/blog/htop/> |
| Antisèche journalctl | <https://www.loggly.com/ultimate-guide/using-journalctl/> |
| `ss` remplace `netstat` | <https://www.redhat.com/sysadmin/ss-command> |
| Documentation UFW | <https://help.ubuntu.com/community/UFW> |

---

## 📊 TP5 — Supervision & sauvegarde

| Ressource | Lien |
|---|---|
| Documentation Netdata | <https://learn.netdata.cloud/> |
| Manuel Monit | <https://mmonit.com/monit/documentation/monit.html> |
| Monit — exemples de configuration | <https://mmonit.com/wiki/Monit/ConfigurationExamples> |
| Documentation rsnapshot | <https://rsnapshot.org/rsnapshot.html> |
| Documentation restic | <https://restic.readthedocs.io/> |
| La règle de sauvegarde 3-2-1 | <https://www.backblaze.com/blog/the-3-2-1-backup-strategy/> |

---

## 🖥️ TP6 — Terminal & environnement graphique

| Ressource | Lien |
|---|---|
| 🧵 Antisèche tmux | <https://tmuxcheatsheet.com/> |
| 🧵 Antisèche GNU screen | <https://gist.github.com/jctosta/af918e1618682638aa82> |
| 🪟 Guide de l'utilisateur i3wm | <https://i3wm.org/docs/userguide.html> |
| 🐚 Thèmes oh-my-zsh | <https://github.com/ohmyzsh/ohmyzsh/wiki/Themes> |
| 🐚 Greffons oh-my-zsh | <https://github.com/ohmyzsh/ohmyzsh/wiki/Plugins> |
| 🔍 fzf | <https://github.com/junegunn/fzf> |
| ✍️ Vim Adventures (apprendre vim en jouant) | <https://vim-adventures.com/> |
| ✍️ Antisèche vim | <https://vim.rtorr.com/lang/fr> |
| 📖 Pages tldr | <https://tldr.inbrowser.app/> |

---

## 🧱 TP7 — Proxmox & cloud-init

| Ressource | Lien |
|---|---|
| Documentation Proxmox VE (admin guide) | <https://pve.proxmox.com/pve-docs/pve-admin-guide.html> |
| Proxmox — Cloud-Init Support | <https://pve.proxmox.com/wiki/Cloud-Init_Support> |
| Proxmox — Cloud-Init FAQ | <https://pve.proxmox.com/wiki/Cloud-Init_FAQ> |
| Manuel `qm` (gestion des VM en CLI) | <https://pve.proxmox.com/pve-docs/qm.1.html> |
| Manuel `pvesm` (stockages) | <https://pve.proxmox.com/pve-docs/pvesm.1.html> |
| Images cloud officielles Debian | <https://cloud.debian.org/images/cloud/> |
| Debian Cloud — équipe & vérification des images | <https://wiki.debian.org/Teams/Cloud> |
| Documentation cloud-init | <https://cloudinit.readthedocs.io/> |
| cloud-init — référence des modules `#cloud-config` | <https://cloudinit.readthedocs.io/en/latest/reference/modules.html> |
| cloud-init — exemples de configuration | <https://cloudinit.readthedocs.io/en/latest/reference/examples.html> |
| `virt-customize` (libguestfs) | <https://libguestfs.org/virt-customize.1.html> |
| LVM-thin dans Proxmox | <https://pve.proxmox.com/wiki/Storage:_LVM_Thin> |
| Réseau Proxmox (bridges, VLAN) | <https://pve.proxmox.com/wiki/Network_Configuration> |

---

## 🛠️ Divers

| Ressource | Lien |
|---|---|
| apt-cacher-ng — cache APT pour un parc | <https://www.blog-libre.org/2016/01/09/installation-et-configuration-de-apt-cacher-ng/> |
| Miroir Debian/Ubuntu local (Nouvelle-Calédonie) | <http://ubuntu.nautile.nc/> |
| crontab.guru — décoder une expression cron | <https://crontab.guru/> |
| Vérifier une configuration systemd | <https://www.freedesktop.org/software/systemd/man/systemd.service.html> |

---

## 🪦 Liens historiques (hors service)

Conservés parce qu'ils apparaissent encore dans beaucoup de tutoriels :

| Lien mort | Remplacement |
|---|---|
| `carlchenet.com/htop-explique-luptime/` — page supprimée | [htop expliqué](https://peteris.rocks/blog/htop/) |
| `btrfs-tools` — paquet renommé depuis Debian 9 | `btrfs-progs` |
| `apt-key` — retiré d'APT | Une clé par dépôt dans `/etc/apt/keyrings/` + option `signed-by` |
