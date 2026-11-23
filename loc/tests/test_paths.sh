#!/usr/bin/env bash
# Path classification: each case is one file in a directory of its own.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0
cases=0

# check_path <path> <content> <category> [<lines>] [executable]
check_path() {
  local path="$1" content="$2" category="$3" expected="${4:-1}" executable="${5:-}" output
  cases=$((cases + 1))
  local dir="$scratch/$cases"
  mkdir -p "$dir/$(dirname "$path")"
  printf '%s\n' "$content" >"$dir/$path"
  if [[ -n "$executable" ]]; then
    chmod +x "$dir/$path"
  fi
  if output="$(bash "$ROOT_DIR/loc.sh" "$dir" 2>&1)" \
    && grep -Eq "\"total\": .*\"$category\": ${expected}[,}]" <<<"$output"; then
    printf 'PASS: %s is %s\n' "$path" "$category"
  else
    printf 'FAIL: %s expected %s %s line(s):\n%s\n' "$path" "$expected" "$category" "$output" >&2
    failures=$((failures + 1))
  fi
}

check_path infra/main.hcl 'name = "example"' code
check_path Dockerfile.alpine 'FROM scratch' other
check_path .nvmrc '22' other
check_path .tool-versions 'nodejs 22.0.0' other
check_path Justfile 'default: build' other
check_path schema.graphql 'type Query { hello: String }' code
check_path .prettierrc '{}' other
check_path tests/selftest.sh 'echo test' tests

# Common config formats. An unknown one exits 2 with "unrecognized file
# type", which would stop the table on an ordinary edit.
check_path .just/common.just 'default: build' other
check_path .just/caps/docker.just 'docker-build: build' other
check_path .npmrc 'registry=https://example.invalid' other
check_path .gitleaksignore 'abc123:path/to/file:generic-api-key:1' other
check_path terraform/.tflintignore 'terraform/vendor' other
check_path .python-version '3.13' other
check_path .envrc 'export EXAMPLE=1' other
check_path .semrelrc '{}' other
check_path configs/connect/connect-distributed.properties 'group.id=connect' other
check_path units/mirror.service '[Unit]' other
check_path units/disk-metric.timer '[Timer]' other
check_path terraform/environments/prod/module.version '1.2.3' other
check_path seed/order.jq '.items | sort_by(.id)' other
check_path alembic/README 'Generic single-database configuration.' docs

# A generated artefact is classified by what it generates, not by the templating
# language wrapped around it.
check_path clients/templates/endpoint_module.py.jinja 'value = 1' code
check_path alembic/script.py.mako 'revision = "abc"' code
check_path bootstrap/db-startup.sh.tpl 'echo starting' code
check_path reports/report_template.md.j2 '# Report' docs
check_path configs/ecs/task-definition.json.template '{"family": "x"}' other
check_path config/config.toml.example 'key = "value"' other
check_path .env.development.local.template 'EXAMPLE=1' other
check_path clients/templates/api_params.mustache '{{name}}: {{type}}' other
check_path bootstrap/broker-user-data.cloud-config.tftpl 'runcmd:' other

# Binary formats classify before any line is read. A NUL-free placeholder does
# not exercise this: it is the NUL check that a real font or archive hits first.
check_binary() {
  local path="$1" output
  cases=$((cases + 1))
  local dir="$scratch/$cases"
  mkdir -p "$dir/$(dirname "$path")"
  printf '\000\001\002binary content\000' >"$dir/$path"
  if output="$(bash "$ROOT_DIR/loc.sh" "$dir" 2>&1)" \
    && grep -Fq '"total": {"files": 0, "binary_files": 1,' <<<"$output"; then
    printf 'PASS: %s is a binary file\n' "$path"
  else
    printf 'FAIL: %s expected one binary file:\n%s\n' "$path" "$output" >&2
    failures=$((failures + 1))
  fi
}
check_binary vendor/libfoo/lib/libfoo.a
check_binary public/fonts/Montserrat-Regular.ttf
# A vendored generated client arrives as a packed archive.
check_binary vendor/clients/api-client-2.1.0.tgz
check_binary vendor/clients/api-client-2.1.0.tar.gz
check_binary vendor/clients/api-client.zip
check_binary libs/api-client.jar
check_binary vendor/wheels/api_client-2.1.0-py3-none-any.whl
check_binary vendor/clients/api-client-2.1.0.tar.xz
check_binary fixtures/events.json.gz
check_binary vendor/clients/api-client-2.1.0.tar.zst
check_binary data/sample.parquet
# Names match in any case.
check_binary assets/Logo.PNG
check_binary vendor/clients/API-CLIENT.TGZ
# Every binary and archive name is a binary file here, in lower and in upper
# case, so none of them stops the Added lines table.
parity_names='.7z
.a
.avif
.avro
.bin
.bmp
.bz2
.class
.db
.dll
.dylib
.eot
.exe
.gem
.gif
.gz
.heic
.ico
.jar
.jpeg
.jpg
.m4a
.mo
.mov
.mp3
.mp4
.nupkg
.o
.ogg
.otf
.parquet
.pdf
.png
.psd
.pyc
.so
.sqlite
.tar
.tar.bz2
.tar.gz
.tar.xz
.tar.zst
.tgz
.tif
.tiff
.ttf
.war
.wasm
.wav
.webm
.webp
.whl
.woff
.woff2
.xz
.zip
.zst'
parity_count=57
while IFS= read -r suffix; do
  check_binary "parity/sample${suffix}"
  check_binary "parity/UPPER$(printf '%s' "$suffix" | tr '[:lower:]' '[:upper:]')"
