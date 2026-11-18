# Guide d'exécution : mettre le projet en route, lot par lot

Ce guide explique **dans quel ordre lancer quoi** sur ta machine (WSL2 Ubuntu). Chaque lot a une
**preuve** à garder pour le rapport (capture ou sortie de commande). Ne passe au lot suivant que
quand la preuve du précédent est obtenue.

> Les noms entre `< >` sont à remplacer, **sans** les `< >`.
> Pour toute commande qui attend un secret (`read -s`), lance-la **seule** sur sa ligne.

## 0. Avant de commencer

| À avoir | Pourquoi | Comment |
|---|---|---|
| Compte GitHub | dépôt, pull requests, webhook | github.com |
| Compte Docker Hub + jeton | publier l'image | hub.docker.com → Account settings → Personal access tokens (droits Read & Write) |
| Dépôt Docker Hub **public** `legeni-webapp` | Minikube doit pouvoir télécharger l'image sans identifiants | créé automatiquement au premier `docker push` (le mettre en *Public*) |
| Ansible | provisionner et déployer | `sudo apt install -y ansible python3-kubernetes` |
| Ressources | Jenkins + Minikube | 4 vCPU et 8 Go de RAM conseillés (minimum raisonnable : 6 Go libres) |

Dans `Jenkinsfile`, remplace `TON_ID_DOCKERHUB` par ton identifiant Docker Hub (une seule ligne).

> **Machine vierge.** Le sujet demande que `provision.yml` fonctionne sur une machine vierge. Pour
> la preuve du lot 2, le plus propre est une VM Ubuntu 24.04 neuve (VirtualBox ou Multipass).
> Sur ton poste WSL où Docker est déjà installé, lance seulement `--tags minikube,jenkins`.

## Lot 0 : Git

```bash
cd ~/legeni-webapp
git init -b main
git add . && git commit -m "feat: dépôt initial Legeni WebApp (app, Dockerfile, Ansible, Jenkinsfile)"
git remote add origin https://github.com/<ton_id_github>/legeni-webapp.git
git push -u origin main
```

Protéger `main` (GitHub → *Settings* → *Branches* → *Add branch protection rule*) :
- Branch name pattern : `main`
- Cocher *Require a pull request before merging*
- Cocher *Require status checks to pass before merging* et choisir le build Jenkins (le contrôle apparaît après le premier build de PR, étape du lot 4)

Travailler ensuite **uniquement en branches** `feature/...` :
```bash
git switch -c feature/couleur-1-1-0
```

**Preuve :** capture de la règle de protection, capture d'une PR, `git tag` (voir lot 5).

## Lot 1 : Conteneurisation

```bash
cd ~/legeni-webapp
docker build --target test -t legeni-webapp:test .                       # flake8 + pytest dans l'image
docker build --build-arg APP_VERSION=1.0.0-local -t legeni-webapp:1.0.0-local .
docker run --rm -i hadolint/hadolint:v2.12.0 < Dockerfile; echo "hadolint rc=$?"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy_cache:/root/.cache \
  aquasec/trivy:0.57.1 image --no-progress --severity CRITICAL --ignore-unfixed --exit-code 1 \
  legeni-webapp:1.0.0-local; echo "trivy rc=$?"
```

Si le scan Trivy échoue avec `tls: bad record MAC` pendant le téléchargement de la base, c'est le
réseau (voir *Dépannage*). Réessayer sur une autre connexion.

**Preuve :** `hadolint rc=0`, rapport Trivy sans CRITICAL corrigeable (`trivy rc=0`),
`docker images` montrant un tag de la forme `<VERSION>-<build>` (jamais `latest` en production).

## Lot 2 : Infrastructure as Code (Ansible)

1. Générer les secrets chiffrés :
   ```bash
   ./scripts/init-secrets.sh
   git add ansible/vars/vault.yml && git commit -m "chore: secrets Redis chiffrés (Ansible Vault)"
   ```
   `.vault_pass` est ignoré par Git : **sauvegarde-le hors du dépôt** (sans lui, `vault.yml` est illisible).
