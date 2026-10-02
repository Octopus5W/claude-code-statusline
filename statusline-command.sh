#!/usr/bin/env bash
# Claude Code status line, two rows, truecolor
#
#  Row 1  ▌ repo  ⎇ branch  ·  +added −removed vs main  ·  $cost
#  Row 2  ctx ███░░┃░ 12%  │  session 53k ↑45k ↓8k  │  today 1.2M  │  5h ██░░ 8%  7d █░░░ 2%

input=$(cat)

ESC=$'\033'
RST="${ESC}[0m"
BOLD="${ESC}[1m"
fg() { printf '%s[38;2;%s;%s;%sm' "$ESC" "$1" "$2" "$3"; }

# ── Palette ──────────────────────────────────────────────────────────────────
C_ACCENT=$(fg 99 179 237)   # sky blue: repo
C_BRANCH=$(fg 154 230 180)  # mint: branch
C_LABEL=$(fg 113 128 150)   # slate: labels
C_TEXT=$(fg 226 232 240)    # near white: values
C_SEP=$(fg 74 85 104)       # separators
C_TRACK=$(fg 45 55 72)      # empty bar track
C_ADD=$(fg 72 207 130)
C_DEL=$(fg 245 101 101)
C_COST=$(fg 246 201 100)
C_TODAY=$(fg 183 148 244)
C_OK=$(fg 72 207 130)
C_WARN=$(fg 246 173 85)
C_BAD=$(fg 245 101 101)
C_MARK=$(fg 246 173 85)    # auto-compact tick

SEP=" ${C_SEP}│${RST} "
DOT=" ${C_SEP}·${RST} "

# ── JSON extraction (single jq pass) ─────────────────────────────────────────
eval "$(echo "$input" | jq -r '
  @sh "repo_name=\(.workspace.repo.name // (.workspace.project_dir // "" | split("/") | last) // "claude")",
  @sh "cwd=\(.workspace.current_dir // .cwd // ".")",
  @sh "ctx_raw=\(.context_window.used_percentage // 0)",
  @sh "total_input=\(.context_window.total_input_tokens // 0)",
  @sh "total_output=\(.context_window.total_output_tokens // 0)",
  @sh "cost_raw=\(.cost.total_cost_usd // 0)",
  @sh "five_h=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "seven_d=\(.rate_limits.seven_day.used_percentage // "")"
')"
[ -z "$repo_name" ] && repo_name="claude"
ctx_pct=$(printf "%.0f" "$ctx_raw")

# ── Helpers ──────────────────────────────────────────────────────────────────
# Level color: green < 60, amber < 85, red otherwise
level_color() {
  if [ "$1" -lt 60 ]; then printf '%s' "$C_OK"
  elif [ "$1" -lt 85 ]; then printf '%s' "$C_WARN"
  else printf '%s' "$C_BAD"
  fi
}

# bar <pct> <width> [marker-cell]: solid blocks in level color over a dim track,
# with an optional tick drawn after <marker-cell> cells
bar() {
  local pct=$1 width=$2 mark=${3:-0} filled i out=""
  [ "$pct" -gt 100 ] && pct=100
  filled=$(( (pct * width + 50) / 100 ))
  [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  out="$(level_color "$pct")"
  for ((i = 0; i < width; i++)); do
    [ "$mark" -gt 0 ] && [ "$i" -eq "$mark" ] && out+="${C_MARK}┃"
    if [ "$i" -lt "$filled" ]; then out+="$(level_color "$pct")█"; else out+="${C_TRACK}░"; fi
  done
  printf '%s%s' "$out" "$RST"
}

# 1234 -> 1.2k, 1234567 -> 1.2M
fmt_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000)    printf "%.1fM", n / 1000000
    else if (n >= 10000) printf "%.0fk", n / 1000
    else if (n >= 1000)  printf "%.1fk", n / 1000
    else                 printf "%d", n
  }'
}

# usage_segment <label> <pct-or-empty>
usage_segment() {
  if [ -z "$2" ]; then
    printf '%s%s%s %s–%s' "$C_LABEL" "$1" "$RST" "$C_SEP" "$RST"
    return
  fi
  local p
  p=$(printf "%.0f" "$2")
  printf '%s%s%s %s %s%s%d%%%s' "$C_LABEL" "$1" "$RST" "$(bar "$p" 6)" "$BOLD" "$(level_color "$p")" "$p" "$RST"
}

