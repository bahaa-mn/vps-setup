#!/usr/bin/env bash
# Initialisation et sécurisation d'un VPS Ubuntu (basé sur la doc "Config VPS").
#
# Usage (en root ou via sudo) :
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/setup.sh | sudo bash
#
# Une seule étape, après la configuration de base :
#   curl -fsSL .../setup.sh | sudo bash -s -- <docker|coolify|backup>
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

  AUTO_REBOOT=0
  confirm "Redémarrage automatique à 4h si une mise à jour l'exige (noyau, libc...) ?" o && AUTO_REBOOT=1

  DOCKER=0 DOCKER_GROUP=0
  if command -v docker &>/dev/null; then
    warn "Docker est déjà installé, étape Docker ignorée."
  elif confirm "Installer Docker (Engine + Compose, script officiel get.docker.com) ?" n; then
    ask_docker
  fi

  echo
  info "Récapitulatif"
  echo "  Utilisateur : $NEW_USER (sudo, connexion par clé uniquement)"
  echo "  Port SSH    : $SSH_PORT (root interdit, mot de passe désactivé)"
  echo "  UFW         : $SSH_PORT/tcp ${UFW_RULES[*]}"
  echo "  Fuseau      : $TZ_NAME"
  echo "  Hostname    : ${NEW_HOSTNAME:-$(hostname)}"
  echo "  Sauvegarde  : $( ((BACKUP)) && echo oui || echo non)"
  echo "  Reboot auto : $( ((AUTO_REBOOT)) && echo 'oui (4h)' || echo non)"
  echo "  Verrouiller : $( ((LOCK_OTHERS)) && echo "$OTHER_USERS" || echo aucun)"
  echo "  Docker      : $( ((DOCKER)) && echo "oui$( ((DOCKER_GROUP)) && echo ', groupe docker pour '"$NEW_USER")" || echo non)"
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

ask_docker() {
  DOCKER=1
  if [[ -n $NEW_USER ]] && confirm "Ajouter $NEW_USER au groupe docker (docker sans sudo, équivalent à un accès root) ?" n; then
    DOCKER_GROUP=1
  fi
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
    *) die "Étape inconnue : $1 (étapes disponibles : docker, coolify, backup)" ;;
  esac

  ask_inputs
  step_packages
  step_system
  step_user
  step_coolify
  step_ssh
  step_firewall
  step_fail2ban
  step_autoupdates
  step_backup
  step_docker
  step_finalize
  summary
}

main "$@"
