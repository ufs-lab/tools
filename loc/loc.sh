#!/usr/bin/env bash
# Counts the lines of the files in one or more directories, by category, and
# prints the counts as JSON.
#
# Usage: loc.sh <directory>...
#
# In a Git work tree it reads the tracked files and the untracked files that
# .gitignore does not leave out, and classifies each path from the top of the
# work tree. Elsewhere it reads every regular file, and classifies each path
# from the directory. A symbolic link is not read.
#
# Each file is read whole, so a line in a block comment, in a string that
# spans lines or in a heredoc is counted for what it is.
set -euo pipefail
# The files need not be text in the caller's locale, and the C locale makes
# the output the same bytes on every host.
LC_ALL=C
export LC_ALL
if [ "$#" -eq 0 ]; then
  echo 'loc: usage: loc.sh <directory>...' >&2
  exit 2
fi
scratch_dir="$(mktemp -d)"
trap 'rm -rf "$scratch_dir"' EXIT

# A generated artefact is classified by what it generates: `endpoint_module.py.jinja`
# holds Python, `task-definition.json.template` holds config. Strip one template
# suffix and classify the name underneath. What the script cannot parse is the
# template syntax, not the target language, so a template of something it does not
# recognise is config rather than a hard stop.
strip_template_suffix() {
  case "$1" in
    *.template | *.tmpl | *.tpl | *.tftpl | *.j2 | *.jinja | *.jinja2 | *.mustache | *.mako | *.example | *.sample)
      printf '%s\n' "${1%.*}"
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Where a path lands, before any line is read. Explicit test filenames come
# before source extensions. Source extensions come before generic test, fixture,
# and docs directories: a directory name cannot hide executable source lines.
# Comment syntax is per language: "#" opens a comment in a shell or Python
# file and an attribute in Rust or a directive in Swift.
source_kind_for_name() {
  case "$1" in
    *.vue) echo vue ;;
    *.ts | *.tsx | *.mts | *.cts | *.js | *.jsx | *.mjs | *.cjs | *.go | *.rs | *.java | *.kt | *.swift | *.c | *.h | *.cc | *.cpp | *.cxx | *.hh | *.hpp | *.hxx | *.cs | *.scala | *.proto) echo c ;;
    *.lua) echo lua ;;
    *.tf | *.hcl) echo terraform ;;
    *.py | *.sh | *.bash | *.zsh | *.ksh | *.rb | *.pl | *.graphql | *.gql) echo hash ;;
    *.sql) echo sql ;;
    *) return 1 ;;
  esac
}

category_of() {
  local raw="$1"
  local file templated=0
  file="$(strip_template_suffix "$raw")"
  [ "$file" = "$raw" ] || templated=1
  local name="${file##*/}"
  local source_kind
  case "$name" in
    pnpm-lock.yaml | package-lock.json | yarn.lock | go.sum | Cargo.lock | poetry.lock | uv.lock | .terraform.lock.hcl)
      echo other
      return
      ;;
  esac
  if [[ "$file" =~ \.(test|spec)\.[cm]?[jt]sx?$ || "$file" =~ _test\.go$ || "$name" == conftest.py ||
    "$file" =~ (^|/)test_[^/]*\.(py|sh)$ || "$file" =~ _test\.py$ || "$file" =~ \.test\.sh$ ||
    "$file" =~ (^|/)tests?/.*\.(py|sh|bash|zsh|ksh|[cm]?[jt]sx?)$ ||
    "$file" =~ (^|/)src/(test|testFixtures)/(java|kotlin|scala)/.*\.(java|kt|scala)$ ||
    "$file" =~ (^|/)tests?/.*\.rs$ ]]; then
    echo tests
  elif [[ "$file" =~ (^|/)(requirements|constraints)([-_.][^/]*)?\.txt$ ]]; then
    echo other
  elif [[ "$name" =~ ^(LICENSE|LICENCE|COPYING)([.-].*)?$ ]]; then
    echo docs
  elif source_kind="$(source_kind_for_name "$name")"; then
    echo "$source_kind"
  elif [[ "$file" =~ (^|/)__(fixtures|mocks|snapshots|tests)__/ ||
    "$file" =~ (^|/)(playwright|tests?|fixtures|testdata)/ ]]; then
    echo tests
  elif [[ "$file" =~ \.(md|mdx|txt|rst)$ || "$file" =~ (^|/)docs/ ]]; then
    echo docs
  else
    case "$name" in
      *.yml | *.yaml | *.json | *.jsonc | *.toml | *.tfvars | *.lock | *.ini | *.cfg | *.conf | *.csv | *.tsv | *.psv | *.dat | *.xml | *.html | *.css | *.scss | *.svg | *.png | *.jpg | *.jpeg | *.gif | *.ico | *.webp | *.woff | *.woff2 | *.ttf | *.otf | *.wasm | *.pdf | *.bin | *.a | *.so | *.dylib) echo other ;;
      Dockerfile | Dockerfile.* | Makefile | justfile | Justfile | .nvmrc | .tool-versions | .prettierrc | Jenkinsfile | CODEOWNERS | go.mod | go.work | .gitignore | .gitattributes | .dockerignore | .npmignore | .editorconfig | .env.example) echo other ;;
      # More config formats. `*.just` is a recipe module, and takes `justfile`'s
      # answer above. The remaining names are ignore files and single-value config.
      *.just | *.properties | *.service | *.timer | *.version | *.sha256 | *.manifest | *.patch | *.env | *.jq) echo other ;;
      .gitkeep | .npmrc | .python-version | .envrc | .env.* | .semrelrc | .swaggo | .gitmodules | editorconfig) echo other ;;
      .gitleaksignore | .prettierignore | .tflintignore | .mintignore | docker.ignore) echo other ;;
      README | NOTICE | CHANGELOG) echo docs ;;
      # A template of a type nothing above recognises is config. The alternative,
      # reporting it as unknown, hides a file whose target language is unknowable
      # from its name, which is exactly what the suffix already told us.
      *) if ((templated)); then echo other; else echo unknown; fi ;;
    esac
  fi
}

# binary_name <path> succeeds for a binary format or a vendored archive (a
# packed tarball, a jar), counted by name before its NUL bytes are read, in
# any case.
binary_name() {
  case "$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')" in
    *.png | *.jpg | *.jpeg | *.gif | *.ico | *.webp | *.bmp | *.avif | *.heic | *.tif | *.tiff | *.psd | \
      *.mp3 | *.mp4 | *.m4a | *.mov | *.wav | *.ogg | *.webm | *.woff | *.woff2 | *.ttf | *.otf | *.eot | *.wasm | *.pdf | \
      *.bin | *.a | *.o | *.so | *.dylib | *.dll | *.exe | *.class | *.pyc | *.mo | *.sqlite | *.db | *.parquet | *.avro | \
      *.tgz | *.tar.gz | *.tar | *.tar.bz2 | *.tar.xz | *.tar.zst | *.gz | *.bz2 | *.xz | *.zst | *.zip | *.jar | *.war | *.whl | *.gem | *.nupkg | *.7z)
      return 0
      ;;
  esac
  return 1
}

