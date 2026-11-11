#!/usr/bin/env bash
# pre-commit-large-files.sh -- warn about staged files above a size limit and let the
# committer decide, instead of rejecting them.
#
#   Limit:        LARGE_FILE_MB (default 5)
#   Skip prompt:  LARGE_FILE_OK=1 git commit ...   (or git commit --no-verify)
#   Compress:     LARGE_FILE_ACTION=compress git commit ...
#                 bash pre-commit-large-files.sh --compress   (outside a commit)
#   Originals:    LARGE_FILE_DELETE=1 removes a compressed original from disk too
#   Per repo:     git config largefiles.action compress|commit|abort|ask
#                 git config largefiles.deleteOriginals true|false
#
# Without a decision from the environment or git config the hook asks
# yes / compress / No. "compress" zips every large file next to itself
# (<file>.zip), unstages the original, stages the zip and checks again.
# Who is asked:
#   * the terminal, when /dev/tty opens (Linux, macOS);
#   * else the Neovim the commit runs under ($NVIM: lazygit in Neovim, a Neovim
#     terminal), as a dialog via lib.nvim's bin/nvim-ask. Git for Windows starts
#     hooks without any /dev/tty, so on Windows this is the only way to be asked;
#   * nobody (GUI, plain Windows terminal): the files are listed and the commit is
#     aborted with the hints above.
#
# Installed per repo by scripts/git-hooks/install.sh, which writes a one-line
# .git/hooks/pre-commit that calls this file.

limit_mb="${LARGE_FILE_MB:-5}"
# Bash arithmetic reads "5MB" or "" as 0, and every file would be "large".
case "$limit_mb" in
  '' | *[!0-9]*)
    echo "pre-commit: LARGE_FILE_MB='$limit_mb' is not a whole number, using 5" >&2
    limit_mb=5
    ;;
esac
limit=$((limit_mb * 1024 * 1024))

standalone=0
[ "${1:-}" = "--compress" ] && standalone=1

# Bytes as "   6.7 MB" (or KB below one MB, where a zip usually ends up).
human() {
  awk -v s="$1" 'BEGIN { if (s < 1048576) printf "%7.1f KB", s / 1024; else printf "%7.1f MB", s / 1048576 }'
}

# Every staged blob that is new in content: added, copied, modified, renamed or
# changed in type (a large file moved to a new path is a rename, not an add).
# --raw gives the staged blob's id; one `git cat-file --batch-check` sizes them
# all, instead of one process per file. Fills big (display lines) and big_paths.
collect_big() {
  local paths=() ids=() meta path size i=0
  big=()
  big_paths=()
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    case "$meta" in *' R'* | *' C'*) IFS= read -r -d '' path ;; esac # R/C: old path, then new
    set -- $meta
    [ "$1" = ":160000" ] || [ "$2" = "160000" ] && continue # a submodule commit, no blob
    paths+=("$path")
    ids+=("$4")
  done < <(git diff --cached --raw -z --diff-filter=ACMRT)

  [ ${#ids[@]} -eq 0 ] && return
  while read -r size; do
    if [ "$size" -eq "$size" ] 2>/dev/null && [ "$size" -gt "$limit" ]; then
      big+=("$(human "$size")  ${paths[$i]}")
      big_paths+=("${paths[$i]}")
    fi
    i=$((i + 1))
  done < <(printf '%s\n' "${ids[@]}" | git cat-file --batch-check='%(objectsize)')
}

# zip if installed, else a bsdtar (Windows ships one as System32/tar.exe; Git Bash's
# own tar is GNU tar, which cannot write zip).
find_archiver() {
  if command -v zip >/dev/null 2>&1; then
    echo zip
    return
  fi
  local win_tar
  if [ -n "${WINDIR:-}" ] && command -v cygpath >/dev/null 2>&1; then
    win_tar="$(cygpath -u "$WINDIR")/System32/tar.exe"
    [ -x "$win_tar" ] && echo "$win_tar" && return
  fi
  command -v bsdtar >/dev/null 2>&1 && echo bsdtar
}

# Zip one file to <file>.zip (the archive holds the bare file name), verify it,
# then unstage the original and stage the zip. Returns 1 when it did nothing.
compress_one() {
  local file="$1" archiver="$2" dir base out
  dir="$(dirname -- "$file")"
  base="$(basename -- "$file")"
  out="$file.zip"
  case "$base" in
    *.zip | *.gz | *.7z | *.xz | *.zst | *.bz2 | *.rar)
      echo "  skip: $file is already compressed" >&2
      return 1
      ;;
  esac
  if [ -e "$out" ]; then
    echo "  skip: $out already exists" >&2
    return 1
  fi
  if [ ! -f "$file" ]; then
    echo "  skip: $file is not in the work tree (only staged)" >&2
    return 1
  fi
  if [ "$archiver" = zip ]; then
    (cd "$dir" && zip -q -9 "$base.zip" "$base")
  else
    "$archiver" -a -c -f "$out" -C "$dir" "$base"
  fi || {
    echo "  fail: could not write $out" >&2
    rm -f -- "$out"
    return 1
  }
  if command -v unzip >/dev/null 2>&1 && ! unzip -tqq "$out" >/dev/null 2>&1; then
    echo "  fail: $out does not test clean, removed" >&2
    rm -f -- "$out"
    return 1
  fi
  git rm --cached -q -- "$file" && git add -- "$out" || return 1
  echo "  $(human "$(wc -c <"$out")")  $out" >&2
  return 0
}

