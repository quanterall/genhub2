#!/bin/sh
# Phase B's acceptance test (gh_phase_b.erl): this machine as two of a lab's nodes, each an Erlang node in its own
# genhub2-dev container on its own cores, joined by Erlang distribution on a Docker network of their own.
#   sh acceptance/run_phase_b.sh [SITE_CPUS [WORKER_CPUS]]      default 0-4 and 10-14 (five efficiency cores each)
# The site node (the coordinator) keeps phase A's data under data/; the worker has its own store
# (data/phase-b-worker) and fetches what its tasks need from the site by hash. The distribution cookie is made for
# the run and is not kept.
set -e
# storage_encryption warn: a test on public data, on a disk that may not be encrypted (gh_storage); a site with
# patients' data keeps the default, required
cd "$(dirname "$0")/.."
SITE_CPUS=${1:-0-4}; WORKER_CPUS=${2:-10-14}
NET=genhub2-phase-b; WORKER=genhub2-phase-b-worker
DATE=$(date -u +%Y-%m-%dT%H%MZ); HOSTNAME=$(hostname -s)
OUT=acceptance/results/phase-b-$HOSTNAME-$DATE.json
COOKIE=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
# the worker starts with an empty store every run, so part 0 measures its first fetch of the references
WORKER_DATA=data/phase-b-worker
case "$WORKER_DATA" in data/phase-b-worker) rm -rf -- "./$WORKER_DATA" ;; *) echo "unexpected worker data dir" >&2; exit 1 ;; esac
mkdir -p data/mnesia-phase-b "$WORKER_DATA" .cache-home
RUN="docker run --rm --user $(id -u):$(id -g) -e HOME=$PWD/.cache-home -e CARGO_HOME=$PWD/.cache-home/cargo
     -e COOKIE=$COOKIE -v $HOME:$HOME -w $PWD --network $NET"
docker network inspect $NET >/dev/null 2>&1 || docker network create $NET >/dev/null
# only the container this script started is stopped
trap 'docker stop $WORKER genhub2-phase-b-site >/dev/null 2>&1 || true' EXIT
docker run --rm --user "$(id -u):$(id -g)" -e HOME="$PWD/.cache-home" -e CARGO_HOME="$PWD/.cache-home/cargo" \
  -v "$HOME:$HOME" -w "$PWD" genhub2-dev sh -c "rebar3 compile >/dev/null"
$RUN -d --name $WORKER --hostname $WORKER --cpuset-cpus="$WORKER_CPUS" genhub2-dev sh -c "
  erl -noshell -sname gh_worker -setcookie \"\$COOKIE\" -mnesia dir '\"/tmp/mnesia\"' -pa _build/default/lib/*/ebin -genhub2 storage_encryption warn \
      -genhub2 role worker -genhub2 data_dir '\"data/phase-b-worker\"' -genhub2 http undefined \
      -eval '{ok, _} = application:ensure_all_started(genhub2)'" >/dev/null
$RUN --name genhub2-phase-b-site --hostname genhub2-phase-b-site --cpuset-cpus="$SITE_CPUS" genhub2-dev sh -c "
  erl -noshell -sname gh_site -setcookie \"\$COOKIE\" -mnesia dir '\"data/mnesia-phase-b\"' -pa _build/default/lib/*/ebin -genhub2 storage_encryption warn \
      -pa _build/default/lib/genhub2/acceptance -genhub2 http undefined \
      -eval 'gh_phase_b:main([\"gh_worker@$WORKER\", \"$OUT\"])'"
