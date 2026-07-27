# 🖥️ TP6 — Environnement graphique & terminal de l'admin sys

## 🎯 Objectif

Transformer un serveur Debian en poste de travail efficace :

1. 🪟 Un environnement graphique **léger** : X11 + i3, un *tiling window manager* piloté au clavier
2. 🧵 Le multiplexeur de terminal **tmux** : garder ses sessions vivantes malgré les coupures SSH
3. 🐚 Un shell productif : **zsh + oh-my-zsh + fzf + autosuggestions**
4. ✍️ Maîtriser **vim** (tutoriel en français fourni)

💡 **Pourquoi i3 et pas GNOME ?** i3 consomme ~50 Mo de RAM contre ~1 Go, se pilote entièrement
au clavier, et organise les fenêtres automatiquement. Sur un serveur ou une VM, c'est le rapport
confort/ressources imbattable.

---

## 📋 Prérequis

- Debian 13, session **root** pour les installations
- ⚠️ Accès **console** à la VM (l'affichage graphique ne passe pas par SSH)
- ~1 Go d'espace disque

---

## 1️⃣ 🪟 Environnement graphique X11 + i3

```bash
apt update
apt install -y xorg i3 suckless-tools xterm thunar lightdm dbus-x11 \
               fonts-dejavu feh network-manager-gnome
```

| Paquet | Rôle |
|---|---|
| `xorg` | Le serveur d'affichage X11 |
| `i3` | Le gestionnaire de fenêtres en pavage |
| `suckless-tools` | `dmenu` : le lanceur d'applications (`Mod+d`) |
| `xterm` | Émulateur de terminal minimal, toujours disponible |
| `thunar` | Gestionnaire de fichiers graphique léger |
| `lightdm` | Gestionnaire de connexion graphique |
| `dbus-x11` | Bus de messages, requis par beaucoup d'applications |
| `feh` | Fond d'écran |

> 💡 L'installateur demande de choisir le *display manager* : sélectionnez **lightdm**.

```bash
systemctl enable lightdm
reboot
```

Au premier lancement d'i3, un assistant propose de générer `~/.config/i3/config` et de choisir
la **touche Mod** : `Win` (recommandé) ou `Alt`.

### ⌨️ Les raccourcis i3 à connaître

| Raccourci | Action |
|---|---|
| `Mod + Entrée` | Ouvrir un terminal |
| `Mod + d` | Lanceur d'applications (dmenu) |
| `Mod + ⇧ + q` | Fermer la fenêtre |
| `Mod + ← ↑ ↓ →` (ou `h j k l`) | Naviguer entre les fenêtres |
| `Mod + ⇧ + ← ↑ ↓ →` | Déplacer la fenêtre |
| `Mod + h` / `Mod + v` | Prochaine division : horizontale / verticale |
| `Mod + f` | Plein écran |
| `Mod + 1..9` | Changer d'espace de travail |
| `Mod + ⇧ + 1..9` | Envoyer la fenêtre vers un espace de travail |
| `Mod + r` | Mode redimensionnement (`Échap` pour sortir) |
| `Mod + ⇧ + c` | Recharger la configuration |
| `Mod + ⇧ + e` | Quitter i3 |

🏋️ Personnalisez `~/.config/i3/config` : couleurs, fond d'écran avec `feh`, barre `i3status`.

---

## 2️⃣ 🐚 Shell productif : le script `crazy-shell.sh`

📄 Script fourni : [`crazy-shell.sh`](crazy-shell.sh)

Il installe zsh, oh-my-zsh, fzf, les autosuggestions, tmux, vim, git et ccze.

> ⚠️ **À exécuter en tant qu'utilisateur normal, PAS en root** — il écrit dans `~/.zshrc`,
> `~/.fzf` et `~/.oh-my-zsh`. Lancé en root, vous configurerez le shell de root.

```bash
cd ~/FormationLinux-niveau2/TP6-TerminalX11/
less crazy-shell.sh          # 💡 on lit toujours un script avant de l'exécuter
bash crazy-shell.sh
```

> 🐛 **Ce script a deux défauts.** À vous de les corriger :
> 1. Il appelle `google-chrome`, qui n'est **pas installé** → `command not found`. Ouvrez plutôt
>    <https://github.com/ohmyzsh/ohmyzsh/wiki/Themes> depuis votre navigateur habituel.
> 2. Il lance `zsh` **avant** `chsh`. Comme `zsh` ouvre un shell interactif, le `chsh` n'est
>    exécuté qu'après avoir tapé `exit`. Inversez les deux lignes.

### Installation manuelle équivalente

```bash
sudo apt install -y zsh tmux git vim ccze curl fzf

# oh-my-zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Suggestions à la frappe (à partir de l'historique)
git clone https://github.com/zsh-users/zsh-autosuggestions \
    ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions

# Coloration syntaxique de la ligne de commande
git clone https://github.com/zsh-users/zsh-syntax-highlighting \
    ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
```

Dans `~/.zshrc` :

```zsh
ZSH_THEME="agnoster"        # ou robbyrussell, powerlevel10k…
plugins=(git sudo systemd debian zsh-autosuggestions zsh-syntax-highlighting)

source /usr/share/doc/fzf/examples/key-bindings.zsh
source /usr/share/doc/fzf/examples/completion.zsh
```

```bash
# Faire de zsh le shell par défaut (prend effet à la prochaine connexion)
chsh -s "$(which zsh)"

# ✅ Vérification
echo $SHELL
grep "^$USER" /etc/passwd
```

### 🔍 fzf — le raccourci qui change tout

| Raccourci | Effet |
|---|---|
| `Ctrl + R` | Recherche floue dans l'historique — **le plus utile de tous** |
| `Ctrl + T` | Insérer un chemin de fichier |
| `Alt + C` | Se déplacer dans un dossier |
| `commande **` puis `Tab` | Complétion floue |

---

## 3️⃣ 🧵 tmux — le multiplexeur de terminal

💡 **Le problème qu'il résout :** votre SSH tombe pendant un `apt dist-upgrade` de 20 minutes,
et le processus meurt avec la session. Avec tmux, la session vit **sur le serveur** : vous vous
reconnectez et vous la retrouvez intacte.

```bash
tmux new -s formation        # créer une session nommée
# ... travaillez ...
# Ctrl+b puis d              -> se détacher (le travail continue)

exit                         # fermez même le SSH

# Reconnectez-vous, puis :
tmux ls                      # lister les sessions
tmux attach -t formation     # ✅ tout est là
```

Le préfixe est `Ctrl + b`, à taper **avant** chaque commande :

| Raccourci | Action |
|---|---|
| `Ctrl+b` `d` | Se détacher |
| `Ctrl+b` `c` | Nouvelle fenêtre |
| `Ctrl+b` `n` / `p` | Fenêtre suivante / précédente |
| `Ctrl+b` `0..9` | Aller à la fenêtre N |
| `Ctrl+b` `%` | Diviser verticalement |
| `Ctrl+b` `"` | Diviser horizontalement |
| `Ctrl+b` `← ↑ ↓ →` | Naviguer entre les panneaux |
| `Ctrl+b` `z` | Zoomer/dézoomer le panneau |
| `Ctrl+b` `[` | Mode défilement (`q` pour sortir) |
| `Ctrl+b` `,` | Renommer la fenêtre |
| `Ctrl+b` `?` | Aide |

Configuration recommandée dans `~/.tmux.conf` :

```tmux
set -g mouse on                 # molette et sélection à la souris
set -g history-limit 10000      # historique de défilement
set -g base-index 1             # fenêtres numérotées à partir de 1
setw -g mode-keys vi            # navigation vim en mode copie
```

🏋️ **Exercice :** lancez `htop` dans tmux, détachez-vous, coupez votre SSH, reconnectez-vous
et retrouvez `htop` en cours d'exécution.

---

## 4️⃣ ✍️ vim

📄 Tutoriel complet en français fourni : [`vimtutor.fr`](vimtutor.fr) (1040 lignes, 7 leçons)

```bash
# Version interactive (recommandée) : une copie de travail modifiable
cp vimtutor.fr /tmp/vimtutor && vim /tmp/vimtutor

# Ou le vimtutor système
apt install -y vim
vimtutor fr
```

### Le minimum vital

| Mode | Entrée | Sortie |
|---|---|---|
| Normal | `Échap` | — |
| Insertion | `i` `a` `o` `I` `A` `O` | `Échap` |
| Visuel | `v` `V` `Ctrl+v` | `Échap` |
| Commande | `:` | `Entrée` / `Échap` |

| Commande | Action |
|---|---|
| `:w` / `:q` / `:wq` / `:q!` | Écrire / quitter / écrire+quitter / quitter sans sauver |
| `dd` `yy` `p` | Couper / copier / coller une ligne |
| `u` / `Ctrl+r` | Annuler / rétablir |
| `/motif` puis `n` `N` | Rechercher, occurrence suivante / précédente |
| `:%s/vieux/neuf/g` | Remplacer partout |
| `gg` / `G` / `:42` | Début / fin / ligne 42 |
| `:set number` | Numéros de ligne |

> 💡 **Le réflexe qui sauve :** perdu ? `Échap` `Échap` `:q!` `Entrée` quitte sans rien enregistrer.
> Et sur un serveur inconnu, `vi` est **toujours** là — pas `nano`.

---

## 🧰 Autres outils du quotidien

```bash
sudo apt install -y htop ncdu tree jq ripgrep bat fd-find ccze mtr-tiny iftop tldr
```

| Outil | Usage |
|---|---|
| `htop` | Moniteur de processus interactif |
| `ncdu` | Trouver ce qui remplit le disque, en navigation |
| `tree` | Arborescence de dossiers |
| `jq` | Manipuler du JSON en ligne de commande |
| `rg` (ripgrep) | `grep` moderne, bien plus rapide |
| `batcat` | `cat` avec coloration syntaxique |
| `fdfind` | `find` simplifié |
| `ccze` | Colorise les logs : `journalctl -f \| ccze` (⚠️ pas `/var/log/syslog` : absent sans `rsyslog` depuis Debian 12) |
| `mtr` | `traceroute` + `ping` en continu |
| `iftop` | Bande passante par connexion |
| `tldr` | Exemples concrets au lieu des pages `man` |

---

## ✅ Validation du TP

```bash
echo $SHELL                     # /usr/bin/zsh
tmux ls                         # au moins une session
which fzf i3 vim tmux
systemctl is-enabled lightdm    # enabled
```

Et en console graphique : ouvrir un terminal avec `Mod+Entrée`, lancer `tmux`, le diviser en
deux panneaux, et éditer un fichier dans vim.

---

## 🆘 Dépannage

| Problème | Solution |
|---|---|
| Écran noir après `reboot` | `systemctl status lightdm`, `journalctl -b -u lightdm` ; en secours `Ctrl+Alt+F2` pour une console texte |
| `chsh` sans effet | Le changement s'applique **à la prochaine connexion**. Vérifier avec `grep "^$USER" /etc/passwd` |
| Caractères bizarres dans le thème zsh | Le thème `agnoster` exige une *Nerd Font*. Installer `fonts-powerline` ou changer de thème |
| tmux : couleurs cassées | `export TERM=xterm-256color` dans `~/.zshrc` |
| Pas de réseau en session graphique | `sudo apt install network-manager-gnome` puis lancer `nm-applet` |
| Clavier en QWERTY sous X11 | `sudo dpkg-reconfigure keyboard-configuration` puis redémarrer |
