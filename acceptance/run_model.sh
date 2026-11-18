#!/bin/sh
# Phase E's model test (gh_model_check.erl): naive Bayes on 6-mers against GenHub2's classical classification, on
# phase A's 593 held-out genomes. Needs the reference bundles and genomes of acceptance/run.sh.
#   sh acceptance/run_model.sh [cpuset]
set -e
# storage_encryption warn: a test on public data, on a disk that may not be encrypted (gh_storage); a site with
# patients' data keeps the default, required
cd "$(dirname "$0")/.."
CPUS=${1:-0-4,10-14}
DATE=$(date -u +%Y-%m-%dT%H%MZ); HOSTNAME=$(hostname -s)
OUT=acceptance/results/model-$HOSTNAME-$DATE.json
mkdir -p data/mnesia-model .cache-home
docker run --rm --hostname genhub2 --user "$(id -u):$(id -g)" --cpuset-cpus="$CPUS" -e HOME="$PWD/.cache-home" \
  -e CARGO_HOME="$PWD/.cache-home/cargo" -v "$HOME:$HOME" -w "$PWD" genhub2-dev sh -c "
  rebar3 compile >/dev/null &&
  erl -noshell -sname gh_model -mnesia dir '\"data/mnesia-model\"' -pa _build/default/lib/*/ebin -genhub2 storage_encryption warn \
      -pa _build/default/lib/genhub2/acceptance -genhub2 http undefined \
      -eval 'gh_model_check:main([\"$OUT\"])'"