# classify <path> <mode> <file> counts the lines of the file into c, m, t, d, o
# and b, and sets unknown to 1 for a type or interpreter it cannot name.
classify() {
  local file="$1" new_mode="$2" head_file="$3"
  unknown=0
  kind="$(category_of "$file")"
  # Every language test below reads the path with its template suffix removed,
  # so the parser matches the classification category_of just made.
  classify_path="$(strip_template_suffix "$file")"
  first_line="$(sed -n '1p' "$head_file")"
  interpreter=''
  marked=0
  # An executable file is a script whatever it is called, and an
  # unrecognised name with a shebang is a script whether or not the mode bit
  # survived. A sourced shell file never runs, so it has no shebang; ShellCheck's
  # `# shellcheck shell=<shell>` directive is its marker, and it is read from the
  # same first line.
  if [[ "$kind" == unknown || ("$kind" == other && "$new_mode" == 100755) ]]; then
    if [[ "$first_line" == '#!'* ]]; then
      marked=1
      shebang="${first_line#\#!}"
      read -r -a shebang_words <<<"$shebang"
      if ((${#shebang_words[@]} > 0)); then
        interpreter="${shebang_words[0]##*/}"
      fi
      if [[ "$interpreter" == env ]]; then
        interpreter=''
        for shebang_word in "${shebang_words[@]:1}"; do
          if [[ "$shebang_word" == -* || "$shebang_word" == *=* ]]; then
            continue
          fi
          interpreter="${shebang_word##*/}"
          break
        done
      fi
    elif [[ "$first_line" =~ ^#[[:space:]]*shellcheck[[:space:]]([^#]*[[:space:]])?shell=([^[:space:]#]*) ]]; then
      marked=1
      # ShellCheck ends a directive at a `#`, takes the value in one pair of
      # quotes, and knows these shells (0.11).
      # Each maps to the shebang name its family counts as; any other value
      # takes the unrecognized-interpreter refusal below.
      interpreter="${BASH_REMATCH[2]}"
      if [[ "$interpreter" =~ ^\'(.*)\'$ || "$interpreter" =~ ^\"(.*)\"$ ]]; then
        interpreter="${BASH_REMATCH[1]}"
      fi
      case "$interpreter" in
        sh | bash | dash | ash | ksh) ;;
        bats) interpreter='bash' ;;
        busybox) interpreter='sh' ;;
        ksh88 | ksh93 | oksh) interpreter='ksh' ;;
        *) interpreter='' ;;
      esac
    fi
  fi
  if ((marked)); then
    case "$interpreter" in
      sh | bash | dash | ash | zsh | ksh | python | python[0-9]* | pypy | pypy[0-9]* | ruby | perl | awk | gawk | Rscript) kind='hash' ;;
      node | nodejs | deno | bun) kind='c' ;;
      *)
        kind='other'
        unknown=1
        ;;
    esac
  elif [[ "$kind" == unknown ]]; then
    kind='other'
    unknown=1
  fi
  shell_heredocs=0
  if [[ "$classify_path" =~ \.(sh|bash|zsh|ksh)$ || "$interpreter" =~ ^(sh|bash|dash|ash|zsh|ksh)$ ]]; then
    shell_heredocs=1
  fi
  counts="$({
    # Every line counts: the awk program below takes line ranges.
    printf '%s\n' '1 2147483647' --
    cat "$head_file"
  } | awk -v kind="$kind" -v rust="$([[ "$classify_path" == *.rs ]] && echo 1 || echo 0)" -v python="$([[ "$classify_path" =~ \.(py|graphql|gql)$ || "$interpreter" =~ ^(python|pypy) ]] && echo 1 || echo 0)" -v hash_strings="$([[ "$classify_path" =~ \.(rb|pl)$ || "$interpreter" =~ ^(ruby|perl)$ ]] && echo 1 || echo 0)" -v ruby="$([[ "$classify_path" == *.rb || "$interpreter" == ruby ]] && echo 1 || echo 0)" -v perl="$([[ "$classify_path" == *.pl || "$interpreter" == perl ]] && echo 1 || echo 0)" -v nested_blocks="$([[ "$classify_path" == *.rs || "$classify_path" == *.swift || "$classify_path" == *.kt ]] && echo 1 || echo 0)" -v javascript="$([[ "$classify_path" =~ \.[cm]?[jt]sx?$ || "$interpreter" =~ ^(node|nodejs|deno|bun)$ ]] && echo 1 || echo 0)" -v jsx="$([[ "$classify_path" =~ \.[jt]sx$ ]] && echo 1 || echo 0)" -v csharp="$([[ "$classify_path" == *.cs ]] && echo 1 || echo 0)" -v c_splices="$([[ "$classify_path" =~ \.(c|h|cc|cpp|cxx|hh|hpp|hxx)$ ]] && echo 1 || echo 0)" -v cpp="$([[ "$classify_path" =~ \.(cc|cpp|cxx|hh|hpp|hxx)$ ]] && echo 1 || echo 0)" -v swift="$([[ "$classify_path" == *.swift ]] && echo 1 || echo 0)" -v backticks="$([[ "$classify_path" =~ \.[cm]?[jt]sx?$ || "$classify_path" == *.go || "$classify_path" == *.vue || "$interpreter" =~ ^(node|nodejs|deno|bun)$ ]] && echo 1 || echo 0)" -v triple_quotes="$([[ "$classify_path" =~ \.(java|kt|scala|swift)$ ]] && echo 1 || echo 0)" -v java_text_blocks="$([[ "$classify_path" == *.java ]] && echo 1 || echo 0)" -v raw_backticks="$([[ "$classify_path" == *.go ]] && echo 1 || echo 0)" -v shell_heredocs="$shell_heredocs" '
    !content {
      if ($0 == "--") {
        content = 1
        range_i = 1
        next
      }
      n++
      split($0, bounds, " ")
      lo[n] = bounds[1]
      hi[n] = bounds[2]
      next
    }
    function added(ln) {
      while (range_i <= n && ln > hi[range_i]) range_i++
      return range_i <= n && ln >= lo[range_i] && ln <= hi[range_i]
    }
    function closing_quote(text, start, quote, doubled,   i, ch, escaped) {
      for (i = start + 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (escaped) {
          escaped = 0
          continue
        }
        if (ch == "\\") {
          escaped = 1
          continue
        }
        if (ch == quote) {
          if (doubled && substr(text, i + 1, 1) == quote) {
            i++
            continue
          }
          return i
        }
      }
      return 0
    }
    function escaped_delimiter(text, start,   i, slash_count) {
      slash_count = 0
      for (i = start - 1; i > 0 && substr(text, i, 1) == "\\"; i--) slash_count++
      return slash_count % 2
    }
    function regex_allowed(prefix,   clean, last) {
      clean = prefix
      sub(/[[:space:]]+$/, "", clean)
      if (clean == "") return 1
      last = substr(clean, length(clean), 1)
      if (index("=([{,:;!?&|+-*%~<>", last) > 0) return 1
      return clean ~ /(^|[^[:alnum:]_$])(return|throw|case|delete|void|typeof|instanceof|in|of|yield|await)$/
    }
    function closing_regex(text, start,   i, ch, escaped, in_class) {
      for (i = start + 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (escaped) {
          escaped = 0
          continue
        }
        if (ch == "\\") {
          escaped = 1
          continue
        }
        if (ch == "[" && !in_class) {
          in_class = 1
          continue
        }
        if (ch == "]" && in_class) {
          in_class = 0
          continue
        }
        if (ch == "/" && !in_class) return i
      }
      return 0
    }
    function dollar_delimiter(text, start,   i, ch, previous) {
      if (kind != "sql" || substr(text, start, 1) != "$") return ""
      previous = (start > 1 ? substr(text, start - 1, 1) : "")
      if (previous ~ /[[:alnum:]_$]/) return ""
      ch = substr(text, start + 1, 1)
      if (ch == "$") return "$$"
      if (ch !~ /[[:alpha:]_]/) return ""
      for (i = start + 2; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (ch == "$") return substr(text, start, i - start + 1)
        if (ch !~ /[[:alnum:]_]/) return ""
      }
      return ""
    }
    function lua_long_delimiter(text, start,   i, equals) {
      if (kind != "lua" || substr(text, start, 1) != "[") return ""
      equals = ""
      for (i = start + 1; substr(text, i, 1) == "="; i++) equals = equals "="
      if (substr(text, i, 1) != "[") return ""
      return "]" equals "]"
    }
    function cpp_raw_delimiter(text, start,   prefix_length, previous, i, ch, raw_delimiter) {
      if (!cpp) return ""
      previous = (start > 1 ? substr(text, start - 1, 1) : "")
      if (previous ~ /[[:alnum:]_]/) return ""
      if (substr(text, start, 4) == "u8R\"") prefix_length = 4
      else if (substr(text, start, 3) ~ /^(u|U|L)R\"$/) prefix_length = 3
      else if (substr(text, start, 2) == "R\"") prefix_length = 2
      else return ""
      raw_delimiter = ""
      for (i = start + prefix_length; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (ch == "(") {
          cpp_raw_open_end = i
          return ")" raw_delimiter "\""
        }
        if (length(raw_delimiter) >= 16 || ch ~ /[[:space:]\\()]/) return ""
        raw_delimiter = raw_delimiter ch
      }
      return ""
    }
    function closing_python_triple(text, start, delimiter,   i, escaped, ch) {
      escaped = 0
      for (i = start; i <= length(text) - 2; i++) {
        ch = substr(text, i, 1)
        if (escaped) {
          escaped = 0
          continue
        }
        if (ch == "\\") {
          escaped = 1
          continue
        }
        if (substr(text, i, 3) == delimiter) return i
      }
      return 0
    }
    # Python triple-quoted strings can contain lines that start with "#".
    # Track their state before the hash-comment rule classifies those lines.
    function scan_python_line(text,   i, ch, quote_at, close_at, single_quote, single_triple, delimiter) {
      python_string_line = (python_triple_quote != "")
      single_quote = sprintf("%c", 39)
      single_triple = single_quote single_quote single_quote
      i = 1
      while (i <= length(text)) {
        if (python_triple_quote != "") {
          python_string_line = 1
          close_at = closing_python_triple(text, i, python_triple_quote)
          if (close_at == 0) return
          i = close_at + 3
          python_triple_quote = ""
          continue
        }
        ch = substr(text, i, 1)
        if (ch == "#") return
        delimiter = substr(text, i, 3)
        if (delimiter == "\"\"\"" || delimiter == single_triple) {
          python_triple_quote = delimiter
          python_string_line = 1
          i += 3
          continue
        }
        if (ch == "\"" || ch == single_quote) {
          quote_at = closing_quote(text, i, ch, 0)
          if (quote_at == 0) return
          i = quote_at + 1
          continue
        }
        i++
      }
    }
    # Ruby and Perl permit ordinary quoted strings to span source lines.
    # Preserve that state before classifying a leading hash as a comment.
    function scan_hash_string_line(text,   i, ch, escaped, single_quote) {
      hash_string_line = (hash_string_quote != "")
      single_quote = sprintf("%c", 39)
      escaped = 0
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (hash_string_quote != "") {
          hash_string_line = 1
          if (escaped) {
            escaped = 0
            continue
          }
          if (ch == "\\") {
            escaped = 1
            continue
          }
          if (ch == hash_string_quote) hash_string_quote = ""
          continue
        }
        if (ch == "#") return
        if (ch == "\"" || ch == single_quote) {
          hash_string_quote = ch
          hash_string_line = 1
        }
      }
    }
    function scan_terraform_heredoc(text,   i, ch, close_at, delimiter) {
      for (i = 1; i < length(text); i++) {
        ch = substr(text, i, 1)
        if (ch == "#" || (ch == "/" && substr(text, i + 1, 1) == "/")) return
        if (ch == "\"") {
          close_at = closing_quote(text, i, ch, 0)
          if (close_at == 0) return
          i = close_at
          continue
        }
        if (ch == "<" && substr(text, i + 1, 1) == "<") {
          i += 2
          terraform_heredoc_indent = 0
          if (substr(text, i, 1) == "-") {
            terraform_heredoc_indent = 1
            i++
          }
          if (substr(text, i, 1) !~ /[[:alpha:]_]/) return
          while (i <= length(text) && substr(text, i, 1) ~ /[[:alnum:]_]/) {
            delimiter = delimiter substr(text, i, 1)
            i++
          }
          terraform_heredoc_delimiter = delimiter
          return
        }
      }
    }
    function hash_heredoc_word(text, start, allow_indent,   i, ch, quote, delimiter) {
      i = start
      ch = substr(text, i, 1)
      quote = ""
      delimiter = ""
      if (ch == "\"" || ch == sprintf("%c", 39) || ch == "`") {
        quote = ch
        i++
        while (i <= length(text) && substr(text, i, 1) != quote) {
          delimiter = delimiter substr(text, i, 1)
          i++
        }
        if (substr(text, i, 1) != quote || delimiter == "") return 0
      } else {
        if (ch !~ /[[:alpha:]_]/ || (!perl && !allow_indent && ch !~ /[[:upper:]_]/)) return 0
        while (i <= length(text) && substr(text, i, 1) ~ /[[:alnum:]_]/) {
          delimiter = delimiter substr(text, i, 1)
          i++
        }
        i--
      }
      hash_heredoc_tail++
      hash_heredoc_delimiter[hash_heredoc_tail] = delimiter
      hash_heredoc_allow_indent[hash_heredoc_tail] = allow_indent
      hash_heredoc_word_end = i
      return 1
    }
    function scan_hash_heredocs(text,   i, ch, close_at, allow_indent) {
      for (i = 1; i < length(text); i++) {
        ch = substr(text, i, 1)
        if (ch == "#") return
        if (ch == "\"" || ch == sprintf("%c", 39)) {
          close_at = closing_quote(text, i, ch, 0)
          if (close_at == 0) return
          i = close_at
          continue
        }
        if (ch != "<" || substr(text, i + 1, 1) != "<") continue
        i += 2
        allow_indent = 0
        if ((!perl && substr(text, i, 1) == "-") || substr(text, i, 1) == "~") {
          allow_indent = 1
          i++
        }
        if (perl) {
          while (substr(text, i, 1) ~ /[[:space:]]/ && i <= length(text)) i++
          if (substr(text, i, 1) == "\\") i++
        }
        if (hash_heredoc_word(text, i, allow_indent)) i = hash_heredoc_word_end
      }
    }
    function rust_test_attribute(text) {
      return text ~ /#\[[[:space:]]*((([[:alnum:]_]+::)*test)|(rstest)|(test_case))[[:space:]]*(\([^]]*\))?[[:space:]]*\]/
    }
    function trim_space(text) {
      sub(/^[[:space:]]+/, "", text)
      sub(/[[:space:]]+$/, "", text)
      return text
    }
    function rust_cfg_requires_test(predicate,   inner, i, ch, depth, quote, escaped, start, child) {
      predicate = trim_space(predicate)
      if (predicate == "test") return 1
      if (predicate !~ /^all[[:space:]]*\(/ || substr(predicate, length(predicate), 1) != ")") return 0
      inner = predicate
      sub(/^all[[:space:]]*\(/, "", inner)
      inner = substr(inner, 1, length(inner) - 1)
      depth = 0
      quote = ""
      escaped = 0
      start = 1
      for (i = 1; i <= length(inner); i++) {
        ch = substr(inner, i, 1)
        if (quote != "") {
          if (escaped) escaped = 0
          else if (ch == "\\") escaped = 1
          else if (ch == quote) quote = ""
          continue
        }
        if (ch == "\"" || ch == sprintf("%c", 39)) {
          quote = ch
          continue
        }
        if (ch == "(") depth++
        else if (ch == ")") depth--
        else if (ch == "," && depth == 0) {
          child = substr(inner, start, i - start)
          if (rust_cfg_requires_test(child)) return 1
          start = i + 1
        }
      }
      return rust_cfg_requires_test(substr(inner, start))
    }
    function rust_test_cfg_attribute(text,   attribute, open_at, predicate) {
      attribute = trim_space(text)
      if (attribute !~ /^#\[[[:space:]]*cfg[[:space:]]*\(/ || attribute !~ /\)[[:space:]]*\]$/) return 0
      open_at = index(attribute, "(")
      predicate = substr(attribute, open_at + 1)
      sub(/\)[[:space:]]*\]$/, "", predicate)
      return rust_cfg_requires_test(predicate)
    }
    # Queue shell heredoc delimiters in source order. Quote removal applies to
    # the delimiter, while expansion does not. The body starts on the next
    # source line, after every delimiter on the command line has been queued.
    function shell_heredoc_word(text, start, strip_tabs, resume,   i, ch, next_ch, quote, delimiter, started) {
      i = start
      while (substr(text, i, 1) ~ /[[:space:]]/) i++
      delimiter = (resume ? shell_pending_heredoc_delimiter : "")
      quote = (resume ? shell_pending_heredoc_quote : "")
      started = resume
      shell_pending_heredoc = 0
      for (; i <= length(text); i++) {
        ch = substr(text, i, 1)
        next_ch = substr(text, i + 1, 1)
        if (quote == "single") {
          if (ch == sprintf("%c", 39)) quote = ""
          else delimiter = delimiter ch
          started = 1
          continue
        }
        if (quote == "double") {
          if (ch == "\"") {
            quote = ""
          } else if (ch == "\\" && next_ch == "") {
            shell_pending_heredoc = 1
            shell_pending_heredoc_delimiter = delimiter
            shell_pending_heredoc_quote = quote
            shell_pending_heredoc_strip_tabs = strip_tabs
            heredoc_word_end = i
            return 2
          } else if (ch == "\\" && (next_ch == "$" || next_ch == "`" || next_ch == "\"" || next_ch == "\\")) {
            delimiter = delimiter next_ch
            i++
          } else {
            delimiter = delimiter ch
          }
          started = 1
          continue
        }
        if (ch ~ /[[:space:]]/ || index(";&|()<>", ch) > 0) break
        if (ch == "#" && !started) return 0
        if (ch == sprintf("%c", 39)) {
          quote = "single"
          started = 1
          continue
        }
        if (ch == "\"") {
          quote = "double"
          started = 1
          continue
        }
        if (ch == "\\" && next_ch == "") {
          shell_pending_heredoc = 1
          shell_pending_heredoc_delimiter = delimiter
          shell_pending_heredoc_quote = quote
          shell_pending_heredoc_strip_tabs = strip_tabs
          heredoc_word_end = i
          return 2
        }
        if (ch == "\\" && next_ch != "") {
          delimiter = delimiter next_ch
          started = 1
          i++
          continue
        }
        delimiter = delimiter ch
        started = 1
      }
      if (!started || quote != "") return 0
      heredoc_tail++
      heredoc_delimiter[heredoc_tail] = delimiter
      heredoc_strip_tabs[heredoc_tail] = strip_tabs
      heredoc_word_end = i - 1
      return 1
    }
    function push_shell_context(context, parens) {
      shell_context_depth++
      shell_context[shell_context_depth] = context
      shell_parens[shell_context_depth] = parens
      shell_case_depth[shell_context_depth] = 0
    }
    function pop_shell_context(   case_index) {
      for (case_index = 1; case_index <= shell_case_depth[shell_context_depth]; case_index++) {
        delete shell_case_phase[shell_context_depth, case_index]
        delete shell_case_pattern_parens[shell_context_depth, case_index]
      }
      delete shell_case_depth[shell_context_depth]
      delete shell_context[shell_context_depth]
      delete shell_parens[shell_context_depth]
      shell_context_depth--
    }
    function shell_keyword_at(text, start, keyword,   before, after) {
      before = (start > 1 ? substr(text, start - 1, 1) : "")
      after = substr(text, start + length(keyword), 1)
      return substr(text, start, length(keyword)) == keyword && before !~ /[[:alnum:]_]/ && after !~ /[[:alnum:]_]/
    }
    function shell_command_position(text, start,   prefix) {
      prefix = substr(text, 1, start - 1)
      sub(/[[:space:]]+$/, "", prefix)
      return prefix == "" || prefix ~ /[;|&(){}]$/ || prefix ~ /(^|[;|&(){}[:space:]])(then|do|else|elif)$/
    }
    # Track shell lexical contexts across source lines. A command substitution
    # inside a double-quoted word has its own shell grammar, so heredocs inside
    # it remain visible. Heredoc payloads do not pass through this scanner.
    function scan_shell_line(text,   i, ch, next_ch, previous, context, escaped, strip_tabs, word_start, arithmetic_end, case_depth, case_phase) {
      if (shell_context_depth == 0) push_shell_context("plain", 0)
      escaped = 0
      shell_line_continues = 0
      i = 1
      if (shell_pending_heredoc) {
        shell_heredoc_word(text, i, shell_pending_heredoc_strip_tabs, 1)
        if (shell_pending_heredoc) {
          shell_line_continues = 1
          return
        }
        i = heredoc_word_end + 1
      }
      for (; i <= length(text); i++) {
        ch = substr(text, i, 1)
        next_ch = substr(text, i + 1, 1)
        if (escaped) {
          escaped = 0
          continue
        }
        context = shell_context[shell_context_depth]
        if (context == "arithmetic") {
          if (ch == "(") {
            shell_parens[shell_context_depth]++
          } else if (ch == ")") {
            shell_parens[shell_context_depth]--
            if (shell_parens[shell_context_depth] == 0) pop_shell_context()
          }
          continue
        }
        if (context == "single") {
          if (ch == sprintf("%c", 39)) pop_shell_context()
          continue
        }
        if (context == "double") {
          if (ch == "\\") {
            escaped = 1
          } else if (ch == sprintf("%c", 36) && next_ch == "(" && substr(text, i + 2, 1) == "(") {
            arithmetic_end = index(substr(text, i + 3), "))")
            if (arithmetic_end > 0) {
              i += arithmetic_end + 3
            } else {
              push_shell_context("arithmetic", 2)
              i += 2
            }
          } else if (ch == sprintf("%c", 36) && next_ch == "(") {
            push_shell_context("command", 1)
            i++
          } else if (ch == "\"") {
            pop_shell_context()
          }
          continue
        }
        if (ch == "\\") { escaped = 1; continue }
        if (ch == sprintf("%c", 39)) {
          push_shell_context("single", 0)
          continue
        }
        if (ch == "\"") {
          push_shell_context("double", 0)
          continue
        }
        previous = (i > 1 ? substr(text, i - 1, 1) : "")
        word_start = (i == 1 || previous ~ /[[:space:];|&()<>]/)
        if (ch == "#" && word_start) break
        case_depth = shell_case_depth[shell_context_depth]
        case_phase = (case_depth > 0 ? shell_case_phase[shell_context_depth, case_depth] : "")
        if (case_depth > 0 && case_phase == "pattern") {
          if (shell_command_position(text, i) && shell_keyword_at(text, i, "esac")) {
            delete shell_case_phase[shell_context_depth, case_depth]
            delete shell_case_pattern_parens[shell_context_depth, case_depth]
            shell_case_depth[shell_context_depth]--
            i += 3
            continue
          }
          if (ch == "(") {
            shell_case_pattern_parens[shell_context_depth, case_depth]++
            continue
          }
          if (ch == ")") {
            if (shell_case_pattern_parens[shell_context_depth, case_depth] > 0) {
              shell_case_pattern_parens[shell_context_depth, case_depth]--
            } else {
              shell_case_phase[shell_context_depth, case_depth] = "body"
            }
            continue
          }
        } else if (case_depth > 0 && case_phase == "wait-in" && shell_keyword_at(text, i, "in")) {
          shell_case_phase[shell_context_depth, case_depth] = "pattern"
          i++
          continue
        } else if (case_depth > 0 && case_phase == "body") {
          if (shell_command_position(text, i) && shell_keyword_at(text, i, "esac")) {
            delete shell_case_phase[shell_context_depth, case_depth]
            delete shell_case_pattern_parens[shell_context_depth, case_depth]
            shell_case_depth[shell_context_depth]--
            i += 3
            continue
          }
          if (substr(text, i, 3) == ";;&") {
            shell_case_phase[shell_context_depth, case_depth] = "pattern"
            i += 2
            continue
          }
          if (substr(text, i, 2) == ";;" || substr(text, i, 2) == ";&") {
            shell_case_phase[shell_context_depth, case_depth] = "pattern"
            i++
            continue
          }
        }
        case_depth = shell_case_depth[shell_context_depth]
        case_phase = (case_depth > 0 ? shell_case_phase[shell_context_depth, case_depth] : "")
        if ((case_depth == 0 || case_phase == "body") && shell_command_position(text, i) && shell_keyword_at(text, i, "case")) {
          case_depth++
          shell_case_depth[shell_context_depth] = case_depth
          shell_case_phase[shell_context_depth, case_depth] = "wait-in"
          shell_case_pattern_parens[shell_context_depth, case_depth] = 0
          i += 3
          continue
        }
        # A shell arithmetic expansion can contain the same token as a left
        # shift. Skip it so "$((value << 2))" cannot open a false heredoc.
        if (substr(text, i, 3) == "$((") {
          arithmetic_end = index(substr(text, i + 3), "))")
          if (arithmetic_end > 0) {
            i += arithmetic_end + 3
          } else {
            push_shell_context("arithmetic", 2)
            i += 2
          }
          continue
        }
        if (substr(text, i, 2) == "((" && word_start) {
          arithmetic_end = index(substr(text, i + 2), "))")
          if (arithmetic_end > 0) {
            i += arithmetic_end + 2
            continue
          }
          push_shell_context("arithmetic", 2)
          i++
          continue
        }
        if (substr(text, i, 3) == "<<<") {
          i += 2
          continue
        }
        if (ch == "<" && next_ch == "<") {
          strip_tabs = 0
          i += 2
          if (substr(text, i, 1) == "-") {
            strip_tabs = 1
            i++
          }
          if (shell_heredoc_word(text, i, strip_tabs, 0)) i = heredoc_word_end
          continue
        }
        if (ch == sprintf("%c", 36) && next_ch == "(") {
          push_shell_context("command", 1)
          i++
          continue
        }
        if (context == "command") {
          if (ch == "(") shell_parens[shell_context_depth]++
          else if (ch == ")") {
            shell_parens[shell_context_depth]--
            if (shell_parens[shell_context_depth] == 0) pop_shell_context()
          }
        }
      }
      shell_line_continues = escaped
    }
    # Track JSX tags so visible text does not use JavaScript comment syntax.
    function jsx_tag_can_start(prefix,   clean, last) {
      if (jsx_element_depth > 0 && jsx_expression_depth == 0) return 1
      clean = prefix
      sub(/[[:space:]]+$/, "", clean)
      if (clean == "" || clean ~ /(^|[^[:alnum:]_$])return$/ || clean ~ /=>$/) return 1
      last = substr(clean, length(clean), 1)
      return index("=([{,:", last) > 0
    }
    function jsx_tag_starts(text, start, prefix,   next_char, name_char) {
      if (!jsx || substr(text, start, 1) != "<" || !jsx_tag_can_start(prefix)) return 0
      next_char = substr(text, start + 1, 1)
      if (next_char == ">") return 1
      if (next_char == "/") {
        name_char = substr(text, start + 2, 1)
        return name_char == ">" || name_char ~ /[[:alpha:]_$]/
      }
      return next_char ~ /[[:alpha:]_$]/
    }
    # Scan comment state and retain the text outside comments. Rust, Swift, and
    # Kotlin block comments nest. The outside text also identifies inline Rust
    # test modules and JavaScript regions within JSX.
    function scan_line(text, state,   i, ch, next_ch, quote_at, single_quote, delimiter, quote_run) {
      single_quote = sprintf("%c", 39)
      scan_state = state
      outside = ""
      structure = ""
      comment_seen = 0
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        next_ch = substr(text, i + 1, 1)
        if (spliced_quote != "") {
          outside = outside "Q"
          structure = structure "Q"
          quote_at = closing_quote(text, i - 1, spliced_quote, 0)
          if (quote_at > 0) {
            spliced_quote = ""
            i = quote_at
            continue
          }
          if (substr(text, length(text), 1) != "\\") spliced_quote = ""
          break
        }
        if (jsx_tag) {
          outside = outside ch
          structure = structure ch
          if (jsx_tag_quote != "") {
            if (ch == "\\") i++
            else if (ch == jsx_tag_quote) jsx_tag_quote = ""
          } else if (ch == "\"" || ch == single_quote) {
            jsx_tag_quote = ch
          } else if (ch == ">") {
            if (jsx_tag_closing) {
              if (jsx_element_depth > 0) jsx_element_depth--
            } else if (substr(text, i - 1, 1) != "/") {
              jsx_element_depth++
            }
            jsx_tag = 0
            jsx_tag_closing = 0
          }
          continue
        }
        if (lua_long_close != "") {
          if (lua_long_is_comment) comment_seen = 1
          else {
            outside = outside "Q"
            structure = structure "Q"
          }
          if (substr(text, i, length(lua_long_close)) == lua_long_close) {
            i += length(lua_long_close) - 1
            lua_long_close = ""
            lua_long_is_comment = 0
          }
          continue
        }
        if (sql_single_quote) {
          outside = outside "Q"
          structure = structure "Q"
          if (ch == single_quote) {
            if (next_ch == single_quote) i++
            else sql_single_quote = 0
          }
          continue
        }
        if (sql_double_quote) {
          outside = outside "Q"
          structure = structure "Q"
          if (ch == "\"") {
            if (next_ch == "\"") i++
            else sql_double_quote = 0
          }
          continue
        }
        if (rust_raw_quote) {
          if (ch == "\"") {
            raw_close = 1
            for (raw_i = 1; raw_i <= rust_raw_hashes; raw_i++) {
              if (substr(text, i + raw_i, 1) != "#") raw_close = 0
            }
            if (raw_close) {
              i += rust_raw_hashes
              rust_raw_quote = 0
              rust_raw_hashes = 0
            }
          }
          continue
        }
        if (csharp_raw_quotes > 0) {
          outside = outside "Q"
          structure = structure "Q"
          if (ch == "\"") {
            quote_run = 1
            while (substr(text, i + quote_run, 1) == "\"") quote_run++
            if (quote_run == csharp_raw_quotes) csharp_raw_quotes = 0
            i += quote_run - 1
          }
          continue
        }
        if (csharp_verbatim_quote) {
          outside = outside "Q"
          structure = structure "Q"
          if (ch == "\"") {
            if (next_ch == "\"") i++
            else csharp_verbatim_quote = 0
          }
          continue
        }
        if (cpp_raw_close != "") {
          outside = outside "Q"
          structure = structure "Q"
          if (substr(text, i, length(cpp_raw_close)) == cpp_raw_close) {
            i += length(cpp_raw_close) - 1
            cpp_raw_close = ""
          }
          continue
        }
        if (template_quote) {
          if (!raw_backticks && ch == "\\") {
            i++
          } else if (javascript && ch == "$" && next_ch == "{") {
            template_quote = 0
            template_expression_depth = 1
            outside = outside "{"
            structure = structure "{"
            i++
          } else if (ch == "`") {
            template_quote = 0
            if (template_stack_depth > 0) {
              template_expression_depth = template_parent_expression_depth[template_stack_depth]
              delete template_parent_expression_depth[template_stack_depth]
              template_stack_depth--
            }
          }
          continue
        }
        if (triple_quote) {
          outside = outside "Q"
          structure = structure "Q"
          if (substr(text, i, 3) == "\"\"\"" && (!(java_text_blocks || swift) || !escaped_delimiter(text, i))) {
            triple_quote = 0
            i += 2
          }
          continue
        }
        if (sql_dollar_quote != "") {
          if (substr(text, i, length(sql_dollar_quote)) == sql_dollar_quote) {
            i += length(sql_dollar_quote) - 1
            sql_dollar_quote = ""
          }
          continue
        }
        if (html_comment) {
          comment_seen = 1
          if (ch == "-" && next_ch == "-" && substr(text, i + 2, 1) == ">") {
            html_comment = 0
            i += 2
          }
          continue
        }
        if (scan_state > 0) {
          comment_seen = 1
          if (nested_blocks && ch == "/" && next_ch == "*") {
            scan_state++
            i++
          } else if (ch == "*" && next_ch == "/") {
            scan_state--
            i++
          }
          continue
        }
        if (kind == "vue" && !vue_script && ch == "<" && substr(text, i) ~ /^<script([[:space:]>]|$)/) vue_script = 1
        if (jsx && jsx_tag_starts(text, i, structure)) {
          jsx_tag = 1
          jsx_tag_closing = (next_ch == "/")
          jsx_tag_quote = ""
          outside = outside ch
          structure = structure ch
          continue
        }
        if (jsx && jsx_element_depth > 0 && jsx_expression_depth == 0) {
          if (ch == "{") {
            jsx_expression_depth = 1
          }
          outside = outside ch
          structure = structure ch
          continue
        }
        delimiter = dollar_delimiter(text, i)
        if (delimiter != "") {
          outside = outside delimiter
          structure = structure "Q"
          sql_dollar_quote = delimiter
          i += length(delimiter) - 1
          continue
        }
        if ((kind == "c" || (kind == "vue" && vue_script) || kind == "terraform") && ch == "/" && next_ch == "/") {
          comment_seen = 1
          break
        }
        if (kind == "sql" && ch == "-" && next_ch == "-") {
          comment_seen = 1
          break
        }
        if (kind == "lua" && ch == "-" && next_ch == "-") {
          delimiter = lua_long_delimiter(text, i + 2)
          if (delimiter != "") {
            comment_seen = 1
            lua_long_close = delimiter
            lua_long_is_comment = 1
            i += length(delimiter) + 1
            continue
          }
          comment_seen = 1
          break
        }
        if (kind == "terraform" && ch == "#") {
          comment_seen = 1
          break
        }
        if (kind == "lua" && ch == "[") {
          delimiter = lua_long_delimiter(text, i)
          if (delimiter != "") {
            outside = outside "Q"
            structure = structure "Q"
            lua_long_close = delimiter
            lua_long_is_comment = 0
            i += length(delimiter) - 1
            continue
          }
        }
        if (javascript && template_expression_depth > 0) {
          if (ch == "{") {
            template_expression_depth++
            outside = outside ch
            structure = structure ch
            continue
          }
          if (ch == "}") {
            template_expression_depth--
            outside = outside ch
            structure = structure ch
            if (template_expression_depth == 0) template_quote = 1
            continue
          }
        }
        if (jsx && jsx_expression_depth > 0) {
          if (ch == "{") {
            jsx_expression_depth++
            outside = outside ch
            structure = structure ch
            continue
          }
          if (ch == "}") {
            jsx_expression_depth--
            outside = outside ch
            structure = structure ch
            continue
          }
        }
        if (javascript && ch == "/" && next_ch != "/" && next_ch != "*" && regex_allowed(structure)) {
          quote_at = closing_regex(text, i)
          if (quote_at > 0) {
            outside = outside substr(text, i, quote_at - i + 1)
            structure = structure "R"
            i = quote_at
            while (substr(text, i + 1, 1) ~ /[[:alpha:]]/) i++
            continue
          }
        }
        if (ch == "/" && next_ch == "*") {
          comment_seen = 1
          scan_state++
          i++
          continue
        }
        if (kind == "vue" && ch == "<" && substr(text, i, 4) == "<!--") {
          comment_seen = 1
          html_comment = 1
          i += 3
          continue
        }
        if (backticks && ch == "`") {
          if (javascript && template_expression_depth > 0) {
            template_stack_depth++
            template_parent_expression_depth[template_stack_depth] = template_expression_depth
            template_expression_depth = 0
          }
          template_quote = 1
          continue
        }
        if (csharp && ch == "\"") {
          quote_run = 1
          while (substr(text, i + quote_run, 1) == "\"") quote_run++
          if (quote_run >= 3) {
            outside = outside "Q"
            structure = structure "Q"
            csharp_raw_quotes = quote_run
            i += quote_run - 1
            continue
          }
        }
        if (csharp && ch == "@" && (next_ch == "\"" || (next_ch == "$" && substr(text, i + 2, 1) == "\""))) {
          outside = outside "Q"
          structure = structure "Q"
          csharp_verbatim_quote = 1
          i += (next_ch == "$" ? 2 : 1)
          continue
        }
        delimiter = cpp_raw_delimiter(text, i)
        if (delimiter != "") {
          outside = outside "Q"
          structure = structure "Q"
          cpp_raw_close = delimiter
          i = cpp_raw_open_end
          continue
        }
        if (triple_quotes && substr(text, i, 3) == "\"\"\"") {
          outside = outside "Q"
          structure = structure "Q"
          triple_quote = 1
          i += 2
          continue
        }
        if (rust && ch == "r") {
          raw_i = i + 1
          raw_hashes = 0
          while (substr(text, raw_i, 1) == "#") {
            raw_hashes++
            raw_i++
          }
          if (substr(text, raw_i, 1) == "\"") {
            rust_raw_quote = 1
            rust_raw_hashes = raw_hashes
            i = raw_i
            continue
          }
        }
        if (ch == "\"" || ch == single_quote) {
          quote_at = closing_quote(text, i, ch, kind == "sql")
          if (quote_at > 0) {
            outside = outside substr(text, i, quote_at - i + 1)
            i = quote_at
            continue
          }
          if (c_splices && substr(text, length(text), 1) == "\\") {
            outside = outside "Q"
            structure = structure "Q"
            spliced_quote = ch
            break
          }
          if (kind == "sql" && ch == single_quote) {
            outside = outside "Q"
            structure = structure "Q"
            sql_single_quote = 1
            continue
          }
          if (kind == "sql" && ch == "\"") {
            outside = outside "Q"
            structure = structure "Q"
            sql_double_quote = 1
            continue
          }
        }
        outside = outside ch
        structure = structure ch
      }
      return scan_state
    }
    {
      line_number++
      line = $0
      is_blank = (line ~ /^[[:space:]]*$/)
      is_comment = 0
      is_rust_test = (rust_test_depth > 0)
      close_rust_test = 0
      is_shell_heredoc = 0
      is_terraform_heredoc = 0
      is_ruby_block_comment = 0
      is_hash_heredoc = 0
      is_perl_pod = 0
      hash_heredoc_opened = 0
      if (shell_heredocs) {
        if (heredoc_head == 0) heredoc_head = 1
        if (heredoc_command_continues) {
          shell_line_in_quote = (shell_context_depth > 0 && (shell_context[shell_context_depth] == "single" || shell_context[shell_context_depth] == "double"))
          scan_shell_line(line)
          heredoc_command_continues = (shell_pending_heredoc || shell_line_continues)
        } else if (heredoc_head <= heredoc_tail) {
          is_shell_heredoc = 1
          heredoc_candidate = line
          if (heredoc_strip_tabs[heredoc_head]) sub(/^\t+/, "", heredoc_candidate)
          if (heredoc_candidate == heredoc_delimiter[heredoc_head]) {
            delete heredoc_delimiter[heredoc_head]
            delete heredoc_strip_tabs[heredoc_head]
            heredoc_head++
          }
        } else {
          shell_line_in_quote = (shell_context_depth > 0 && (shell_context[shell_context_depth] == "single" || shell_context[shell_context_depth] == "double"))
          scan_shell_line(line)
          heredoc_command_continues = (shell_pending_heredoc || (heredoc_head <= heredoc_tail && shell_line_continues))
        }
      }
      if (python) scan_python_line(line)
      if (perl_pod) {
        is_perl_pod = 1
        if (line ~ /^=cut([[:space:]]|$)/) perl_pod = 0
      } else if (perl && line ~ /^=(pod|head[1-6]|over|item|back|begin|end|for|encoding)([[:space:]]|$)/) {
        perl_pod = 1
        is_perl_pod = 1
      }
      if (ruby_block_comment) {
        is_ruby_block_comment = 1
        if (line ~ /^=end([[:space:]]|$)/) ruby_block_comment = 0
      } else if (ruby && line ~ /^=begin([[:space:]]|$)/) {
        ruby_block_comment = 1
        is_ruby_block_comment = 1
      }
      if ((ruby || perl) && !is_ruby_block_comment && !is_perl_pod) {
        if (hash_heredoc_head == 0) hash_heredoc_head = 1
        if (hash_heredoc_head <= hash_heredoc_tail) {
          is_hash_heredoc = 1
          hash_heredoc_candidate = line
          if (hash_heredoc_allow_indent[hash_heredoc_head]) sub(/^[[:space:]]+/, "", hash_heredoc_candidate)
          if (hash_heredoc_candidate == hash_heredoc_delimiter[hash_heredoc_head]) {
            delete hash_heredoc_delimiter[hash_heredoc_head]
            delete hash_heredoc_allow_indent[hash_heredoc_head]
            hash_heredoc_head++
          }
        } else if (hash_string_quote == "") {
          previous_hash_heredoc_tail = hash_heredoc_tail
          scan_hash_heredocs(line)
          hash_heredoc_opened = (hash_heredoc_tail > previous_hash_heredoc_tail)
        }
      }
      if (hash_strings && !is_perl_pod && !is_ruby_block_comment && !is_hash_heredoc && !hash_heredoc_opened) scan_hash_string_line(line)
      if (kind == "terraform") {
        if (terraform_heredoc_delimiter != "") {
          is_terraform_heredoc = 1
          terraform_heredoc_candidate = line
          if (terraform_heredoc_indent) sub(/^[[:space:]]+/, "", terraform_heredoc_candidate)
          if (terraform_heredoc_candidate == terraform_heredoc_delimiter) {
            terraform_heredoc_delimiter = ""
            terraform_heredoc_indent = 0
          }
        } else if (inblock == 0) {
          scan_terraform_heredoc(line)
        }
      }
      # Comment state is tracked over every line, added or not, so an
      # addition inside an unchanged block comment is a comment.
      if (kind == "c" || kind == "sql" || kind == "vue" || kind == "lua" || kind == "terraform") {
        if (!is_terraform_heredoc) inblock = scan_line(line, inblock)
        else { outside = ""; structure = ""; comment_seen = 0 }
        is_comment = (comment_seen && (outside ~ /^[[:space:]]*$/ || (jsx && outside ~ /^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$/)))
        if (rust) {
          if (rust_test_depth == 0 && (rust_test_attribute(structure) || rust_test_cfg_attribute(structure))) {
            rust_cfg_pending = 1
            is_rust_test = 1
          }
          if (rust_cfg_pending && structure ~ /^[[:space:]]*#\[/) is_rust_test = 1
          if (rust_cfg_pending && structure !~ /^[[:space:]]*$/ && structure !~ /^[[:space:]]*#\[/) {
            is_rust_test = 1
            if (structure ~ /\{/) {
              rust_test_depth = brace_depth + 1
              rust_cfg_pending = 0
            } else if (structure ~ /;/) {
              rust_cfg_pending = 0
            }
          }
          opens = gsub(/\{/, "{", structure)
          closes = gsub(/\}/, "}", structure)
          brace_depth += opens - closes
          close_rust_test = (rust_test_depth > 0 && brace_depth < rust_test_depth)
        }
        if (kind == "vue" && structure ~ /<\/script[[:space:]]*>/) vue_script = 0
      } else if (is_perl_pod || is_ruby_block_comment) {
        is_comment = 1
      } else if (kind == "hash" && !is_shell_heredoc && !is_hash_heredoc && !shell_line_in_quote && !python_string_line && !hash_string_line && line ~ /^[[:space:]]*#/) {
        is_comment = !(line_number == 1 && line ~ /^#!/)
      }
      if (!added(line_number)) {
        if (close_rust_test) rust_test_depth = 0
        next
      }
      if (is_blank) { blank++; next }
      if (kind == "tests" || is_rust_test) tests++
      else if (kind == "docs") docs++
      else if (kind == "other") other++
      else if (is_comment) comments++
      else code++
      if (close_rust_test) rust_test_depth = 0
    }
    END { printf "%d %d %d %d %d %d\n", code, comments, tests, docs, other, blank }')"
  read -r c m t d o b <<<"$counts"
}

is_lockfile() {
  case "${1##*/}" in
    pnpm-lock.yaml | package-lock.json | yarn.lock | go.sum | Cargo.lock | poetry.lock | uv.lock | .terraform.lock.hcl | \
      npm-shrinkwrap.json | bun.lock | bun.lockb | go.work.sum | Pipfile.lock | pdm.lock | Gemfile.lock | composer.lock | \
      flake.lock | mix.lock | pubspec.lock)
      return 0
      ;;
  esac
  return 1
}

# list_files <directory> prints the NUL-separated paths to count, and sets
# root, the directory they are relative to.
list_files() {
  if root="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)"; then
    git -C "$1" ls-files -z --full-name --cached --others --exclude-standard | sort -zu
  else
    root="$1"
    (cd "$1" && find . -type f -print0)
  fi
}

json_string() {
  local s="$1" out='' ch i
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      '"') out+='\"' ;;
      \\) out+='\\' ;;
      [[:cntrl:]]) out+="$(printf '\\u%04x' "'$ch")" ;;
      *) out+="$ch" ;;
    esac
  done
  printf '"%s"' "$out"
}

