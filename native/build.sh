#!/bin/sh
# Builds the Rust kernels (gh2k) and puts the program where gh_tool runs it from (priv/gh2k).
set -e
cd "$(dirname "$0")/gh2k"
cargo build --release --locked -q 2>/dev/null || cargo build --release -q
mkdir -p ../../priv
cp target/release/gh2k ../../priv/gh2k
