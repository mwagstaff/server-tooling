#!/usr/bin/env zsh

# Shared project-name resolution helpers for deploy scripts.
# Resolution order:
# 1) Exact canonical name or alias match (case-insensitive).
# 2) If input length >= 3, case-insensitive contains match on name + aliases.
# 3) If no match is found, return the original input so callers can handle "not found".
project_match_resolve_name() {
  local config_file="$1"
  local input_name="$2"
  local normalized_input
  local exact_match
  local -a partial_matches

  if [[ -z "$input_name" ]]; then
    echo "Error: Project name cannot be empty." >&2
    return 1
  fi

  if [[ ! -f "$config_file" ]]; then
    echo "Error: Config file not found: $config_file" >&2
    return 1
  fi

  normalized_input="${(L)input_name}"

  exact_match="$(jq -r --arg q "$normalized_input" '
    ([.[] | select(
      (.name | ascii_downcase) == $q
      or (((.aliases // []) | map(ascii_downcase) | index($q)) != null)
    ) | .name][0]) // empty
  ' "$config_file")"
  if [[ -n "$exact_match" ]]; then
    echo "$exact_match"
    return 0
  fi

  if (( ${#input_name} < 3 )); then
    echo "$input_name"
    return 0
  fi

  partial_matches=("${(@f)$(jq -r --arg q "$normalized_input" '
    [.[] | select(
      ((.name | ascii_downcase) | contains($q))
      or (((.aliases // []) | map(ascii_downcase)) | any(contains($q)))
    ) | .name][]
  ' "$config_file")}")

  if (( ${#partial_matches[@]} == 1 )); then
    echo "$partial_matches[1]"
    return 0
  fi

  if (( ${#partial_matches[@]} > 1 )); then
    echo "Error: Project name '$input_name' is ambiguous. Matches: ${partial_matches[*]}" >&2
    return 2
  fi

  echo "$input_name"
  return 0
}
