#!/usr/bin/env bash
# Is Nextcloud running, installed, protected and using the shared services? (changes nothing)
source "$(dirname "$0")/lib.sh"
echo "== 01 Running"

trap client_stop EXIT
client_start
POD="$(nextcloud_pod)"
LAN="$(kubectl get svc -n kube-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

check "Nextcloud pod is Ready (web + cron)" \
  kubectl wait -n "$NS" --for=condition=Ready "pod/$POD" --timeout=10s
check "storage (PVC) is Bound" \
  test "$(kubectl get pvc -n "$NS" nextcloud-data -o jsonpath='{.status.phase}')" = Bound
check "service is internal only (ClusterIP)" \
  test "$(kubectl get svc -n "$NS" nextcloud -o jsonpath='{.spec.type}')" = ClusterIP
check "home network address is $HOST" \
  test "$(kubectl get ingress -n "$NS" nextcloud -o jsonpath='{.spec.rules[0].host}')" = "$HOST"
check "secrets exist (admin, database, email)" \
  kubectl get secret -n "$NS" nextcloud-admin nextcloud-db nextcloud-email

STATUS="$(status)"
check "Nextcloud is installed"         contains "$STATUS" '"installed":true'
check "not in maintenance mode"        contains "$STATUS" '"maintenance":false'
check "no database upgrade pending"    contains "$STATUS" '"needsDbUpgrade":false'
check "Nextcloud version is 34.0.5"    contains "$STATUS" '"versionstring":"34.0.5"'

check "uses the shared PostgreSQL" \
  test "$(occ config:system:get dbhost)" = postgres.databases.svc.cluster.local
check "database answers"               occ user:list
check "sends email through the shared Mailpit" \
  test "$(occ config:system:get mail_smtphost)" = mailpit.email.svc.cluster.local

check "files refuse access without login" test "$(dav "" "" PROPFIND "")" = 401
check "admin can log in"                  test "$(dav "$(admin_user)" "$(admin_pass)" PROPFIND "$(admin_user)/")" = 207
check "HTTPS works on the home network ($LAN)" contains \
  "$(kubectl exec -n "$TEST_NS" "$CLIENT" -- curl -sk --resolve "$HOST:443:$LAN" "https://$HOST/status.php")" '"installed":true'

# Background jobs switch to cron after the first run (5 minutes after install)
if [[ "$(occ config:app:get core backgroundjobs_mode)" == cron ]]; then pass "background jobs run by cron"
else warn "background jobs not on cron yet (first run 5 minutes after install)"; fi

# Memory of the web container: below 80% of the 1Gi limit
MEM="$(kubectl top pod -n "$NS" "$POD" --containers --no-headers 2>/dev/null | awk '$2 == "nextcloud" {print $4}' | tr -d 'Mi')"
if [[ -z "$MEM" ]]; then warn "memory usage unknown (metrics not ready yet)"
elif [[ "$MEM" -lt 819 ]]; then pass "memory usage ${MEM}Mi (< 80% of limit)"
else fail "memory usage ${MEM}Mi (>= 80% of 1Gi limit)"; fi

finish
