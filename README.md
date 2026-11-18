# Legeni WebApp : chaîne CI/CD complète

Application Flask + Redis déployée automatiquement du commit à la production :
Git → Jenkins (tests, analyse, build, scan, push) → Ansible → Kubernetes (staging puis production).

| Besoin | Où regarder |
|---|---|
| Mettre le projet en route, lot par lot | [`docs/GUIDE_EXECUTION.md`](docs/GUIDE_EXECUTION.md) |
| Rapport final (architecture, pipeline, choix) | [`docs/rapport.md`](docs/rapport.md) |
| Pipeline | [`Jenkinsfile`](Jenkinsfile) |
| Installation de l'infrastructure | [`ansible/provision.yml`](ansible/provision.yml) |
| Déploiement Kubernetes | [`ansible/deploy.yml`](ansible/deploy.yml) |

Démarrage rapide :
```bash
./scripts/init-secrets.sh                      # secrets Redis chiffrés (Ansible Vault)
cd ansible && ansible-playbook provision.yml --ask-become-pass
```

Version courante : voir [`VERSION`](VERSION).
