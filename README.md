# GenHub2

Rapid classification of DNA and RNA viruses for genetic labs, on the FVLLMP federation of lab nodes. GenHub2 is the
first application built on [PQCF](https://github.com/quanterall/pqcf).

| layer | what |
| --- | --- |
| L0, FVLLMP | the lab nodes (NVIDIA DGX Spark), each lab's own; mutual-TLS gates between them; no central point |
| L1, PQCF | tasks as plain data, executors (this node, the owner's nodes, federation peers), provenance of every result |
| L2, GenHub2 | this repository: the analyses, the job service, the store, later the gateway, MQTT (EMQX) and sharing |

## Status: phase A, one node (in progress)

Built:
- **The analyses, each a PQCF task** (a module implementing the `pq_task` behaviour, run by PQCF's executors):

  | task | module | does | tools |
  | --- | --- | --- | --- |
  | `validate` | `gh_validate` | checks and normalises an uploaded FASTA/FASTQ file (gzipped or not); RNA as cDNA | `gh2k` |
  | `dehost` | `gh_dehost` | removes the human read pairs; runs at the lab only | minimap2, samtools |
  | `screen` | `gh_screen` | the nearest references of a read set, to choose the consensus reference | `gh2k` |
  | `consensus` | `gh_consensus` | the sample's genome from its reads | minimap2, samtools |
  | `classify` | `gh_classify` | species, genus, family, nearest references, confidence | `gh2k` |
  | `mutations` | `gh_mutations` | substitutions, insertions, deletions against a reference genome | minimap2 |
  | `lineage` | `gh_lineage` | SARS-CoV-2 clade and Pango lineage | Nextclade |
  | `tree` | `gh_tree` | neighbour-joining or approximate maximum-likelihood tree | `gh2k`, FastTree |
  | `knowledge` | `gh_knowledge` | links to public records, trials and literature, marked as information only | none |
  | `fetch_public` | `gh_fetch` | a public file from NCBI or ENA, into the store | none |

- **`gh2k`, the Rust kernels** (`native/gh2k`, run as a supervised external program): FASTA/FASTQ validation,
  MinHash sketches and nearest-reference search
  ([Mash](https://doi.org/10.1186/s13059-016-0997-x)), neighbour-joining
  ([Saitou and Nei 1987](https://doi.org/10.1093/oxfordjournals.molbev.a040454)) on Jukes-Cantor distances, and a
  seeded read simulator for tests.
- **The site's store**, keyed by content hash (`gh_store`). Tasks, results and provenance records refer to data by
  its SHA-256.
- **Reference bundles** (`gh_refs`, `gh_refdb`):
  - every complete viral genome in NCBI RefSeq, with its taxonomy from NCBI Taxonomy;
  - the human genome's minimap2 index;
  - Nextclade's SARS-CoV-2 dataset at a pinned tag.
- **The job service** (`gh_jobs`, `gh_pipeline`): a genome or read-pair upload runs as a job of steps. Each step runs
  its tasks through PQCF's executor, and each result is stored in Mnesia with its provenance record. A restarted
  node resumes unfinished jobs from their last completed step.
  - Genome: `validate`, `classify`, `mutations`, `lineage`, `knowledge`.
  - Reads: `validate`, `dehost`, `screen`, `consensus`, `classify`, `mutations`, `lineage`, `knowledge`.
- **The acceptance test** (`acceptance/`): the SARS-CoV-2 example, a held-out set from NCBI Virus, and the
  specification's timing targets, measured. All 17 checks hold ([`acceptance/RESULTS.md`](acceptance/RESULTS.md)):
  - **reads:** human reads removed and the consensus exact;
  - **held-out genomes:** species right for 95.1%, and for 99.6% at high confidence;
  - **1,000 SARS-CoV-2 genomes:** our mutations agree with Nextclade's except at the genome ends and next to indels;
  - **targets:** a 10 MB upload in 4.5 s, 1,000 genomes classified in 0.7 s, a neighbour-joining tree of 1,000
    in 4 s.

- **The gateway** (`gh_web`, cowboy): the web page (`priv/www`: upload, analyses, results, related knowledge,
  provenance, live events) and the API: `POST /api/uploads`, `POST /api/jobs`, `GET /api/jobs[/:id]`,
  `GET /api/files/:hash`, and a WebSocket `/ws` with every event of the site. Phase A listens on this machine only;
  accounts, roles and MFA come with sharing.
- **MQTT inside the site** (`gh_mqtt`): every event is published to the site's EMQX 5.8.9 broker, QoS 1, on the
  specification's topics:
  - `genhub/sequences/new` and `genhub/sequences/processed`;
  - `genhub/results/classification`, `genhub/results/mutations` and `genhub/results/knowledge`;
  - `genhub/tasks/status`.

  A message on `genhub/sequences/new` from another publisher, for example a sequencer's integration, starts a job.
  The gateway check passes all 9 of its checks against a real EMQX 5.8.9
  ([`acceptance/RESULTS.md`](acceptance/RESULTS.md)).

Still to come in phase A: the remaining FS 3.1 pages (sharing, monitoring, accounts) and exports (CSV, PDF, SVG).

## Build and test

```sh
docker build -t pqcf-dev ~/pqcf && docker build -t pqcf-variants ~/pqcf/research/variants/docker
docker build -t genhub2-dev docker
docker run --rm -v "$PWD:$PWD" -w "$PWD" -e HOME="$PWD/.cache-home" genhub2-dev rebar3 eunit
sh acceptance/run.sh <GRCh38 minimap2 index> <GRCh38 FASTA>
sh acceptance/run_gateway.sh          # starts emqx/emqx:5.8.9 on 127.0.0.1:21883 for the check, then stops it
```

To run a site: set `{genhub2, [{http, #{ip => ..., port => ...}}, {mqtt, #{host => "127.0.0.1", port => 1883}}]}` and
start the `genhub2` application. The page is then at the gateway's address.

## Licence

Apache License 2.0 (see `LICENSE` and `NOTICE`). The external programs GenHub2 calls keep their own licences, and none
is linked into GenHub2: minimap2, samtools, Nextclade (MIT); MAFFT (BSD); FastTree (GPL). The libraries in the release are permissive:
cowboy, cowlib, ranch, gun (ISC), getopt (BSD), emqtt (Apache 2.0); EMQX 5.8.9 (Apache 2.0) runs as its own service.
