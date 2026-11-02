#!/usr/bin/env bash
# Did the tests clean up after themselves? (run last)
source "$(dirname "$0")/lib.sh"
echo "== 99 Leftovers"

check_fails "no test users left" users_match "nctest[a-z]*"
check "no background jobs left for test users" test -z "$(jobs_for 'nctest[a-z]*')"
check_fails "no test files left" \
  kubectl exec -n "$NS" deploy/nextcloud -c nextcloud -- sh -c 'ls -d /var/www/html/data/nctest*'

check_fails "no test backups left" sh -c "ls -d '$BACKUP'/test_*"
check "no test backup jobs left" \
  test -z "$(kubectl get jobs -n "$NS" -o name | grep nextcloud-backup-test-)"
check_fails "no restore pod left" kubectl get pod -n "$NS" nextcloud-restore

finish
