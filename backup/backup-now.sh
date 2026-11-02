#!/usr/bin/env bash
# Run a backup immediately (same job as the nightly CronJob) and show the result.
# Usage: ./backup-now.sh          (real backup, replaces today's)
#        ./backup-now.sh --test   (used by the tests: separate test_ folder)
set -euo pipefail
# Use ~/.kube/config on the Pi
if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/config" ]]; then export KUBECONFIG="$HOME/.kube/config"; fi

PREFIX=nextcloud-backup-manual
[[ "${1:-}" == "--test" ]] && PREFIX=nextcloud-backup-test
JOB="$PREFIX-$(date +%Y%m%d%H%M%S)"
kubectl create job -n nextcloud --from=cronjob/nextcloud-backup "$JOB" >/dev/null
echo "Started $JOB, waiting..."

# Wait until the job is Complete or Failed (max 30 minutes, the first backup copies everything)
STATUS=""
for _ in $(seq 1 900); do
  STATUS="$(kubectl get job -n nextcloud "$JOB" -o jsonpath='{.status.conditions[?(@.status=="True")].type}')"
  [[ "$STATUS" == *Complete* || "$STATUS" == *Failed* ]] && break
  sleep 2
done

kubectl logs -n nextcloud "job/$JOB"
if [[ "$STATUS" == *Complete* ]]; then
  echo "Backup succeeded."
else
  echo "Backup FAILED (status: $STATUS)."
  exit 1
fi
