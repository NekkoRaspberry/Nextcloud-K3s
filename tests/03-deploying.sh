#!/usr/bin/env bash
# Is the file valid, does the cluster match it, and do users and files survive a restart?
# NOTE: restarts Nextcloud once (about a minute).
source "$(dirname "$0")/lib.sh"
echo "== 03 Deploying"

check "manifest is valid (server dry-run)" kubectl apply --dry-run=server -f "$ROOT/nextcloud.yaml"
# kubectl diff returns 0 when the cluster matches the file exactly
check "cluster matches the file (no drift)" kubectl diff -f "$ROOT/nextcloud.yaml"

# Upload a file, restart Nextcloud, check the user and the file are still there
P=nctestp
PASS_P="$(openssl rand -hex 16)"
cleanup() { has_user "$P" && user_del "$P" >/dev/null 2>&1; }
trap 'cleanup; client_stop' EXIT
client_start
cleanup

user_add "$P" "$PASS_P" >/dev/null
dav "$P" "$PASS_P" PUT "$P/nctest.txt" "before restart" >/dev/null

echo "  ...restarting Nextcloud"
kubectl rollout restart deployment/nextcloud -n "$NS" >/dev/null
check "Nextcloud comes back Ready after restart" \
  kubectl rollout status deployment/nextcloud -n "$NS" --timeout=300s
check "still installed after restart" contains "$(status)" '"installed":true'
check "users survive a restart"       test "$(dav "$P" "$PASS_P" PROPFIND "$P/")" = 207
check "files survive a restart"       test "$(dav_get "$P" "$PASS_P" "$P/nctest.txt")" = "before restart"

finish
