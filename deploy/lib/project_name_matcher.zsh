#!/usr/bin/env zsh

# Shared project-name resolution helpers for deploy scripts.
# Resolution order:
# 1) Exact canonical name or alias match (case-insensitive).
# 2) Tokenized, case-insensitive fuzzy match across name, aliases, and path.
#    Each token must match at least one candidate field exactly, or by
#    substring when the token length is >= 3.
# 3) If no match is found, return the original input so callers can handle "not found".
project_match_list_candidates() {
  local config_file="$1"
  local input_name="$2"
  local normalized_input
  local -a query_tokens
  local tokens_json

  normalized_input="${(L)input_name}"
  query_tokens=("${(z)normalized_input}")
  query_tokens=("${(@)query_tokens:#}")

  if (( ${#query_tokens[@]} == 0 )); then
    return 0
  fi

  tokens_json="$(printf '%s\n' "${query_tokens[@]}" | jq -R . | jq -cs .)"

  jq -r --argjson tokens "$tokens_json" '
    def token_matches($token; $candidate):
      ($candidate == $token)
      or (($token | length) >= 3 and ($candidate | contains($token)));

    [
      .[]
      | . as $project
      | (([.name] + (.aliases // []) + [.path // ""]) | map(ascii_downcase)) as $candidates
      | select(
          ($tokens | all(. as $token | any($candidates[]; token_matches($token; .))))
        )
      | $project.name
    ] | unique[]
  ' "$config_file"
}

project_match_prompt_for_choice() {
  local config_file="$1"
  local input_name="$2"
  shift 2
  local -a matches=("$@")
  local selection
  local path
  local index=1

  if [[ ! -t 0 ]]; then
    echo "Error: Project name '$input_name' is ambiguous. Matches: ${matches[*]}" >&2
    return 2
  fi

  echo "Multiple projects match '$input_name':" >&2
  for match in "${matches[@]}"; do
    path=""
    if command -v jq >/dev/null 2>&1; then
      path="$(jq -r --arg name "$match" '.[] | select(.name == $name) | .path // empty' "$config_file")"
    fi
    if [[ -n "$path" ]]; then
      echo "  ${index}. ${match} (${path})" >&2
    else
      echo "  ${index}. ${match}" >&2
    fi
    index=$((index + 1))
  done

  while true; do
    read "?Select project number: " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#matches[@]} )); then
      echo "$matches[$selection]"
      return 0
    fi
    echo "Invalid selection. Enter a number between 1 and ${#matches[@]}." >&2
  done
}

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

  partial_matches=("${(@f)$(project_match_list_candidates "$config_file" "$input_name")}")
  partial_matches=("${(@)partial_matches:#}")

  if (( ${#partial_matches[@]} == 1 )); then
    echo "$partial_matches[1]"
    return 0
  fi

  if (( ${#partial_matches[@]} > 1 )); then
    project_match_prompt_for_choice "$config_file" "$input_name" "${partial_matches[@]}"
    return $?
  fi

  echo "$input_name"
  return 0
}
