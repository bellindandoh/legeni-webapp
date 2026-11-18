#!/bin/bash
# Génère les mots de passe Redis (staging et prod) et les chiffre avec Ansible Vault.
#   ./scripts/init-secrets.sh
# Résultat :
#   .vault_pass            mot de passe Vault (gitignoré, À SAUVEGARDER hors du dépôt)
#   ansible/vars/vault.yml fichier chiffré ($ANSIBLE_VAULT;1.1;AES256), à commiter
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f ansible/vars/vault.yml ]; then
    echo "ansible/vars/vault.yml existe déjà : rien à faire (supprimez-le pour le régénérer)."
    exit 0
fi

if [ ! -f .vault_pass ]; then
    openssl rand -base64 24 > .vault_pass
    chmod 600 .vault_pass
    echo "Mot de passe Vault généré dans .vault_pass (ne PAS le commiter, le sauvegarder ailleurs)."
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
---
vault_redis_password_staging: "$(openssl rand -hex 16)"
vault_redis_password_prod: "$(openssl rand -hex 16)"
EOF

ansible-vault encrypt --vault-password-file .vault_pass --output ansible/vars/vault.yml "$TMP"
echo "OK : ansible/vars/vault.yml chiffré."
head -1 ansible/vars/vault.yml
