#!/usr/bin/env bash
# The command line and the JSON: arguments, the file list, and the output bytes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
PASS=0
FAIL=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "PASS: $1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n--- expected\n%s\n--- actual\n%s\n' "$1" "$2" "$3"
  fi
}
loc() { bash "$ROOT_DIR/loc.sh" "$@"; }

# 1. Two directories, every category, and the total, byte for byte.
a="$scratch/a"
b="$scratch/b"
mkdir -p "$a/src" "$a/tests" "$a/docs" "$b"
printf '%s\n' '# a comment' 'x = 1' '' 'y = 2' >"$a/src/main.py"
printf '%s\n' 'assert True' >"$a/tests/test_main.py"
printf '%s\n' '# Title' '' 'Text.' >"$a/docs/guide.md"
printf '%s\n' 'lock: 1' 'lock: 2' >"$a/yarn.lock"
printf '%s\n' 'a: 1' >"$a/config.yml"
printf '%s\n' 'what is this' >"$a/data.xyz"
printf '\000\001' >"$a/blob.xyz"
printf '\000\001' >"$a/logo.png"
ln -s main.py "$a/src/link.py"
printf '%s\n' 'package main' >"$b/main.go"
expected="{
  \"directories\": [
    {\"path\": \"$a\", \"files\": 6, \"binary_files\": 2, \"lines\": {\"code\": 2, \"comments\": 1, \"tests\": 1, \"docs\": 2, \"generated\": 2, \"other\": 1, \"unknown\": 1, \"blank\": 2}},
    {\"path\": \"$b\", \"files\": 1, \"binary_files\": 0, \"lines\": {\"code\": 1, \"comments\": 0, \"tests\": 0, \"docs\": 0, \"generated\": 0, \"other\": 0, \"unknown\": 0, \"blank\": 0}}
  ],
  \"total\": {\"files\": 7, \"binary_files\": 2, \"lines\": {\"code\": 3, \"comments\": 1, \"tests\": 1, \"docs\": 2, \"generated\": 2, \"other\": 1, \"unknown\": 1, \"blank\": 2}}
}"
check 'two directories print every category and the total' "$expected" "$(loc "$a" "$b")"

# 2. In a Git work tree: tracked and untracked files, without ignored ones,
#    and each path is classified from the top of the work tree.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
repo="$scratch/repo"
git init -q "$repo"
mkdir -p "$repo/tests/unit" "$repo/build"
printf '%s\n' 'ignored = 1' >"$repo/build/out.py"
printf '%s\n' 'build/' >"$repo/.gitignore"
printf '%s\n' 'tracked = 1' >"$repo/tracked.py"
printf '%s\n' 'untracked = 1' >"$repo/untracked.py"
printf '%s\n' 'data' >"$repo/tests/unit/case.json"
git -C "$repo" add tracked.py .gitignore
expected='"total": {"files": 4, "binary_files": 0, "lines": {"code": 2, "comments": 0, "tests": 1, "docs": 0, "generated": 0, "other": 1, "unknown": 0, "blank": 0}}'
check 'a work tree counts tracked and untracked files, and no ignored file' "$expected" "$(loc "$repo" | grep -o '"total".*}}')"
expected='"total": {"files": 1, "binary_files": 0, "lines": {"code": 0, "comments": 0, "tests": 1, "docs": 0, "generated": 0, "other": 0, "unknown": 0, "blank": 0}}'
check 'a subdirectory of a work tree keeps the classification of its full path' "$expected" "$(loc "$repo/tests/unit" | grep -o '"total".*}}')"

# 3. A directory name is a JSON string.
odd="$scratch/a \"b\"\\c"$'\t'"d"
mkdir -p "$odd"
check 'a quote, a backslash and a tab in a directory name are escaped' \
  "    {\"path\": \"$scratch/a \\\"b\\\"\\\\c\\u0009d\", \"files\": 0, \"binary_files\": 0, \"lines\": {\"code\": 0, \"comments\": 0, \"tests\": 0, \"docs\": 0, \"generated\": 0, \"other\": 0, \"unknown\": 0, \"blank\": 0}}" \
  "$(loc "$odd" | sed -n 3p)"

# 4. Bad arguments exit 2, name the fault, and print no JSON.
set +e
out="$(loc 2>"$scratch/err")"
status=$?
set -e
check 'no argument is a usage error' "2||loc: usage: loc.sh <directory>..." "$status|$out|$(cat "$scratch/err")"
set +e
out="$(loc "$a" "$scratch/missing" 2>"$scratch/err")"
status=$?
set -e
check 'a missing directory exits 2 by name with no output' "2||loc: '$scratch/missing' is not a directory" "$status|$out|$(cat "$scratch/err")"

echo "loc cli: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -eq 6 ]
