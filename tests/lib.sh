# shellcheck shell=bash
# Shared helpers for the tests (loaded by each test file, not run directly)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=nextcloud
TEST_NS=nctest           # temporary namespace for the helper pod (deleted by run-all.sh)
CLIENT=nctest-client     # helper pod with curl, acts like a browser or the Nextcloud app
HOST=nextcloud.home.arpa # the name Nextcloud answers to
URL=http://nextcloud.nextcloud.svc.cluster.local
BACKUP="$ROOT/backup/data"  # backup folder on the Pi (hostPath in backup/cronjob.yaml)
FAILS=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
warn() { echo "  WARN  $1"; }

# check "<description>" <command...>  -> PASS if the command succeeds
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# check_fails "<description>" <command...>  -> PASS if the command FAILS
check_fails() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

# contains "<text>" "<part>"  -> succeeds if text contains part
contains() { grep -qF -- "$2" <<< "$1"; }

# Name of the running Nextcloud pod (it changes after every restart)
nextcloud_pod() { kubectl get pod -n "$NS" -l app=nextcloud -o jsonpath='{.items[0].metadata.name}'; }

# Run a Nextcloud command (occ) as the web server user. Usage: occ user:list
occ() { kubectl exec -n "$NS" deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c "php /var/www/html/occ $*"; }

# Is any user name matching this in the user list? (regex allowed, e.g. "nctest[a-z]*")
users_match() { occ user:list | grep -q -- "- $1:"; }

# Does this Nextcloud user exist? (asks the list: "user:info" logs an error for unknown users)
has_user() { users_match "$1"; }

# Create / delete a test user (users are normally managed in the web UI).
# Usage: user_add <name> <password>   (password goes in through stdin, not a command line)
user_add() {
  printf '%s\n' "$2" | kubectl exec -i -n "$NS" deploy/nextcloud -c nextcloud -- sh -c \
    "read -r OC_PASS; export OC_PASS; su -s /bin/sh www-data -c 'php /var/www/html/occ user:add --password-from-env $1'"
}
user_del() { occ user:delete "$1" && jobs_del "$1"; }

# Background jobs Nextcloud queued for a user's files. A deleted user's jobs
# would fail (and fill the log) on the next cron run, so remove them too.
# Usage: jobs_for <user-regex>   jobs_del <user>
jobs_for() { occ background-job:list --limit=1000 | grep -E "\"$1\"" | awk -F'|' '{gsub(/ /, "", $2); print $2}'; }
jobs_del() {
  local ids
  ids="$(jobs_for "$1" | tr '\n' ' ')"
  [[ -z "$ids" ]] && return 0
  # One exec for all jobs; "y" answers the "really delete?" question.
  # A job cron already ran meanwhile is gone: fine (99-leftovers checks nothing is left).
  kubectl exec -n "$NS" deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c \
    "for id in $ids; do echo y | php /var/www/html/occ background-job:delete \$id >/dev/null 2>&1; done; true"
}

# Admin login (Secret nextcloud-admin)
admin_user() { kubectl get secret -n "$NS" nextcloud-admin -o jsonpath='{.data.username}' | base64 -d; }
admin_pass() { kubectl get secret -n "$NS" nextcloud-admin -o jsonpath='{.data.password}' | base64 -d; }

# Helper pod that talks to Nextcloud like a browser would
client_start() {
  kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl run "$CLIENT" -n "$TEST_NS" --restart=Never --image=curlimages/curl:8.22.0 \
    --command -- sleep 600 >/dev/null
  kubectl wait -n "$TEST_NS" --for=condition=Ready "pod/$CLIENT" --timeout=90s >/dev/null
}
client_stop() { kubectl delete pod -n "$TEST_NS" "$CLIENT" --ignore-not-found --grace-period=1 >/dev/null 2>&1; }

# Nextcloud's public status (installed, version, maintenance)
status() { kubectl exec -n "$TEST_NS" "$CLIENT" -- curl -sS --fail -H "Host: $HOST" "$URL/status.php"; }

# Files over WebDAV, like the Nextcloud app. The login goes in through stdin (not a command line).
# Usage: dav <user> <password> <METHOD> <path> [content]   -> prints the HTTP status
#        dav_get <user> <password> <path>                 -> prints the file
dav() {
  printf 'user = "%s:%s"\n' "$1" "$2" | kubectl exec -i -n "$TEST_NS" "$CLIENT" -- \
    curl -s -K - -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H "Depth: 0" -X "$3" \
    ${5:+--data-binary "$5"} "$URL/remote.php/dav/files/$4"
}
dav_get() {
  printf 'user = "%s:%s"\n' "$1" "$2" | kubectl exec -i -n "$TEST_NS" "$CLIENT" -- \
    curl -sS --fail -K - -H "Host: $HOST" "$URL/remote.php/dav/files/$3"
}

# Failed logins slow down the helper pod (brute force protection): reset that
reset_bruteforce() {
  local ip
  ip="$(kubectl get pod -n "$TEST_NS" "$CLIENT" -o jsonpath='{.status.podIP}' 2>/dev/null)"
  [[ -n "$ip" ]] && occ security:bruteforce:reset "$ip" >/dev/null 2>&1
}

# Print the result and exit with 0 (all good) or 1 (something failed)
finish() {
  if [[ "$FAILS" -eq 0 ]]; then echo "  -> all passed"; exit 0
  else echo "  -> $FAILS failed"; exit 1; fi
}
