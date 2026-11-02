#!/usr/bin/env bash
# Restore Nextcloud's files from a backup folder. FILES ADDED SINCE THAT BACKUP ARE REMOVED.
# Usage: ./restore.sh <backup/data/date> [user] [--yes]
#   with a user:    only that user's files (e.g. after deleting a folder by mistake)
#   without a user: everything (restore the database from the same night first, see README)
set -euo pipefail
# Use ~/.kube/config on the Pi
if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/config" ]]; then export KUBECONFIG="$HOME/.kube/config"; fi

FOLDER="${1:-}"
USER_NAME="${2:-}"
[[ "$USER_NAME" == "--yes" ]] && USER_NAME=""
if [[ -z "$FOLDER" || ! -f "$FOLDER/config/config.php" ]]; then
  echo "Usage: $0 <backup/data/date> [user] [--yes]"
  exit 1
fi
FOLDER="$(cd "$FOLDER" && pwd)"   # the restore pod needs the full path
if [[ -n "$USER_NAME" && ! -d "$FOLDER/data/$USER_NAME" ]]; then
  echo "No files for user '$USER_NAME' in $FOLDER."
  exit 1
fi

# Ask before overwriting, unless --yes was given
if [[ " $* " != *" --yes "* ]]; then
  WHAT="${USER_NAME:-everything}"
  read -r -p "This replaces $WHAT with the backup from $(basename "$FOLDER"). Type '$WHAT' to confirm: " ANSWER
  [[ "$ANSWER" == "$WHAT" ]] || { echo "Cancelled."; exit 1; }
fi

occ() { kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c "php /var/www/html/occ $*"; }

# What to copy back (files go back to Nextcloud's user, www-data)
RSYNC="rsync -a --delete --chown=33:33 --chmod=D750,F640"
if [[ -n "$USER_NAME" ]]; then
  COPY="$RSYNC /backup/data/$USER_NAME/ /nextcloud/data/$USER_NAME/"
else
  COPY="$RSYNC --exclude=/data/appdata_*/preview/ --exclude=/data/nextcloud.log \
    /backup/config /backup/data /backup/custom_apps /backup/themes /nextcloud/"
  occ maintenance:mode --on >/dev/null   # nobody changes files during the restore
fi

# Copy with a short-lived pod that sees both the backup folder and Nextcloud's storage
IMAGE="$(kubectl get deploy -n nextcloud nextcloud -o jsonpath='{.spec.template.spec.containers[0].image}')"
POD=nextcloud-restore
kubectl delete pod -n nextcloud "$POD" --ignore-not-found >/dev/null
kubectl run "$POD" -n nextcloud --restart=Never --image="$IMAGE" --overrides='{
  "spec": {
    "containers": [{
      "name": "restore", "image": "'"$IMAGE"'", "command": ["sh", "-c", "'"$COPY"'"],
      "securityContext": {"allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"], "add": ["CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER"]}},
      "volumeMounts": [{"name": "backup", "mountPath": "/backup", "readOnly": true},
                       {"name": "nextcloud", "mountPath": "/nextcloud"}]
    }],
    "volumes": [{"name": "backup", "hostPath": {"path": "'"$FOLDER"'", "type": "Directory"}},
                {"name": "nextcloud", "persistentVolumeClaim": {"claimName": "nextcloud-data"}}]
  }}' >/dev/null

# Wait until the copy is finished (max 30 minutes)
PHASE=""
for _ in $(seq 1 900); do
  PHASE="$(kubectl get pod -n nextcloud "$POD" -o jsonpath='{.status.phase}')"
  [[ "$PHASE" == Succeeded || "$PHASE" == Failed ]] && break
  sleep 2
done
kubectl logs -n nextcloud "$POD"
kubectl delete pod -n nextcloud "$POD" >/dev/null
if [[ "$PHASE" != Succeeded ]]; then
  echo "Restore FAILED (status: $PHASE). Nextcloud may still be in maintenance mode."
  exit 1
fi

# Tell Nextcloud which files exist now
if [[ -n "$USER_NAME" ]]; then
  occ files:scan "$USER_NAME" >/dev/null
else
  occ maintenance:mode --off >/dev/null
  occ files:scan --all >/dev/null
  occ files:scan-app-data >/dev/null           # Nextcloud's own files (themes, avatars...)
  occ maintenance:data-fingerprint >/dev/null   # tells the apps to re-sync
fi

echo "Restored ${USER_NAME:-everything} from $FOLDER"
