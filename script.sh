#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s dotglob

# ----------------------------
# Helpers / logging
# ----------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

show_help() {
  cat <<'EOF'
Klipper backup -> git commit -> push (with origin sync before commit).

Usage:
  ./klipper_backup_sync.sh [options]

Options:
  -h, --help                Show help
  -c, --commit_message MSG  Use MSG as commit message
  -d, --debug               Enable debug output
  -f, --fix                 Placeholder for compatibility (no-op)
EOF
}

# ----------------------------
# Paths
# ----------------------------
parent_path="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd -P
)"

ENV_FILE="${ENV_FILE:-$parent_path/.env}"
[[ -f "$ENV_FILE" ]] || die "Missing .env file at: $ENV_FILE"

# shellcheck disable=SC1090
source "$ENV_FILE"

# ----------------------------
# Dependencies
# ----------------------------
require_cmd git
require_cmd rsync
require_cmd curl
require_cmd jq

# ----------------------------
# Defaults (mirror Klipper-Backup style)
# ----------------------------
backup_folder="${backup_folder:-config_backup}"
backup_path="${backup_path:-$HOME/$backup_folder}"

allow_empty_commits="${allow_empty_commits:-true}"
use_filenames_as_commit_msg="${use_filenames_as_commit_msg:-false}"

git_protocol="${git_protocol:-https}"     # https or ssh
git_host="${git_host:-github.com}"
ssh_user="${ssh_user:-git}"

branch_name="${branch_name:-main}"

exclude=(${exclude:-"*.swp *.tmp printer-[0-9]*_[0-9]*.cfg *.bak *.bkp *.csv *.zip"})

commit_message_used=false
debug_output=false
commit_message=""
args="$*"

# ----------------------------
# Args
# ----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    -f|--fix) shift ;; # kept for compatibility (no-op here)
    -c|--commit_message)
      [[ -n "${2:-}" && ! "${2:-}" =~ ^- ]] || die "commit message expected after $1"
      commit_message="$2"
      commit_message_used=true
      shift 2
      ;;
    -d|--debug)
      debug_output=true
      shift
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ----------------------------
# Validate required env (v2 style)
# ----------------------------
: "${github_username:?Missing github_username in .env}"
: "${github_repository:?Missing github_repository in .env}"

# backupPaths must be an array in v2.
# Example in .env:
#   backupPaths=( "printer_data/config" "printer_data/database" )
declare -p backupPaths >/dev/null 2>&1 || die ".env must define backupPaths as a bash array (v2 config)."

# Identity defaults
commit_username="${commit_username:-}"
commit_email="${commit_email:-}"

# Token is required for https
github_token="${github_token:-}"

# Build remote URL
if [[ "$git_protocol" == "ssh" ]]; then
  full_git_url="ssh://${ssh_user}@${git_host}/${github_username}/${github_repository}.git"
else
  [[ -n "$github_token" ]] || die "git_protocol=https requires github_token in .env"
  full_git_url="https://${github_token}@${git_host}/${github_username}/${github_repository}.git"
fi

if [[ "$debug_output" == "true" ]]; then
  log "Debug enabled"
  log "Command: $0 $args"
  log "parent_path: $parent_path"
  log "backup_path: $backup_path"
  log "remote host: $git_host"
  log "remote repo: ${github_username}/${github_repository}"
  log "branch_name: $branch_name"
fi

# Quick check (public repo visibility check; not authoritative for private)
if [[ "$debug_output" == "true" && "$git_host" == "github.com" ]]; then
  if curl -fsS "https://api.github.com/repos/${github_username}/${github_repository}" >/dev/null; then
    log "GitHub repo ${github_username}/${github_repository} exists (public or accessible)"
  else
    log "GitHub repo ${github_username}/${github_repository} not reachable via unauth API (might be private)"
  fi
fi

# ----------------------------
# Prepare backup directory & git repo
# ----------------------------
mkdir -p "$backup_path"
cd "$backup_path"

if [[ ! -d .git ]]; then
  mkdir -p .git
  {
    echo "[init]"
    echo "  defaultBranch = ${branch_name}"
  } >> .git/config
  git init >/dev/null
fi

# Ensure correct branch
if [[ "$(git symbolic-ref --short -q HEAD || true)" != "$branch_name" ]]; then
  if git show-ref --quiet --verify "refs/heads/$branch_name"; then
    git checkout "$branch_name" >/dev/null
  else
    git checkout -b "$branch_name" >/dev/null
  fi
