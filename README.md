# vps-setup

Initialisation et sécurisation d'un VPS Ubuntu neuf en une commande : utilisateur sudo avec clé SSH, durcissement SSH (root interdit, clé uniquement, port au choix), UFW, Fail2ban, mises à jour de sécurité automatiques, sauvegarde de `/etc`.

Le script pose ses questions au début, affiche un récapitulatif, puis fait tout sans intervention. Le port 22 reste ouvert tant que la connexion sur le nouveau port n'a pas été testée, et un filet de sécurité restaure la config SSH initiale si rien n'est validé dans les 30 minutes.

## Utilisation

Sur le VPS, connecté en root (ou avec un utilisateur sudo) :

```bash
curl -fsSL https://raw.githubusercontent.com/bahaa-mn/vps-setup/main/setup.sh | sudo bash
```

## Ce que le script demande

- nom de l'utilisateur admin et son mot de passe (pour `sudo` et la console de l'hébergeur, pas pour SSH)
- port SSH (22 par défaut)
- ports à ouvrir dans UFW (`80,443` par défaut, plages et UDP acceptés : `8000:8100/udp`)
- clé SSH publique : reprise de celle de root, collée, ou importée depuis `github.com/<user>.keys`
- fuseau horaire, hostname
- installation de Docker (optionnelle, script officiel get.docker.com), avec ou sans accès au groupe `docker`
- utilisateur dédié Coolify (optionnel, `coolify` par défaut) pour connecter le serveur à un Coolify central, selon la [doc non-root user](https://coolify.io/docs/core/infrastructure/servers/non-root-user) : clé publique générée dans Coolify, sudo sans mot de passe, `/data/coolify`, ajouté à `AllowUsers`
- verrouillage des autres comptes de l'image cloud (`ubuntu`...), sauvegarde quotidienne de `/etc`, redémarrage automatique à 4h après une mise à jour du noyau

## Lancer une seule étape

Une fois la configuration de base faite, certaines étapes peuvent être lancées seules, en passant leur nom en paramètre (depuis l'utilisateur admin, avec `sudo`) :

| Étape     | Ce qu'elle fait |
|-----------|-----------------|
| `docker`  | installe Docker Engine + Compose (get.docker.com), rotation des logs, groupe `docker` optionnel pour l'utilisateur qui lance `sudo` |
| `coolify` | crée l'utilisateur Coolify (clé, sudo sans mot de passe, `/data/coolify`) et l'ajoute à `AllowUsers` dans `/etc/ssh/sshd_config.d/00-hardening.conf` |
| `backup`  | sauvegarde quotidienne de `/etc` à 2h dans `/opt/backups` (14 jours) |

Exemple Coolify (générer d'abord la clé dans Coolify : Keys & Tokens > Private Keys > Generate ED25519) :

```bash
curl -fsSL https://raw.githubusercontent.com/bahaa-mn/vps-setup/main/setup.sh | sudo bash -s -- coolify
```

Puis dans Coolify : Servers > Add, avec l'IP du VPS, le port SSH, l'utilisateur `coolify` et la clé générée.

Exemple Docker :

```bash
curl -fsSL https://raw.githubusercontent.com/bahaa-mn/vps-setup/main/setup.sh | sudo bash -s -- docker
```

## Après le script

- Connexion : `ssh -p <port> <user>@<ip>`
- Seul l'utilisateur créé peut se connecter (`AllowUsers`). Pour en ajouter un : `/etc/ssh/sshd_config.d/00-hardening.conf`
- Docker contourne UFW : publier les ports des conteneurs sur `127.0.0.1` ou utiliser le pare-feu de l'hébergeur
