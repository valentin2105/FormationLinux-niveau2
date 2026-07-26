# 🔎 TP4 — Analyse et diagnostic de panne

## 🎯 Objectif

Un script va **casser volontairement** votre serveur de plusieurs façons différentes.
À vous de le réparer, **sans lire le script**, en appliquant une méthode de diagnostic.

> 🏁 **Critère de réussite :** depuis **votre poste** (pas depuis le serveur),
> `curl http://IP_DU_SERVEUR/` doit renvoyer :
>
> ```
> Mon application de Formation.
> ```
>
> Et la charge CPU du serveur doit être revenue à la normale.

---

## 📋 Prérequis

- Debian 13 **sain** (jouez ce TP avant de bricoler le système)
- ⚠️ **Snapshot obligatoire** de la VM — c'est votre seule voie de retour
- L'IP du serveur joignable depuis votre poste, et un accès SSH **déjà ouvert et testé**

⚠️ **Testez votre accès SSH avant de lancer le script.** Il manipule le pare-feu. Si vous êtes
enfermé dehors, il vous faudra la console de la VM (hyperviseur) pour reprendre la main.

---

## 🚀 Lancer la panne

```bash
cd ~/FormationLinux-niveau2/TP4-Analyse/
sudo bash install.sh
```

Le script installe et configure plusieurs services, puis introduit **cinq problèmes distincts**
de natures différentes : configuration, permissions, réseau, gestion de service et ressources.

> 🚫 **Ne lisez pas `install.sh`.** Tout l'intérêt du TP est de diagnostiquer à l'aveugle,
> comme face à un vrai incident. Un corrigé replié est disponible en fin de page.

---

## 🧭 Méthode de diagnostic

Face à un incident, on ne tape pas des commandes au hasard. On descend la pile, couche par couche,
en validant chaque niveau avant de passer au suivant.

```
   [ Votre poste ]
         │  ❶ Le réseau passe-t-il ? (ping, route)
         ▼
   [ Pare-feu ]
         │  ❷ Le port est-il autorisé ? (ufw, nftables)
         ▼
   [ Écoute TCP ]
         │  ❸ Un processus écoute-t-il sur ce port, sur la bonne interface ?
         ▼
   [ Service ]
         │  ❹ Est-il démarré ? activé au boot ? que disent ses logs ?
         ▼
   [ Configuration ]
         │  ❺ Sert-il le bon fichier, depuis le bon dossier ?
         ▼
   [ Fichiers ]
         │  ❻ Existent-ils ? l'utilisateur du service peut-il les lire ?
         ▼
   [ Ressources ]
            ❼ CPU / RAM / disque / inodes suffisants ?
```

**Règle d'or : une hypothèse → une commande qui la valide ou l'invalide → on note le résultat.**

---

## 🧰 La boîte à outils

### ❶ Réseau

```bash
ip -br a                       # Interfaces et adresses IP (vue compacte)
ip route                       # Passerelle par défaut
ping -c3 IP_DU_SERVEUR         # Depuis votre poste
```

### ❷ Pare-feu

```bash
ufw status verbose             # Règles UFW et politique par défaut
nft list ruleset               # Règles netfilter brutes (Debian 13)
```

### ❸ Ports en écoute

```bash
ss -tlnp                       # TCP / Listen / Numérique / Processus  ← LA commande
ss -tlnp | grep -E ':80|:81'
```

💡 Lisez bien la colonne « Local Address » : `0.0.0.0:80` écoute sur **toutes** les interfaces,
`127.0.0.1:80` **uniquement en local** — un piège classique.

### ❹ Services systemd

```bash
systemctl status SERVICE            # État courant + 10 dernières lignes de log
systemctl is-active SERVICE         # Tourne-t-il maintenant ?
systemctl is-enabled SERVICE        # Démarrera-t-il au prochain boot ?  ← souvent oublié
systemctl list-units --failed       # Tout ce qui a échoué
```

⚠️ `is-active` et `is-enabled` répondent à **deux questions différentes**. Un service peut très
bien tourner aujourd'hui et ne jamais revenir après un redémarrage.

### ❺ Journaux

```bash
journalctl -u SERVICE -n 50 --no-pager    # Log d'un service
journalctl -p err -b                      # Toutes les erreurs depuis le boot
journalctl -f                             # Suivi en direct
tail -f /var/log/nginx/error.log          # Log applicatif nginx ← très parlant ici
tail -f /var/log/apache2/error.log
```

### ❻ Fichiers et permissions

```bash
ls -l /var/www/html/                # Droits, propriétaire, groupe
namei -l /var/www/html/index.html   # Droits de TOUT le chemin, dossier par dossier
id www-data                         # Sous quelle identité tourne le serveur web ?

# Le test décisif : le serveur peut-il vraiment lire ce fichier ?
sudo -u www-data cat /var/www/html/index.html
```

### ❼ Ressources

```bash
uptime                    # Load average : 1 / 5 / 15 minutes
htop                      # Vue interactive (apt install htop)
top -b -n1 | head -15
ps aux --sort=-%cpu | head -10     # Top 10 des dévoreurs de CPU
free -h                            # Mémoire
df -h && df -i                     # Disque ET inodes (un disque plein d'inodes ment)
```

