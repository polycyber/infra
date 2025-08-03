# Infra PolyCyber

L'objectif de ce dépot est de rassembler l'ensemble des ressources utilisées pour déployer les infrastructures CTFd de PolyCyber (PolyPwn, ainsi que CTFd interne à PolyCyber) afin de partager une méthode de déploiement de services fonctionnelle et simplifiée.  

## Scripts Disponibles

### 1. Script d'Installation CTFd (`setup.sh`)

Script Bash qui automatise l'installation et la configuration d'un serveur CTFd avec Docker sécurisé via TLS et utilisant le plugin CTFd-Docker-Challenges.

### 2. Outil de Gestion des Challenges (`challenges_management.sh`)

Script Bash avancé pour la construction, l'ingestion et la synchronisation des challenges CTF avec support des conteneurs Docker.

## Prérequis

### Pour le script d'installation CTFd

- **Systèmes d'exploitation** : Testé et vérifié sous : 
  - Ubuntu Server 24
  - Ubuntu Server 25
  - Debian 12
- **Privilèges** : Le script doit être exécuté en tant que root (utilise sudo automatiquement si nécessaire)

### Pour l'outil de gestion des challenges

- **Docker** : Installé et fonctionnel
- **CTFcli** : Installé via pipx (installation automatique si absent)
- **Dépôt de challenges** : Structure de dossiers avec fichiers `challenge.yml`

