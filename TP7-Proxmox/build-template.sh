#!/usr/bin/env bash
#
# TP7 — Construction automatisée d'un template Proxmox « Debian 13 cloud »
#
# Rejoue les parties 1 à 4 du TP :
#   téléchargement + vérification de l'image cloud officielle
#   -> personnalisation (virt-customize)
#   -> création de la VM + import du disque sur un stockage LVM
#   -> disque cloud-init, valeurs par défaut
#   -> conversion en template
#
# À exécuter EN ROOT SUR LE NOEUD PROXMOX.
#
# Usage :  ./build-template.sh [options]
#          ./build-template.sh --help
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Valeurs par défaut (surchargeables par options ou variables d'environnement)
# --------------------------------------------------------------------------- #
VMID="${VMID:-9000}"
VMNAME="${VMNAME:-debian13-cloud}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"
DISK_SIZE="${DISK_SIZE:-20G}"
CIUSER="${CIUSER:-formation}"
SSHKEY="${SSHKEY:-/root/.ssh/id_ed25519.pub}"
NAMESERVER="${NAMESERVER:-1.1.1.1 9.9.9.9}"
SEARCHDOMAIN="${SEARCHDOMAIN:-lan}"
TIMEZONE="${TIMEZONE:-Pacific/Noumea}"
PACKAGES="${PACKAGES:-qemu-guest-agent,htop,vim,curl}"

IMG_DIR="${IMG_DIR:-/var/lib/vz/template/iso}"
IMG="debian-13-genericcloud-amd64.qcow2"
BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest"

SKIP_CUSTOMIZE=0
FORCE=0

# --------------------------------------------------------------------------- #
# Affichage
# --------------------------------------------------------------------------- #
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  ⚠\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Construction d'un template Proxmox à partir de l'image cloud Debian 13.

Usage : $(basename "$0") [options]

Options :
  --vmid ID              VMID du template               (défaut : $VMID)
  --name NOM             Nom de la VM/template          (défaut : $VMNAME)
  --storage NOM          Stockage des disques           (défaut : $STORAGE)
  --bridge NOM           Bridge réseau                  (défaut : $BRIDGE)
  --cores N              vCPU                           (défaut : $CORES)
  --memory MO            RAM en Mo                      (défaut : $MEMORY)
  --disk-size TAILLE     Taille du disque système       (défaut : $DISK_SIZE)
  --ciuser NOM           Utilisateur cloud-init         (défaut : $CIUSER)
  --sshkey FICHIER       Clé publique à injecter        (défaut : $SSHKEY)
  --nameserver "A B"     Résolveurs DNS                 (défaut : $NAMESERVER)
  --searchdomain NOM     Domaine de recherche           (défaut : $SEARCHDOMAIN)
  --timezone TZ          Fuseau horaire de l'image      (défaut : $TIMEZONE)
  --packages "a,b,c"     Paquets à préinstaller         (défaut : $PACKAGES)
  --skip-customize       Ne pas passer par virt-customize
  --force                Détruire le VMID existant avant de commencer
  -h, --help             Cette aide

Exemples :
  $(basename "$0")
  $(basename "$0") --vmid 9001 --name debian13-large --cores 4 --memory 8192
  STORAGE=local-zfs $(basename "$0") --skip-customize

Après exécution :
  qm clone $VMID 201 --name web01 --full --storage $STORAGE
  qm set 201 --ipconfig0 ip=192.168.1.201/24,gw=192.168.1.1
  qm start 201
EOF
}

# --------------------------------------------------------------------------- #
# Options
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)          VMID="$2";          shift 2 ;;
        --name)          VMNAME="$2";        shift 2 ;;
        --storage)       STORAGE="$2";       shift 2 ;;
        --bridge)        BRIDGE="$2";        shift 2 ;;
        --cores)         CORES="$2";         shift 2 ;;
        --memory)        MEMORY="$2";        shift 2 ;;
        --disk-size)     DISK_SIZE="$2";     shift 2 ;;
        --ciuser)        CIUSER="$2";        shift 2 ;;
        --sshkey)        SSHKEY="$2";        shift 2 ;;
        --nameserver)    NAMESERVER="$2";    shift 2 ;;
        --searchdomain)  SEARCHDOMAIN="$2";  shift 2 ;;
        --timezone)      TIMEZONE="$2";      shift 2 ;;
        --packages)      PACKAGES="$2";      shift 2 ;;
        --skip-customize) SKIP_CUSTOMIZE=1;  shift ;;
        --force)         FORCE=1;            shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "Option inconnue : $1  (--help pour l'aide)" ;;
    esac
done

# --------------------------------------------------------------------------- #
# 0. Contrôles préalables
# --------------------------------------------------------------------------- #
info "Contrôles préalables"

[[ $EUID -eq 0 ]] || die "Ce script doit être lancé en root sur le nœud Proxmox."
command -v qm    >/dev/null || die "'qm' introuvable : ce script s'exécute sur un nœud Proxmox VE."
command -v pvesm >/dev/null || die "'pvesm' introuvable : ce script s'exécute sur un nœud Proxmox VE."

pvesm status --storage "$STORAGE" >/dev/null 2>&1 \
    || die "Stockage '$STORAGE' inconnu. Stockages disponibles :$(pvesm status | awk 'NR>1{printf " %s", $1}')"

ip link show "$BRIDGE" >/dev/null 2>&1 \
    || die "Bridge '$BRIDGE' inexistant. Bridges disponibles :$(ip -br link show type bridge | awk '{printf " %s", $1}')"

if qm config "$VMID" >/dev/null 2>&1; then
    if [[ $FORCE -eq 1 ]]; then
        warn "VMID $VMID existant : destruction (--force)"
        qm stop "$VMID" >/dev/null 2>&1 || true
        qm destroy "$VMID" --purge --destroy-unreferenced-disks 1
    else
        die "Le VMID $VMID existe déjà. Choisissez --vmid autre, ou utilisez --force."
    fi
