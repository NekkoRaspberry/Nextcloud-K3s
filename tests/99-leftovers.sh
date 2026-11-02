#!/usr/bin/env bash
# Did the tests clean up after themselves? (run last)
source "$(dirname "$0")/lib.sh"
echo "== 99 Leftovers"

check_fails "no test users left" users_match "nctest[a-z]*"
check_fails "no test files left" \
  kubectl exec -n "$NS" deploy/nextcloud -c nextcloud -- sh -c 'ls -d /var/www/html/data/nctest*'

finish
