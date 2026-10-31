#!/usr/bin/env bash
# Puts the FM-1 Hub pages into the folder that serves torindrax.com, as <web root>/FM1Hub.
# Usage: bash FM1Hub-site/deploy.sh [web-root]   (finds the torindrax.com folder itself if no path is given)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/FM1Hub"
[ -f "$SRC/index.html" ] || { echo "Stopped: FM1Hub/index.html is not next to this script."; exit 1; }

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  FOUND=$(find /var/www /srv /usr/share/nginx /opt "$HOME" -maxdepth 5 -name index.html -not -path '*FM1Hub*' 2>/dev/null \
          | xargs -r grep -lsF 'SYS.STATUS' 2>/dev/null || true)
  COUNT=$(printf '%s' "$FOUND" | grep -c . || true)
  if [ "$COUNT" -ne 1 ]; then
    echo "Stopped: could not tell which folder serves torindrax.com (found $COUNT candidates)."
    [ -n "$FOUND" ] && printf '%s\n' "$FOUND"
    echo "Run it again with the folder, e.g.:  bash FM1Hub-site/deploy.sh /var/www/torindrax.com"
    exit 1
  fi
  ROOT="$(dirname "$FOUND")"
fi
[ -d "$ROOT" ] || { echo "Stopped: $ROOT is not a folder."; exit 1; }
[ -w "$ROOT" ] || { echo "Stopped: no write access to $ROOT. Run it again with sudo:  sudo bash FM1Hub-site/deploy.sh \"$ROOT\""; exit 1; }

echo "torindrax.com folder: $ROOT"
rm -rf "$ROOT/FM1Hub.new"
cp -r "$SRC" "$ROOT/FM1Hub.new"
if [ -d "$ROOT/FM1Hub" ]; then
  # outside the web root, because nginx would serve anything kept inside it
  BACKUPS="$HOME/fm1hub-site-backups"
  mkdir -p "$BACKUPS"
  OLD="$BACKUPS/FM1Hub.old.$(date +%Y%m%d-%H%M%S)"
  mv "$ROOT/FM1Hub" "$OLD"
  echo "Previous version kept as $OLD"
fi
mv "$ROOT/FM1Hub.new" "$ROOT/FM1Hub"
chmod -R a+rX "$ROOT/FM1Hub"
# the lowercase address sends people to the real one
mkdir -p "$ROOT/fm1hub"
cat > "$ROOT/fm1hub/index.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>FM-1 Hub</title>
<link rel="canonical" href="/FM1Hub/"><meta http-equiv="refresh" content="0; url=/FM1Hub/"></head>
<body><a href="/FM1Hub/">FM-1 Hub</a></body></html>
HTML
chmod -R a+rX "$ROOT/fm1hub"
echo "Done. Files:"
find "$ROOT/FM1Hub" -type f | sed "s#^$ROOT##"
echo
echo "Page:    https://torindrax.com/FM1Hub/"
echo "Privacy: https://torindrax.com/FM1Hub/privacy/"
