#!/bin/sh
# Regenerate AI_ATTRIBUTION.md from the AI-Attribution trailers in commit messages.
# Commits without the trailer had no AI involvement and are omitted.
set -eu

cd "$(git rev-parse --show-toplevel)"

{
  printf '# AI Attribution Log\n\n'
  printf 'Commits where AI was used, oldest first, with a short note on how.\n'
  printf 'Commits with no AI involvement have no entry.\n\n'
  printf 'Generated from `AI-Attribution:` commit trailers by `scripts/gen-ai-attribution.sh`.\n'
  printf 'Do not edit by hand.\n'

  git log --reverse --format='%h%x1f%s%x1f%(trailers:key=AI-Attribution,valueonly,separator=%x20)%x1e' |
    awk 'BEGIN { RS = "\036\n?"; FS = "\037" }
         $3 != "" { sub(/\n+$/, "", $3); printf "\n## %s — %s\n\n%s\n", $1, $2, $3 }'
} > AI_ATTRIBUTION.md
