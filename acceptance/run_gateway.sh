#!/bin/sh
# Phase A's gateway and MQTT check (gh_gateway_check.erl): GenHub2's HTTP API, WebSocket and the site's EMQX broker.
# Starts EMQX 5.8.9 (Apache 2.0, the last release under it; plan section 3.8) on this machine only (MQTT on 127.0.0.1:21883; dashboard not published), unless one is
# already running as genhub2-emqx, and stops it afterwards unless KEEP_EMQX=1. Needs the reference bundles of
# acceptance/run.sh.
#   sh acceptance/run_gateway.sh [cpuset]
set -e
cd "$(dirname "$0")/.."
CPUS=${1:-0-4,10-14}
DATE=$(date -u +%Y-%m-%dT%H%MZ); HOSTNAME=$(hostname -s)
OUT=acceptance/results/gateway-$HOSTNAME-$DATE.json
STARTED=
if [ -z "$(docker ps -q --filter name=^genhub2-emqx$)" ]; then
  docker run -d --rm --name genhub2-emqx -p 127.0.0.1:21883:1883 emqx/emqx:5.8.9 >/dev/null
  STARTED=1
  until docker exec genhub2-emqx emqx ctl status 2>/dev/null | grep -q "is started"; do sleep 1; done
fi
# the check's site starts with no jobs (its alerts are for the first species and lineage seen)
d=data/mnesia-gateway; rm -rf "${d:?}"
mkdir -p data/mnesia-gateway .cache-home
set +e
docker run --rm --network host --user "$(id -u):$(id -g)" --cpuset-cpus="$CPUS" \
  -e HOME="$PWD/.cache-home" -v "$HOME:$HOME" -w "$PWD" genhub2-dev sh -c "
  rebar3 compile >/dev/null &&
  erl -noshell -sname gh_acceptance -mnesia dir '\"data/mnesia-gateway\"' -pa _build/default/lib/*/ebin \
      -pa _build/default/lib/genhub2/acceptance -eval 'gh_gateway_check:main([\"$OUT\"])'"
RC=$?
[ -n "$STARTED" ] && [ -z "$KEEP_EMQX" ] && docker stop genhub2-emqx >/dev/null
exit $RC
