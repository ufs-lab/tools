#!/usr/bin/env bash
# Comment and multi-line literal state, one language construct for each case.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0
cases=0

# assert_counts <file name> <code> <comments> <description> <line>...
assert_counts() {
  local name="$1" code="$2" comments="$3" description="$4" output
  cases=$((cases + 1))
  local dir="$scratch/$cases"
  mkdir -p "$dir/src"
  printf '%s\n' "${@:5}" >"$dir/src/$name"
  output="$(bash "$ROOT_DIR/loc.sh" "$dir")"
  grep -Fq "\"total\": {\"files\": 1, \"binary_files\": 0, \"lines\": {\"code\": $code, \"comments\": $comments, \"tests\": 0," <<<"$output" || {
    printf 'FAIL: expected %s code and %s comment lines for %s:\n%s\n' "$code" "$comments" "$description" "$output" >&2
    failures=$((failures + 1))
  }
}

assert_counts pod.pl 1 3 'a Perl POD block' '=pod' 'POD explanation' '=cut' 'print "ok";'

assert_counts Nested.kt 2 4 'a nested Kotlin block comment' 'fun example() {' '  /* outer' '  /* nested */' '  nested explanation' '  */' '}'

assert_counts Text.jsx 8 1 'JSX text and a JSX expression comment' \
  'export const view = (' \
  '  <div>' \
  '    // visible JSX text' \
  '    {' \
  '      // JSX expression comment' \
  '      value' \
  '    }' \
  '  </div>' \
  ');'

assert_counts Escaped.swift 4 1 'an escaped Swift multiline delimiter' 'let payload = """' '\"""' '// escaped Swift delimiter data' '"""' '// a real Swift comment'

assert_counts ScriptString.vue 4 1 'a Vue closing tag inside a JavaScript string' \
  '<template><div /></template>' \
  '<script>' \
  'const snippet = "</script>";' \
  '// Vue script comment' \
  '</script>'

assert_counts raw.cpp 3 1 'a C++ raw string with a custom delimiter' 'const char* payload = R"tag(' '// C++ raw-string data' ')tag";' '// a real C++ comment'

assert_counts Comment.vue 5 1 'a Vue script opener inside an HTML comment' '<template>' '<!-- <script> is documentation -->' '<div>' '// visible template text' '</div>' '</template>'

# shellcheck disable=SC1003
assert_counts splice.c 3 1 'a C string across spliced physical lines' 'const char* payload = "first \' '// literal payload \' 'last";' '// real comment'

# shellcheck disable=SC2016
assert_counts heredoc.pl 4 1 'a Perl heredoc and a subsequent comment' "my \$payload = <<'PAYLOAD';" '# literal payload' 'PAYLOAD' '# real comment' 'print $payload;'

[[ "$cases" -eq 9 && "$failures" -eq 0 ]] || {
  printf 'FAIL: %s language cases ran with %s failures; expected 9 cases and no failures\n' "$cases" "$failures" >&2
  exit 1
}
printf 'PASS: all 9 language cases\n'