fi

# Configure identity
if [[ -n "$commit_username" ]]; then
  git config user.name "$commit_username"
else
  git config user.name "$(whoami)"
fi

if [[ -n "$commit_email" ]]; then
  git config user.email "$commit_email"
else
  unique_id="$(date +%s%N | md5sum | head -c 7)"
  git config user.email "$(whoami)@$(hostname --short)-${unique_id}"
fi

# Set origin
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "$full_git_url"
else
  if [[ "$(git remote get-url origin)" != "$full_git_url" ]]; then
    git remote set-url origin "$full_git_url"
  fi
fi

# ----------------------------
# Sync from origin BEFORE copying new backup
# (fail if non-fast-forward / conflicts)
# ----------------------------
git fetch origin "$branch_name" || die "Failed to fetch origin/$branch_name"

if git ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
  # If remote exists, fast-forward only
  git pull --ff-only origin "$branch_name" || die "Cannot fast-forward to origin/$branch_name (diverged/conflict). Aborting."
fi

# Clean working tree (keep .git and README.md if you like)
find "$backup_path" -maxdepth 1 -mindepth 1 \
  ! -name '.git' \
  ! -name 'README.md' \
  ! -name '.gitmodules' \
  -exec rm -rf {} \;

# ----------------------------
# Copy backupPaths into repo (ignore symlinks)
# ----------------------------
cd "$HOME"

for path in "${backupPaths[@]}"; do
  fullPath="$HOME/$path"

  # Expand directories into contents
  if [[ -d "$fullPath" ]]; then
    # If user gave "dir", treat as "dir/*"
    if [[ "$path" != */* && -d "$HOME/$path" ]]; then
      path="$path/*"
    elif [[ "$path" != */* && -d "$path" ]]; then
      path="$path/*"
    fi
  fi

  if compgen -G "$HOME/$path" >/dev/null; then
    for file in $path; do
      if [[ -h "$file" ]]; then
        log "Skipping symlink: $file"
        continue
      fi
      abs="$(readlink -e "$file")" || continue
      rsync -Rr --filter "- /.git/" --filter "- /.github/" "${abs##"$HOME"/}" "$backup_path"
    done
  else
    log "Path did not match anything, skipping: $path"
  fi
done

cd "$backup_path"

# Ensure .gitignore exists
touch .gitignore

# Append excludes
for pat in "${exclude[@]}"; do
  # add newline if needed
  [[ -n "$(tail -c1 .gitignore 2>/dev/null || true)" ]] && echo >> .gitignore
  echo "$pat" >> .gitignore
done

# Ensure README exists
if [[ ! -f README.md ]]; then
  cat > README.md <<'EOF'
# Klipper Backup

This repository is a backup of Klipper/Moonraker/Mainsail printer configuration and related files.
EOF
fi

# ----------------------------
# Commit message
# ----------------------------
if [[ "$commit_message_used" != "true" ]]; then
  commit_message="New backup from $(date +"%x - %X")"
fi

if [[ "$use_filenames_as_commit_msg" == "true" ]]; then
  # Only meaningful if repo already had content
  # Use staged diff vs branch tip
  files="$(git diff --name-only "$branch_name" || true)"
  if [[ -n "$files" ]]; then
    commit_message="$(echo "$files" | xargs -n 1 basename | tr '\n' ' ')"
  fi
fi

# Untrack all so that ignore changes apply (optional; mirrors original idea)
git rm -r --cached . >/dev/null 2>&1 || true

git add -A

# Don’t fail if nothing changed; allow empty commit if enabled
if git diff --cached --quiet; then
  log "No changes to commit."
  if [[ "$allow_empty_commits" == "true" ]]; then
    git commit --allow-empty -m "$commit_message - No new changes pushed" >/dev/null
  else
    log "Empty commits disabled; exiting without push."
    exit 0
  fi
else
  git commit -m "$commit_message" >/dev/null
fi

git push -u origin "$branch_name"

# Optional cleanup after push
find "$backup_path" -maxdepth 1 -mindepth 1 \
  ! -name '.git' \
  ! -name 'README.md' \
  ! -name '.gitmodules' \
  -exec rm -rf {} \;

log "Backup complete."
