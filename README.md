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
- verrouillage des autres comptes de l'image cloud (`ubuntu`...), sauvegarde quotidienne de `/etc`, redémarrage automatique à 4h après une mise à jour du noyau

## Après le script

- Connexion : `ssh -p <port> <user>@<ip>`
- Seul l'utilisateur créé peut se connecter (`AllowUsers`). Pour en ajouter un : `/etc/ssh/sshd_config.d/00-hardening.conf`
- Docker contourne UFW : publier les ports des conteneurs sur `127.0.0.1` ou utiliser le pare-feu de l'hébergeur
