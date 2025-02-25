# Infra PolyCyber

L'objectif de ce repo est de rassembler l'ensemble des ressources utilisées pour déployer les infrastructures CTFd de PolyCyber (PolyPwn, ainsi que CTFd interne à PolyCyber sur les serveurs du STEP). 

### Notes
Les scripts actuellement présents ne prennent pour le moment pas d'arguments à leur exécution : ces changements viendront par la suite.

## Déploiement et paramétrage du serveur

### Installation
Le paramétrage d'un serveur pour déployer un CTFd sur le port `8000` est automatique via le script `ctfd_server_setup.sh`. Ce script est à exécuter en tant que root, mais tentera d'élever automatiquement ses privilèges une fois exécuté. Une fois téléchargé sur le serveur cible, il suffit de lancer les commandes suivantes :
```bash
chmod +x ctfd_server_setup.sh
./ctfd_server_setup.sh
```

### Important
Le script installe Docker, et donne les privilèges d'exécution à l'utilisateur courant. Afin d'assurer que celui-ci puisse immédiatement utiliser les commandes docker après installation, le script termine la session de l'utilisateur sur le serveur post-installation pour rafraichir les droits de l'utilisateur, le script est donc à exécuter deux fois si docker n'est pas déjà installé. 

### Post installation
Une fois CTFd déployé, il sera accessible à l'adresse IP du serveur sur le port `8000`. Afin de paramétrer le plugin Docker, il suffit de se rendre sur la page `Admin Panel -> Plugins -> Docker Config` (une fois l'événement créé sur CTFd), et entrer les informations suivantes :
- Host: `172.17.0.1:2376`
- TLS: `Yes`

Sur cette page de configuration, il est nécessaire de passer des certificats et clefs. Ces certificats sont récupérables depuis le serveur dans une archive compressée au format zip via la commande suivante :
```bash
scp <remote_user>@<server_ip>:/home/<remote_user>/cert/cert.zip <local_path_for_cert>
```
L'archive contient les fichiers `ca-cert.pem`, `client-cert.pem` et `client-key.pem` nécessaires pour la bonne configuration du plugin afin que celui-ci puisse communiquer en TLS à l'API Docker sur le serveur directement. 

Une fois les certificats et clef entrés, appuyer sur le bouton `Submit` en bas de la page. Les images docker actuellement sur le serveur devraient s'actualiser dans la boite `Repositories`. Sélectionner les images pertinentes pour le CTF dans cette boite (Ctrl + Clique ou Shift + Clique), et appuyer de nouveau sur `Submit` pour valider. Les images ainsi sélectionnées seront accessibles pour des challenges par la suite. Pour ajouter de nouvelles images une fois le plugin configuré, réitérer cette étape.


## Installation de challenges sur CTFd
Afin d'installer les challenges automatiquement sur CTFd en passant par les fichiers `challenge.yml`, il est d'abord nécessaire de paramétrer le CTFCLI afin qu'il sache dans quel dossier s'exécuter. Pour se faire, naviguer dans le dossier du repo de challenges depuis le serveur, et lancer : 
```bash
ctf init
```
Il faut ensuite entrer l'URL de CTFd (logiquement `http://127.0.0.1:8000`), et un token admin de CTFd (récupérable sur CTFd, dans `Settings -> Access Tokens -> Generate`). 

Ensuite, exécuter le script d'installation de challenges depuis le dossier du repo : 
```bash
chmod +x challenges_ingest.sh
./challenges_ingest.sh
```
