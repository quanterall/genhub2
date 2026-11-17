#!/bin/sh
# The site operator's commands (gh_cli), in GenHub2's image, on the site's Mnesia directory. Run with the site stopped.
#   sh scripts/genhub2-admin.sh MNESIA_DIR add_user NAME admin|analyst|researcher    asks for the password (not echoed)
#   sh scripts/genhub2-admin.sh MNESIA_DIR audit_verify
# MNESIA_DIR: the site's, e.g. data/mnesia. The node name must be the site's (Mnesia keeps it): GENHUB2_NODE, default
# genhub2, with the host name GENHUB2_HOST (default genhub2), as acceptance/run.sh starts it.
set -e
cd "$(dirname "$0")/.."
DIR=$1; shift
[ -d "$DIR" ] || mkdir -p "$DIR"
NODE=${GENHUB2_NODE:-genhub2}; HOST=${GENHUB2_HOST:-genhub2}
ARGS=$(printf '"%s", ' "$@"); ARGS="[${ARGS%, }]"
if [ "$1" = add_user ]; then
  if [ -t 0 ]; then
    printf 'password for %s (12 characters or more): ' "$2" >&2
    stty -echo; read -r PW; stty echo; printf '\n' >&2
  else
    read -r PW
  fi
fi
printf '%s\n' "${PW:-}" | docker run --rm -i --hostname "$HOST" --user "$(id -u):$(id -g)" -e HOME="$PWD/.cache-home" \
  -v "$HOME:$HOME" -w "$PWD" genhub2-dev sh -c "
  erl -noshell -sname $NODE -mnesia dir '\"$DIR\"' -pa _build/default/lib/*/ebin -eval 'gh_cli:main($ARGS)'"
