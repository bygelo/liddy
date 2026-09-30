#!/usr/bin/env bash
# Publish site/ to liddy.bygelo.com.
#
# The site is static — no build step, no dependency, nothing to install. This
# copies it to the VPS and reloads nginx, and it is safe to run repeatedly.
#
#   ./Script/deploy-site.sh            # deploy
#   ./Script/deploy-site.sh --dry-run  # show what would change, copy nothing
#
# One-time setup on the box is in Script/site-nginx.conf.

set -euo pipefail

HOST="${LIDDY_SITE_HOST:-bygelo}"
ROOT="${LIDDY_SITE_ROOT:-/var/www/liddy}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$HERE/site/index.html" ]; then
    echo "==> no site/index.html — run this from the repo" >&2
    exit 1
fi

# A plain "${DRY[@]}" on an empty array trips `set -u` under bash 3.2, which is
# what ships with macOS — the ${x+...} guard expands to nothing when it is empty.
DRY=()
[ "${1:-}" = "--dry-run" ] && DRY=(--dry-run) && echo "==> dry run, nothing will be written"

echo "==> deploying site/ to $HOST:$ROOT"

# --delete keeps the served tree identical to the repo, so a file removed here
# stops being reachable there. Everything under site/ is meant to be public.
rsync -az --delete ${DRY[@]+"${DRY[@]}"} \
    --exclude '.DS_Store' \
    "$HERE/site/" "$HOST:$ROOT/"

if [ ${#DRY[@]} -eq 0 ]; then
    ssh "$HOST" "chown -R www-data:www-data $ROOT && nginx -t && systemctl reload nginx"
    echo "==> live at https://liddy.bygelo.com"
fi