> [!CAUTION]
> **📍 Exigence de placement du script** : Le script de gestion des challenges a des exigences de placement spécifiques qui sont **essentielles** pour un fonctionnement correct. Consultez le [guide de placement détaillé](#outil-de-gestion-des-challenges) avant d'exécuter le script.

## Installation du serveur CTFd

1. **Clonez ce dépôt** :
   ```bash
   git clone https://github.com/polycyber/infra
   cd infra
   chmod +x setup.sh challenges_management.sh
   mv challenges_management.sh ..
   ```

2. **Exécutez le script d'installation et suivez les instructions** :
   ```bash
   ./setup.sh --ctfd-url <votre-domaine.com>
   ```

3. **Rendez-vous sur l'URL du serveur configurée**
   - Effectuez la configuration de l'événement CTF
   - Dirigez-vous vers le panneau de configuration administrateur `Admin Panel` --> `Plugins` --> `Docker Config`
   - Entrez les informations suivantes pour initialiser la connexion du plugin à la socket Docker :
     - Hostname: `172.17.0.1:2376`
     - TLS Enabled: `Yes`
     - Récupérez les CA Cert / Client Cert / Client Key depuis le serveur une fois la configuration finie : 
    ```bash
    scp -r <user>@<server_ip>:<working_dir>/cert/cert.zip <local_path>
    ``` 

## Utilisation

### Options du script d'installation

| Option | Description | Obligatoire |
|--------|-------------|-------------|
| `--ctfd-url URL` | URL/domaine de votre serveur CTFd | ✅ Oui |
| `--working-folder DIR` | Répertoire de travail (défaut: `/home/$USER`) | ❌ Non |
| `--theme` | Active l'utilisation d'un thème personnalisé | ❌ Non |
| `--help` | Affiche l'aide | ❌ Non |

#### Exemples d'installation

```bash
# Installation basique avec domaine
./setup.sh --ctfd-url exemple.com

# Installation avec répertoire personnalisé
./setup.sh --ctfd-url exemple.com --working-folder /opt/ctfd

# Installation avec thème personnalisé activé
./setup.sh --ctfd-url exemple.com --theme

# Afficher l'aide
./setup.sh --help
```

#### Configuration du thème personnalisé

Si vous utilisez l'option `--theme`, le script activera automatiquement le montage du dossier de thèmes dans le `docker-compose.yml`. 

> [!WARNING]  
> Vous devez placer votre thème personnalisé dans le dossier `theme/` du répertoire de travail avant de démarrer les conteneurs Docker. Ce dossier sera créé automatiquement durant l'installation.

### Outil de gestion des challenges

> [!WARNING]
> **Exigences de placement du script pour la gestion des challenges**
> 
> Le script de gestion de challenges utilise l'utilitaire `ctfcli`, qui nécessite que les répertoires de challenges soient situés **en dessous** de son point d'exécution dans la hiérarchie du système de fichiers. Cela signifie que le script doit être placé au même niveau que le répertoire des challenges ou dans un répertoire parent.

#### **Exemples de placement correct**

| Composant | Chemin | Statut |
|-----------|--------|--------|
| Challenges | `/home/user/challenges` | ✅ Fonctionne |
| Script | `/home/user/challenges_management.sh` | ✅ Fonctionne |

**Pourquoi cela fonctionne :** Le script est au même niveau que le répertoire des challenges, donc `ctfcli` peut accéder au dossier challenges.

| Composant | Chemin | Statut |
|-----------|--------|--------|
| Challenges | `/home/user/challenges` | ✅ Fonctionne |
| Script | `/home/challenges_management.sh` | ✅ Fonctionne |

**Pourquoi cela fonctionne :** Le script est dans un répertoire parent, donc `ctfcli` peut toujours atteindre le dossier challenges en dessous.

#### **Exemple de placement incorrect**

| Composant | Chemin | Statut |
|-----------|--------|--------|
| Challenges | `/home/user/challenges` | ❌ Échoue |
| Script | `/home/user/infra/challenges_management.sh` | ❌ Échoue |

**Pourquoi cela échoue :** Le script est dans un sous-répertoire (`infra`) qui est au même niveau que `challenges`. Depuis cet emplacement, `ctfcli` ne peut pas accéder au répertoire des challenges car il n'est pas dans le chemin hiérarchique du script.

#### Actions disponibles

| Action | Description |
|--------|-------------|
| `all` | Construction + ingestion (défaut) |
| `build` | Construction des images Docker uniquement |
| `ingest` | Ingestion des challenges dans CTFd |
| `sync` | Synchronisation des challenges existants |
| `status` | Affichage du statut et statistiques |
| `cleanup` | Nettoyage des images Docker |

#### Options principales

| Option | Description | Obligatoire |
|--------|-------------|-------------|
| `--ctf-repo REPO` | Nom du dépôt de challenges présent dans le répertoire de travail | ✅ Oui |
| `--action ACTION` | Action à effectuer (all, build, ingest, sync, status, cleanup) | ❌ Non |
| `--working-folder DIR` | Répertoire de travail (défaut: `/home/$USER`) | ❌ Non |
| `--config FILE` | Charger la configuration depuis un fichier | ❌ Non |

#### Options de filtrage

| Option | Description |
|--------|-------------|
| `--categories LIST` | Liste des catégories à traiter (séparées par virgules) |
| `--challenges LIST` | Liste des challenges spécifiques à traiter (séparés par virgules) |

#### Options de comportement

| Option | Description |
|--------|-------------|
| `--dry-run` | Mode simulation (affiche les actions sans les exécuter) |
| `--force` | Force les opérations (reconstruction, écrasement) |
| `--parallel-builds N` | Nombre de constructions parallèles (défaut: 4) |
| `--backup-before-sync` | Crée une sauvegarde avant synchronisation |

#### Options de debug

| Option | Description |
|--------|-------------|
| `--debug` | Active la sortie de debug |
| `--skip-docker-check` | Ignore la vérification du daemon Docker |
| `--help` | Affiche l'aide |
| `--version` | Affiche les informations de version |

#### Exemples de gestion des challenges

```bash
# Configuration complète (construction + ingestion)
./challenges_management.sh --ctf-repo PolyPwnCTF-2025-challenges

# Construction uniquement pour certaines catégories
./challenges_management.sh --action build --ctf-repo PolyPwnCTF-2025-challenges --categories "web,crypto"

# Synchronisation avec mise à jour forcée
./challenges_management.sh --action sync --ctf-repo PolyPwnCTF-2025-challenges --force

# Mode simulation pour voir les actions prévues
./challenges_management.sh --ctf-repo PolyPwnCTF-2025-challenges --dry-run

# Traitement de challenges spécifiques
./challenges_management.sh --action build --ctf-repo PolyPwnCTF-2025-challenges --challenges "web-challenge-1,crypto-rsa"

# Construction parallèle avec 8 threads
./challenges_management.sh --action build --ctf-repo PolyPwnCTF-2025-challenges --parallel-builds 8

# Affichage du statut
./challenges_management.sh --action status --ctf-repo PolyPwnCTF-2025-challenges

# Nettoyage des images Docker
./challenges_management.sh --action cleanup --ctf-repo PolyPwnCTF-2025-challenges
```

#### Fichier de configuration

Créez un fichier `.env` avec des paires `CLE=VALEUR` :

```bash
CTF_REPO=PolyPwnCTF-2025-challenges
WORKING_DIR=/opt/ctf
PARALLEL_BUILDS=8
FORCE=true
DEBUG=false
```

Utilisation :
```bash
./challenges_management.sh --config .env
```

## Fonctionnement des scripts

### Script d'installation CTFd

#### 1. Mise à jour du système
- Mise à jour des paquets système
- Installation des dépendances

#### 2. Installation de Docker
- Ajout du dépôt officiel Docker
- Installation de Docker CE, Docker Compose...
- Configuration des groupes utilisateurs

#### 3. Installation de pipx
- Installation de pipx pour la gestion des paquets Python (plus spécifiquement CTFcli)

#### 4. Génération des certificats TLS
Le script génère automatiquement :
- **Certificats CA** (Certificate Authority)
- **Certificats serveur** pour Docker daemon
- **Certificats client** pour l'authentification via le plugin CTFd-Docker-Challenges
- **Archive ZIP** contenant les certificats nécessaires

#### 5. Configuration Docker TLS
- Configuration du Docker daemon pour utiliser TLS

#### 6. Configuration des thèmes (optionnel)
Si l'option `--theme` est utilisée :
- Active le montage du dossier `theme/` dans le conteneur CTFd
- Permet l'utilisation de thèmes personnalisés
- Les thèmes doivent être placés manuellement dans le dossier avant le démarrage des conteneurs
  
### Outil de gestion des challenges

#### 1. Vérification des dépendances
- Vérification de la disponibilité de Docker et du daemon
- Contrôle de la présence des outils système requis
- Installation automatique de CTFcli via pipx si nécessaire

#### 2. Découverte des challenges
- Analyse de la structure du dépôt de challenges
- Identification des challenges Docker et statiques

#### 3. Construction des images Docker
- Construction séquentielle ou parallèle des images
- Support du mode `--force` pour reconstruction complète
- Gestion des erreurs avec rapports détaillés

#### 4. Ingestion des challenges
- Installation via CTFcli dans l'instance CTFd

#### 5. Synchronisation
- Mise à jour des challenges existants
- Option de sauvegarde avant synchronisation
- Support du mode `--force` pour écrasement

#### 6. Nettoyage
- Suppression des images Docker associées aux challenges
- Mode dry-run disponible

## Structure des challenges

### Dépôt de challenges attendu

```
repo-challenges/
├── challenges/                    # (optionnel, détecté automatiquement)
│   ├── web/
│   │   ├── challenge-1/
│   │   │   ├── challenge.yml      # Configuration du challenge
│   │   │   ├── Dockerfile         # Image Docker (pour type: docker)
│   │   │   ├── src/               # Code source
│   │   │   └── files/             # Fichiers du challenge
│   │   └── challenge-2/
│   ├── crypto/
│   └── pwn/
```


> [!WARNING]  
> Le script d'ingestion de challenges fonctionne par ordre alphabétique de catégories et de challenges. Si un challenge a des prérequis, il est donc nécessaire d'ingest les prérequis en amont

### Format du fichier `challenge.yml`

```yaml
name: "MonChallenge"
author: Auteur_du_chall
category: AI

description: |-
  ## Description (français)

  Petite description en français

  ## Description (english)

  Small English description

flags:
  - polycyber{flag_a_tr0uv3r}
  
tags:
  - AI
  - A:Auteur_du_chall

requirements:
  - "Règles"

# If files needed
files:
  - "files/hello_world.txt"

# If hints needed, choose the cost
hints:
  - Hint intéressant

value: 500
type: docker                          # ou type: dynamic
extra:
  docker_image: "monchallenge:latest" # requis pour type; docker
  dynamic: True                       # requis pour type; docker
  initial: 500
  decay: 10
  minimum: 50
```

## Configuration générée

### Certificats TLS

Les certificats sont créés dans `${WORKING_DIR}/cert/` :

- `ca-cert.pem` - Certificat de l'autorité de certification
- `ca-key.pem` - Clé privée de l'autorité de certification
- `server-cert.pem` - Certificat du serveur Docker
- `server-key.pem` - Clé privée du serveur Docker
- `client-cert.pem` - Certificat client
- `client-key.pem` - Clé privée client
- `cert.zip` - Archive contenant les certificats nécessaires

### Configuration Docker

Le script configure Docker pour écouter sur :
- `172.17.0.1:2376` (TLS sécurisé)
- Socket Unix par défaut (`fd://`)

### Secrets générés

Le script génère automatiquement :
- **Clé secrète CTFd** (32 caractères)
- **Mot de passe base de données** (16 caractères)
- **Mot de passe root base de données** (16 caractères)
- **Mot de passe CA** (32 caractères)

Ces scripts sont développés par l'équipe PolyCyber pour l'installation automatisée et la gestion de serveurs CTFd.