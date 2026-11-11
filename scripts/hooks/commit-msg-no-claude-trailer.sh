#!/usr/bin/env bash
# commit-msg-no-claude-trailer.sh -- strip Claude/Anthropic Co-Authored-By trailers.
#
# Git runs this as a commit-msg hook with the message file as $1. Lines starting with
# "Co-Authored-By:" (any case) that mention Claude or Anthropic are removed, then
# blank lines left over (consecutive, trailing) are squeezed. Everything else, including
# Co-Authored-By lines of real people, stays untouched. Always exits 0, except when
# nothing would be left of the message (exit 1, commit aborted).

msg="$1"
[ -f "$msg" ] || exit 0

# Match against a CR-stripped copy so autocrlf checkouts behave; the file itself is
# only rewritten when something was actually removed.
pattern='^[[:space:]]*co-authored-by:.*(claude|anthropic)'
if ! tr -d '\r' <"$msg" | grep -qiE "$pattern"; then
  exit 0
fi

tmp="$(mktemp)" || exit 0
trap 'rm -f "$tmp"' EXIT

# Drop matching lines, then collapse runs of blank lines and trim trailing ones.
tr -d '\r' <"$msg" | grep -viE "$pattern" | awk '
  /^[[:space:]]*$/ { blank++; next }
  { if (blank && started) print ""; blank = 0; started = 1; print }
' >"$tmp"

if ! grep -q '[^[:space:]]' "$tmp"; then
  echo "commit-msg: message contains only a Claude/Anthropic trailer; refusing empty commit message" >&2
  exit 1
fi

cat "$tmp" >"$msg"
echo "commit-msg: removed Claude/Anthropic Co-Authored-By trailer" >&2
exit 0