# Compress every large staged file. $1 = delete originals (1), keep them (0) or ask.
compress_all() {
  local delete="$1" archiver f done_files=()
  # `git commit <paths>` commits from a temporary index: a zip staged there would
  # land in the commit while the real index keeps the original staged.
  case "${GIT_INDEX_FILE:-}" in
    *next-index*)
      echo "pre-commit: cannot compress during 'git commit <paths>'." >&2
      echo "  Run: bash \"$0\" --compress   then commit again." >&2
      return 1
      ;;
  esac
  archiver="$(find_archiver)"
  if [ -z "$archiver" ]; then
    echo "pre-commit: no zip or bsdtar found, cannot compress." >&2
    return 1
  fi
  echo "pre-commit: compressing:" >&2
  for f in "${big_paths[@]}"; do
    compress_one "$f" "$archiver" && done_files+=("$f")
  done
  [ ${#done_files[@]} -eq 0 ] && return 1

  [ "$delete" = ask ] && delete="$(ask_delete)"
  if [ "$delete" = 1 ]; then
    rm -f -- "${done_files[@]}"
    echo "pre-commit: originals deleted." >&2
  else
    echo "pre-commit: originals kept on disk, now untracked (do not 'git add' them again):" >&2
    printf '  %s\n' "${done_files[@]}" >&2
  fi
  return 0
}

# After compressing, check again: a zip that is still above the limit is listed
# and asked about like any other file.
recheck() {
  collect_big
  [ ${#big[@]} -eq 0 ] && return 0
  echo "pre-commit: still above ${limit_mb} MB after compressing:" >&2
  printf '  %s\n' "${big[@]}" >&2
  return 1
}

collect_big

if [ "$standalone" = 1 ]; then
  [ ${#big[@]} -eq 0 ] && echo "nothing staged above ${limit_mb} MB" >&2 && exit 0
  compress_all "${LARGE_FILE_DELETE:-0}"
  exit $?
fi

[ ${#big[@]} -eq 0 ] && exit 0

echo "pre-commit: ${#big[@]} staged file(s) larger than ${limit_mb} MB:" >&2
printf '  %s\n' "${big[@]}" >&2

[ "${LARGE_FILE_OK:-}" = "1" ] && exit 0

# The decision without asking: LARGE_FILE_ACTION, else `git config largefiles.action`
# (per repo: compress | commit | abort | ask). Originals: LARGE_FILE_DELETE, else
# `git config --type=bool largefiles.deleteOriginals`, else asked (kept when nobody can be asked).
action="${LARGE_FILE_ACTION:-$(git config --get largefiles.action 2>/dev/null)}"
delete="${LARGE_FILE_DELETE:-}"
if [ -z "$delete" ]; then
  case "$(git config --type=bool --get largefiles.deleteOriginals 2>/dev/null)" in
    true) delete=1 ;;
    false) delete=0 ;;
    *) delete=ask ;;
  esac
fi

# Who answers a question: the terminal when /dev/tty opens (Linux, macOS), else the Neovim the
# commit runs under ($NVIM: lazygit or a Neovim terminal) via lib.nvim's nvim-ask. Git for Windows
# starts hooks without any /dev/tty, so there only Neovim can be asked.
# LARGE_FILE_TTY lets a test feed terminal answers from a file, LARGE_FILE_NVIM_ASK overrides the
# script for a test. In real use terminal.nvim's native terminals already hand it over as $NVIM_ASK.
channel=""
tty="${LARGE_FILE_TTY:-/dev/tty}"
if [ -r "$tty" ] && { exec 3<"$tty"; } 2>/dev/null; then
  channel=tty
elif [ -n "${NVIM:-}" ]; then
  nvim_ask="${LARGE_FILE_NVIM_ASK:-${NVIM_ASK:-$(command -v nvim-ask 2>/dev/null)}}"
  if [ -z "$nvim_ask" ]; then
    nvim_ask="$(nvim --clean --headless --server "$NVIM" --remote-expr \
      "luaeval('require(\"lib.nvim.terminal.ask\").script()')" 2>/dev/null)"
  fi
  [ -n "$nvim_ask" ] && [ -f "$nvim_ask" ] && channel=nvim
fi

# Ask through $channel. ask_nvim <question> <choice>... prints the choice; non-zero = no answer.
ask_nvim() {
  bash "$nvim_ask" --title " pre-commit " --timeout "${LARGE_FILE_ASK_TIMEOUT:-300}" "$@"
}

# Prints y (commit anyway), c (compress) or n (abort).
ask_main() {
  local answer
  if [ "$channel" = tty ]; then
    printf 'Commit anyway? [y]es / [c]ompress to .zip / [N]o ' >&2
    read -r answer <&3
    case "$answer" in
      y | Y | yes | j | J | ja) echo y ;;
      c | C | compress | k | K) echo c ;;
      *) echo n ;;
    esac
    return
  fi
  answer="$(ask_nvim "$(printf '%s staged file(s) larger than %s MB:\n%s' \
    "${#big[@]}" "$limit_mb" "$(printf '%s\n' "${big[@]}" | head -n 8)")" \
    "Compress to .zip" "Commit anyway" "Abort")"
  case "$answer" in
    "Commit anyway") echo y ;;
    "Compress to .zip") echo c ;;
    *) echo n ;;
  esac
}

