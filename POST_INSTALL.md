# ⚙️ Post-installation Debian 13

Configuration minimale à appliquer sur une Debian 13 fraîchement installée, **avant** de
commencer les TP.

---

## 👤 1. Donner les droits `sudo` à l'utilisateur

Sur une installation Debian netinstall, si vous avez défini un mot de passe root, votre
utilisateur n'est **pas** dans le groupe `sudo`.

```bash
# En root (su -)
/sbin/usermod -aG sudo VOTRE_UTILISATEUR
```

⚠️ Le changement de groupe ne prend effet qu'à la **prochaine connexion**.

```bash
# ✅ Vérification, après reconnexion
id
groups
sudo -v
```

> 💡 Autre symptôme classique du même problème : la commande `su` fonctionne mais `sudo`
> répond « *n'est pas dans le fichier sudoers* ».

---

## 🛣️ 2. `/sbin` absent du `PATH`

Debian ne met pas `/sbin` et `/usr/sbin` dans le `PATH` d'un utilisateur non-root. D'où les
`command not found` sur `ifconfig`, `fdisk`, `usermod`, `mdadm`…

```bash
# Dans ~/.bashrc (ou ~/.zshrc)
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
```

```bash
source ~/.bashrc
echo $PATH
```

---

## 🌍 3. Locales

Une locale mal configurée provoque l'avertissement classique
`perl: warning: Setting locale failed` à chaque `apt install`.

```bash
# En root — décommenter les locales voulues, ex. en_US.UTF-8 et fr_FR.UTF-8
dpkg-reconfigure locales
```

> 💡 `locale-gen en_US.UTF-8` seul ne suffit **pas** : la locale doit d'abord être décommentée
> dans `/etc/locale.gen`. `dpkg-reconfigure locales` fait les deux via son interface.

Sans interface, en ligne de commande :

```bash
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^# *\(fr_FR.UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
```

Dans `~/.bashrc` de l'utilisateur :

```bash
export LANGUAGE=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

```bash
# ✅ Vérification
locale
```

⚠️ Ne définissez `LC_ALL` que si vous savez pourquoi : il écrase **toutes** les autres
variables de locale, y compris celles transmises par SSH.

---

## 🕐 4. Fuseau horaire et heure

```bash
timedatectl set-timezone Pacific/Noumea
timedatectl                       # ✅ vérifier NTP synchronized: yes
```

---

## 📦 5. Paquets de base pour les TP

```bash
apt update && apt upgrade -y
apt install -y \
    sudo curl wget git vim htop tree less \
    ca-certificates gnupg lsb-release \
    net-tools iproute2 dnsutils \
    build-essential
```

---

## 🔐 6. Durcissement SSH minimal

```bash
# /etc/ssh/sshd_config.d/99-formation.conf
cat > /etc/ssh/sshd_config.d/99-formation.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication yes
EOF

sshd -t                           # ✅ valider la syntaxe AVANT de recharger
systemctl reload ssh
```

⚠️ **Gardez votre session SSH actuelle ouverte** et testez la reconnexion dans un **second**
terminal avant de fermer la première. C'est la règle d'or de toute modification SSH à distance.

> 💡 Debian 13 lit les fichiers de `/etc/ssh/sshd_config.d/` : on y dépose ses réglages plutôt
> que d'éditer `sshd_config`, qui sera écrasé lors des mises à jour.

---

## 🌐 7. Réseau

```bash
ip -br a                          # adresses IP
ip route                          # passerelle par défaut
cat /etc/resolv.conf              # DNS
ping -c3 deb.debian.org           # ✅ connectivité + résolution
```

Configuration statique dans `/etc/network/interfaces` :

```
auto ens18
iface ens18 inet static
    address 192.168.1.50/24
    gateway 192.168.1.1
    dns-nameservers 1.1.1.1 8.8.8.8
```

```bash
systemctl restart networking
```

---

## ✅ Contrôle final

```bash
sudo -v && echo "sudo OK"
echo $PATH | grep -q /sbin && echo "PATH OK"
locale | grep -q UTF-8 && echo "locale OK"
timedatectl | grep -q "synchronized: yes" && echo "NTP OK"
ping -c1 -W2 deb.debian.org >/dev/null && echo "reseau OK"
```

📸 **Prenez un snapshot de la VM maintenant.** C'est votre point de retour propre pour tous les TP.
