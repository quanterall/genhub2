# GenHub2's build, test and analysis environment: PQCF's (OTP 27, the pinned Rust toolchain) with the variant tools
# (minimap2, samtools, bcftools; research/variants in PQCF), plus MAFFT (BSD), FastTree (GPL: called only as a
# separate program, FS 11) and Nextclade (MIT) for SARS-CoV-2 lineages.
#   docker build -t pqcf-dev ~/pqcf && docker build -t pqcf-variants ~/pqcf/research/variants/docker
#   docker build -t genhub2-dev docker
FROM pqcf-variants
RUN apt-get update && apt-get install -y --no-install-recommends mafft=7.505-1 fasttree=2.1.11-2 && rm -rf /var/lib/apt/lists/*
RUN curl -sL -o /usr/local/bin/nextclade \
      https://github.com/nextstrain/nextclade/releases/download/3.29.0/nextclade-aarch64-unknown-linux-gnu \
 && chmod +x /usr/local/bin/nextclade
