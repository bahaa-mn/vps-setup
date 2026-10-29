# vps-setup

Initialisation et sécurisation d'un VPS Ubuntu neuf en une commande : utilisateur sudo avec clé SSH, durcissement SSH (root interdit, clé uniquement, port au choix), UFW, Fail2ban, mises à jour de sécurité automatiques, sauvegarde de `/etc`.

Le script pose ses questions au début, affiche un récapitulatif, puis fait tout sans intervention. Le port 22 reste ouvert tant que la connexion sur le nouveau port n'a pas été testée, et un filet de sécurité restaure la config SSH initiale si rien n'est validé dans les 30 minutes.

## Utilisation

Sur le VPS, connecté en root (ou avec un utilisateur sudo) :

```bash
curl -fsSL https://github.com/bahaa-mn/vps-setup/releases/download/v1.1.1/setup.sh | sudo bash
```

L'URL pointe vers une [release](https://github.com/bahaa-mn/vps-setup/releases) immuable : le fichier d'une version publiée ne peut plus être modifié, contrairement à la branche `main`.

Pour vérifier le fichier avant de l'exécuter :

```bash
curl -fsSLO https://github.com/bahaa-mn/vps-setup/releases/download/v1.1.1/setup.sh
echo "5f00c9e4ce9722e9847c604c3c19761ba25bf719832c0cb780e1715ac8098e7c  setup.sh" | sha256sum -c && sudo bash setup.sh
```

Ou, avec la CLI GitHub, via l'attestation de la release : `gh release verify-asset v1.1.1 setup.sh -R bahaa-mn/vps-setup`

## Ce que le script demande

- nom de l'utilisateur admin et son mot de passe (pour `sudo` et la console de l'hébergeur, pas pour SSH)
- port SSH (22 par défaut)
- ports à ouvrir dans UFW (`80,443` par défaut, plages et UDP acceptés : `8000:8100/udp`)
- clé SSH publique : reprise de celle de root, collée, ou importée depuis `github.com/<user>.keys`
- fuseau horaire, hostname
- installation de Docker (optionnelle, script officiel get.docker.com), avec ou sans accès au groupe `docker`
- utilisateur dédié Coolify (optionnel, `coolify` par défaut) pour connecter le serveur à un Coolify central, selon la [doc non-root user](https://coolify.io/docs/core/infrastructure/servers/non-root-user) : clé publique générée dans Coolify, sudo sans mot de passe, `/data/coolify`, ajouté à `AllowUsers`
- fichier swap (optionnel, 4 Go par défaut, taille modifiable, `vm.swappiness=10`), ignoré si un swap existe déjà
- sauvegardes chiffrées [restic](https://restic.net) (optionnel) vers une ou plusieurs cibles : stockage S3 (Cloudflare R2, Backblaze B2, Wasabi...), rest-server ou SFTP (NAS, serveur central)
- verrouillage des autres comptes de l'image cloud (`ubuntu`...), sauvegarde quotidienne de `/etc`, redémarrage automatique à 4h après une mise à jour du noyau

## Lancer une seule étape

Une fois la configuration de base faite, certaines étapes peuvent être lancées seules, en passant leur nom en paramètre (depuis l'utilisateur admin, avec `sudo`) :

| Étape     | Ce qu'elle fait |
|-----------|-----------------|
| `docker`  | installe Docker Engine + Compose (get.docker.com), rotation des logs, groupe `docker` optionnel pour l'utilisateur qui lance `sudo` |
| `coolify` | crée l'utilisateur Coolify (clé, sudo sans mot de passe, `/data/coolify`) et l'ajoute à `AllowUsers` dans `/etc/ssh/sshd_config.d/00-hardening.conf` |
| `backup`  | sauvegarde quotidienne de `/etc` à 2h dans `/opt/backups` (14 jours) |
| `restic`  | installe restic (binaire officiel, SHA256 vérifié), configure les cibles et la sauvegarde quotidienne (voir plus bas) |
| `swap`    | crée `/swapfile` (4 Go par défaut), l'ajoute à `/etc/fstab`, `vm.swappiness=10` |

Exemple Coolify (générer d'abord la clé dans Coolify : Keys & Tokens > Private Keys > Generate ED25519) :

```bash
curl -fsSL https://github.com/bahaa-mn/vps-setup/releases/download/v1.1.1/setup.sh | sudo bash -s -- coolify
```

Puis dans Coolify : Servers > Add, avec l'IP du VPS, le port SSH, l'utilisateur `coolify` et la clé générée.

Exemple Docker :

```bash
curl -fsSL https://github.com/bahaa-mn/vps-setup/releases/download/v1.1.1/setup.sh | sudo bash -s -- docker
```

## Sauvegardes restic

Chaque serveur envoie lui-même ses sauvegardes vers chaque cible configurée (par exemple un NAS local et R2) : si une cible est en panne, les autres continuent d'être alimentées. Les données sont chiffrées sur le serveur avant l'envoi.

- Cibles : `/etc/restic/targets/<nom>.env` (identifiants) et `<nom>.pass` (mot de passe du dépôt). **Garder une copie des mots de passe hors du serveur** : sans eux, aucune restauration possible.
- Dossiers sauvegardés : `/etc/restic/paths` (par défaut `/etc /home /root /data /var/lib/docker/volumes`, les absents sont ignorés). Les bases de données doivent être exportées (dump) dans un de ces dossiers.
- Planification : timer systemd `restic-backup.timer`, chaque nuit entre 2h30 et 3h. Logs : `journalctl -u restic-backup`
- Rétention (7 jours, 4 semaines, 6 mois) appliquée depuis le serveur seulement si demandé pour la cible. Pour une cible en append-only (rest-server `--append-only`), le nettoyage (`restic forget --prune`) se fait depuis la machine qui a les droits complets.
- rest-server : lancé avec `--private-repos`, chaque serveur a son utilisateur et son dépôt `/<utilisateur>/`.
- SFTP : une clé `/etc/restic/id_ed25519` est générée, sa clé publique est à ajouter sur la cible.

Commandes utiles :

```bash
sudo restic-backup                                   # sauvegarde vers toutes les cibles
sudo restic-backup nas snapshots                     # liste des sauvegardes d'une cible
sudo restic-backup r2 restore latest --target /tmp/restore --include /etc/nginx
sudo restic-backup r2 check                          # vérifie l'intégrité du dépôt
```

## Après le script

- Connexion : `ssh -p <port> <user>@<ip>`
- Seul l'utilisateur créé peut se connecter (`AllowUsers`). Pour en ajouter un : `/etc/ssh/sshd_config.d/00-hardening.conf`
- Avant de redémarrer SSH, le script vérifie avec `sshd -T` que root, les mots de passe et `AllowUsers` sont bien appliqués pour chaque compte : un bloc `Match`, un `Include` absent ou un autre `AllowUsers` dans la config existante arrête le script (le filet de sécurité restaure alors l'accès initial)
- Cible restic en `http://` hors de la machine locale : une confirmation est demandée, car les identifiants y circulent en clair. Préférer `https://` ou un tunnel VPN
- Docker contourne UFW : publier les ports des conteneurs sur `127.0.0.1` ou utiliser le pare-feu de l'hébergeur
