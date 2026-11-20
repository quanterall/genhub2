#!/bin/sh
# Prepares genhub2.quanterall.com's site on this machine, once:
#   sh deploy/genhub2.quanterall.com/setup.sh DATA [BUNDLES_FROM]
# DATA: the site's data directory (under $HOME), e.g. ~/genhub2-site/data. BUNDLES_FROM: a data directory whose
# reference bundles (refs, bundles, store, hostile-cache; acceptance/run.sh builds them) the site starts from,
# hard-linked, not copied: the store is written once per hash and never changed in place.
# Writes DATA/site.config from site.config.example and .env beside compose.yml. The checkout this script is in is the
# code the site runs (GENHUB2_SRC).
set -e
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$(cd "$HERE/../.." && pwd)
DATA=$(realpath -m "${1:?usage: setup.sh DATA [BUNDLES_FROM]}")
case "$DATA" in "$HOME"/*) ;; *) echo "$DATA: must be under $HOME" >&2; exit 2;; esac
mkdir -p "$DATA/home" "$DATA/mnesia"
if [ -n "$2" ]; then
  FROM=$(realpath "$2")
  for d in refs bundles store hostile-cache; do
    if [ -d "$FROM/$d" ] && [ ! -e "$DATA/$d" ]; then cp -al "$FROM/$d" "$DATA/$d"; echo "linked $d"; fi
  done
fi
[ -e "$DATA/site.config" ] || { sed "s|@DATA@|$DATA|" "$HERE/site.config.example" > "$DATA/site.config"; echo "wrote $DATA/site.config"; }
cat > "$HERE/.env" <<ENV
GENHUB2_SRC=$SRC
GENHUB2_SITE_DATA=$DATA
GENHUB2_UID=$(id -u)
GENHUB2_GID=$(id -g)
ENV
echo "wrote $HERE/.env"
echo "next: the first admin, with the site stopped:"
echo "  GENHUB2_DATA=$DATA sh $SRC/scripts/genhub2-admin.sh $DATA/mnesia add_user NAME admin"
echo "then: docker compose -f $HERE/compose.yml up -d"
