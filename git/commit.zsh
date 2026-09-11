#!/usr/bin/env zsh

setopt NO_UNSET PIPE_FAIL

typeset -r SCRIPT_NAME=${0:t}
typeset -r DEFAULT_ROOT=${0:A:h:h:h}
typeset root=${COMMIT_ROOT:-$DEFAULT_ROOT}
typeset dry_run=false

usage() {
  print "Usage: $SCRIPT_NAME [--dry-run]"
  print
  print "Commit and push changes in every GitHub-backed repository under $DEFAULT_ROOT."
  print "Set COMMIT_ROOT to scan a different directory."
}

case ${1:-} in
  --dry-run) dry_run=true ;;
  --help|-h) usage; exit 0 ;;
  "") ;;
  *) print -u2 "Unknown option: $1"; usage >&2; exit 2 ;;
esac

if [[ ! -d $root ]]; then
  print -u2 "Directory does not exist: $root"
  exit 1
fi

is_github_url() {
  local url=$1
  [[ $url == git@github.com:* ||
     $url == ssh://git@github.com/* ||
     $url == https://github.com/* ||
     $url == http://github.com/* ||
     $url == git://github.com/* ]]
}

typeset selected_remote selected_upstream

select_github_remote() {
  local upstream remote url
  local -a candidates
  local -A seen

  selected_remote=""
  selected_upstream=""
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=""

  if [[ -n $upstream ]]; then
    candidates+=("${upstream%%/*}")
  fi
  candidates+=(origin)
  candidates+=("${(@f)$(git remote)}")

  for remote in $candidates; do
    [[ -n $remote && -z ${seen[$remote]:-} ]] || continue
    seen[$remote]=1
    url=$(git remote get-url --push "$remote" 2>/dev/null) || continue
    is_github_url "$url" || continue

    selected_remote=$remote
    if [[ $upstream == "$remote/"* ]]; then
      selected_upstream=${upstream#*/}
    fi
    return 0
  done

  return 1
}

operation_in_progress() {
  local marker
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [[ -e $(git rev-parse --git-path "$marker") ]] && return 0
  done
  return 1
}

build_commit_message() {
  local token change_status file_path action scope subject body
  local -a tokens files scopes
  local -A seen_scopes
  local added=0 modified=0 deleted=0 renamed=0 other=0
  local index=1

  while IFS= read -r -d '' token; do
    tokens+=("$token")
  done < <(git diff --cached --name-status -z)

  while (( index <= ${#tokens} )); do
    change_status=${tokens[$index]}
    (( index++ ))
    case ${change_status[1]} in
      A) (( added++ )) ;;
      M) (( modified++ )) ;;
      D) (( deleted++ )) ;;
      R)
        (( renamed++ ))
        (( index++ )) # Skip the old path; the new path follows.
        ;;
      *) (( other++ )) ;;
    esac
    file_path=${tokens[$index]}
    files+=("$file_path")
    (( index++ ))
  done

  if (( ${#files} == 1 )); then
    if (( added == 1 )); then
      action=Add
    elif (( deleted == 1 )); then
      action=Remove
    elif (( renamed == 1 )); then
      action=Rename
    else
      action=Update
    fi
    subject="$action ${files[1]}"
  else
    for file_path in $files; do
      scope=${file_path%%/*}
      [[ -n ${seen_scopes[$scope]:-} ]] && continue
      seen_scopes[$scope]=1
      scopes+=("$scope")
    done

    if (( ${#scopes} == 1 )); then
      subject="Update ${scopes[1]}"
    elif (( ${#scopes} == 2 )); then
      subject="Update ${scopes[1]} and ${scopes[2]}"
    elif (( ${#scopes} == 3 )); then
      subject="Update ${scopes[1]}, ${scopes[2]}, and ${scopes[3]}"
    else
      subject="Update ${scopes[1]}, ${scopes[2]}, and $(( ${#scopes} - 2 )) other areas"
    fi
  fi

  (( ${#subject} > 72 )) && subject="${subject[1,69]}..."
  body="Changes: $added added, $modified modified, $deleted deleted, $renamed renamed"
  (( other > 0 )) && body+=", $other other"

  commit_subject=$subject
  commit_body=$body
}

typeset -a repositories
while IFS= read -r -d '' marker; do
  repositories+=("${marker:h}")
done < <(
  find "$root" \
    \( -type d \( -name node_modules -o -name vendor -o -name .venv -o -name .cache \) -prune \) -o \
    \( -name .git -print0 -prune \)
)
repositories=("${(@o)repositories}")

integer committed=0 pushed=0 skipped=0 failed=0

for repo in $repositories; do
  print
  print -- "==> ${repo#$root/}"

  if ! cd "$repo"; then
    print -u2 "    Could not enter repository"
    (( failed++ ))
    continue
  fi

  if operation_in_progress; then
    print -u2 "    Skipped: a merge, rebase, cherry-pick, or revert is in progress"
    (( skipped++ ))
    continue
  fi

  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
  if [[ -z $branch ]]; then
    print -u2 "    Skipped: HEAD is detached"
    (( skipped++ ))
    continue
  fi

  if [[ -z $(git status --porcelain=v1) ]]; then
    print "    Working tree is clean"
    continue
  fi

  if ! select_github_remote; then
    print "    Skipped: no GitHub push remote"
    (( skipped++ ))
    continue
  fi

  if $dry_run; then
    print "    Would commit all working-tree changes"
    print "    Would push $branch to $selected_remote"
    continue
  fi

  if ! git add -A; then
    print -u2 "    Failed to stage changes"
    (( failed++ ))
    continue
  fi

  if git diff --cached --quiet; then
    print "    No committable changes after staging"
    continue
  fi

  typeset commit_subject commit_body
  build_commit_message
  print "    Committing: $commit_subject"
  if git commit -m "$commit_subject" -m "$commit_body"; then
    (( committed++ ))
  else
    print -u2 "    Commit failed"
    (( failed++ ))
    continue
  fi

  if [[ -n $selected_upstream ]]; then
    if git push "$selected_remote" "HEAD:$selected_upstream"; then
      (( pushed++ ))
    else
      print -u2 "    Push failed"
      (( failed++ ))
    fi
  elif git push --set-upstream "$selected_remote" "$branch"; then
    (( pushed++ ))
  else
    print -u2 "    Push failed"
    (( failed++ ))
  fi
done

print
if $dry_run; then
  print "Dry run complete: ${#repositories} repositories found, $skipped skipped, $failed failed."
else
  print "Complete: $committed committed, $pushed pushed, $skipped skipped, $failed failed."
fi

(( failed == 0 ))
