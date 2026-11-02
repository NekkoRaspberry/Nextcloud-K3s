#!/usr/bin/env bash
# Can users log in and use their files, and are their files private?
# Creates temporary users and deletes them (and their files) at the end.
source "$(dirname "$0")/lib.sh"
echo "== 02 Users"

A=nctesta
B=nctestb
PASS_A="$(openssl rand -hex 16)"
PASS_B="$(openssl rand -hex 16)"

cleanup() {
  for U in "$A" "$B"; do
    has_user "$U" && user_del "$U" >/dev/null 2>&1
  done
  reset_bruteforce
}
trap 'cleanup; client_stop' EXIT
client_start
cleanup   # start from a clean state

check "creates user A"                  user_add "$A" "$PASS_A"
check "creates user B"                  user_add "$B" "$PASS_B"

check "A can log in"                    test "$(dav "$A" "$PASS_A" PROPFIND "$A/")" = 207
check "B can log in"                    test "$(dav "$B" "$PASS_B" PROPFIND "$B/")" = 207
check "A can upload a file"             test "$(dav "$A" "$PASS_A" PUT "$A/nctest.txt" "hello from A")" = 201
check "A can download the file"         test "$(dav_get "$A" "$PASS_A" "$A/nctest.txt")" = "hello from A"
check_fails "B cannot read A's files"   test "$(dav "$B" "$PASS_B" GET "$A/nctest.txt")" = 200
check "wrong password is rejected"      test "$(dav "$A" wrongpassword PROPFIND "$A/")" = 401

check "deletes user B"                         user_del "$B"
check "deleted user can no longer log in"      test "$(dav "$B" "$PASS_B" PROPFIND "$B/")" = 401
check_fails "deleted user's files are removed" \
  kubectl exec -n "$NS" deploy/nextcloud -c nextcloud -- test -e "/var/www/html/data/$B"
check "other users keep working"               test "$(dav_get "$A" "$PASS_A" "$A/nctest.txt")" = "hello from A"

finish
