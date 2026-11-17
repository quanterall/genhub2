# Monitoring from aggregated counts: results (phase D, inside the labs)

Plan section 3.4 and FS 5.4: each site turns its results into counts per week, region, lineage and mutation, sites
exchange the counts and never sequences, and every site computes the alerts from all of them, with no central
server. Phase D is done when a planted novel lineage triggers an alert at every site. This page is the part that does
not need the federation: three sites simulated in one test, exchanging their counts as files. Between real labs, the
counts will travel through the FVLLMP federation.

Results file: [`results/monitoring-dgx-spark-2026-11-17T1813Z.json`](results/monitoring-dgx-spark-2026-11-17T1813Z.json),
17 November 2026. How it is run: [`run_monitoring.sh`](run_monitoring.sh) and
[`gh_monitoring_check.erl`](gh_monitoring_check.erl). How to reproduce it: [REPRODUCE-PHASE-D.md](REPRODUCE-PHASE-D.md).

**All 6 checks hold.**

## What a site exchanges

An aggregate (format `genhub2-aggregates/1`, `gh_agg`) holds, for one site:
- counts per ISO week, region and lineage;
- counts per week, region and mutation (e.g. `NC_045512.2:A23403G`);
- the number of sequences per week and region.

Nothing else is in it: no sequence, no sample name, no job, no patient data.
- **The week** is that of the sample's collection date, not of the analysis.
- **The region** is an ISO 3166-2 code (e.g. `BG-22`).
- **Metadata:** both come with the upload (`metadata` of `POST /api/jobs`), for the whole upload or per sequence. A
  sequence without them is not counted.

A site:
- exports its aggregate (`GET /api/aggregates`);
- imports other sites' (`POST /api/aggregates`, admin);
- reads the alerts of all of them merged (`GET /api/aggregates/alerts`).

The merge keeps each site's newest aggregate and sums the counts. Its result does not depend on the order the
aggregates arrive in, so every site that holds the same aggregates computes the same alerts.

**Alerts,** for the latest week of the merged counts (`gh_agg:alerts/2`):
- **a new lineage:** counted in that week and in no earlier week, at any site;
- **a rising mutation:** its share of that week's sequences is at least 10%, at least twice its mean share over the
  4 weeks before, and in at least 5 sequences. The three numbers are settings (`alert_thresholds`).

## The test

- **Three simulated sites** (regions BG-22, BG-02, BG-03).
- **The genomes:** phase A's 1,000 public SARS-CoV-2 genomes, with their real lineages (Nextclade) and mutations
  (minimap2). 842 of them have both.
- **Weeks 1-7** (14 September to 26 October 2026): the genomes of 2020-2023 and the Bulgarian set, spread over the
  sites and weeks.
- **Week 8** (2 November): genomes of lineages already seen in weeks 1-7, at every site.
- **Planted at site C only, in week 8:** 19 genomes of LB.1.7. It is the most common lineage of the June 2024
  genomes that no earlier genome has.
- **The exchange:** each site exports its aggregate as JSON and imports the other two's.

| check | result |
| --- | --- |
| before the exchange, only site C sees the planted lineage | yes |
| after it, all three sites raise the same alerts | yes: 1 new lineage and 51 rising mutations each |
| after it, every site alerts on LB.1.7 | yes |
| a control run without the planted genomes: no new-lineage alert | none at any site (and no mutation alert either) |
| the merge does not depend on the order of the aggregates | yes |
| no aggregate contains a genome's name or accession | none of the genomes' names or accessions found |

## What the results show, and their limits

- **Exchanging counts removes false alerts.** On its own counts, site A saw 2 lineages as new, site B 3, and site C 7
  (LB.1.7 among them). All but LB.1.7 had been seen at another site. After the exchange, LB.1.7 is the only new
  lineage at every site.
- **A new lineage brings many mutation alerts.** The 51 rising mutations are LB.1.7's own: each of its defining
  mutations rises with it. They are all correct, but they say one thing 51 times. A later version should report the
  mutations a new lineage explains as part of its alert.
- **Simulated sites and dates.** The genomes are real, but their sites and collection dates are assigned by the
  test. Real data would bring uneven reporting delays: a week's counts keep growing as late samples are analysed. The
  alerts are then recomputed on each new aggregate.
- **Small counts are exchanged as they are.** A count of 1 in a small region may say more about a patient than a
  lab may share. A threshold below which counts are merged or withheld is a decision for the labs and their data
  protection officers, not a technical one.

## At a site, through its gateway

The gateway check ([RESULTS.md](RESULTS.md), section 5) covers the same at one site. It has 5 checks:
- a job's sample metadata is counted (2026-W46, BG-22, lineage B);
- a bad region and a future collection date are refused, each saying why;
- an admin imports another site's aggregate, an analyst cannot, and a malformed one is refused;
- the merged alerts name the other site's new lineage;
- a researcher reads the aggregates and the alerts.
