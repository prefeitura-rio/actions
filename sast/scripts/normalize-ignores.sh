#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail";
# replicate that here since a nested "bash script.sh" invocation does not inherit it.
set -eo pipefail

export FILE_SEMGREP=".semgrepignore"
export FILE_SONAR="sonar-project.properties"
export FILE_CHECKOV=".checkov.yaml"
export FILE_CHECKOV_SKIP="checkov-skip-paths.txt"

extract_sonar_exclusions() {
  awk '
    BEGIN { collecting=0 }
    /^[[:space:]]*#/ { next }

    /^(sonar\.exclusions|sonar\.test\.exclusions|sonar\.coverage\.exclusions|sonar\.tests)=/ {
      collecting=1
      sub(/^[^=]+= */, "")
    }

    collecting {
      continues = ($0 ~ /\\$/)
      gsub(/\\$/, "")   # remove trailing backslash
      printf "%s", $0

      if (!continues) {
        printf "\n"
        collecting=0
      }
    }
  ' "$FILE_SONAR" \
  | tr ',' '\n' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
  | grep -v '^$' \
  | sort -u
}

extract_semgrep_exclusions() {
  grep -v '^[[:space:]]*#' "$FILE_SEMGREP" \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
  | grep -v '^$' \
  | sort -u
}

# Reads the "skip-path:" block sequence from .checkov.yaml. Only the plain
# block-sequence form is supported (one "  - pattern" per line, optionally
# single/double-quoted, optional trailing "# comment"); flow-style
# "skip-path: [a, b]" is not. Entries are checkov's own regex dialect, not a
# glob, matching what checkov itself reads from this file.
extract_checkov_exclusions() {
  awk '
    BEGIN { collecting=0 }
    /^[[:space:]]*#/ { next }
    /^skip-path:[[:space:]]*$/ { collecting=1; next }
    collecting {
      if ($0 ~ /^[[:space:]]*-[[:space:]]/) {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        print line
      } else if ($0 !~ /^[[:space:]]*($|#)/) {
        collecting = 0
      }
    }
  ' "$FILE_CHECKOV" \
  | sed -E 's/[[:space:]]+#.*$//' \
  | sed -E "s/^'(.*)'\$/\1/; s/^\"(.*)\"\$/\1/" \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
  | grep -v '^$' \
  | sort -u
}

# checkov's --skip-path / .checkov.yaml "skip-path" is matched with re.search
# against the full path, not a glob (see filter_ignored_paths in
# checkov/common/runners/base_runner.py), so gitignore/Ant-style globs are
# translated here: a leading "**/" or trailing "/**" is dropped (checkov
# already prunes a whole matched directory's subtree), any remaining
# "**"/"*"/"?" become their regex equivalents, and every other character is
# regex-escaped.
glob_to_checkov_regex() {
  local p="$1" out="" c i n
  p="${p#/}"; p="${p%/}"
  case "$p" in '**/'*) p="${p#\*\*/}" ;; esac
  case "$p" in */'**') p="${p%/\*\*}" ;; esac
  n=${#p}
  i=0
  while (( i < n )); do
    c="${p:i:1}"
    if [[ "$c" == "*" && "${p:i:2}" == "**" ]]; then
      out+=".*"
      i=$((i + 2))
      continue
    elif [[ "$c" == "*" ]]; then
      out+="[^/]*"
    elif [[ "$c" == "?" ]]; then
      out+="."
    else
      case "$c" in
        '.'|'^'|'$'|'+'|'('|')'|'['|']'|'{'|'}'|'|'|'\')
          out+="\\$c" ;;
        *)
          out+="$c" ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Best-effort inverse of glob_to_checkov_regex, for when .checkov.yaml is the
