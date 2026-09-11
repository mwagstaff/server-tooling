#!/usr/bin/env zsh

setopt NO_UNSET PIPE_FAIL

typeset -r SCRIPT_NAME=${0:t}
typeset -r DEFAULT_ROOT=$HOME/dev
typeset root=${GIT_STATUS_ROOT:-$DEFAULT_ROOT}
typeset jobs=${GIT_TOOL_JOBS:-8}

usage() {
  print "Usage: $SCRIPT_NAME"
  print
  print "Show uncommitted changes in Git repositories beneath $DEFAULT_ROOT."
  print "Set GIT_STATUS_ROOT to scan a different directory."
  print "Set GIT_TOOL_JOBS to control parallel workers (default: 8)."
}

case ${1:-} in
  --help|-h) usage; exit 0 ;;
  "") ;;
  *) print -u2 "Unknown option: $1"; usage >&2; exit 2 ;;
esac

if [[ ! -d $root ]]; then
  print -u2 "Directory does not exist: $root"
  exit 1
fi

case $jobs in
  ""|*[!0-9]*) print -u2 "GIT_TOOL_JOBS must be a positive integer"; exit 2 ;;
esac
if (( jobs < 1 )); then
  print -u2 "GIT_TOOL_JOBS must be a positive integer"
  exit 2
fi

count_paths() {
  local item
  integer count=0

  while IFS= read -r -d '' item; do
    (( count++ ))
  done
  print $count
}

run_directory=$(mktemp -d "${TMPDIR:-/tmp}/status-zsh.XXXXXX") || exit 1
trap 'rm -rf -- "$run_directory"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

discover_repositories() {
  if [[ -e $1/.git ]]; then
    print -rn -- "$1/.git"$'\0'
    return
  fi
  find "$1" \
    \( -type d \( \
      -name node_modules -o -name vendor -o -name .venv -o -name .cache -o \
      -name .build -o -name Pods -o -name DerivedData \
    \) -prune \) -o \
    \( -name .git -print0 -prune \)
}

flush_discovery_batch() {
  local batch_index discovery_file marker

  for (( batch_index = 1; batch_index <= ${#discovery_pids}; batch_index++ )); do
    wait "${discovery_pids[$batch_index]}" 2>/dev/null || true
  done
  for discovery_file in $discovery_outputs; do
    while IFS= read -r -d '' marker; do
      repositories+=("${marker:h}")
    done < "$discovery_file"
  done
  discovery_pids=()
  discovery_outputs=()
}

typeset -a repositories top_directories discovery_pids discovery_outputs
[[ -e $root/.git ]] && repositories+=("$root")
while IFS= read -r -d '' top_directory; do
  top_directories+=("$top_directory")
done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0)

integer discovery_index=0
for top_directory in $top_directories; do
  (( discovery_index++ ))
  discovery_file="$run_directory/discovery-$discovery_index"
  discover_repositories "$top_directory" > "$discovery_file" 2>/dev/null &
  discovery_pids+=($!)
  discovery_outputs+=("$discovery_file")
  (( ${#discovery_pids} >= jobs )) && flush_discovery_batch
done
(( ${#discovery_pids} > 0 )) && flush_discovery_batch
repositories=("${(@o)repositories}")
typeset -a independent_repositories
for candidate_repo in $repositories; do
  nested_repository=false
  for parent_repo in $independent_repositories; do
    if [[ $candidate_repo == "$parent_repo/"* ]]; then
      nested_repository=true
      break
    fi
  done
  [[ $nested_repository == false ]] && independent_repositories+=("$candidate_repo")
done
repositories=("${independent_repositories[@]}")

summarize_repository() {
  local repo=$1 status_output relative_path branch
  local staged_count unstaged_count untracked_count status_line

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return
  if ! status_output=$(git -C "$repo" -c color.status=false status \
      --short --untracked-files=all 2>/dev/null); then
    return
  fi
  [[ -n $status_output ]] || return

  relative_path=${repo#$root/}
  [[ $relative_path == $repo ]] && relative_path=${repo:t}
  branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null) || \
    branch="detached @ $(git -C "$repo" rev-parse --short HEAD 2>/dev/null)"

  staged_count=$(git -C "$repo" diff --cached --name-only -z | count_paths)
  unstaged_count=$(git -C "$repo" diff --name-only -z | count_paths)
  untracked_count=$(git -C "$repo" ls-files --others --exclude-standard -z | count_paths)

  print -- "==> $relative_path [$branch]"
  print "    Staged: $staged_count | Unstaged: $unstaged_count | Untracked: $untracked_count"
  while IFS= read -r status_line; do
    print -r -- "    $status_line"
  done <<< "$status_output"
}

flush_batch() {
  local batch_index output_file

  for (( batch_index = 1; batch_index <= ${#batch_pids}; batch_index++ )); do
    wait "${batch_pids[$batch_index]}" 2>/dev/null || true
  done
  for output_file in $batch_outputs; do
    [[ -s $output_file ]] || continue
    (( dirty_repositories++ ))
    (( dirty_repositories > 1 )) && print
    cat "$output_file"
  done
  batch_pids=()
  batch_outputs=()
}

integer dirty_repositories=0 repository_index=0
typeset -a batch_pids batch_outputs

for repo in $repositories; do
  (( repository_index++ ))
  output_file="$run_directory/$repository_index.out"
  summarize_repository "$repo" > "$output_file" 2>&1 &
  batch_pids+=($!)
  batch_outputs+=("$output_file")
  (( ${#batch_pids} >= jobs )) && flush_batch
done
(( ${#batch_pids} > 0 )) && flush_batch

if (( dirty_repositories == 0 )); then
  print "No uncommitted changes found."
else
  print
  print "$dirty_repositories repositories with uncommitted changes."
fi