# ── Git: branch + lines changed vs main (commits + uncommitted) ──────────────
branch=""
added=0
deleted=0
if git --no-optional-locks -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)

  base_ref=main
  git --no-optional-locks -C "$cwd" rev-parse --verify -q origin/main >/dev/null && base_ref=origin/main
  base=$(git --no-optional-locks -C "$cwd" merge-base HEAD "$base_ref" 2>/dev/null)
  if [ -n "$base" ]; then
    read -r added deleted < <(
      git --no-optional-locks -C "$cwd" diff --numstat "$base" 2>/dev/null \
        | awk '$1 ~ /^[0-9]+$/ {a+=$1} $2 ~ /^[0-9]+$/ {d+=$2} END {print a+0, d+0}'
    )
  fi
fi

# ── Tokens used today on this machine, all sessions (cached, background) ─────
CACHE="${TMPDIR:-/tmp}/claude-statusline-alltokens.cache"
refresh_all_tokens() {
  (
    find "$HOME/.claude/projects" -name '*.jsonl' -mtime -1 -print0 2>/dev/null \
      | xargs -0 cat 2>/dev/null \
      | jq -rn --argjson start "$(date -v0H -v0M -v0S +%s 2>/dev/null || date -d 'today 00:00' +%s)" '
          [inputs | select(.type == "assistant" and .message.usage != null
                           and ((.timestamp // "1970-01-01T00:00:00Z" | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $start))
           | {id: (.message.id // .uuid), u: .message.usage}]
          | unique_by(.id)
          | map((.u.input_tokens // 0) + (.u.output_tokens // 0)
                + (.u.cache_creation_input_tokens // 0))
          | add // 0' > "$CACHE.tmp" 2>/dev/null \
      && mv "$CACHE.tmp" "$CACHE"
  ) >/dev/null 2>&1 &
}
if [ ! -f "$CACHE" ] || [ -n "$(find "$CACHE" -mmin +1 2>/dev/null)" ]; then
  refresh_all_tokens
fi
all_tokens=$(cat "$CACHE" 2>/dev/null || echo 0)

cost=$(awk -v c="$cost_raw" 'BEGIN { printf (c < 1 ? "$%.3f" : "$%.2f"), c }')

# ── Row 1: identity ──────────────────────────────────────────────────────────
printf '%s▌%s %s%s%s' "$C_ACCENT" "$RST" "${BOLD}${C_ACCENT}" "$repo_name" "$RST"
[ -n "$branch" ] && printf '  %s⎇%s %s%s%s' "$C_LABEL" "$RST" "$C_BRANCH" "$branch" "$RST"
printf '%s%s+%d%s %s−%d%s' "$DOT" "$C_ADD" "$added" "$RST" "$C_DEL" "$deleted" "$RST"
printf '%s%s%s%s' "$DOT" "$C_COST" "$cost" "$RST"
printf '\n'

# ── Row 2: usage ─────────────────────────────────────────────────────────────
# Tick where auto-compact triggers (~80% by default, approximate)
compact_at=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-80}
case "$compact_at" in ''|*[!0-9]*|0) compact_at=80 ;; esac
printf '%sctx%s %s %s%s%d%%%s' "$C_LABEL" "$RST" "$(bar "$ctx_pct" 10 $(( compact_at * 10 / 100 )))" "$BOLD" "$(level_color "$ctx_pct")" "$ctx_pct" "$RST"
printf '%s%ssession%s %s%s%s %s↑%s ↓%s%s' "$SEP" "$C_LABEL" "$RST" "${BOLD}${C_TEXT}" "$(fmt_tokens "$((total_input + total_output))")" "$RST" \
  "$C_LABEL" "$(fmt_tokens "$total_input")" "$(fmt_tokens "$total_output")" "$RST"
printf '%s%stoday%s %s%s%s' "$SEP" "$C_LABEL" "$RST" "${BOLD}${C_TODAY}" "$(fmt_tokens "$all_tokens")" "$RST"
printf '%s%s  %s' "$SEP" "$(usage_segment 5h "$five_h")" "$(usage_segment 7d "$seven_d")"
printf '\n'
