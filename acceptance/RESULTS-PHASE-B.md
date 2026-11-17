# Phase B acceptance: results

GenHub2 on two of a lab's nodes, with PQCF's `{nodes, ...}` executor, 16 November 2026. Done when the results are
identical to one node's and the speed-up is measured (plan section 5, FS 6.3).
Results file: [`results/phase-b-dgx-spark-2026-11-16T1227Z.json`](results/phase-b-dgx-spark-2026-11-16T1227Z.json).
How it is run: [`run_phase_b.sh`](run_phase_b.sh) and [`gh_phase_b.erl`](gh_phase_b.erl). How to reproduce it:
[REPRODUCE-PHASE-B.md](REPRODUCE-PHASE-B.md).

**All 20 checks hold.**

## The two nodes

- **The machine:** one NVIDIA DGX Spark, used as two nodes. Each node is an Erlang node in its own container, on five
  of the machine's efficiency cores (Cortex-A725): cores 0-4 for the site and 10-14 for the worker. The two are joined
  by Erlang distribution on a Docker network of their own.
- **The site** (coordinating node) has phase A's store and reference bundles.
- **The worker** starts with an empty store. Its tasks fetch what they need from the site by SHA-256 and check it.
  The first tasks fetched **1.5 GB of reference bundles in 18.6 s**: viral RefSeq with its MinHash sketches, the
  DIAMOND protein database and the Nextclade dataset.
- **Placement:** steps on the lab's raw data (validate, dehost, kraken, screen, consensus) run on the site only. The
  others go to both nodes.

A second DGX Spark joins as a third configuration of the same test once it is reachable by Erlang distribution.

## Identical results

Every workload ran four times, alternating: on the site alone (`local`), then on both nodes (`{nodes, ...}`), twice
each. All four runs of every workload give identical results, and in every two-node run the worker ran a share of
the tasks.

The tree of the 1,000 SARS-CoV-2 genomes and the reference was computed in parts:
- the genomes aligned in 10 tasks;
- the Jukes-Cantor distance matrix in 36 tiles of 128 rows;
- neighbour-joining on the joined tiles (Saitou and Nei 1987,
  [doi:10.1093/oxfordjournals.molbev.a040454](https://doi.org/10.1093/oxfordjournals.molbev.a040454)).

It is **byte for byte phase A's tree**, which was built in one task (Newick SHA-256 `b06e5e9f...`). A pair's distance
depends only on the two genomes, so a tile has exactly the values of the whole matrix (gh2k's tests check this
bit for bit).

The 100 bootstrap replicates (Felsenstein 1985,
[doi:10.1111/j.1558-5646.1985.tb00420.x](https://doi.org/10.1111/j.1558-5646.1985.tb00420.x)) are one task each, each
seeded by its number. The tree with its support values is the same in every run (SHA-256 `054bc67e...`).

## Speed-up

Best of two runs each, in seconds:

| workload | tasks | one node (5 cores) | two nodes (5 + 5 cores) | speed-up |
| --- | --- | --- | --- | --- |
| classification by MinHash, 1,593 genomes (the 1,000 SARS-CoV-2 and the 593 held-out) | 32 | 3.4 | 1.8 | 1.91 |
| classification by proteins (DIAMOND blastx), the 593 held-out genomes | 10 | 82.0 | 43.9 | 1.87 |
| mutations of the 1,000 SARS-CoV-2 genomes (minimap2) | 20 | 2.3 | 1.2 | 1.97 |
| lineages of the 1,000 (Nextclade) | 20 | 8.4 | 4.4 | 1.92 |
| tree of the 1,000 and the reference, with 100 bootstrap replicates | 148 | 61.3 | 31.3 | 1.96 |

**The tree's parts**, best runs:

| part | one node | two nodes |
| --- | --- | --- |
| align, 10 tasks | 2.4 s | 1.3 s |
| distance tiles, 36 | 1.9 s | 1.0 s |
| neighbour-joining | 0.4 s | 0.4 s |
| 100 replicates | 56.4 s | 28.5 s |
| support | 0.1 s | 0.1 s |

**Through the job service:** a tree job of the same genomes with 100 replicates took 36.7 s on both nodes. Its tree
and support are those above.

**What the times show:**
- The work that is spread nearly halves on two nodes (1.87-1.97).
- Neighbour-joining itself is one task, so it does not speed up. At 1,001 genomes it takes 0.4 s. It grows as the
  cube of the number of genomes, so for much larger trees it, not the distances, will set the time.
- The machine is shared with other projects, so times vary between runs. The first one-node tree took 86.1 s against
  61.3 s in the second, and each workload's best is reported. All four times of every run are in the results file.

**Task size matters for tools that load a database.** DIAMOND loads its 720,495-protein database on every call. In an
earlier run with 30 tasks of 20 genomes, the protein search took 229 s on one node and 116 s on two. With one task per
slot (10 tasks of 60 genomes), it takes 82 s and 44 s. The speed-up is about the same, but the work is a third.
GenHub2's job pipeline sends a job's weak calls to DIAMOND as one task.

## The jobs

- **A tree job** with executor `{nodes, ...}`: its align, distance and bootstrap tasks ran on both nodes;
  neighbour-joining and support, one task each, ran on the site.
- **A genome job:** the upload's `validate` step ran on the site only, as placement requires. The genome job's other
  steps were one task each, and they ran on the site this time.

## A correction (17 November 2026)

A bug was found after the run above, and fixed:
- **What was wrong:** a task run on the worker leaves its output file in the worker's store and returns its hash.
  The site did not fetch such files, so a later step on the site could not read them.
- **Why the published run missed it:** that run computed every workload on the site alone before running it on both
  nodes. The site already held the same files, under the same hashes, so nothing was missing and the checks passed.
- **How it showed:** when tree jobs began sending bootstrap replicates in batches of 10, their outputs were new files,
  and the tree job failed.
- **The fix:**
  - after each step, the site fetches every stored file a result refers to from the node that ran its task, checked
    by hash (`gh_store:pull_traced/1`);
  - the test now runs each workload on two nodes first;
  - a unit test fetches outputs made only on a peer node.
- **The rerun:** [`results/phase-b-dgx-spark-2026-11-17T0735Z.json`](results/phase-b-dgx-spark-2026-11-17T0735Z.json),
  all 20 checks hold.
  - Every result is the same as above: the tree (`b06e5e9f...`) and the support values (`054bc67e...`).
  - The speed-ups are 1.80-1.95.
  - The tree job, with replicates in batches of 10, took 30.0 s.

## The checks

The 20 checks, all holding:
- two nodes;
- the worker fetched its references by hash;
- for each of the five workloads: identical results in all four runs, and the worker ran some of the tasks;
- the tree from tiles is phase A's tree;
- the tree is faster on two nodes;
- the tree job finished, with the tree and support of part 1, its distance tiles and replicates on both nodes;
- the genome job finished, with its upload validated on the site only.
