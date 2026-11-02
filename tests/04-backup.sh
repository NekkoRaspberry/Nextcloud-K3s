#!/usr/bin/env bash
# Does a backup really work? Upload -> backup -> lose the file -> restore -> file is back.
# The test backup goes to its own test_ folder (never replaces a real backup),
# only the test user is restored, and everything is deleted at the end.
source "$(dirname "$0")/lib.sh"
echo "== 04 Backup & restore"

U=nctestbk
PASS_U="$(openssl rand -hex 16)"

cleanup() {
  has_user "$U" && user_del "$U" >/dev/null 2>&1
  rm -rf "$BACKUP"/test_*
  kubectl get jobs -n "$NS" -o name | grep '/nextcloud-backup-test-' \
    | xargs -r kubectl delete -n "$NS" --cascade=foreground >/dev/null 2>&1
}
trap 'cleanup; client_stop' EXIT
client_start
cleanup

# Fingerprint of all real backups (names, sizes, times), to prove the test does not change them
real_backups() { (cd "$BACKUP" && find . -path './test_*' -prune -o -type f -printf '%p %s %T@\n' | sort); }
BEFORE="$(real_backups)"
LATEST="$(ls -1d "$BACKUP"/20??-??-?? 2>/dev/null | tail -n 1)"

check "backup CronJob exists" kubectl get cronjob -n "$NS" nextcloud-backup

# Test data
user_add "$U" "$PASS_U" >/dev/null
dav "$U" "$PASS_U" PUT "$U/nctest.txt" "precious" >/dev/null

check "test backup job succeeds" "$ROOT/backup/backup-now.sh" --test

TESTDIR="$(ls -1d "$BACKUP"/test_* 2>/dev/null | grep -v '\.partial' | tail -n 1)"
check "test backup folder created"         test -n "$TESTDIR"
check "settings are backed up (config.php)" test -s "$TESTDIR/config/config.php"
check "user files are backed up" \
  test "$(cat "$TESTDIR/data/$U/files/nctest.txt" 2>/dev/null)" = precious
check "backup files are private (owner only)" \
  test "$(stat -c '%U %a' "$TESTDIR/data/$U/files/nctest.txt")" = "$(id -un) 600"
check_fails "previews are not backed up" sh -c "ls -d '$TESTDIR'/data/appdata_*/preview"
if [[ -n "$LATEST" ]]; then
  check "unchanged files take no extra space (hard links)" \
    test "$(stat -c %i "$TESTDIR/data/.ncdata")" = "$(stat -c %i "$LATEST/data/.ncdata")"
else warn "no real backup yet, hard links not checked"; fi
check_fails "no unfinished (.partial) backups left" sh -c "ls -d '$BACKUP'/*.partial"
check "real backups were not changed" test "$(real_backups)" = "$BEFORE"

# Simulate losing the file, then restore only this user
check "test file deleted"        test "$(dav "$U" "$PASS_U" DELETE "$U/nctest.txt")" = 204
check "restore.sh runs (one user)" "$ROOT/backup/restore.sh" "$TESTDIR" "$U" --yes
check "restored file is correct" test "$(dav_get "$U" "$PASS_U" "$U/nctest.txt")" = precious
check_fails "restore pod is removed" kubectl get pod -n "$NS" nextcloud-restore
check "Nextcloud is not left in maintenance mode" contains "$(status)" '"maintenance":false'
check "real backups were not changed by the restore" test "$(real_backups)" = "$BEFORE"

finish
