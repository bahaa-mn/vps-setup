# Sécurité : vps-setup

Ce document dit ce que le script protège, ce qu'il ne peut pas faire à votre place, et les limites connues.

## Ce qui est protégé

| Risque | Protection |
|---|---|
| Connexion SSH par mot de passe ou en root | clé uniquement, root interdit, `AllowUsers`, vérifiés par `sshd -T` pour chaque compte avant le redémarrage de SSH |
| Se couper l'accès en changeant de port | le port 22 reste ouvert tant que le nouveau port n'est pas validé ; un minuteur restaure la config SSH du début du lancement au bout de 30 minutes sans validation (instantané neuf à chaque lancement), et le script revérifie après votre réponse qu'il n'a pas tourné |
| Force brute | Fail2ban : l'adresse est bannie sur tous les ports (action `ufw` d'Ubuntu) |
| Comptes de l'image cloud (`ubuntu`...) | verrouillés |
| Compte existant détourné | un compte système (UID hors de la plage de `login.defs`, `nobody` compris) est refusé ; un compte existant n'est repris qu'après confirmation, et comme utilisateur Coolify il ne garde que la clé de Coolify |
| Clés élargies à la copie | les clés reprises de root gardent leurs options (`command=`, `from=`...) ; les lignes commentées sont ignorées |
| Liens symboliques dans un dossier personnel | les clés sont écrites en tant que l'utilisateur, jamais en root dans son dossier |
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
- [ ] si le script signale un bloc `Match` : le relire avant de confirmer. `sshd -T` ne vérifie qu'une connexion type, un `Match Address`, `LocalAddress` ou `LocalPort` sur un autre réseau peut réautoriser root ou les mots de passe
- [ ] réemployer un compte existant comme admin seulement s'il vous appartient : il garde son mot de passe et ses clés

## Limites connues

- **Docker est installé par `get.docker.com`**, sans épinglage de clé : on fait confiance au serveur de Docker au moment de l'installation.
- **Relancer la configuration restic d'une cible existante en laissant le mot de passe vide** en génère un nouveau, qui remplace l'ancien `.pass` : le dépôt déjà initialisé sur la cible devient illisible pour le serveur. Saisir le mot de passe existant, ou sauvegarder l'ancien `.pass` avant.
- **Le minuteur de secours restaure la config SSH du début du lancement**, y compris l'accès root si l'image l'autorisait au premier lancement : c'est voulu (ne jamais perdre l'accès), mais il faut valider dans les 30 minutes.
- Le script vise un VPS Ubuntu neuf. Sur un serveur déjà configuré, la vérification `sshd -T` arrête le script plutôt que d'écraser une config qui contredit le durcissement.

## Audits

- Octobre 2026, premier passage (profil standard) : une faille confirmée (minuteur de secours déclenché pendant la validation), corrigée ; deux pistes (cibles `http://`, politique `sshd` effective) vérifiées et corrigées ; Fail2ban vérifié, conforme.
- Octobre 2026, second passage : correctifs du premier confirmés ; trois failles (compte Coolify existant qui gardait ses clés, instantané SSH d'un ancien lancement, options des clés root retirées) et trois pistes (release publiée sans les correctifs, blocs `Match` hors de la connexion type, liens symboliques dans un dossier personnel), toutes corrigées.

## Signaler une faille

Par un avis de sécurité privé sur GitHub (onglet Security du dépôt), pas par une issue publique.
