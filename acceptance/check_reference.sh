#!/bin/sh
# Is this site's RefSeq bundle the one of the published acceptance run? Compares the genomes' accessions with
# acceptance/refseq-viral-accessions.txt (19,607, sha256 8e7bc69d...), and says how many were added or removed.
# NCBI Datasets serves RefSeq as it is on the day: a bundle built later differs by the genomes added since.
#   sh acceptance/check_reference.sh [data dir]       from the repository root, where erl runs (genhub2-dev)
set -eu
data=${1:-data}
hash=$(cat "$data/bundles/refseq_viral")
fai=$(erl -noshell -eval "{ok, B} = file:read_file(\"$data/store/$(echo "$hash" | cut -c1-2)/$hash\"),
  io:format(\"~s\", [maps:get(\"refs.fasta.fai\", binary_to_term(B))]), halt().")
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cut -f1 "$data/store/$(echo "$fai" | cut -c1-2)/$fai" | LC_ALL=C sort > "$tmp"
echo "this site's bundle: $(wc -l < "$tmp") genomes, accessions sha256 $(sha256sum < "$tmp" | cut -c1-16)..."
echo "the published run:  $(wc -l < acceptance/refseq-viral-accessions.txt) genomes, accessions sha256 $(sha256sum < acceptance/refseq-viral-accessions.txt | cut -c1-16)..."
added=$(comm -13 acceptance/refseq-viral-accessions.txt "$tmp" | wc -l)
removed=$(comm -23 acceptance/refseq-viral-accessions.txt "$tmp" | wc -l)
if [ "$added" -eq 0 ] && [ "$removed" -eq 0 ]; then
    echo "the same reference genomes"
else
    echo "different: $added genomes added since, $removed removed (comm against acceptance/refseq-viral-accessions.txt lists them)"
    exit 1
fi