fi

if [[ ! -f "$SSHKEY" ]]; then
    warn "Clé publique absente : $SSHKEY"
    info "Génération d'une paire de clés ed25519"
    mkdir -p "$(dirname "${SSHKEY%.pub}")"
    ssh-keygen -t ed25519 -C "proxmox-$(hostname -s)" -N '' -f "${SSHKEY%.pub}"
fi
ok "Environnement validé (stockage=$STORAGE, bridge=$BRIDGE, VMID=$VMID)"

# --------------------------------------------------------------------------- #
# 1. Image cloud : téléchargement + vérification
# --------------------------------------------------------------------------- #
info "Image cloud Debian 13 (genericcloud)"

mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

[[ -f "$IMG" ]] && ok "Image déjà présente : $IMG_DIR/$IMG" \
                || wget --quiet --show-progress "$BASE_URL/$IMG"

wget --quiet -O SHA512SUMS "$BASE_URL/SHA512SUMS"

info "Vérification de l'empreinte SHA512"
if grep " $IMG\$" SHA512SUMS | sha512sum -c - >/dev/null 2>&1; then
    ok "Empreinte conforme"
else
    die "Empreinte INVALIDE. Supprimez $IMG_DIR/$IMG et relancez le script."
fi

# La vérification de la SIGNATURE reste manuelle : elle exige de comparer
# l'empreinte de la clé avec celle publiée par l'équipe Debian Cloud.
# Voir la partie 1.2 du README.
warn "Signature GPG non vérifiée par ce script — voir README partie 1.2"

# --------------------------------------------------------------------------- #
# 2. Personnalisation de l'image
# --------------------------------------------------------------------------- #
SRC_IMG="$IMG_DIR/$IMG"

if [[ $SKIP_CUSTOMIZE -eq 0 ]]; then
    info "Personnalisation de l'image (virt-customize)"

    command -v virt-customize >/dev/null || {
        info "Installation de libguestfs-tools"
        apt-get install -y libguestfs-tools
    }

    # Le noyau Proxmox n'est pas lisible par l'appliance libguestfs
    export LIBGUESTFS_BACKEND=direct

    SRC_IMG="$IMG_DIR/custom-$IMG"
    cp -f "$IMG_DIR/$IMG" "$SRC_IMG"    # on ne touche jamais à l'original vérifié

    virt-customize -a "$SRC_IMG" \
        --install "$PACKAGES" \
        --run-command 'systemctl enable qemu-guest-agent' \
        --timezone "$TIMEZONE" \
        --truncate /etc/machine-id      # sinon les clones se disputent la même IP en DHCP

    ok "Image personnalisée : $SRC_IMG"
else
    warn "virt-customize ignoré : pas de qemu-guest-agent, /etc/machine-id non vidé"
fi

# --------------------------------------------------------------------------- #
# 3. Création de la VM + import du disque
# --------------------------------------------------------------------------- #
info "Création de la VM $VMID ($VMNAME)"

qm create "$VMID" \
    --name "$VMNAME" \
    --ostype l26 \
    --cpu host \
    --sockets 1 --cores "$CORES" \
    --memory "$MEMORY" --balloon $(( MEMORY / 2 )) \
    --numa 0 \
    --net0 "virtio,bridge=$BRIDGE" \
    --scsihw virtio-scsi-single \
    --serial0 socket --vga serial0 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --tablet 0 \
    --onboot 1 \
    --description "Template Debian 13 cloud-init — généré par TP7/build-template.sh"

info "Import du disque vers $STORAGE"
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$SRC_IMG,discard=on,ssd=1,iothread=1" >/dev/null

info "Disque cloud-init, ordre de boot, redimensionnement ($DISK_SIZE)"
qm set "$VMID" --ide2 "$STORAGE:cloudinit" >/dev/null
qm set "$VMID" --boot order=scsi0 >/dev/null
qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null
ok "Disque système prêt"

# --------------------------------------------------------------------------- #
# 4. Valeurs cloud-init par défaut
# --------------------------------------------------------------------------- #
info "Valeurs cloud-init par défaut"

CI_OPTS=(
    --ciuser "$CIUSER"
    --sshkeys "$SSHKEY"
    --nameserver "$NAMESERVER"
    --searchdomain "$SEARCHDOMAIN"
    --ipconfig0 ip=dhcp
)

# --ciupgrade n'existe qu'à partir de PVE 8.2
if qm set --help 2>&1 | grep -q -- '--ciupgrade'; then
    CI_OPTS+=(--ciupgrade 0)
fi

qm set "$VMID" "${CI_OPTS[@]}" >/dev/null
ok "Utilisateur '$CIUSER' + clé $(basename "$SSHKEY"), IP par défaut en DHCP"

# --------------------------------------------------------------------------- #
# 5. Conversion en template (irréversible)
# --------------------------------------------------------------------------- #
info "Conversion en template (irréversible)"
qm template "$VMID"
ok "Template $VMID créé"

# --------------------------------------------------------------------------- #
# Récapitulatif
# --------------------------------------------------------------------------- #
echo
info "Configuration finale"
qm config "$VMID"

cat <<EOF

$(ok "Terminé.")

Cloner et démarrer une VM :

    qm clone $VMID 201 --name web01 --full --storage $STORAGE
    qm set 201 --ipconfig0 ip=192.168.1.201/24,gw=192.168.1.1
    qm start 201

Puis vérifier :

    qm agent 201 ping && echo "agent OK"
    ssh $CIUSER@192.168.1.201 'cloud-init status --long; df -h /'

EOF
