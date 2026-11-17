# genhub2-task: the image GenHub2's tasks run in on FVLLMP federation nodes (FS 4.5; acceptance/FEDERATION.md).
# Only GenHub2's Rust kernels (gh2k, Apache 2.0), on Debian's slim base: the nodes run tasks without network, with a
# read-only root filesystem, inputs under /work/in and outputs under /work/out. Both stages are pinned by digest, so
# the same source gives the same program. linux/arm64: the federation's nodes are DGX Sparks.
#   docker build --platform linux/arm64 -t genhub2-task -f docker/task/Dockerfile .
FROM rust:1.90.0-slim-bookworm@sha256:64232e656c058f4468e8d024e990acff04f0fd5a5c0a88a574dc37773d7325c9 AS build
WORKDIR /src
COPY native/gh2k/Cargo.toml native/gh2k/Cargo.lock ./
COPY native/gh2k/src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
COPY --from=build /src/target/release/gh2k /usr/local/bin/gh2k
COPY LICENSE NOTICE /usr/share/doc/genhub2/
USER 65534:65534
WORKDIR /work
ENTRYPOINT []
CMD ["gh2k"]
