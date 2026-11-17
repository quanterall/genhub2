# genhub2-task: the image GenHub2's tasks run in on FVLLMP federation nodes (FS 4.5; acceptance/FEDERATION.md).
# Never published to a registry: it is handed to GenHub2's own node, which carries it to its peers. Every node that
# runs it can read its recipe (this file, also at /fvllmp/Dockerfile in the image) and its purpose (the labels).
# GenHub2's Rust kernels (gh2k, Apache 2.0) and minimap2 (MIT; Li 2018, doi:10.1093/bioinformatics/bty191, Debian's
# package, the version of GenHub2's build image), on Debian's slim base: the nodes run tasks without network, with a
# read-only root filesystem, inputs under /work/in and outputs under /work/out. Both stages are pinned by digest, so
# the same source gives the same program. linux/arm64: the federation's nodes are DGX Sparks.
#   docker build --platform linux/arm64 -t genhub2-task -f docker/task/Dockerfile .
FROM rust:1.90.0-slim-bookworm@sha256:64232e656c058f4468e8d024e990acff04f0fd5a5c0a88a574dc37773d7325c9 AS build
WORKDIR /src
COPY native/gh2k/Cargo.toml native/gh2k/Cargo.lock ./
COPY native/gh2k/src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
RUN apt-get update && apt-get install -y --no-install-recommends minimap2=2.24+dfsg-3+b1 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/gh2k /usr/local/bin/gh2k
COPY LICENSE NOTICE /usr/share/doc/genhub2/
COPY docker/task/Dockerfile /fvllmp/Dockerfile
LABEL org.opencontainers.image.title="genhub2-task" \
      org.opencontainers.image.source="https://github.com/quanterall/genhub2/blob/main/docker/task/Dockerfile" \
      org.opencontainers.image.description="GenHub2's analyses of viral genomes: classification by MinHash distance to the RefSeq viral reference genomes (gh2k), mutations against a reference genome (minimap2), and phylogenetic trees (Jukes-Cantor distance tiles, bootstrap replicates of neighbour-joining trees). Inputs are viral genomes and reference data given as inputs. No network; no personal data." \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Quanterall"
USER 65534:65534
WORKDIR /work
ENTRYPOINT []
CMD ["gh2k"]