# only ignore file present and .semgrepignore/sonar-project.properties need
# to be derived from it: undoes our own escaping ("\X" -> "X"), "[^/]*" -> "*",
# ".*" -> "**", a bare "." -> "?". Any other regex construct a user wrote by
# hand (character classes, anchors, alternation, ...) passes through
# unchanged, since it has no general glob equivalent. checkov always matches
# the pattern anywhere in the path (re.search, no anchor), so the result is
# prefixed with "**/" -- without it, Ant-style sonar.exclusions in particular
# would only match at the exclusion's literal depth instead of everywhere.
checkov_regex_to_glob() {
  local p="$1" out="" n i
  n=${#p}
  i=0
  while (( i < n )); do
    if [[ "${p:i:1}" == "\\" && $((i + 1)) -lt n ]]; then
      out+="${p:i+1:1}"
      i=$((i + 2))
      continue
    elif [[ "${p:i:5}" == "[^/]*" ]]; then
      out+="*"
      i=$((i + 5))
      continue
    elif [[ "${p:i:2}" == ".*" ]]; then
      out+="**"
      i=$((i + 2))
      continue
    elif [[ "${p:i:1}" == "." ]]; then
      out+="?"
      i=$((i + 1))
    else
      out+="${p:i:1}"
      i=$((i + 1))
    fi
  done
  printf '**/%s' "$out"
}

generate_semgrep() {
  local source="$1" glob_patterns="$2"
  {
    echo "# Auto-generated from $source"
    echo ""
    printf '%s\n' "$glob_patterns"
  } > "$FILE_SEMGREP"
  echo "Generated $FILE_SEMGREP"
}

generate_sonar() {
  local source="$1" glob_patterns="$2"
  local exclusions
  exclusions=$(printf '%s\n' "$glob_patterns" | paste -sd "," -)
  {
    echo "# Auto-generated from $source"
    echo ""
    echo "sonar.exclusions=$exclusions"
  } > "$FILE_SONAR"
  echo "Generated $FILE_SONAR"
}

generate_checkov() {
  local source="$1" glob_patterns="$2"
  {
    echo "# Auto-generated from $source"
    echo "skip-path:"
    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      local regex
      regex=$(glob_to_checkov_regex "$pattern")
      printf "  - '%s'\n" "${regex//\'/\'\'}"
    done <<< "$glob_patterns"
  } > "$FILE_CHECKOV"
  echo "Generated $FILE_CHECKOV"
}

# One exclusion list, authored in whichever of the three files exists, drives
# all three tools: opengrep/.semgrepignore, SonarQube/sonar-project.properties
# and checkov/.checkov.yaml. Priority when picking the source among several
# pre-existing files is .semgrepignore, then sonar-project.properties, then
# .checkov.yaml (glob-native formats first, since translating out of
# checkov's regex dialect is lossy for anything beyond our own vocabulary);
# whichever file(s) are still missing get generated from that source. Files
# that already exist are left untouched (assumed to already be in sync).
glob_patterns=""
source_name=""
if [[ -f "$FILE_SEMGREP" ]]; then
  source_name="$FILE_SEMGREP"
  glob_patterns=$(extract_semgrep_exclusions)
elif [[ -f "$FILE_SONAR" ]]; then
  source_name="$FILE_SONAR"
  glob_patterns=$(extract_sonar_exclusions)
elif [[ -f "$FILE_CHECKOV" ]]; then
  source_name="$FILE_CHECKOV"
  glob_patterns=$(extract_checkov_exclusions | while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    checkov_regex_to_glob "$pattern"
    echo
  done)
fi

if [[ -n "$source_name" ]]; then
  if [[ ! -f "$FILE_SEMGREP" ]]; then
    generate_semgrep "$source_name" "$glob_patterns"
  fi
  if [[ ! -f "$FILE_SONAR" ]]; then
    generate_sonar "$source_name" "$glob_patterns"
  fi
  if [[ ! -f "$FILE_CHECKOV" ]]; then
    generate_checkov "$source_name" "$glob_patterns"
  fi
fi

# The "Run checkov" step needs a plain regex list (not YAML) to build
# --skip-path args; derive it straight from .checkov.yaml, whether that file
# pre-existed or was just generated above, so it always reflects the same
# exclusions as the other two files.
if [[ -f "$FILE_CHECKOV" ]]; then
  extract_checkov_exclusions > "$FILE_CHECKOV_SKIP"
else
  : > "$FILE_CHECKOV_SKIP"
fi
