#!/usr/bin/env bash
#
# Stages an allowlisted copy of the given top-level folders as a Vercel Build Output API v3
# directory, for deploy-static.yml. `vercel deploy --prebuilt` uploads only that directory, so a
# file outside the listed folders can never be published, whatever else the repository holds.
#
# Usage:
#   stage-static-output.sh [--keep-readmes] <repo-root> <out-dir> <folder>...
#
# <out-dir> must resolve to a directory inside <repo-root> (not the root itself, an ancestor of
# it or anywhere outside it), because it is wiped. Wipes <out-dir>, then writes <out-dir>/config.json ({"version":3}) and
# <out-dir>/static/<path relative to repo-root> for every file it publishes.
#
# The rules, in the order they apply:
#   1. Each <folder> is a plain top-level folder name: letters, digits, `.`, `_` and `-`, not
#      starting with `.` or `-`. No `/`, so no `..`, no absolute path and no nested path. A listed name
#      that is not a real directory (missing, a file or a symlink) is an error, so a renamed or
#      mistyped folder fails the deploy instead of publishing a site without it.
#   2. Only regular files under those folders are published, at any depth.
#   3. A file or folder whose name starts with `.` is left out, at any depth, and a dot-folder is
#      not descended into (.DS_Store, .gitkeep, .drafts/).
#   4. Symlinks are left out and never followed: they are the one way an allowlist can still
#      reach files outside it.
#   5. Unless --keep-readmes, each folder's own README.md (directly inside it, any case) is left
#      out: it documents the repository for the team and is not published content. A README.md
#      deeper down belongs to the content next to it and is published.
#   6. At least one file must be published. An empty output would replace the live site with
#      nothing on a production deploy, so zero files is an error, not an empty deploy.
#
# Prints each published path on stdout, then each excluded path with its reason, then a count.
# Exit codes: 0 staged at least one file; 1 a listed folder is not a real directory, or nothing
# to publish; 2 usage error, an invalid folder name or an <out-dir> outside the repository.
# <out-dir> is left untouched on every non-zero exit.

set -euo pipefail

usage() {
  echo "usage: $0 [--keep-readmes] <repo-root> <out-dir> <folder>..." >&2
  exit 2
}

KEEP_READMES=0
if [ "${1:-}" = "--keep-readmes" ]; then
  KEEP_READMES=1
  shift