done <<<"$parity_names"

# A shebang classifies a script whatever its mode bit.
check_path scripts/python/_git-env '#!/usr/bin/env bash
echo sanitizing' code 2

# A sourced shell file has no shebang, because it never runs. A ShellCheck
# shell directive on its first line is its marker. This one is mode 100644 and named so
# that the path classifier does not know it.
check_path .just/scripts/python/_git-env '# shellcheck shell=bash
# Sourced, not run.
unset GIT_DIR GIT_WORK_TREE' code 1
check_path .just/scripts/python/_git-env-comments '# shellcheck shell=bash
# Sourced, not run.
unset GIT_DIR GIT_WORK_TREE' comments 2
check_path lib/_quote '# shellcheck disable=SC2034 shell=sh
cat <<EOF
# a heredoc line, not a comment
EOF' code 3
# The directive reaches an executable file under a config name,
# the same as a shebang does.
check_path scripts/hooks/setup.env '# shellcheck shell=dash
export EXAMPLE=1' code 1 executable
# A CRLF line ending ends the value at the carriage return, which is a space
# character, so a file saved on Windows keeps its shell classification.
check_path lib/_crlf $'# shellcheck shell=bash\r\nunset GIT_DIR' code 1
# ShellCheck 0.11 parses a quoted value, and knows busybox, bats and the ksh
# variants as shells; each counts as its family, heredocs included.
check_path lib/_quoted "# shellcheck shell='bash'
unset GIT_DIR" code 1
check_path lib/_double-quoted '# shellcheck shell="sh"
unset GIT_DIR' code 1
check_path lib/_busybox '# shellcheck shell=busybox
cat <<EOF
# a heredoc line, not a comment
EOF' code 3
check_path lib/_ash '# shellcheck shell=ash
unset GIT_DIR' code 1
check_path lib/_bats '# shellcheck shell=bats
cat <<EOF
# a heredoc line, not a comment
EOF' code 3
check_path lib/_ksh93 '# shellcheck shell=ksh93
unset GIT_DIR' code 1

# A file with neither marker is unknown. The directive counts only on the
# first line, the same bound as a shebang, so a later one is not a marker.
check_path lib/_unmarked '# Sourced, not run.
unset GIT_DIR' unknown 2
check_path lib/_late-directive '# Sourced, not run.
# shellcheck shell=bash
unset GIT_DIR' unknown 3
check_path lib/_other-directive '# shellcheck disable=SC2034
unset GIT_DIR' unknown 2
check_path lib/_fish '# shellcheck shell=fish
set -x GIT_DIR' unknown 2
check_path lib/_empty-shell '# shellcheck shell=
unset GIT_DIR' unknown 2
# zsh is a shebang interpreter but not a ShellCheck dialect, so the directive
# does not classify it.
check_path lib/_zsh '# shellcheck shell=zsh
unset GIT_DIR' unknown 2
# A `#` ends the directive, so a shell= in a trailing comment is not one, and
# a value in an unmatched quote is not a shell.
check_path lib/_comment-shell '# shellcheck disable=SC2034 # note shell=bash
unset GIT_DIR' unknown 2
check_path lib/_open-quote "# shellcheck shell='bash
unset GIT_DIR" unknown 2

expected_cases=$((64 + 2 * parity_count))
[[ "$cases" -eq "$expected_cases" && "$failures" -eq 0 ]] || {
  printf 'FAIL: %s cases ran with %s failures; expected %s cases and no failures\n' "$cases" "$failures" "$expected_cases" >&2
  exit 1
}
printf 'PASS: all %s common path classifications\n' "$expected_cases"
