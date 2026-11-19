#!/bin/sh
# The joint test with TechUPGRADE (gh_joint_check.erl): GenHub2's test site opens the structure view for four public
# genomes through TechUPGRADE's external integration protocol v1.
#   sh acceptance/run_joint.sh dry     the links checked here only; nothing is sent
#   sh acceptance/run_joint.sh push    the joint test: hand-offs pushed to TechUPGRADE's test entry point
# VIEWER_BASE: the entry point (default https://techupgrade2.quanterall.com); VIEWER_KEY: the test key's private file
# (default ~/.config/genhub2/viewer/genhub2-test-2026a.key; scripts/genhub2-admin.sh ... viewer_key makes one).
# Starts EMQX 5.8.9 on 127.0.0.1:21883 as run_gateway.sh does. Needs the reference bundles of acceptance/run.sh.
set -e
cd "$(dirname "$0")/.."
MODE=${1:-dry}
case "$MODE" in dry|push) ;; *) echo "usage: sh acceptance/run_joint.sh dry|push" >&2; exit 2 ;; esac
BASE=${VIEWER_BASE:-https://techupgrade2.quanterall.com}
KEY=${VIEWER_KEY:-$HOME/.config/genhub2/viewer/genhub2-test-2026a.key}
[ -r "$KEY" ] || { echo "no test key at $KEY" >&2; exit 2; }
DATE=$(date -u +%Y-%m-%dT%H%MZ); HOSTNAME=$(hostname -s)
OUT=acceptance/results/joint-$MODE-$HOSTNAME-$DATE.json
mkdir -p data/joint .cache-home

# the genomes: example sequences of Nextclade's datasets, at pinned tags
docker run --rm --user "$(id -u):$(id -g)" -e HOME="$PWD/.cache-home" -v "$PWD:$PWD" -w "$PWD/data/joint" genhub2-dev sh -c '
  get() { [ -s "$3/sequences.fasta" ] || nextclade dataset get --name "$1" --tag "$2" --output-dir "$3" >/dev/null; }
  get nextstrain/sars-cov-2/wuhan-hu-1/orfs 2026-10-28--15-04-26Z sars-cov-2 &&
  get nextstrain/rsv/a/EPI_ISL_412866 2026-04-14--11-55-23Z rsv-a &&
  get nextstrain/rsv/b/EPI_ISL_1653999 2026-04-14--11-55-23Z rsv-b'
pick() { awk -v id=">$2" '/^>/ { p = ($1 == id) } p' "data/joint/$1/sequences.fasta" > "data/joint/$2.fa"
         [ -s "data/joint/$2.fa" ] || { echo "$2 not in $1" >&2; exit 1; }; }
pick sars-cov-2 ON544943
pick rsv-a PP_0030E57
pick rsv-b PP_002XZ5U
sha256sum data/joint/*.fa

STARTED=
if [ -z "$(docker ps -q --filter name=^genhub2-emqx$)" ]; then
  docker run -d --rm --name genhub2-emqx -p 127.0.0.1:21883:1883 emqx/emqx:5.8.9 >/dev/null
  STARTED=1
  until docker exec genhub2-emqx emqx ctl status 2>/dev/null | grep -q "is started"; do sleep 1; done
fi
# a site of its own, with no earlier jobs or users
d=data/mnesia-joint; rm -rf "${d:?}"
mkdir -p data/mnesia-joint
set +e
docker run --rm --network host --user "$(id -u):$(id -g)" \
  -e HOME="$PWD/.cache-home" -v "$HOME:$HOME" -w "$PWD" genhub2-dev sh -c "
  rebar3 compile >/dev/null &&
  erl -noshell -sname gh_joint -mnesia dir '\"data/mnesia-joint\"' -pa _build/default/lib/*/ebin -genhub2 storage_encryption warn \
      -pa _build/default/lib/genhub2/acceptance \
      -eval 'gh_joint_check:main([\"$OUT\", \"$MODE\", \"$BASE\", \"$KEY\", \"data/joint\"])'"
RC=$?
[ -n "$STARTED" ] && [ -z "$KEEP_EMQX" ] && docker stop genhub2-emqx >/dev/null
exit $RC