fi
[ $# -ge 2 ] || usage
REPO_ROOT=$1
OUT_DIR=$2
shift 2

if [ $# -eq 0 ]; then
  echo "error: no folders to publish. List at least one top-level folder, e.g. 'wireframes artifacts'." >&2
  exit 2
fi
if [ -z "$OUT_DIR" ]; then
  echo "error: <out-dir> is empty." >&2
  exit 2
fi
if [ ! -d "$REPO_ROOT" ]; then
  echo "error: $REPO_ROOT: no such directory." >&2
  exit 2
fi

# Rule 1. Validated before anything is wiped or written.
FOLDERS=()
for folder in "$@"; do
  if ! [[ "$folder" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
    echo "error: '$folder' is not a plain top-level folder name. Use names like 'wireframes': letters, digits, '.', '_' and '-', not starting with '.' or '-', no '/'." >&2
    exit 2
  fi
  # A folder listed twice is published once.
  seen=0
  for f in ${FOLDERS[@]+"${FOLDERS[@]}"}; do [ "$f" = "$folder" ] && seen=1; done
  [ "$seen" -eq 1 ] || FOLDERS+=("$folder")
done

# Resolved before the cd below, so a relative <out-dir> means what the caller meant.
case "$OUT_DIR" in
  /*) ;;
  *) OUT_DIR="$PWD/$OUT_DIR" ;;
esac
cd "$REPO_ROOT"

# <out-dir> is wiped below, so it must resolve to a directory strictly inside the repository:
# never the root, an ancestor of it, or anything outside it. `..` is refused outright. The
# deepest part that exists is resolved with `pwd -P` (symlinks included), and the parts that
# do not exist yet are appended as they are.
resolve_out_dir() {
  local path=$1 rest="" base
  case "/$path/" in */../*) return 1 ;; esac
  while [ ! -d "$path" ]; do
    base=$(basename "$path")
    [ "$base" = "." ] || rest="/$base$rest"
    path=$(dirname "$path")
  done
  printf '%s%s\n' "$(cd "$path" && pwd -P)" "$rest"
}
REPO_REAL=$(pwd -P)
OUT_REAL=$(resolve_out_dir "$OUT_DIR") || OUT_REAL=""
case "$OUT_REAL" in
  "$REPO_REAL"/?*) ;;
  *)
    echo "error: <out-dir> must be a directory inside the repository, not its root, an ancestor of it or outside it (got: $OUT_DIR)." >&2
    exit 2
    ;;
esac

INCLUDED=()
EXCLUDED=()  # "<reason> <path>"
n_dotfile=0 n_symlink=0 n_readme=0
NOT_FOLDERS=0

# Case-insensitive match for rule 5: the Linux runner treats README.md and readme.md as two files.
shopt -s nocasematch

for folder in "${FOLDERS[@]}"; do
  # Rule 1: every listed name must be a real folder. All of them are reported before failing.
  if [ -L "$folder" ]; then
    echo "::error::'$folder' is a symlink, not a folder. Symlinks are never followed: list a real top-level folder." >&2
    NOT_FOLDERS=$((NOT_FOLDERS + 1))
    continue
  fi
  if [ ! -d "$folder" ]; then
    echo "::error::'$folder' is not a folder in this repository. Was it renamed or mistyped? Fix 'folders' in the caller workflow." >&2
    NOT_FOLDERS=$((NOT_FOLDERS + 1))
    continue
  fi

  # find -P (the default) never follows a symlink. Each walk prunes dot-entries first, so
  # nothing inside a dot-folder is seen at all.
  while IFS= read -r -d '' path; do  # rule 3
    EXCLUDED+=("dotfile $path")
    n_dotfile=$((n_dotfile + 1))
  done < <(find "$folder" -mindepth 1 -name '.*' -prune -print0 | sort -z)

  while IFS= read -r -d '' path; do  # rule 4
    EXCLUDED+=("symlink $path")
    n_symlink=$((n_symlink + 1))
  done < <(find "$folder" -mindepth 1 -name '.*' -prune -o -type l -print0 | sort -z)

  while IFS= read -r -d '' path; do  # rules 2 and 5
    if [ "$KEEP_READMES" -eq 0 ] && [[ "$path" == "$folder/readme.md" ]]; then
      EXCLUDED+=("readme $path")
      n_readme=$((n_readme + 1))
    else
      INCLUDED+=("$path")
    fi
  done < <(find "$folder" -mindepth 1 -name '.*' -prune -o -type f -print0 | sort -z)
done

shopt -u nocasematch

# Rules 1 and 6, checked before <out-dir> is wiped. `vercel deploy --prebuilt --prod` with an
# empty output would take the live site down, so neither case may reach the deploy.
if [ "$NOT_FOLDERS" -gt 0 ]; then
  echo "error: $NOT_FOLDERS listed folder(s) are not folders in this repository. Nothing was staged." >&2
  exit 1
fi
if [ "${#INCLUDED[@]}" -eq 0 ]; then
  for entry in ${EXCLUDED[@]+"${EXCLUDED[@]}"}; do
    echo "excluded (${entry%% *}): ${entry#* }"
  done
  echo "::error::No files to publish in: ${FOLDERS[*]}. Every file there is excluded (dotfiles, symlinks, folder READMEs) or the folders are empty. Deploying an empty output would replace the site with nothing, so nothing was staged." >&2
  exit 1
fi

# Wiped first: a file deleted or renamed in the repository must disappear on the next deploy.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/static"
printf '{"version":3}\n' >"$OUT_DIR/config.json"

for path in ${INCLUDED[@]+"${INCLUDED[@]}"}; do
  mkdir -p "$OUT_DIR/static/$(dirname "$path")"
  cp "$path" "$OUT_DIR/static/$path"
  echo "published: $path"
done
for entry in ${EXCLUDED[@]+"${EXCLUDED[@]}"}; do
  echo "excluded (${entry%% *}): ${entry#* }"
done

echo "Staged ${#INCLUDED[@]} file(s) from: ${FOLDERS[*]}. Excluded $((n_dotfile + n_symlink + n_readme)): $n_dotfile dotfile(s), $n_symlink symlink(s), $n_readme folder README(s)."
