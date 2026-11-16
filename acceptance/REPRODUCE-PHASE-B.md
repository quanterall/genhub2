# Reproducing GenHub2's phase B acceptance test

This page takes you to the results in [RESULTS-PHASE-B.md](RESULTS-PHASE-B.md): GenHub2's analyses and trees spread
over two of a lab's nodes give exactly one node's results, nearly twice as fast. 20 checks.

The test runs both nodes on one machine, each in its own container on its own cores, joined by Erlang distribution on
a Docker network of their own. No ports are opened on the machine.

## What you need

- Everything phase A's test needs ([REPRODUCE.md](REPRODUCE.md), "What you need"), except the human reference: phase
  B uses the reference bundles that phase A's reduced run builds.
- **Cores:** 10 free, five a node. By default the site gets cores 0-4 and the worker 10-14, the same kind of core
  on a DGX Spark. Choose others with the script's arguments (below).
- **Disk:** 2 GB more, for the worker's own copy of the reference bundles.

## Steps

### 1. The code, the images and phase A's data

Follow [REPRODUCE.md](REPRODUCE.md) steps 1 and 3 (the code, the images, GenHub2's tests). Then run phase A's test,
reduced or full:

```sh
sh acceptance/run.sh --reduced
```

It builds the reference bundles (viral RefSeq, its proteins for DIAMOND, Nextclade's dataset), fetches the held-out
and SARS-CoV-2 genomes into `data/`, and must end with all its checks holding.

### 2. Phase B's test

```sh
sh acceptance/run_phase_b.sh                 # site on cores 0-4, worker on 10-14
sh acceptance/run_phase_b.sh 0-3 4-7         # or other cores: SITE_CPUS WORKER_CPUS
```

The script:
- creates the Docker network `genhub2-phase-b` if it is missing;
- empties the worker's store (`data/phase-b-worker`), so the test measures its first fetch of the references;
- starts the worker container, `genhub2-phase-b-worker`, with role `worker`;
- runs the test in the site container, `genhub2-phase-b-site`.

The distribution cookie is random for each run and is not kept. Both containers are stopped at the end, whatever the
outcome. The script stops no other container.

It takes about 10 minutes and ends with:

```
20 of 20 checks hold
written acceptance/results/phase-b-<host>-<date>.json
```

The exit status is 0 when every check holds.

## How to compare with the published results

The published run is [results/phase-b-dgx-spark-2026-11-16T1227Z.json](results/phase-b-dgx-spark-2026-11-16T1227Z.json).

- **These must be the same:**
  - the neighbour-joining tree's SHA-256, `b06e5e9f...`, which is also phase A's;
  - the tree with its 100 bootstrap supports, `054bc67e...`;
  - the 1.5 GB (1,523,890,428 bytes) the worker fetched;
  - identical results in all four runs of every workload.
- **The times differ** with the machine, its cores and its load. The speed-ups should be near 2 on two equal nodes.
  They were 1.87-1.97 here.

## Tested

The published run was made in the development worktree on phase A's data. The fresh-clone test of this page is
below.