# Prints 1 (delete the compressed originals) or 0 (keep them).
ask_delete() {
  local answer
  if [ "$channel" = tty ]; then
    printf 'Delete the originals from disk (the .zip holds them)? [y/N] ' >&2
    read -r answer <&3
    case "$answer" in y | Y | yes | j | J | ja) echo 1 ;; *) echo 0 ;; esac
  elif [ "$channel" = nvim ]; then
    answer="$(ask_nvim "Delete the originals from disk? The .zip holds them." "Keep originals" "Delete originals")"
    [ "$answer" = "Delete originals" ] && echo 1 || echo 0
  else
    echo 0
  fi
}

finish() {
  [ "$channel" = tty ] && exec 3<&-
  exit "$1"
}

case "$action" in
  commit) finish 0 ;;
  abort)
    echo "pre-commit: aborted (git config largefiles.action = abort)." >&2
    finish 1
    ;;
  compress)
    compress_all "$delete" || finish 1
    recheck && finish 0
    echo "pre-commit: aborted. Commit anyway with LARGE_FILE_OK=1 git commit ..." >&2
    finish 1
    ;;
esac

if [ -n "$channel" ]; then
  while :; do
    case "$(ask_main)" in
      y) finish 0 ;;
      c)
        if compress_all "$delete"; then
          recheck && finish 0
          continue
        fi
        ;;
    esac
    break
  done
  echo "pre-commit: aborted, nothing committed." >&2
  finish 1
fi

echo "pre-commit: nobody to ask (no terminal, no Neovim). Either" >&2
echo "  compress them: LARGE_FILE_ACTION=compress git commit ...   (or: bash \"$0\" --compress)" >&2
echo "  for this repo for good: git config largefiles.action compress" >&2
echo "  or commit anyway: LARGE_FILE_OK=1 git commit ..." >&2
finish 1
