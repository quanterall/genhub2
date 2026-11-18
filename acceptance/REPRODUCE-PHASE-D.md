# Reproducing the monitoring check (phase D, inside the labs)

This page reproduces [RESULTS-PHASE-D.md](RESULTS-PHASE-D.md): three simulated sites, a new lineage planted at one,
and the same alerts at every site after they exchange their counts. 6 checks.

## What you need

Phase A's data: follow [REPRODUCE.md](REPRODUCE.md) steps 1 and 3, then run phase A's test, reduced or full:

```sh
sh acceptance/run.sh --reduced
```

It builds the reference bundles and fetches the 1,000 SARS-CoV-2 genomes (`acceptance/sars-cov-2.tsv`) into `data/`.

## The check

```sh
sh acceptance/run_monitoring.sh            # cores 0-4,10-14; or give a cpuset
```

It takes about a minute: Nextclade and minimap2 on the 1,000 genomes, then the three sites' aggregates, the
exchange and the alerts. It ends with:

```
6 of 6 checks hold
written acceptance/results/monitoring-<host>-<date>.json
```

The exit status is 0 when every check holds.

## How to compare with the published results

The published run is [results/monitoring-dgx-spark-2026-11-17T1813Z.json](results/monitoring-dgx-spark-2026-11-17T1813Z.json).
These must be the same, because the test assigns sites and dates by each genome's place in the file:
- the planted lineage (LB.1.7) and its 19 genomes;
- the 842 genomes counted;
- the alerts: 1 new lineage and 51 rising mutations at every site;
- each site's new lineages before the exchange.

A different Nextclade dataset (`acceptance/gh_acceptance.erl` pins the tag) can change the lineages, and so the
planted one.

## Tested

- **In the development worktree** on 17 November 2026, on phase A's data: twice, with identical results.
- **From a fresh clone of GenHub2 at 619bbcd** on 18 November 2026, on the same DGX Spark, with the images already
  built:
  - GenHub2's 48 tests passed;
  - `run.sh --reduced` built the bundles from NCBI and held its 14 checks;
  - `run_monitoring.sh` held all 6. The results were the published ones: LB.1.7 with 19 genomes at site C, 842
    genomes counted, and 1 new lineage and 51 rising mutations at every site.
