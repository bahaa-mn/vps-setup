# Sécurité : vps-setup

Ce document dit ce que le script protège, ce qu'il ne peut pas faire à votre place, et les limites connues.

## Ce qui est protégé

| Risque | Protection |
|---|---|
| Connexion SSH par mot de passe ou en root | clé uniquement, root interdit, `AllowUsers`, vérifiés par `sshd -T` pour chaque compte avant le redémarrage de SSH |
| Se couper l'accès en changeant de port | le port 22 reste ouvert tant que le nouveau port n'est pas validé ; un minuteur restaure la config SSH initiale au bout de 30 minutes sans validation, et le script revérifie après votre réponse qu'il n'a pas tourné |
| Force brute | Fail2ban : l'adresse est bannie sur tous les ports (action `ufw` d'Ubuntu) |
| Comptes de l'image cloud (`ubuntu`...) | verrouillés |
| Compte système détourné | un nom d'utilisateur qui correspond à un compte système (UID hors de la plage de `login.defs`, `nobody` compris) est refusé ; un compte existant ne reçoit le sudo sans mot de passe de Coolify qu'après confirmation |
| Script modifié après publication | releases immuables, SHA256 et attestation GitHub vérifiables |
| Binaire restic modifié | SHA256 vérifié |
| Sauvegardes lues sur la cible | chiffrées par restic sur le serveur avant l'envoi |

## À faire de votre côté

- [ ] lancer le script depuis une release (URL du README), vérifiée par SHA256 ou `gh release verify-asset`, pas depuis `main`
- [ ] tester la connexion sur le nouveau port **dans un second terminal** avant de répondre oui
- [ ] garder une copie des mots de passe restic (`/etc/restic/targets/*.pass`) hors du serveur : sans eux, aucune restauration possible
- [ ] cible restic en `http://` : seulement dans un tunnel VPN (NetBird, WireGuard) ou un réseau de confiance. Sinon le mot de passe rest-server passe en clair et les requêtes S3 peuvent être rejouées
- [ ] rest-server : le lancer en `--append-only` et `--private-repos`, le nettoyage se faisant depuis une machine de confiance. Un serveur compromis ne peut alors pas effacer ses sauvegardes
- [ ] Docker contourne UFW : publier les ports des conteneurs sur `127.0.0.1`, ou filtrer avec le pare-feu de l'hébergeur
- [ ] Coolify : clé propre à ce serveur. L'utilisateur Coolify a sudo sans mot de passe : la clé vaut un accès root
- [ ] ne pas réécrire `/etc/ssh/sshd_config.d/00-hardening.conf` à la main sans relancer `sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|allowusers'`

## Limites connues

- **Docker est installé par `get.docker.com`**, sans épinglage de clé : on fait confiance au serveur de Docker au moment de l'installation.
- **Relancer la configuration restic d'une cible existante en laissant le mot de passe vide** en génère un nouveau, qui remplace l'ancien `.pass` : le dépôt déjà initialisé sur la cible devient illisible pour le serveur. Saisir le mot de passe existant, ou sauvegarder l'ancien `.pass` avant.
- **Le minuteur de secours restaure la config SSH initiale**, y compris l'accès root si l'image l'autorisait : c'est voulu (ne jamais perdre l'accès), mais il faut valider dans les 30 minutes.
- Le script vise un VPS Ubuntu neuf. Sur un serveur déjà configuré, la vérification `sshd -T` arrête le script plutôt que d'écraser une config qui contredit le durcissement.

## Audits

- Octobre 2026, premier passage (profil standard) : une faille confirmée (minuteur de secours déclenché pendant la validation), corrigée ; deux pistes (cibles `http://`, politique `sshd` effective) vérifiées et corrigées ; Fail2ban vérifié, conforme.

## Signaler une faille

Par un avis de sécurité privé sur GitHub (onglet Security du dépôt), pas par une issue publique.