💡 **Lire le `load average` :** il se compare au **nombre de cœurs**. `nproc` renvoie 2 ?
Alors un load de 2.00 = machine saturée à 100 %, et 4.00 = surchargée.

### 🔍 Inspection fine

```bash
nginx -T                             # Configuration nginx complète, includes résolus
apachectl -S                         # VirtualHosts Apache
lsof -i :80                          # Qui utilise le port 80
curl -v localhost                    # Voir les en-têtes et le code HTTP
curl -I localhost                    # En-têtes seuls
```

---

## 🗺️ Feuille de route suggérée

Progressez de l'extérieur vers l'intérieur, et **notez vos constats** :

1. Depuis votre poste : `curl -v http://IP/` → timeout ? refus ? code HTTP ? La nature de
   l'échec vous dit déjà à quelle couche chercher.
2. Sur le serveur : `curl -v localhost` → même résultat ou différent ? **Si ça marche en local
   mais pas à distance, le problème est réseau/pare-feu.**
3. `ss -tlnp` → qui écoute, sur quel port, sur quelle interface ?
4. `systemctl status` sur chaque service web trouvé. Puis `is-enabled`.
5. Les logs d'erreur applicatifs.
6. Les permissions du contenu servi (`sudo -u www-data cat ...`).
7. `uptime` + `ps aux --sort=-%cpu`.

🏋️ **Livrable :** rédigez un mini rapport d'incident — pour chaque problème trouvé,
la **commande** qui l'a révélé, le **symptôme**, la **cause** et le **correctif appliqué**.
C'est exactement ce qu'on attend d'un post-mortem en production.

---

## ✅ Vérification finale

```bash
# Sur le serveur
curl localhost                  # -> Mon application de Formation.
uptime                          # load average revenu proche de 0
systemctl is-enabled nginx      # enabled

# ⚠️ Le vrai test : depuis VOTRE POSTE
curl http://IP_DU_SERVEUR/      # -> Mon application de Formation.

# Et le test de résistance : après un redémarrage, ça marche toujours ?
sudo reboot
```

---

<details>
<summary>🔐 <b>Corrigé — à n'ouvrir qu'après avoir cherché</b></summary>

### Les cinq problèmes injectés

| # | Problème | Symptôme | Commande révélatrice |
|---|---|---|---|
| 1 | **UFW n'autorise que SSH** | Timeout depuis l'extérieur, OK en local | `ufw status verbose` |
| 2 | **Directive `index` de nginx amputée** — `index.html` retiré de la liste | Le mauvais contenu est servi | `nginx -T \| grep index` |
| 3 | **`index.html` en mode 400 (root uniquement)** | `403 Forbidden`, `Permission denied` dans le log | `ls -l /var/www/html/` puis `sudo -u www-data cat ...` |
| 4 | **Apache déplacé sur le port 81 et désactivé au boot** | Fausse piste / service absent après reboot | `ss -tlnp`, `systemctl is-enabled apache2` |
| 5 | **Deux processus `yes` saturent le CPU** | Load average élevé, machine lente | `ps aux --sort=-%cpu` |

### Correctifs

```bash
# 1 — Ouvrir le port 80
sudo ufw allow 80/tcp
sudo ufw status verbose

# 2 — Rétablir index.html en priorité
sudo sed -i 's/index index.nginx-debian.html;/index index.html index.htm index.nginx-debian.html;/' \
     /etc/nginx/sites-enabled/default
sudo nginx -t                       # TOUJOURS tester avant de recharger
sudo systemctl reload nginx

# 3 — Rendre le fichier lisible par www-data
sudo chmod 644 /var/www/html/index.html
sudo -u www-data cat /var/www/html/index.html    # doit fonctionner

# 4 — Réactiver Apache au démarrage (ou le désinstaller : il ne sert à rien ici)
sudo systemctl enable --now apache2
# Alternative propre : sudo systemctl disable --now apache2

# 5 — Tuer les processus parasites
sudo pkill -x yes
uptime                              # le load redescend en quelques minutes

# Persistance
sudo systemctl enable nginx
```

💡 **Les deux leçons à retenir :**
- « Ça marche en local » ne veut rien dire tant qu'on n'a pas testé **depuis l'extérieur**.
- Un correctif qui ne survit pas au redémarrage n'est pas un correctif (`systemctl enable`,
  `ufw` persistant, fichier de conf et non commande à chaud).

</details>

---

## 🆘 Dépannage

| Problème | Solution |
|---|---|
| Enfermé dehors, SSH ne répond plus | Console de la VM via l'hyperviseur, puis `ufw allow ssh` |
| Machine inutilisable tant le CPU est chargé | `pkill -x yes`, ou `renice 19 -p PID` |
| `nginx: [emerg]` au rechargement | `nginx -t` donne le fichier et la ligne exacte |
| Impossible de revenir en arrière | Restaurer le snapshot pris avant le TP |
