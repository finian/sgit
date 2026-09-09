#!/usr/bin/env bash
# Run every test file and report a combined result.
set -u
cd "$(dirname "$0")" || exit 1

total=0
failed=0
for f in t[0-9]*.sh; do
	printf '%s\n' "$f"
	if bash "$f"; then :; else failed=$((failed + 1)); fi
	total=$((total + 1))
done

printf '\n%d file(s), %d failing\n' "$total" "$failed"
[ "$failed" = 0 ]
