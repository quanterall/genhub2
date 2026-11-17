#!/bin/sh
# GenHub2 on the FVLLMP federation (gh_federation_check.erl): tasks sent to the FVLLMP node this machine runs, which
# runs them on itself or on a peer.
#   sh acceptance/run_federation.sh [IMAGE]     IMAGE: genhub2-task@sha256:... once the nodes' owners allow it;
#                                               without it, part 2 (GenHub2's own tasks) is skipped and said so
# GenHub2's token on the node is read from $GENHUB2_FED_TOKEN (default ~/.config/genhub2/federation/genhub2.token,
# mode 600, outside the repository). The node is $GENHUB2_FED_NODE (default http://127.0.0.1:18100). Part 2 uses the
# reference bundles and genomes of phase A's run (run.sh).
set -e
cd "$(dirname "$0")/.."
IMAGE=${1:-none}
TOKEN=${GENHUB2_FED_TOKEN:-$HOME/.config/genhub2/federation/genhub2.token}
NODE=${GENHUB2_FED_NODE:-http://127.0.0.1:18100}
[ -r "$TOKEN" ] || { echo "no token file: $TOKEN" >&2; exit 1; }
DATE=$(date -u +%Y-%m-%dT%H%MZ); HOSTNAME=$(hostname -s)
OUT=acceptance/results/federation-$HOSTNAME-$DATE.json
mkdir -p data/mnesia-federation .cache-home
# the host's network: the FVLLMP node listens on this machine's loopback address
docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME="$PWD/.cache-home" \
  -e CARGO_HOME="$PWD/.cache-home/cargo" -v "$HOME:$HOME" -w "$PWD" genhub2-dev sh -c "
  rebar3 compile >/dev/null &&
  erl -noshell -sname gh_federation -mnesia dir '\"data/mnesia-federation\"' -pa _build/default/lib/*/ebin \
      -pa _build/default/lib/genhub2/acceptance -genhub2 http undefined \
      -genhub2 federation '#{node => \"$NODE\", token_file => \"$TOKEN\", image => \"$IMAGE\", slots => 1}' \
      -eval 'gh_federation_check:main([\"$IMAGE\", \"$OUT\"])'"
