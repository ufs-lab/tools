#!/usr/bin/env bash
# Shell heredocs: a payload line and a terminator are code, never a comment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/src"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'cat <<EOF' \
  '# unquoted payload' \
  'EOF' \
  "cat <<'SINGLE'" \
  '# single-quoted payload' \
  'SINGLE' \
  'cat <<"DOUBLE"' \
  '# double-quoted payload' \
  'DOUBLE' \
  'cat <<\ESCAPED' \
  '# backslash-quoted payload' \
  'ESCAPED' \
  $'cat <<-TABBED' \
  $'\t# tab-stripped payload' \
  $'\tTABBED' \
  "cat <<FIRST <<'SECOND'" \
  '# first queued payload' \
  'FIRST' \
  '# second queued payload' \
  'SECOND' \
  'printf "%s\n" "<<NOT_A_HEREDOC"' \
  "value=\$((8 << 2))" \
  '((value <<= 1))' \
  'cat <<<"# here-string payload"' \
  '# cat <<COMMENT_ONLY' \
  '# ordinary comment after terminators' \
  "value=\"\$(cat <<'SUBSTITUTION'" \
  '# double-quoted command-substitution payload' \
  'SUBSTITUTION' \
  ')"' \
  "eval \"cat <<'EVALUATED'" \
  '# double-quoted evaluated command payload' \
  'EVALUATED' \
  '"' \
  "eval '" \
  '# single-quoted evaluated command payload' \
  "'" \
  'selected="$(' \
  '  case "$mode" in' \
  '    first)' \
  '      :' \
  '     ;&' \
  '    second)' \
  '      :' \
  '     ;;&' \
  '    *)' \
  '      # case body comment' \
  '      case "$nested" in' \
  '        *)' \
  '          # nested case comment' \
  '          :' \
  '          ;;' \
  '      esac' \
  "      cat <<'CASE_PAYLOAD'" \
  '# command-substitution case payload' \
  'CASE_PAYLOAD' \
  '      ;;' \
  '  esac' \
  ')"' \
  'ordinary="$(' \
  "  printf '%s\\n' case in" \
  ')"' \
  '# comment after ordinary case and in arguments' \
  'shifted=$((' \
  '  1 << 2' \
  '))' \
  '# comment after multiline arithmetic' \
  '((' \
  '  2 << 3' \
  '))' \
  '# comment after multiline arithmetic command' \
  'cat <<CONTINUED \' \
  '  /dev/null \' \
  '# command-line continuation comment' \
  'CONTINUED' \
  'cat << \' \
  'SPLIT_DELIMITER' \
  '# split-delimiter payload' \
  'SPLIT_DELIMITER' \
  '# comment after split delimiter terminator' \
  '# ordinary comment after quoted commands' >"$fixture/src/heredocs.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "cat <<'END'" \
  '# extensionless payload' \
  'END' \
  '# extensionless comment after terminator' >"$fixture/src/a-shell-tool"
chmod +x "$fixture/src/a-shell-tool"
printf '%s\n' \
  '# Python remains a hash-comment language, not a shell heredoc language.' \
  'print("ok")' >"$fixture/src/z-comments.py"
bash -n "$fixture/src/heredocs.sh"

output="$(bash "$ROOT_DIR/loc.sh" "$fixture")"
expected='"total": {"files": 3, "binary_files": 0, "lines": {"code": 77, "comments": 12, "tests": 0, "docs": 0, "generated": 0, "other": 0, "unknown": 0, "blank": 0}}'
grep -Fq "$expected" <<<"$output" || {
  printf 'FAIL: expected 77 code lines and the twelve real shell and Python comments:\n%s\n' "$output" >&2
  exit 1
}

printf 'PASS: shell heredoc payloads and terminators are code lines\n'
