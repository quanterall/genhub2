#!/bin/sh
# Phase A's acceptance test (gh_acceptance.erl) in the genhub2-dev image, on one node.
#   sh acceptance/run.sh HOST_INDEX GRCH38_FASTA [cpuset]
# HOST_INDEX: minimap2 -x sr index of GRCh38 (e.g. PQCF's research/variants/data/*.fna.mmi); GRCH38_FASTA: the same
# genome, indexed (samtools faidx). Both must be under $HOME, which is mounted at the same path, so the store can
# hard-link the 8.7 GB index instead of copying it. The container's host name is fixed, so the node name and its Mnesia
# schema are the same on every run (jobs resume).
set -e
cd "$(dirname "$0")/.."
HOSTIDX=$(realpath "$1"); GRCH38=$(realpath "$2"); CPUS=${3:-0-4,10-14}
DATE=$(date -u +%Y-%m-%dT%H%MZ); HOSTNAME=$(hostname -s)
OUT=acceptance/results/phase-a-$HOSTNAME-$DATE.json
mkdir -p data/mnesia .cache-home
docker run --rm --hostname genhub2 --user "$(id -u):$(id -g)" --cpuset-cpus="$CPUS" -e HOME="$PWD/.cache-home" \
  -e CARGO_HOME="$PWD/.cache-home/cargo" -v "$HOME:$HOME" -w "$PWD" genhub2-dev sh -c "
  rebar3 compile >/dev/null &&
  erl -noshell -sname gh_acceptance -mnesia dir '\"data/mnesia\"' -pa _build/default/lib/*/ebin \
      -pa _build/default/lib/genhub2/acceptance -eval 'gh_acceptance:main([\"$HOSTIDX\", \"$GRCH38\", \"$OUT\"])'"
