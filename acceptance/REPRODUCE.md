# Reproducing GenHub2's phase A acceptance test

This page takes you from nothing to the results in [RESULTS.md](RESULTS.md): GenHub2 on one machine classifies viral
genomes against all of NCBI RefSeq's, calls SARS-CoV-2 mutations and lineages, removes human reads, and meets the
specification's time targets. 20 checks, each against a reference.

## What you need

- **Docker** and **git**, and a network connection: the run downloads the human reference genome (0.9 GB), the
  RefSeq viral genomes and the test genomes from NCBI, and Nextclade's SARS-CoV-2 dataset.
- **Disk:** about 25 GB: three images (PQCF's development image 2.5 GB, the variant tools 2.7 GB, GenHub2's 3.3 GB),
  the human reference with its indexes (12 GB) and GenHub2's data (2 GB).
- **Memory:** 16 GB or more. Building the human genome's minimap2 index peaks at 11.3 GB.
- A Linux machine, x86_64 or aarch64, with 10 cores or more for the times below.
- Everything must be **under your home directory**: the scripts mount `$HOME` into the containers at the same path,
  so that GenHub2's store can hard-link the 8.7 GB index instead of copying it.

## Steps

### 1. The code and the images

GenHub2 builds on PQCF and on the variant tools of PQCF's `research/variants` branch:

```sh
mkdir -p ~/genhub2-repro && cd ~/genhub2-repro
git clone https://github.com/quanterall/pqcf.git
git clone -b research/variants https://github.com/quanterall/pqcf.git pqcf-variants
git clone https://github.com/quanterall/genhub2.git
git -C pqcf checkout d77ead6 && git -C pqcf-variants checkout 98fcfda && git -C genhub2 checkout d6a1733
docker build -t pqcf-dev pqcf
docker build -t pqcf-variants pqcf-variants/research/variants/docker
docker build -t genhub2-dev genhub2/docker
```

The `checkout` line **reproduces the published run**: the commits of the three repositories it was tested at (see
"Tested"). To **run the latest** versions, leave it out; the results must still be the published ones.

The images build in a few minutes. `genhub2-dev` adds MAFFT, FastTree, Nextclade 3.29.0, DIAMOND, iVar, Kraken 2 and
bowtie2 at fixed versions ([docker/Dockerfile](../docker/Dockerfile)).

### 2. The human reference genome (GRCh38)

GRCh38's no-alt analysis set from NCBI, checked by NCBI's MD5, then indexed for samtools and minimap2 (short reads),
in the variant tools' image:

```sh
mkdir -p ref && cd ref
B=https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids
F=GCA_000001405.15_GRCh38_no_alt_analysis_set.fna
curl -O "$B/$F.gz" -O "$B/md5checksums.txt"
grep "$F.gz" md5checksums.txt | sed 's| \./| |' | md5sum -c -        # prints: ...fna.gz: OK
RUN="docker run --rm --user $(id -u):$(id -g) -v $PWD:/d -w /d pqcf-variants"
$RUN sh -c "pigz -dc $F.gz > $F"
$RUN samtools faidx "$F"
$RUN minimap2 -x sr -t 8 -d "$F.mmi" "$F"
cd ..
```

On our machine: the download about 10 minutes, the index 1 minute.

### 3. GenHub2's tests

```sh
cd genhub2
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:$PWD" -w "$PWD" -e HOME="$PWD/.cache-home" genhub2-dev rebar3 eunit
```

It ends with `19 tests, 0 failures`. Run it as your own user (`--user`), as written: as root it leaves build
directories that the next step, which runs as your user, cannot write.

### 4. The acceptance test

```sh
sh acceptance/run.sh ~/genhub2-repro/ref/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.mmi \
                     ~/genhub2-repro/ref/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna 0-9
```

The last argument is the cores (a Docker cpuset; the published run used 10). It takes about 20 minutes, most of it
the reference bundles (the first 8 minutes, downloads included) and the maximum-likelihood tree of 1,000 genomes
(about 9 minutes). The genomes it uses are listed by accession in [held-out.tsv](held-out.tsv) and
[sars-cov-2.tsv](sars-cov-2.tsv), so every run uses the same ones.

