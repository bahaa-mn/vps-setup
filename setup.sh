#!/usr/bin/env bash
# Initialisation et sécurisation d'un VPS Ubuntu (basé sur la doc "Config VPS").
#
# Usage (en root ou via sudo) :
#   curl -fsSL https://github.com/bahaa-mn/vps-setup/releases/download/<version>/setup.sh | sudo bash
#   (releases immuables : le fichier d'une version publiée ne peut plus changer)
#
# Une seule étape, après la configuration de base :
#   curl -fsSL .../setup.sh | sudo bash -s -- <docker|coolify|backup|swap|restic>
#
# Les réponses sont lues sur /dev/tty, donc le mode "curl | bash" reste interactif.
# Le port 22 reste ouvert tant que la connexion sur le nouveau port n'a pas été validée,
# et un filet de sécurité restaure la config SSH initiale si rien n'est validé à temps.
set -Eeuo pipefail

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "Échec ligne $LINENO : $BASH_COMMAND"' ERR

# ask VAR "question" [defaut]
ask() {
  local __ans
  if [[ -n ${3:-} ]]; then
    read -rp "$2 [$3] : " __ans </dev/tty
  else
    read -rp "$2 : " __ans </dev/tty
  fi
  printf -v "$1" '%s' "${__ans:-${3:-}}"
}

# confirm "question" [o|n]  (defaut n)
confirm() {
  local a
  read -rp "$1 [${2:-n}] : " a </dev/tty
  [[ ${a:-${2:-n}} =~ ^[oOyY] ]]
}

backup() { if [[ -f $1 ]]; then cp -a "$1" "$1.bak.$(date +%s)"; fi; }

# Garde uniquement les clés publiques valides, sans les options type command="..."
extract_keys() { grep -oE '(ssh|ecdsa|sk)-[a-z0-9@.-]+ AAAA[A-Za-z0-9+/=]+( .*)?$' || true; }

socket_mode() { systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket; }

# ---------------------------------------------------------------------------
# Filet de sécurité : si la session tombe avant validation du test SSH, la config
# SSH initiale est restaurée automatiquement au bout de ROLLBACK_MIN minutes.
# ---------------------------------------------------------------------------
STATE_DIR=/root/.vps-setup
ROLLBACK_UNIT=vps-setup-rollback
ROLLBACK_MIN=30

arm_rollback() {
  local restart
  if [[ ! -d $STATE_DIR/ssh ]]; then
    mkdir -p "$STATE_DIR/ssh"
    cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.d "$STATE_DIR/ssh/"
    if [[ -f /etc/systemd/system/ssh.socket.d/override.conf ]]; then
      cp -a /etc/systemd/system/ssh.socket.d/override.conf "$STATE_DIR/ssh/"
    fi
  fi
  if socket_mode; then
    restart='systemctl daemon-reload; systemctl stop ssh.service; systemctl restart ssh.socket; systemctl start ssh.service'
  else
    restart='systemctl restart ssh'
  fi
  cat >"$STATE_DIR/rollback.sh" <<EOF
#!/bin/bash
# Généré par setup.sh : restaure l'accès SSH initial (filet de sécurité)
cp -a $STATE_DIR/ssh/sshd_config /etc/ssh/sshd_config
rm -rf /etc/ssh/sshd_config.d && cp -a $STATE_DIR/ssh/sshd_config.d /etc/ssh/
rm -f /etc/systemd/system/ssh.socket.d/override.conf
[[ -f $STATE_DIR/ssh/override.conf ]] && cp -a $STATE_DIR/ssh/override.conf /etc/systemd/system/ssh.socket.d/
$restart
ufw status 2>/dev/null | grep -q '^Status: active' && ufw allow 22/tcp
touch $STATE_DIR/ROLLBACK_DONE
wall "vps-setup : délai dépassé, configuration SSH initiale restaurée (port 22)." 2>/dev/null
EOF
  chmod 700 "$STATE_DIR/rollback.sh"
  systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
  rm -f "$STATE_DIR/ROLLBACK_DONE"
  systemd-run --quiet --on-active="${ROLLBACK_MIN}min" --unit="$ROLLBACK_UNIT" "$STATE_DIR/rollback.sh"
}

disarm_rollback() {
  systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
  rm -rf "$STATE_DIR"
}

