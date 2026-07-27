#!/usr/bin/env bash
#
# TP Users — Mise en place complète de l'environnement du TP
#
#   groupes  : admin, developer
#   comptes  : alice (admin), bob (developer)
#   sudo     : %admin  -> privilèges complets
#              %developer -> systemctl / journalctl restreints (liste blanche)
#   partage  : /opt/appli-dev  root:developer  2775 + setgid + ACL
#
# À exécuter EN ROOT sur la VM de TP.
#
# Usage :
#   ./setup-users.sh              # met en place
#   ./setup-users.sh --check      # vérifie sans rien modifier
#   ./setup-users.sh --cleanup    # supprime tout ce que le script a créé
#   ./setup-users.sh --help
#
# ⚠️ Ce script est un FILET DE SÉCURITÉ, pas un raccourci : jouez d'abord le
#    README à la main. Il sert à repartir d'un état propre après une erreur.
#
set -euo pipefail

SHARE_DIR=/opt/appli-dev
SUDOERS_ADMIN=/etc/sudoers.d/10-admin
SUDOERS_DEV=/etc/sudoers.d/20-developer
UMASK_PROFILE=/etc/profile.d/umask-developer.sh

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
nok()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    # Réaffiche l'en-tête du script, sans les '#'
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------- #
# Vérification (--check)
# --------------------------------------------------------------------------- #
do_check() {
    local rc=0

    info "Groupes"
    for g in admin developer; do
        getent group "$g" >/dev/null && ok "groupe $g (gid $(getent group "$g" | cut -d: -f3))" \
            || { nok "groupe $g absent"; rc=1; }
    done

    info "Comptes et appartenances"
    for pair in alice:admin bob:developer; do
        u=${pair%%:*}; g=${pair##*:}
        if id "$u" >/dev/null 2>&1; then
            if id -nG "$u" | tr ' ' '\n' | grep -qx "$g"; then
                ok "$u -> $(id "$u")"
            else
                nok "$u existe mais n'est pas dans le groupe $g"; rc=1
            fi
            [[ -d "/home/$u" ]] && ok "  home /home/$u présent" \
                || { nok "  home /home/$u ABSENT (useradd sans -m ?)"; rc=1; }
        else
            nok "compte $u absent"; rc=1
        fi
    done

    info "Configuration sudo"
    for f in "$SUDOERS_ADMIN" "$SUDOERS_DEV"; do
        if [[ -f $f ]]; then
            perm=$(stat -c '%a %U:%G' "$f")
            [[ $perm == "440 root:root" ]] && ok "$f ($perm)" \
                || { nok "$f a les droits '$perm' au lieu de '440 root:root' → IGNORÉ par sudo"; rc=1; }
        else
            nok "$f absent"; rc=1
        fi
    done
    if visudo -c >/dev/null 2>&1; then
        ok "visudo -c : configuration valide"
    else
        nok "visudo -c : CONFIGURATION INVALIDE"; visudo -c; rc=1
    fi

    info "Droits effectifs"
    for u in alice bob; do
        id "$u" >/dev/null 2>&1 && printf '  %s :\n' "$u" && sudo -l -U "$u" 2>&1 | sed 's/^/    /'
    done

    info "Répertoire partagé"
    if [[ -d $SHARE_DIR ]]; then
        ok "$(stat -c '%n  %U:%G  %A  (%a)' "$SHARE_DIR")"
        [[ $(stat -c '%a' "$SHARE_DIR") == 2775 ]] && ok "  setgid actif (2775)" \
            || { nok "  droits $(stat -c '%a' "$SHARE_DIR") au lieu de 2775"; rc=1; }
        command -v getfacl >/dev/null && getfacl -p "$SHARE_DIR" 2>/dev/null | sed 's/^/    /'
    else
        nok "$SHARE_DIR absent"; rc=1
    fi

    info "umask"
    [[ -f $UMASK_PROFILE ]] && ok "$UMASK_PROFILE présent" || { nok "$UMASK_PROFILE absent"; rc=1; }
    id bob >/dev/null 2>&1 && printf '  umask de bob : %s\n' "$(su - bob -c 'umask')"

    echo
    [[ $rc -eq 0 ]] && ok "Tout est conforme." || nok "Des écarts subsistent (voir ci-dessus)."
    return $rc
}

# --------------------------------------------------------------------------- #
# Nettoyage (--cleanup)
# --------------------------------------------------------------------------- #
do_cleanup() {
    warn "Suppression des comptes alice et bob, de leurs homes, des règles sudo et de $SHARE_DIR"
    read -r -p "Confirmer ? (oui/non) " rep
    [[ $rep == oui ]] || die "Annulé."

    info "Règles sudo"
    rm -f "$SUDOERS_ADMIN" "$SUDOERS_DEV" "$UMASK_PROFILE"
    visudo -c >/dev/null && ok "sudoers toujours valide après suppression"

    info "Comptes"
    for u in alice bob; do
        if id "$u" >/dev/null 2>&1; then
            pkill -u "$u" 2>/dev/null || true
            loginctl terminate-user "$u" 2>/dev/null || true
            sleep 1
            userdel -r "$u" 2>/dev/null && ok "$u supprimé" || warn "échec de userdel $u"
        fi
    done

    info "Groupes"
    for g in admin developer; do
        getent group "$g" >/dev/null && groupdel "$g" && ok "$g supprimé"
    done

    info "Fichiers"
    rm -rf "$SHARE_DIR" /tmp/sans-setgid
    ok "$SHARE_DIR supprimé"

    info "Orphelins éventuels (fichiers sans propriétaire)"
    find / -xdev \( -nouser -o -nogroup \) -print 2>/dev/null | head -20 || true

    ok "Nettoyage terminé."
}

# --------------------------------------------------------------------------- #
# Mise en place
# --------------------------------------------------------------------------- #
do_setup() {
    # --- Paquets ----------------------------------------------------------- #
    info "Paquets requis"
    for p in sudo acl; do
        dpkg -s "$p" >/dev/null 2>&1 || { apt-get install -y "$p"; }
    done
    ok "sudo et acl présents"

    # --- Groupes ----------------------------------------------------------- #
    info "Groupes admin et developer"
    for g in admin developer; do
        getent group "$g" >/dev/null || groupadd "$g"
        ok "groupe $g (gid $(getent group "$g" | cut -d: -f3))"
    done

    # --- Comptes ----------------------------------------------------------- #
    # -m : sans lui, PAS de répertoire personnel — le piège classique.
    # -G : groupe SECONDAIRE. Le groupe principal reste le groupe personnel
    #      (schéma UPG), ce qui rend un umask 002 sans danger.
    info "Comptes alice et bob"
    id alice >/dev/null 2>&1 \
        || useradd -m -s /bin/bash -c "Alice Martin,Administratrice systeme" -G admin alice
    id bob >/dev/null 2>&1 \
        || useradd -m -s /bin/bash -c "Bob Durand,Developpeur" -G developer bob

    # Idempotence : on (re)garantit l'appartenance même si le compte existait
    usermod -aG admin alice
    usermod -aG developer bob

    ok "$(id alice)"
    ok "$(id bob)"
    warn "Aucun mot de passe défini : lancez « passwd alice » et « passwd bob »"

    # --- Politique de mot de passe ----------------------------------------- #
    info "Politique de mot de passe"
    for u in alice bob; do
        chage -M 90 -m 7 -W 14 -I 30 "$u"
        ok "$u : expiration 90 j, avertissement 14 j"
    done

    # --- sudo : groupe admin ----------------------------------------------- #
    info "Règle sudo du groupe admin"
    cat > "$SUDOERS_ADMIN" <<'EOF'
# ── Groupe admin : privilèges complets ───────────────────────────────────────
# (ALL:ALL) = peut devenir n'importe quel utilisateur ET n'importe quel groupe.
# Dernière colonne ALL = n'importe quelle commande, « su » et « -i » compris.
%admin ALL=(ALL:ALL) ALL

# Le mot de passe n'est redemandé qu'après 5 minutes d'inactivité (défaut : 15).
Defaults:%admin timestamp_timeout=5

# Journaliser la sortie des commandes de ce groupe. Rejouable : sudoreplay -l
Defaults:%admin log_output
EOF
    chown root:root "$SUDOERS_ADMIN"
    chmod 0440 "$SUDOERS_ADMIN"
    ok "$SUDOERS_ADMIN"

    # --- sudo : groupe developer ------------------------------------------- #
    # Principe : on n'autorise pas « systemctl », mais des COUPLES
    # (sous-commande, unité). Cela exclut edit / link / mask / set-property,
    # qui donneraient un shell root.
    info "Règle sudo du groupe developer"
    cat > "$SUDOERS_DEV" <<'EOF'
# ── Groupe developer : administration de services, sans privilèges root ──────

# --- Consultation : sans danger, donc sans mot de passe ----------------------
Cmnd_Alias DEV_LECTURE = /usr/bin/systemctl status *,        \
                         /usr/bin/systemctl is-active *,     \
                         /usr/bin/systemctl is-enabled *,    \
                         /usr/bin/systemctl list-units *,    \
                         /usr/bin/systemctl show *,          \
                         /usr/bin/systemctl cat *

# --- Journaux : --no-pager IMPOSÉ, donc aucun sous-processus possible --------
Cmnd_Alias DEV_JOURNAUX = /usr/bin/journalctl --no-pager *,  \
                          /usr/bin/journalctl -n *,          \
                          /usr/bin/journalctl -f -u *,       \
                          /usr/bin/journalctl -u * --no-pager *

# --- Actions : le mot de passe reste exigé ----------------------------------
Cmnd_Alias DEV_ACTIONS = /usr/bin/systemctl start nginx,     \
                         /usr/bin/systemctl stop nginx,      \
                         /usr/bin/systemctl restart nginx,   \
                         /usr/bin/systemctl reload nginx,    \
                         /usr/bin/systemctl start appli-dev, \
                         /usr/bin/systemctl stop appli-dev,  \
                         /usr/bin/systemctl restart appli-dev

%developer ALL=(root) NOPASSWD: DEV_LECTURE, DEV_JOURNAUX
%developer ALL=(root) PASSWD:   DEV_ACTIONS

Defaults:%developer requiretty, !visiblepw, timestamp_timeout=1
EOF
    chown root:root "$SUDOERS_DEV"
    chmod 0440 "$SUDOERS_DEV"
    ok "$SUDOERS_DEV"

    # --- Validation : SANS ELLE, ON PEUT PERDRE TOUT ACCÈS sudo ------------ #
    info "Validation de la configuration sudo"
    if visudo -c; then
        ok "configuration valide"
    else
        rm -f "$SUDOERS_ADMIN" "$SUDOERS_DEV"
        die "Configuration sudo INVALIDE : les fichiers ont été retirés pour vous protéger."
    fi

    # --- Répertoire partagé ------------------------------------------------ #
    info "Répertoire partagé $SHARE_DIR"
    mkdir -p "$SHARE_DIR"/{src,config,logs,releases}

    # root propriétaire : personne ne peut renommer/supprimer la racine.
    # developer groupe  : c'est lui qui travaille dedans.
    chown -R root:developer "$SHARE_DIR"

    # 2775 : setgid (2) -> tout ce qui est créé hérite du groupe developer
    chmod 2775 "$SHARE_DIR"
    find "$SHARE_DIR" -type d -exec chmod 2775 {} +
    ok "$(stat -c '%n  %U:%G  %A' "$SHARE_DIR")"

    # Dépôt commun : setgid + sticky -> chacun ne supprime que ses fichiers
    mkdir -p "$SHARE_DIR/depot"
    chown root:developer "$SHARE_DIR/depot"
    chmod 3775 "$SHARE_DIR/depot"
    ok "$(stat -c '%n  %U:%G  %A' "$SHARE_DIR/depot")"

    # --- ACL : deux groupes sur un même arbre ------------------------------ #
    # Impossible avec ugo seul : un fichier n'a qu'UN groupe propriétaire.
    info "ACL POSIX (developer en écriture, admin en lecture)"
    setfacl -R -m    g:developer:rwX -m    g:admin:rX "$SHARE_DIR"
    setfacl -R -d -m g:developer:rwX -d -m g:admin:rX "$SHARE_DIR"
    ok "ACL et ACL par défaut posées"

    # --- umask ------------------------------------------------------------- #
    # setgid donne le bon GROUPE ; le umask donne le bon DROIT D'ÉCRITURE.
    # Il faut les deux : avec 022, les fichiers naissent en 644 (groupe en
    # lecture seule) et la collaboration est impossible.
    info "umask 002 pour le groupe developer"
    cat > "$UMASK_PROFILE" <<'EOF'
# Écriture collaborative pour les membres du groupe developer.
# Sûr grâce au schéma UPG : le groupe principal de chaque utilisateur ne
# contient que lui-même, un umask 002 n'expose donc rien à des tiers.
if id -nG | tr ' ' '\n' | grep -qx developer; then
    umask 002
fi
EOF
    chmod 644 "$UMASK_PROFILE"
    ok "$UMASK_PROFILE"

    # --- Récapitulatif ----------------------------------------------------- #
    echo
    info "Récapitulatif"
    do_check || true

    cat <<EOF

$(ok "Mise en place terminée.")

Étapes suivantes :

    passwd alice && passwd bob        # définir les mots de passe

    su - bob                          # dans un second terminal
      sudo -l                         # ses droits
      sudo systemctl status nginx     # ✅ autorisé, sans mot de passe
      sudo systemctl restart nginx    # ✅ autorisé, mot de passe demandé
      sudo su                         # ❌ refusé  <- le résultat du TP
      sudo journalctl                 # ❌ refusé (--no-pager absent)

    journalctl -t sudo --no-pager -n 20   # la trace de chaque tentative

Nettoyage : ./setup-users.sh --cleanup
EOF
}

# --------------------------------------------------------------------------- #
# Point d'entrée
# --------------------------------------------------------------------------- #
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $EUID -eq 0 ]] || die "Ce script doit être lancé en root (sudo -i)."
command -v visudo >/dev/null || die "'visudo' introuvable : apt install sudo"

case "${1:-}" in
    "")         do_setup ;;
    --check)    do_check ;;
    --cleanup)  do_cleanup ;;
    *)          die "Option inconnue : $1  (--help pour l'aide)" ;;
esac
