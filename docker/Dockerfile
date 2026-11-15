# GenHub2's build, test and analysis environment: PQCF's (OTP 27, the pinned Rust toolchain) with the variant tools
# (minimap2, samtools, bcftools; research/variants in PQCF), plus MAFFT (BSD), FastTree (GPL: called only as a
# separate program, FS 11) and Nextclade (MIT) for SARS-CoV-2 lineages.
#   docker build -t pqcf-dev ~/pqcf && docker build -t pqcf-variants ~/pqcf/research/variants/docker
#   docker build -t genhub2-dev docker
FROM pqcf-variants
RUN apt-get update && apt-get install -y --no-install-recommends mafft=7.505-1 fasttree=2.1.11-2 && rm -rf /var/lib/apt/lists/*
RUN curl -sL -o /usr/local/bin/nextclade \
      "https://github.com/nextstrain/nextclade/releases/download/3.29.0/nextclade-$(uname -m)-unknown-linux-gnu" \
 && chmod +x /usr/local/bin/nextclade
# Added tools (README, "Methods"). Packaged: DIAMOND (GPL-3, protein search), iVar (GPL-3, primer trimming),
# Kraken 2 (MIT, read classification), bowtie2 (GPL-3, for Hostile).
RUN apt-get update && apt-get install -y --no-install-recommends diamond-aligner=2.1.3-1 ivar=1.3.1+dfsg-7 \
        kraken2=2.1.2-2 bowtie2=2.5.0-3+b2 python3-venv cmake g++ make git libboost-filesystem-dev \
        libboost-program-options-dev libboost-iostreams-dev libboost-date-time-dev libprotobuf-dev protobuf-compiler \
        libtbb-dev rsync && rm -rf /var/lib/apt/lists/*
# VeryFastTree 4.0.5 (GPL-3): FastTree's algorithm, parallel; built without native CPU tuning, so it runs on any arm64
RUN git clone -q --depth 1 --branch v4.0.5 https://github.com/citiususc/veryfasttree /tmp/vft \
 && cmake -S /tmp/vft -B /tmp/vft/build -DUSE_NATIVE=OFF -DUSE_SEE2=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null \
 && make -C /tmp/vft/build -j8 >/dev/null && install /tmp/vft/build/VeryFastTree /usr/local/bin/ && rm -rf /tmp/vft
# Bracken 3.1 (GPL-3): species abundances from Kraken 2's read assignments
RUN git clone -q --depth 1 --branch v3.1 https://github.com/jenniferlu717/Bracken /opt/bracken \
 && make -C /opt/bracken/src >/dev/null && ln -s /opt/bracken/bracken /usr/local/bin/bracken \
 && ln -s /opt/bracken/src/est_abundance.py /usr/local/bin/est_abundance.py
# Hostile 2.0.2 (MIT): host-read removal against the T2T human genome with HLA alleles
RUN apt-get update && apt-get install -y --no-install-recommends python3-dev && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/hostile && /opt/hostile/bin/pip install -q hostile==2.0.2 \
 && ln -s /opt/hostile/bin/hostile /usr/local/bin/hostile
# UShER 0.6.6 (MIT): placement of new genomes in a mutation-annotated tree (Turakhia et al. 2021), built as its
# install script does, with TBB 2019 U9 from source; its TBB libraries are installed next to it
RUN apt-get update && apt-get install -y --no-install-recommends libopenmpi-dev openmpi-bin libisal-dev wget \
 && rm -rf /var/lib/apt/lists/* \
 && cd /tmp && git clone -q --depth 1 --branch v0.6.6 https://github.com/yatisht/usher \
 && wget -q https://github.com/oneapi-src/oneTBB/archive/2019_U9.tar.gz && tar xzf 2019_U9.tar.gz \
 && cmake -S /tmp/usher -B /tmp/usher/build -DCMAKE_BUILD_TYPE=Release -DTBB_DIR=/tmp/oneTBB-2019_U9 \
          -DCMAKE_PREFIX_PATH=/tmp/oneTBB-2019_U9/cmake >/tmp/usher-cmake.log 2>&1; \
    make -C /tmp/usher/build -j8 usher matUtils >/tmp/usher-make.log 2>&1 \
 && install /tmp/usher/build/usher /tmp/usher/build/matUtils /usr/local/bin/ \
 && cp -a /tmp/usher/build/tbb_cmake_build/tbb_cmake_build_subdir_release/libtbb*.so* /usr/local/lib/ && ldconfig \
 && rm -rf /tmp/usher /tmp/oneTBB-2019_U9 /tmp/2019_U9.tar.gz
# Bracken's script runs "python" and finds est_abundance.py next to itself: a python link and a wrapper, not a symlink
RUN ln -sf /usr/bin/python3 /usr/local/bin/python \
 && rm /usr/local/bin/bracken && printf '#!/bin/sh\nexec /opt/bracken/bracken "$@"\n' > /usr/local/bin/bracken \
 && chmod +x /usr/local/bin/bracken
