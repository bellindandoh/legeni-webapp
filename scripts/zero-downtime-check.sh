#!/bin/bash
# Preuve de « zéro interruption » pendant un déploiement : interroge l'URL en boucle
# et compte les réponses en erreur. À lancer AVANT le déploiement, à arrêter avec Ctrl+C
# une fois la mise à jour terminée.
#
#   ./scripts/zero-downtime-check.sh "$(minikube service webapp -n legeni-prod --url)/ready"
#
# Sous WSL2 avec le driver docker, laisser `minikube service ... --url` tourner dans un autre
# terminal (tunnel) et utiliser l'adresse 127.0.0.1:<port> qu'il affiche.
URL=${1:?usage: $0 <url> [pause_en_secondes]}
PAUSE=${2:-0.2}
OK=0; KO=0

summary() {
    echo
    echo "Requêtes OK : $OK    Erreurs : $KO"
    [ "$KO" -eq 0 ] && echo "✅ 0 erreur pendant la mise à jour" || echo "❌ des erreurs ont été observées"
    exit "$KO"
}
trap summary INT TERM

while true; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" || true)
    if [ "$CODE" = "200" ]; then OK=$((OK + 1)); else KO=$((KO + 1)); echo "$(date +%T) erreur HTTP $CODE"; fi
    sleep "$PAUSE"
done
