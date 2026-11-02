#!/usr/bin/env bash
# Run every test on the Pi and print a summary.
# 03 restarts Nextcloud once (about a minute).
# Usage: ./run-all.sh
cd "$(dirname "$0")"
source ./lib.sh

FAILED=()
for TEST in [0-9][0-9]-*.sh; do
  bash "$TEST" || FAILED+=("$TEST")
  echo
done

# Remove the temporary test namespace
kubectl delete namespace "$TEST_NS" --ignore-not-found >/dev/null

if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "FAILED: ${FAILED[*]}"
  exit 1
fi