# counts_json <files> <binary> <code> <comments> <tests> <docs> <generated> <other> <unknown> <blank>
counts_json() {
  printf '"files": %d, "binary_files": %d, "lines": {"code": %d, "comments": %d, "tests": %d, "docs": %d, "generated": %d, "other": %d, "unknown": %d, "blank": %d}' "$@"
}

for dir in "$@"; do
  [ -d "$dir" ] || {
    echo "loc: '$dir' is not a directory" >&2
    exit 2
  }
done
total=(0 0 0 0 0 0 0 0 0 0)
separator=''
# The output is printed whole at the end, so a failure prints no partial JSON.
rows=''
# shortcut: one awk process for each file; batch the files of one language
# into one process when a large tree is too slow.
for dir in "$@"; do
  list_files "$dir" >"$scratch_dir/list"
  n=(0 0 0 0 0 0 0 0 0 0)
  while IFS= read -r -d '' file; do
    file="${file#./}"
    path="$root/$file"
    if [ ! -f "$path" ] || [ -L "$path" ]; then
      continue
    fi
    if binary_name "$file" || ! cmp -s "$path" <(tr -d '\000' <"$path"); then
      n[1]=$((n[1] + 1))
      continue
    fi
    mode=100644
    [ ! -x "$path" ] || mode=100755
    classify "$file" "$mode" "$path"
    n[0]=$((n[0] + 1))
    if is_lockfile "$file"; then
      n[6]=$((n[6] + c + m + t + d + o))
    elif ((unknown)); then
      n[8]=$((n[8] + c + m + t + d + o))
    else
      n[2]=$((n[2] + c))
      n[3]=$((n[3] + m))
      n[4]=$((n[4] + t))
      n[5]=$((n[5] + d))
      n[7]=$((n[7] + o))
    fi
    n[9]=$((n[9] + b))
  done <"$scratch_dir/list"
  for i in "${!n[@]}"; do
    total[i]=$((total[i] + n[i]))
  done
  rows+="$(printf '%s\n    {"path": %s, %s}' "$separator" "$(json_string "$dir")" "$(counts_json "${n[@]}")")"
  separator=','
done
printf '{\n  "directories": [%s\n  ],\n  "total": {%s}\n}\n' "$rows" "$(counts_json "${total[@]}")"
