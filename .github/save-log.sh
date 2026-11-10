#!/bin/bash
# Saves a short build log on the "ci-logs" branch so results can be read without opening GitHub Actions.
name="$1"; file="$2"
[ -f "$file" ] || echo "(no log)" > "$file"
url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
work="$RUNNER_TEMP/ci-logs-$name"; rm -rf "$work"
if ! git clone --quiet --depth 1 --branch ci-logs "$url" "$work" 2>/dev/null; then
  mkdir -p "$work" && cd "$work" && git init -q && git checkout -q -b ci-logs && git remote add origin "$url"
fi
cd "$work" || exit 0
git config user.name "ChargeCheck CI"; git config user.email "ci@users.noreply.github.com"
{ echo "commit: $GITHUB_SHA"; echo "result: $RESULT"; echo "when: $(date -u)"; echo; tail -c 60000 "$file"; } > "$name.txt"
[ "$name" = "app" ] && cp /tmp/shot-*.png . 2>/dev/null
git add -A && git commit -qm "$name: $RESULT ($GITHUB_SHA)" || exit 0
for i in 1 2 3 4; do
  git push -q origin ci-logs && exit 0
  git pull -q --rebase origin ci-logs || true
  sleep 3
done
exit 0