rollback_fired() { [[ -f $STATE_DIR/ROLLBACK_DONE ]]; }

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
ask_inputs() {
  local p ok p2 choice gh lo hi

  while :; do
    ask NEW_USER "Nom de l'utilisateur admin à créer"
    if [[ ! $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ || $NEW_USER == root ]]; then
      warn "Nom invalide (minuscules, chiffres, _ ou -, 32 caractères max, pas root)."
    elif id "$NEW_USER" &>/dev/null && (( $(id -u "$NEW_USER") < 1000 )); then
      warn "$NEW_USER est un compte système (UID < 1000), choisir un autre nom."
    else
      break
    fi
  done

  USER_PASS=""
  if id "$NEW_USER" &>/dev/null; then
    warn "$NEW_USER existe déjà : il sera conservé (mot de passe inchangé)."
  else
    while :; do
      read -rsp "Mot de passe de $NEW_USER (utilisé pour sudo) : " USER_PASS </dev/tty; echo
      read -rsp "Confirmer le mot de passe : " p2 </dev/tty; echo
      [[ -n $USER_PASS && $USER_PASS == "$p2" ]] && break
      warn "Mot de passe vide ou différent."
    done
  fi

  COOLIFY_USER="" COOLIFY_KEY=""
  if confirm "Créer un utilisateur dédié pour connecter ce serveur à un Coolify central ?" n; then
    ask_coolify
  fi

  # Autres comptes humains (ex: "ubuntu" créé par l'image cloud, souvent avec sudo sans mot de passe)
  OTHER_USERS=$(awk -F: -v u="$NEW_USER" -v c="$COOLIFY_USER" '$3>=1000 && $3<60000 && $1!=u && $1!=c && $7!~/(nologin|false)$/ {print $1}' /etc/passwd | xargs)
  LOCK_OTHERS=0
  if [[ -n $OTHER_USERS ]]; then
    confirm "Verrouiller les autres comptes utilisateurs ($OTHER_USERS) une fois l'accès validé ?" o && LOCK_OTHERS=1
  fi

  while :; do
    ask SSH_PORT "Port SSH (22 = inchangé, sinon 1024-65535)" "22"
    if [[ $SSH_PORT =~ ^[0-9]+$ ]]; then
      SSH_PORT=$((10#$SSH_PORT))
      (( SSH_PORT == 22 || (SSH_PORT >= 1024 && SSH_PORT <= 65535) )) && break
    fi
    warn "Port invalide (22 ou 1024-65535)."
  done

  while :; do
    ask UFW_PORTS "Ports à ouvrir dans UFW en plus du SSH (virgules, ex: 80,443,8000:8100/udp ; 'aucun' pour rien)" "80,443"
    UFW_RULES=()
    ok=1
    if [[ $UFW_PORTS != aucun ]]; then
      for p in ${UFW_PORTS//,/ }; do
        if [[ ! $p =~ ^([0-9]+)(:([0-9]+))?(/(tcp|udp))?$ ]]; then
          warn "Port invalide : $p"; ok=0; continue
        fi
        lo=$((10#${BASH_REMATCH[1]})); hi=$((10#${BASH_REMATCH[3]:-$lo}))
        if (( lo < 1 || hi > 65535 || lo > hi )); then
          warn "Plage invalide : $p (1-65535, début <= fin)"; ok=0; continue
        fi
        [[ $p == */* ]] || p="$p/tcp"
        UFW_RULES+=("$p")
      done
    fi
    (( ok )) && break
  done

  SSH_KEYS=""
  while [[ -z $SSH_KEYS ]]; do
    echo
    echo "Clé(s) SSH publique(s) pour $NEW_USER :"
    echo "  1) Reprendre celles de root (/root/.ssh/authorized_keys)"
    echo "  2) Coller une clé publique (contenu de ~/.ssh/id_ed25519.pub)"
    echo "  3) Importer depuis GitHub (https://github.com/<user>.keys)"
    ask choice "Choix" "1"
    case $choice in
      1) SSH_KEYS=$(extract_keys </root/.ssh/authorized_keys 2>/dev/null) ;;
      2) ask p "Clé publique"; SSH_KEYS=$(extract_keys <<<"$p") ;;
      3) ask gh "Utilisateur GitHub"
         if [[ $gh =~ ^[A-Za-z0-9-]+$ ]]; then
           SSH_KEYS=$(curl -fsSL --max-time 15 "https://github.com/$gh.keys" | extract_keys) || true
         fi ;;
    esac
    if [[ -n $SSH_KEYS ]] && ssh-keygen -lf <(printf '%s\n' "$SSH_KEYS") >/dev/null 2>&1; then
      ssh-keygen -lf <(printf '%s\n' "$SSH_KEYS")
    else
      warn "Aucune clé valide trouvée, recommencer."; SSH_KEYS=""
    fi
  done

  while :; do
    ask TZ_NAME "Fuseau horaire" "Europe/Paris"
    timedatectl list-timezones | grep -qxF "$TZ_NAME" && break
    warn "Fuseau inconnu (voir: timedatectl list-timezones)."
  done

  while :; do
    ask NEW_HOSTNAME "Hostname (vide = garder '$(hostname)')"
    [[ -z $NEW_HOSTNAME || $NEW_HOSTNAME =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && break
    warn "Hostname invalide."
  done

  BACKUP=0
  confirm "Sauvegarde quotidienne de /etc à 2h dans /opt/backups (14 jours) ?" o && BACKUP=1

  SWAP_GB=0
  if swap_present; then
    warn "Un swap existe déjà (swapon --show, /swapfile), étape swap ignorée."
  elif confirm "Créer un fichier swap ?" o; then
    ask_swap
  fi

  AUTO_REBOOT=0
  confirm "Redémarrage automatique à 4h si une mise à jour l'exige (noyau, libc...) ?" o && AUTO_REBOOT=1

  DOCKER=0 DOCKER_GROUP=0
  if command -v docker &>/dev/null; then
    warn "Docker est déjà installé, étape Docker ignorée."
  elif confirm "Installer Docker (Engine + Compose, script officiel get.docker.com) ?" n; then
    ask_docker
  fi

  RESTIC_NAMES=()
  if confirm "Configurer les sauvegardes chiffrées restic (S3/R2/B2, NAS, plusieurs cibles possibles) ?" n; then
    ask_restic
  fi

  echo
  info "Récapitulatif"
  echo "  Utilisateur : $NEW_USER (sudo, connexion par clé uniquement)"
  echo "  Port SSH    : $SSH_PORT (root interdit, mot de passe désactivé)"
  echo "  UFW         : $SSH_PORT/tcp ${UFW_RULES[*]}"
  echo "  Fuseau      : $TZ_NAME"
  echo "  Hostname    : ${NEW_HOSTNAME:-$(hostname)}"
  echo "  Sauvegarde  : $( ((BACKUP)) && echo oui || echo non)"
  echo "  Swap        : $( ((SWAP_GB)) && echo "${SWAP_GB} Go (/swapfile)" || echo non)"
  echo "  Reboot auto : $( ((AUTO_REBOOT)) && echo 'oui (4h)' || echo non)"
  echo "  Verrouiller : $( ((LOCK_OTHERS)) && echo "$OTHER_USERS" || echo aucun)"
  echo "  Docker      : $( ((DOCKER)) && echo "oui$( ((DOCKER_GROUP)) && echo ', groupe docker pour '"$NEW_USER")" || echo non)"
  echo "  Restic      : $( ((${#RESTIC_NAMES[@]})) && echo "${RESTIC_NAMES[*]} (chaque nuit vers 2h30)" || echo non)"
  echo "  Coolify     : $( [[ -n $COOLIFY_USER ]] && echo "$COOLIFY_USER (sudo sans mot de passe, clé Coolify uniquement)" || echo non)"
  echo "  + mise à jour système, Fail2ban, mises à jour de sécurité automatiques"
  confirm "Lancer la configuration ?" o || die "Annulé."
}

# Compte dédié à un serveur Coolify central (doc : coolify.io/docs/core/infrastructure/servers/non-root-user)
ask_coolify() {
  local p
  while :; do
    ask COOLIFY_USER "Nom de l'utilisateur Coolify" "coolify"
    if [[ ! $COOLIFY_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ || $COOLIFY_USER == root || $COOLIFY_USER == "$NEW_USER" ]]; then
      warn "Nom invalide (minuscules, chiffres, _ ou -, 32 caractères max, ni root ni l'utilisateur admin)."
    elif id "$COOLIFY_USER" &>/dev/null && (( $(id -u "$COOLIFY_USER") < 1000 )); then
      warn "$COOLIFY_USER est un compte système (UID < 1000), choisir un autre nom."
    else
      break
    fi
  done
  echo "Dans Coolify : Keys & Tokens > Private Keys > New private key > Generate ED25519 (sans passphrase), copier la clé publique."
  while :; do
    ask p "Clé publique générée par Coolify"
    COOLIFY_KEY=$(extract_keys <<<"$p" | head -n1)
    [[ -n $COOLIFY_KEY ]] && ssh-keygen -lf <(printf '%s\n' "$COOLIFY_KEY") 2>/dev/null && break
    warn "Clé invalide, recommencer."
  done
}

swap_present() { [[ -e /swapfile || -n $(swapon --show --noheadings) ]]; }

ask_swap() {
  while :; do
    ask SWAP_GB "Taille du swap en Go" "4"
    if [[ $SWAP_GB =~ ^[0-9]+$ ]]; then
      SWAP_GB=$((10#$SWAP_GB))
      (( SWAP_GB >= 1 && SWAP_GB <= 64 )) && break
    fi
    warn "Taille invalide (1-64)."
  done
}

ask_docker() {
  DOCKER=1
  if [[ -n $NEW_USER ]] && confirm "Ajouter $NEW_USER au groupe docker (docker sans sudo, équivalent à un accès root) ?" n; then
    DOCKER_GROUP=1
  fi
}

# kv CLE valeur : ligne d'un fichier .env relu par bash (valeur échappée)
kv() { printf '%s=%q\n' "$1" "$2"; }

# Cibles restic : une entrée par cible dans RESTIC_NAMES / RESTIC_ENVS / RESTIC_PASSES
ask_restic() {
  local choice name def env url bucket user secret dest port path prune_def pass n dup more=o
  local host=${NEW_HOSTNAME:-$(hostname)} key=/etc/restic/id_ed25519
  RESTIC_NAMES=() RESTIC_ENVS=() RESTIC_PASSES=() RESTIC_GENERATED=()
  ask RESTIC_PATHS "Dossiers à sauvegarder (séparés par des espaces, les absents sont ignorés)" "/etc /home /root /data /var/lib/docker/volumes"
  echo "Les bases de données doivent être exportées (dump) dans un de ces dossiers : une copie à chaud de leurs fichiers peut être incohérente."
  while :; do
    echo
    echo "Cible de sauvegarde n°$(( ${#RESTIC_NAMES[@]} + 1 )) :"
    echo "  1) Stockage S3 (Cloudflare R2, Backblaze B2, Wasabi, Scaleway, MinIO...)"
    echo "  2) rest-server (NAS, serveur de sauvegarde central)"
    echo "  3) SFTP (NAS ou serveur accessible en SSH)"
    ask choice "Choix" "1"
    case $choice in
      1)
        while :; do
          ask url "URL S3 (R2 : https://<compte>.r2.cloudflarestorage.com, B2 : https://s3.<region>.backblazeb2.com)"
          url=${url%/}
          [[ $url =~ ^https?://[^/[:space:]]+$ ]] && break
          warn "URL invalide (https://hôte, sans chemin)."
        done
        while :; do ask bucket "Bucket"; [[ $bucket =~ ^[a-z0-9][a-z0-9.-]{1,62}$ ]] && break; warn "Nom de bucket invalide."; done
        ask user "Access key ID"
        read -rsp "Secret access key : " secret </dev/tty; echo
        env="$(kv RESTIC_REPOSITORY "s3:$url/$bucket/$host"; kv AWS_ACCESS_KEY_ID "$user"; kv AWS_SECRET_ACCESS_KEY "$secret")"
        [[ $url == *.r2.cloudflarestorage.com ]] && env+=$'\n'"$(kv AWS_DEFAULT_REGION auto)"
        case $url in *r2.cloudflarestorage*) def=r2 ;; *backblazeb2*) def=b2 ;; *) def=s3 ;; esac
        prune_def=o ;;
      2)
        while :; do
          ask url "URL du rest-server (ex: http://nas.local:8000)"
          url=${url%/}
          [[ $url =~ ^https?://[^/[:space:]]+$ ]] && break
          warn "URL invalide (http(s)://hôte:port, sans chemin)."
        done
        ask user "Utilisateur rest-server" "$host"
        read -rsp "Mot de passe rest-server : " secret </dev/tty; echo
        # --private-repos : chaque utilisateur n'accède qu'au dépôt qui porte son nom
        env="$(kv RESTIC_REPOSITORY "rest:$url/$user/"; kv RESTIC_REST_USERNAME "$user"; kv RESTIC_REST_PASSWORD "$secret")"
        def=nas
        prune_def=n ;;
      3)
        while :; do ask dest "Connexion SFTP (utilisateur@hôte)"; [[ $dest =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] && break; warn "Format attendu : utilisateur@hôte"; done
        while :; do ask port "Port SSH de la cible" "22"; [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && break; warn "Port invalide."; done
        ask path "Dossier sur la cible" "/backups/$host"
        if [[ ! -f $key ]]; then
          install -d -m 700 /etc/restic
          ssh-keygen -q -t ed25519 -N '' -C "restic@$host" -f "$key"
        fi
        echo "Clé publique à ajouter dans ~/.ssh/authorized_keys de ${dest%@*} sur la cible :"
        echo
        cat "$key.pub"
        echo
        confirm "Clé ajoutée sur la cible ?" o || warn "Sans cette clé, la création du dépôt échouera."
        env="$(kv RESTIC_REPOSITORY "sftp:$dest:$path"; kv SFTP_ARGS "-i $key -p $port -o StrictHostKeyChecking=accept-new")"
        def=nas
        prune_def=o ;;
      *) warn "Choix invalide."; continue ;;
    esac

    while :; do
      ask name "Nom de la cible" "$def"
      dup=0
      for n in "${RESTIC_NAMES[@]}"; do [[ $n == "$name" ]] && dup=1; done
      [[ $name =~ ^[a-z0-9-]{1,32}$ ]] && (( !dup )) && break
      warn "Nom invalide ou déjà utilisé (minuscules, chiffres, -)."
    done
    if confirm "Supprimer les anciennes sauvegardes depuis ce serveur (garde 7 jours, 4 semaines, 6 mois) ? Non si la cible est en append-only" "$prune_def"; then
      env+=$'\n'"$(kv PRUNE 1)"
    fi
    read -rsp "Mot de passe de chiffrement du dépôt (vide = en générer un ; dépôt existant : son mot de passe) : " pass </dev/tty; echo
    if [[ -z $pass ]]; then
      pass=$(openssl rand -base64 32)
      RESTIC_GENERATED+=("$name")
    fi
    RESTIC_NAMES+=("$name") RESTIC_ENVS+=("$env") RESTIC_PASSES+=("$pass")

    confirm "Ajouter une autre cible (ex: un NAS local en plus du stockage distant) ?" "$more" || break
    more=n
  done
}

# ---------------------------------------------------------------------------
# Étapes
# ---------------------------------------------------------------------------
step_packages() {
  info "Mise à jour du système et installation des paquets"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt-get install -y curl wget vim git htop ufw fail2ban unattended-upgrades
  apt-get autoremove -y
  apt-get autoclean
}

step_system() {
  info "Fuseau horaire et hostname"
  timedatectl set-timezone "$TZ_NAME"
  if [[ -n $NEW_HOSTNAME ]]; then
    hostnamectl set-hostname "$NEW_HOSTNAME" || warn "Impossible de changer le hostname, étape ignorée."
    grep -qw "$NEW_HOSTNAME" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >>/etc/hosts
  fi
}

step_user() {
  info "Utilisateur $NEW_USER"
  if ! id "$NEW_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    echo "$NEW_USER:$USER_PASS" | chpasswd
  fi
  usermod -aG sudo "$NEW_USER"

  install_keys "$NEW_USER" "$SSH_KEYS"
}

# install_keys user "clés" : ajoute les clés manquantes à ~user/.ssh/authorized_keys
install_keys() {
  local home ak k
  home=$(getent passwd "$1" | cut -d: -f6)
  ak="$home/.ssh/authorized_keys"
  install -d -m 700 -o "$1" -g "$1" "$home/.ssh"
  touch "$ak"
  while IFS= read -r k; do
    if ! grep -qxF "$k" "$ak"; then echo "$k" >>"$ak"; fi
  done <<<"$2"
  chown "$1:$1" "$ak"
  chmod 600 "$ak"
}

step_coolify() {
  [[ -n $COOLIFY_USER ]] || return 0
  info "Utilisateur Coolify $COOLIFY_USER"
  # 'NP' : compte déverrouillé mais sans mot de passe utilisable (un compte verrouillé refuse les clés SSH)
  if ! id "$COOLIFY_USER" &>/dev/null; then
    useradd --create-home --user-group --shell /bin/bash --password 'NP' "$COOLIFY_USER"
  elif [[ $(passwd -S "$COOLIFY_USER" | awk '{print $2}') == L ]]; then
    usermod -p 'NP' "$COOLIFY_USER"
  fi
  install_keys "$COOLIFY_USER" "$COOLIFY_KEY"

  local sudoers=/etc/sudoers.d/$COOLIFY_USER
  echo "$COOLIFY_USER ALL=(ALL) NOPASSWD: ALL" >"$sudoers.tmp"
  chmod 440 "$sudoers.tmp"
  visudo -cf "$sudoers.tmp" >/dev/null || { rm -f "$sudoers.tmp"; die "Règle sudoers invalide pour $COOLIFY_USER."; }
  mv "$sudoers.tmp" "$sudoers"
  [[ $(su - "$COOLIFY_USER" -c 'sudo -n whoami') == root ]] || die "sudo sans mot de passe ne fonctionne pas pour $COOLIFY_USER."

  mkdir -p /data/coolify
  chown -R "$COOLIFY_USER:$COOLIFY_USER" /data/coolify
  chmod -R o-rwx /data/coolify
}

# Étape seule : ajoute COOLIFY_USER à l'AllowUsers posé par la configuration de base
coolify_allow_ssh() {
  local conf=/etc/ssh/sshd_config.d/00-hardening.conf
  if ! grep -qE '^AllowUsers\s' "$conf" 2>/dev/null; then
    warn "Pas d'AllowUsers dans $conf : aucune restriction SSH à modifier."
    return 0
  fi
  awk -v u="$COOLIFY_USER" '$1=="AllowUsers" {for (i=2; i<=NF; i++) if ($i==u) f=1} END {exit !f}' "$conf" && return 0
  info "Ajout de $COOLIFY_USER à AllowUsers"
  backup "$conf"
  sed -i -E "s/^AllowUsers\s.*/& $COOLIFY_USER/" "$conf"
  install -d -m 755 /run/sshd
  sshd -t || die "Configuration sshd invalide ($conf), SSH non rechargé."
  # Ajouter un utilisateur ne coupe aucun accès existant : un rechargement suffit
  systemctl try-reload-or-restart ssh.service
}

# write_ssh_config "port1 [port2]" : config sshd + ssh.socket, puis redémarrage
write_ssh_config() {
  local ports p f conf=/etc/ssh/sshd_config.d/00-hardening.conf
  read -ra ports <<<"$1"

  # sshd cumule les "Port" : un Port actif ailleurs s'ajouterait aux nôtres
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ $f == "$conf" ]] && continue
    if grep -qE '^\s*Port\s' "$f" 2>/dev/null; then
      backup "$f"
      sed -i -E 's/^\s*Port\s/#&/' "$f"
    fi
  done

  # 00- : sshd garde la première valeur lue, donc ce fichier passe avant 50-cloud-init.conf
  {
    for p in "${ports[@]}"; do echo "Port $p"; done
    cat <<EOF
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowUsers $NEW_USER${COOLIFY_USER:+ $COOLIFY_USER}
EOF
  } >"$conf"
  # En mode ssh.socket, /run/sshd n'existe pas tant que sshd n'a pas tourné
  install -d -m 755 /run/sshd
  sshd -t || die "Configuration sshd invalide ($conf), SSH non redémarré."

  if socket_mode; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    {
      echo "[Socket]"
      echo "ListenStream="
      for p in "${ports[@]}"; do
        echo "ListenStream=0.0.0.0:$p"
        if [[ -f /proc/net/if_inet6 ]]; then echo "ListenStream=[::]:$p"; fi
      done
    } >/etc/systemd/system/ssh.socket.d/override.conf
    systemctl daemon-reload
    # Les sessions ouvertes survivent (KillMode=process sur ssh.service)
    systemctl stop ssh.service
    systemctl restart ssh.socket
    systemctl start ssh.service
  else
    systemctl restart ssh
  fi

  for p in "${ports[@]}"; do
    ss -tlnH "sport = :$p" | grep -q . || die "SSH n'écoute pas sur le port $p. Ne fermez pas cette session."
  done
}

step_ssh() {
  arm_rollback
  if (( SSH_PORT == 22 )); then
    info "Sécurisation SSH (port 22)"
    write_ssh_config "22"
  else
    info "Sécurisation SSH (ports 22 et $SSH_PORT le temps du test)"
    write_ssh_config "22 $SSH_PORT"
  fi
  warn "Filet de sécurité armé : sans validation dans les $ROLLBACK_MIN min, la config SSH initiale sera restaurée."
}

step_firewall() {
  info "Pare-feu UFW"
  local r
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow "$SSH_PORT/tcp"
  for r in "${UFW_RULES[@]}"; do ufw allow "$r"; done
  ufw --force enable
}

step_fail2ban() {
  info "Fail2ban"
  backup /etc/fail2ban/jail.local
  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = systemd
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
}

step_autoupdates() {
  info "Mises à jour de sécurité automatiques"
  # Équivalent non interactif de "dpkg-reconfigure -plow unattended-upgrades"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if (( AUTO_REBOOT )); then
    cat >/etc/apt/apt.conf.d/52auto-reboot <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
  fi
  systemctl enable --now unattended-upgrades
}

step_backup() {
  (( BACKUP )) || return 0
  info "Sauvegarde quotidienne de /etc"
  # /etc contient /etc/shadow : dossier réservé à root
  install -d -m 700 /opt/backups
  cat >/etc/cron.d/backup-etc <<'EOF'
0 2 * * * root tar -czf /opt/backups/etc-$(date +\%F).tar.gz -C / etc 2>/dev/null; find /opt/backups -name 'etc-*.tar.gz' -mtime +14 -delete
EOF
}

step_swap() {
  (( SWAP_GB )) || return 0
  info "Swap de $SWAP_GB Go"
  local free_gb
  free_gb=$(df --output=avail -BG / | tail -n1 | tr -dc 0-9)
  # Garder au moins 2 Go libres après création du swap
  (( free_gb >= SWAP_GB + 2 )) || { warn "Espace disque insuffisant ($free_gb Go libres), swap non créé."; return 0; }
  # fallocate n'est pas supporté partout (certains systèmes de fichiers) : dd en secours
  fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  # Serveur : le swap sert de filet contre l'OOM, pas de mémoire courante
  echo 'vm.swappiness=10' >/etc/sysctl.d/99-swap.conf
  sysctl -q -p /etc/sysctl.d/99-swap.conf
  swapon --show
}

step_docker() {
  (( DOCKER )) || return 0
  info "Docker"
  local installer
  installer=$(mktemp)
  # Téléchargé puis exécuté : un téléchargement interrompu ne lance rien
  curl -fsSL --max-time 60 https://get.docker.com -o "$installer"
  sh "$installer"
  rm -f "$installer"

  # Rotation des logs (sinon les logs de conteneurs grossissent sans limite), sans écraser une config existante
  if [[ ! -f /etc/docker/daemon.json ]]; then
    install -d -m 755 /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  fi
  systemctl enable docker
  systemctl restart docker

  if (( DOCKER_GROUP )); then usermod -aG docker "$NEW_USER"; fi
  docker --version
  docker compose version
  warn "Docker contourne UFW pour les ports publiés (-p). Publier sur 127.0.0.1 ou filtrer via le pare-feu de l'hébergeur."
}

# Binaire officiel épinglé (empreintes de SHA256SUMS de la release) : apt fournit une version trop ancienne sur 22.04
RESTIC_VERSION=0.19.1
install_restic() {
  local arch sum tmp
  [[ $(restic version 2>/dev/null) == "restic $RESTIC_VERSION "* ]] && return 0
  arch=$(dpkg --print-architecture)
  case $arch in
    amd64) sum=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c ;;
    arm64) sum=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465 ;;
    *) die "Architecture $arch non prise en charge pour restic." ;;
  esac
  command -v bunzip2 &>/dev/null || apt-get install -y bzip2
  tmp=$(mktemp)
  curl -fsSL --max-time 120 "https://github.com/restic/restic/releases/download/v$RESTIC_VERSION/restic_${RESTIC_VERSION}_linux_$arch.bz2" -o "$tmp"
  echo "$sum  $tmp" | sha256sum -c --quiet || { rm -f "$tmp"; die "Empreinte SHA256 de restic invalide."; }
  bunzip2 -c "$tmp" >/usr/local/bin/restic.tmp
  rm -f "$tmp"
  chmod 755 /usr/local/bin/restic.tmp
  mv /usr/local/bin/restic.tmp /usr/local/bin/restic
  restic version
}

step_restic() {
  (( ${#RESTIC_NAMES[@]} )) || return 0
  info "Sauvegardes restic vers : ${RESTIC_NAMES[*]}"
  local i n out
  install_restic
  install -d -m 700 /etc/restic /etc/restic/targets
  printf '%s\n' $RESTIC_PATHS >/etc/restic/paths

  cat >/usr/local/sbin/restic-backup <<'EOF'
#!/bin/bash
# Généré par setup.sh.
#   restic-backup                     sauvegarde vers chaque cible de /etc/restic/targets
#   restic-backup <cible> <commande>  commande restic sur une cible (ex: restic-backup nas snapshots)
set -uo pipefail
export RESTIC_CACHE_DIR=/var/cache/restic
r() { restic ${SFTP_ARGS:+-o "sftp.args=$SFTP_ARGS"} "$@"; }
load() { set -a; . "/etc/restic/targets/$1.env" || exit 1; set +a; }

if (( $# )); then load "$1"; shift; r "$@"; exit; fi

mapfile -t paths < <(while read -r p; do [[ -e $p ]] && echo "$p"; done </etc/restic/paths)
fail=0
for f in /etc/restic/targets/*.env; do
  n=$(basename "$f" .env)
  echo "== $n"
  # Une cible en panne n'empêche pas la sauvegarde vers les autres
  ( load "$n"
    r backup --tag auto "${paths[@]}" || exit
    if [[ ${PRUNE:-0} == 1 ]]; then r forget --tag auto --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune; fi
  ) || { echo "Échec de la sauvegarde vers $n" >&2; fail=1; }
done
exit $fail
EOF
  chmod 750 /usr/local/sbin/restic-backup

  for i in "${!RESTIC_NAMES[@]}"; do
    n=${RESTIC_NAMES[i]}
    (
      umask 077
      printf '%s\n' "${RESTIC_PASSES[i]}" >"/etc/restic/targets/$n.pass"
      { printf '%s\n' "${RESTIC_ENVS[i]}"; kv RESTIC_PASSWORD_FILE "/etc/restic/targets/$n.pass"; } >"/etc/restic/targets/$n.env"
    )
    # init directement : un "cat config" sur un bucket absent réessaie pendant de longues minutes
    if out=$(timeout 120 /usr/local/sbin/restic-backup "$n" init 2>&1); then
      echo "Dépôt $n créé."
    elif [[ $out == *"already exists"* ]]; then
      echo "Dépôt $n existant, réutilisé."
    else
      printf '%s\n' "$out" | tail -n 3
      warn "Création du dépôt $n impossible (identifiants, URL, clé SSH ?). Corriger /etc/restic/targets/$n.env puis : restic-backup $n init"
    fi
  done

  cat >/etc/systemd/system/restic-backup.service <<'EOF'
[Unit]
Description=Sauvegarde restic (setup.sh)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/restic-backup
Nice=10
IOSchedulingClass=idle
EOF
  # Après la sauvegarde de /etc (2h) et avant le redémarrage automatique (4h)
  cat >/etc/systemd/system/restic-backup.timer <<'EOF'
[Unit]
Description=Sauvegarde restic quotidienne

[Timer]
OnCalendar=*-*-* 02:30
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now restic-backup.timer
  systemctl start --no-block restic-backup.service
  echo "Première sauvegarde lancée en arrière-plan : journalctl -fu restic-backup"

  for n in "${RESTIC_GENERATED[@]}"; do
    warn "Mot de passe généré pour $n, à conserver HORS du serveur (sans lui, restauration impossible) :"
    echo "    $(cat "/etc/restic/targets/$n.pass")"
  done
}

step_lock_others() {
  (( LOCK_OTHERS )) || return 0
  info "Verrouillage des comptes : $OTHER_USERS"
  local u
  for u in $OTHER_USERS; do
    # Mot de passe verrouillé + compte expiré (bloque aussi les clés SSH) + pas de shell
    usermod -L -e 1970-01-02 -s /usr/sbin/nologin "$u"
  done
}

step_finalize() {
  local ip
  ip=$(hostname -I | awk '{print $1}')
  while :; do
    if rollback_fired; then
      warn "Délai de $ROLLBACK_MIN min dépassé : la config SSH initiale a été restaurée. Ré-application."
      step_ssh
    fi
    info "Test de connexion : NE FERMEZ PAS cette session"
    echo "Dans un AUTRE terminal, depuis votre machine (vous avez $ROLLBACK_MIN min) :"
    echo
    echo "    ssh -p $SSH_PORT $NEW_USER@${ip:-IP_DU_VPS}"
    echo "    sudo whoami     # doit afficher root"
    echo
    if confirm "La connexion et sudo fonctionnent ?" n; then
      disarm_rollback
      if (( SSH_PORT != 22 )); then
        info "Fermeture du port 22"
        write_ssh_config "$SSH_PORT"
        ufw delete allow 22/tcp
        ufw reload
      fi
      step_lock_others
      return 0
    fi
    confirm "Réessayer le test ?" o && continue
    warn "Durcissement laissé en place, port 22 toujours ouvert, cette session reste utilisable."
    warn "Sans validation, la config SSH initiale sera restaurée automatiquement (délai : $ROLLBACK_MIN min depuis l'armement)."
    warn "Pour garder le durcissement malgré tout : systemctl stop $ROLLBACK_UNIT.timer"
    return 0
  done
}

summary() {
  info "Terminé"
  ufw status verbose
  fail2ban-client status sshd || true
  ss -tlnp | grep -E "sshd|systemd" || true
  echo
  echo "Connexion : ssh -p $SSH_PORT $NEW_USER@IP_DU_VPS"
  if [[ -n $COOLIFY_USER ]]; then
    echo "Coolify   : Servers > Add, IP du VPS, port $SSH_PORT, utilisateur $COOLIFY_USER, clé privée générée dans Coolify"
  fi
}

# ---------------------------------------------------------------------------
# Tout est dans main() : un téléchargement tronqué via "curl | bash" ne lance rien.
main() {
  [[ $EUID -eq 0 ]] || die "À lancer en root (ou avec sudo)."
  { : </dev/tty; } 2>/dev/null || die "Pas de terminal interactif (/dev/tty) disponible."
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ ${ID:-} != ubuntu ]]; then
    confirm "Système détecté : ${PRETTY_NAME:-inconnu}, prévu pour Ubuntu. Continuer ?" n || exit 1
  fi

  # Étape seule : l'utilisateur admin est celui qui a lancé sudo
  NEW_USER=${SUDO_USER:-}
  [[ $NEW_USER == root ]] && NEW_USER=""
  DOCKER_GROUP=0
  case ${1:-} in
    "") ;;
    docker)
      command -v docker &>/dev/null && die "Docker est déjà installé."
      ask_docker; step_docker; return 0 ;;
    coolify)
      ask_coolify; step_coolify; coolify_allow_ssh
      echo "Coolify : Servers > Add, IP du VPS, port SSH du serveur, utilisateur $COOLIFY_USER, clé privée générée dans Coolify"
      return 0 ;;
    backup) BACKUP=1; step_backup; return 0 ;;
    swap)
      swap_present && die "Un swap existe déjà (swapon --show, /swapfile)."
      ask_swap; step_swap; return 0 ;;
    restic) ask_restic; step_restic; return 0 ;;
    *) die "Étape inconnue : $1 (étapes disponibles : docker, coolify, backup, swap, restic)" ;;
  esac

  ask_inputs
  step_packages
  step_system
  step_swap
  step_user
  step_coolify
  step_ssh
  step_firewall
  step_fail2ban
  step_autoupdates
  step_backup
  step_docker
  step_finalize
  step_restic
  summary
}

main "$@"