2. Provisionner (deux fois, pour prouver l'idempotence) :
   ```bash
   cd ansible
   ansible-playbook provision.yml --ask-become-pass
   ansible-playbook provision.yml --ask-become-pass | tee ../docs/preuve-idempotence.txt
   ```
   Le second passage doit finir par `changed=0` (hors tâches de vérification).
3. Vérifier : `minikube status`, `kubectl get nodes`, `http://localhost:8080` (Jenkins).

**Preuve :** les deux sorties de `provision.yml` (le `PLAY RECAP` du second passage avec
`changed=0`), `cat ansible/vars/vault.yml | head -2` (commence par `$ANSIBLE_VAULT`).

## Lot 3 : Déploiement Kubernetes (à la main, avant Jenkins)

Il faut une image **publiée** sur Docker Hub :
```bash
read -s DOCKERHUB_TOKEN                      # seule sur sa ligne, puis coller le jeton
echo "$DOCKERHUB_TOKEN" | docker login -u <ton_id_dockerhub> --password-stdin
docker tag legeni-webapp:1.0.0-local <ton_id_dockerhub>/legeni-webapp:1.0.0-1
docker push <ton_id_dockerhub>/legeni-webapp:1.0.0-1
```
Déployer en staging puis en prod :
```bash
cd ~/legeni-webapp/ansible
ansible-playbook deploy.yml -e target_env=staging -e app_image=<ton_id_dockerhub>/legeni-webapp \
  -e app_version=1.0.0-1 --vault-password-file ../.vault_pass
ansible-playbook deploy.yml -e target_env=prod -e app_image=<ton_id_dockerhub>/legeni-webapp \
  -e app_version=1.0.0-1 --vault-password-file ../.vault_pass
kubectl get all,pvc -n legeni-staging
kubectl get all,pvc -n legeni-prod
minikube service webapp -n legeni-staging --url
```
**Test du rollback :** déployer une version inexistante en prod (attendre environ 3 minutes) :
```bash
ansible-playbook deploy.yml -e target_env=prod -e app_image=<ton_id_dockerhub>/legeni-webapp \
  -e app_version=9.9.9 --vault-password-file ../.vault_pass
kubectl get deploy webapp -n legeni-prod -o wide        # l'image est revenue à 1.0.0-1
```
Le playbook se termine en **échec** (c'est voulu : Jenkins doit passer au rouge).

**Preuve :** `kubectl get all` des deux namespaces, sortie du rollback, `kubectl get secret redis-secret -n legeni-prod`.

## Lot 4 : Intégration continue (Jenkins)

1. Dans Jenkins (`http://localhost:8080`), **Manage Jenkins → Credentials → Global → Add Credentials** :

   | ID | Type | Contenu |
   |---|---|---|
   | `registry-credentials` | Username with password | identifiant Docker Hub + jeton |
   | `kubeconfig` | Secret file | `/opt/legeni/kubeconfig-jenkins.yml` |
   | `ansible-vault-pass` | Secret file | `.vault_pass` |
   | `notify-webhook` | Secret text | (facultatif) URL de webhook Discord |

   Pour déposer un fichier : copier d'abord les fichiers là où le navigateur peut les choisir, par
   exemple `cp /opt/legeni/kubeconfig-jenkins.yml /mnt/c/Users/<toi>/Downloads/`.
2. **New Item → Multibranch Pipeline** → *Branch Sources* : GitHub (ou Git avec l'URL du dépôt) →
   *Discover branches* et *Discover pull requests*. Script Path : `Jenkinsfile`.
3. Webhook GitHub : Jenkins doit être joignable depuis Internet. Avec `ngrok http 8080` (ou
   smee.io), puis GitHub → *Settings* → *Webhooks* → *Add webhook* → Payload URL
   `https://<adresse_ngrok>/github-webhook/`, type `application/json`, événements *Push* et
   *Pull requests*. Sans webhook, le bouton *Scan Repository Now* de Jenkins fait l'affaire pour la démo.

**Preuve :** capture du *Stage View* (les 4 contrôles en parallèle), onglets *Tests*, *Coverage*
et *Warnings*, build de PR vert sans stage de déploiement.

## Lot 5 : Déploiement continu

Merger une PR dans `main` : Jenkins enchaîne *Push registre → staging → validation (bouton
**Déployer**) → production*. À chaque mise en production, poser le tag Git :
```bash
git switch main && git pull
git tag -a v$(cat VERSION) -m "Mise en production $(cat VERSION)" && git push origin v$(cat VERSION)
```

**Preuve :** capture du bouton de validation, `kubectl get deploy webapp -n legeni-prod -o wide`,
notification reçue (si webhook configuré).

## Scénario de soutenance (à répéter au moins une fois)

| # | Action | Résultat attendu |
|---|---|---|
| 1 | Dans un terminal : `./scripts/zero-downtime-check.sh "<url_prod>/ready"`. Puis branche `feature/v1-1-0` : changer `VERSION` en `1.1.0` et la couleur (`app_color` dans `ansible/vars/*.yml`, ou vider `app_color` et changer la couleur par défaut dans `app.py`), ouvrir une PR | build vert sur la PR, **pas de déploiement** |
| 1 bis | Merger la PR | staging mis à jour, clic sur **Déployer**, prod mise à jour ; le script affiche `0 erreur` |
| 2 | Branche avec un test qui échoue (`assert False` dans `tests/test_app.py`) | pipeline **rouge** à l'étape *Tests + couverture*, aucune image produite, prod inchangée |
| 3 | Dans `ansible/vars/prod.yml`, décommenter `readiness_path: /nope`, merger, valider la prod | `deploy.yml` échoue, rollback visible dans la console, la prod répond toujours en version précédente |
| 4 | Question surprise | savoir expliquer chaque fichier du dépôt (voir `docs/rapport.md`) |

Penser à **remettre** `readiness_path` en commentaire après le scénario 3.

## Dépannage (problèmes déjà rencontrés)

| Symptôme | Cause | Solution |
|---|---|---|
| `Could not resolve host: github.com` dans la console Jenkins | DNS du conteneur (Docker sous WSL2) | déjà corrigé par `jenkins_dns` dans le rôle `jenkins` ; sinon ajouter `dns: [8.8.8.8, 1.1.1.1]` au service dans `docker-compose.yml` |
| `Couldn't find any revision to build` | branche `*/master` alors que le dépôt utilise `main` | corriger le *Branch Specifier* |
| Trivy : `tls: bad record MAC` pendant le téléchargement de la base | réseau instable ou intercepté | changer de connexion (partage de téléphone), relancer ; en dernier recours décocher le paramètre `SCAN_SECURITE` du job et le noter dans le rapport |
| `password is empty` à `docker login` | `read -s` collé avec la ligne suivante | lancer `read -s DOCKERHUB_TOKEN` **seul**, coller le jeton, Entrée, puis la ligne `docker login` |
| `port is already allocated` | port 5000, 8080 ou 8092 déjà utilisé | `docker ps` puis arrêter le conteneur, ou changer le port hôte |
| `ImagePullBackOff` dans Kubernetes | dépôt Docker Hub privé ou tag absent | mettre le dépôt en *Public*, vérifier le tag publié |
| `kubectl` échoue depuis Jenkins | Jenkins pas sur le réseau `minikube` | `docker network connect minikube jenkins` (déjà fait par `provision.yml`) |
