#!/bin/sh
# The added methods' check (gh_methods_check.erl): VeryFastTree, UShER, Nextclade's datasets, Hostile, iVar,
# Kraken 2 + Bracken, each against what it adds to. Needs the bundles of acceptance/run.sh and those built by
# gh_refdb:hostile/1, primers/2 and kraken/1 (README).
#   sh acceptance/run_methods.sh HOST_INDEX GRCH38_FASTA [cpuset]
set -e
cd "$(dirname "$0")/.."
HOSTIDX=$(realpath "$1"); GRCH38=$(realpath "$2"); CPUS=${3:-0-4,10-14}
DATE=$(date -u +%Y-%m-%dT%H%MZ); HOSTNAME=$(hostname -s)
OUT=acceptance/results/methods-$HOSTNAME-$DATE.json
d=data/mnesia-methods; rm -rf "${d:?}"
mkdir -p data/mnesia-methods .cache-home
docker run --rm --hostname genhub2 --user "$(id -u):$(id -g)" --cpuset-cpus="$CPUS" -e HOME="$PWD/.cache-home" \
  -v "$HOME:$HOME" -w "$PWD" genhub2-dev sh -c "
  rebar3 compile >/dev/null &&
  erl -noshell -sname gh_methods -mnesia dir '\"data/mnesia-methods\"' -pa _build/default/lib/*/ebin \
      -pa _build/default/lib/genhub2/acceptance -eval 'gh_methods_check:main([\"$HOSTIDX\", \"$GRCH38\", \"$OUT\"])'"