The reference genomes are RefSeq as NCBI serves it on the day of the download. To see whether yours are the
published run's 19,607 ([REFERENCE-DATA.md](REFERENCE-DATA.md)):

```sh
cd genhub2
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:$PWD" -w "$PWD" genhub2-dev sh acceptance/check_reference.sh
```

### A reduced run, without the human reference

Only part 1's reads example needs GRCh38: it simulates human reads from it and removes them with its minimap2 index.
Without it, skip step 2 and run:

```sh
cd genhub2
sh acceptance/run.sh --reduced 0-9
```

The reads example's 6 checks are skipped, and the output and the results file say so (`"reduced": true` and
`"skipped"`); the other 14 run unchanged: the genome example, the held-out classification with and without proteins,
the 1,000 SARS-CoV-2 genomes against Nextclade, the targets and both trees. It needs neither the 12 GB of the human
reference and its indexes nor the 11.3 GB peak of building the index.

Tested on 16 November 2026 on our machine (cores 0-9), with the reference bundles already built: all 14 checks hold,
every answer equal to the published run's (both trees' hashes too; only the four timings differ), in 7.5 minutes
([results/phase-a-dgx-spark-2026-11-15T2221Z.json](results/phase-a-dgx-spark-2026-11-15T2221Z.json)). A first run
also downloads and builds the reference bundles (about 8 minutes here).

## What you should see

The stages with their times, then one line per check:

```
... reference bundles
... data: held-out set and SARS-CoV-2 genomes
... 3. mutations and lineages of the 1,000 SARS-CoV-2 genomes
... 1. the SARS-CoV-2 example
... 2. held-out classification
... 2b. held-out classification by proteins
... 4. targets
ok   example genome: SARS-CoV-2 species: Betacoronavirus pandemicum
ok   example genome: lineage B, clade 19A: B 19A
ok   example reads: lineage of the source genome: BQ.1.1 vs BQ.1.1
ok   held-out: species accuracy at high confidence >= 95%: #{total => 275,right => 274,accuracy => 0.9963636363636363}
ok   held-out: family accuracy >= 95%: #{total => 593,right => 591,accuracy => 0.9966273187183811}
ok   SARS-CoV-2 1,000: substitutions = Nextclade's in genomes it rates good, ...: 745 of 843 identical; ...
ok   target: 10 MB processed in < 5 s: 4.141198
...
written acceptance/results/phase-a-<host>-<date>.json
```

Every line must start with `ok` (20 of them); the script exits with 1 otherwise.

## How to compare with the published results

The published run is [results/phase-a-dgx-spark-2026-11-14T0031Z.json](results/phase-a-dgx-spark-2026-11-14T0031Z.json);
yours is `acceptance/results/phase-a-<host>-<date>.json`.

- **Every result must be the same:** the species, lineages and mutations; the held-out accuracies (274 of 275 at
  high confidence, 591 of 593 at family level, 564 then 572 of 593 by species); the 745 of 843 genomes identical to
  Nextclade's; and both trees of the 1,000 genomes, whose Newick text has the same SHA-256 (`b06e5e9f...` for
  neighbour-joining, `4c441ab1...` for FastTree).
- **Only the four times differ:** the 10 MB upload, the 1,000 classifications, and the two trees. They must stay
  under the targets (5 s, 60 s, 300 s for neighbour-joining).

## The other two checks

[run_methods.sh](run_methods.sh) (the added methods: VeryFastTree, UShER, Nextclade's datasets, Hostile, iVar,
Kraken 2 with Bracken) and [run_gateway.sh](run_gateway.sh) (the HTTP API, WebSocket and MQTT through EMQX) use the
reference bundles that step 4 builds; their instructions are at the top of each script. They were not rerun for this
page.

## Tested

From fresh clones of the public repositories on 15 November 2026 (PQCF d77ead6, research/variants, GenHub2 5ca868c),
aarch64 (Cortex-X925 and Cortex-A725), cores 0-9: GRCh38 downloaded and checked, indexed in 55 seconds; 19 tests
passed; the acceptance test passed all 20 checks in 19 minutes, every result equal to the published run and both
trees' hashes identical. The test found that the README's test command ran as root and left directories the
acceptance step could not write; the command above (and the README) now runs as your user.
