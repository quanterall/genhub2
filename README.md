# GenHub2

Rapid classification of DNA and RNA viruses for genetic labs, on the FVLLMP federation of lab nodes. GenHub2 is the
first application built on [PQCF](https://github.com/quanterall/pqcf).

| layer | what |
| --- | --- |
| L0, FVLLMP | the lab nodes (NVIDIA DGX Spark), each lab's own; mutual-TLS gates between them; no central point |
| L1, PQCF | tasks as plain data, executors (this node, the owner's nodes, federation peers), provenance of every result |
| L2, GenHub2 | this repository: the analyses, the job service, the store, later the gateway, MQTT (EMQX) and sharing |

## Status: phase A, one node (done)

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
  - **held-out genomes:** species right for 96.5% with proteins for MinHash's weak calls (95.1% by MinHash alone),
    99.6% at high confidence;
  - **1,000 SARS-CoV-2 genomes:** our mutations agree with Nextclade's except at the genome ends and next to indels;
  - **targets:** a 10 MB upload in 4.5 s, 1,000 genomes classified in 0.7 s, a neighbour-joining tree of 1,000
    in 4 s.

- **The gateway** (`gh_web`, cowboy): the web page (`priv/www`: upload, analyses, results, related knowledge,
  provenance, live events) and the API: `POST /api/uploads`, `POST /api/jobs`, `GET /api/jobs[/:id]`,
  `GET /api/jobs/:id/:export`, `POST /api/trees`, `GET /api/summary`, `GET /api/files/:hash`, and a WebSocket `/ws`
  with every event of the site. Phase A listens on this machine only;
  accounts, roles and MFA come with sharing.
- **MQTT inside the site** (`gh_mqtt`): every event is published to the site's EMQX 5.8.9 broker, QoS 1, on the
  specification's topics:
  - `genhub/sequences/new` and `genhub/sequences/processed`;
  - `genhub/results/classification`, `genhub/results/mutations` and `genhub/results/knowledge`;
  - `genhub/tasks/status`.

  A message on `genhub/sequences/new` from another publisher, for example a sequencer's integration, starts a job.
- **Exports** (`gh_export`): CSV, PDF and JSON of a job's results; phylogenetic trees as SVG and Newick.
- **Trees from the page:** a tree job of the genomes of chosen analyses, by neighbour-joining, FastTree or
  VeryFastTree, drawn in the page.
- **Monitoring at the site** (`gh_monitor`): counts by species, lineage and week, each with the job and date it was
  first seen. A finished job that brings a species or lineage the site has not seen before raises an alert on
  `genhub/alerts`. Exchanging these counts between sites, without sequences, is phase D.
- **The gateway check** passes all 13 of its checks against a real EMQX 5.8.9
  ([`acceptance/RESULTS.md`](acceptance/RESULTS.md)).

## Status: phase B, a lab's nodes (two local nodes done)

- **The executor per step** (`gh_jobs`, `gh_pipeline:placement/1`): steps on the lab's raw data (validate, dehost,
  kraken, screen, consensus) run on the site's node. The others run on the site's executor: `local`, or
  `{nodes, [Node, ...]}`, the lab's own Erlang nodes.
- **Worker nodes** (`{role, worker}`): they run only the tasks the site sends them, with their own store, and fetch
  inputs and reference bundles from the site by hash.
- **Trees in parts** (`gh_phylo`, gh2k): align in chunks, the distance matrix in tiles, neighbour-joining on the
  tiles, bootstrap replicates one task each, and support values on the tree. The page asks for up to 1,000 replicates
  and draws the supports.
- **The acceptance test:** two nodes give exactly one node's results, nearly twice as fast (1.87-1.97). The tree from
  tiles is byte for byte phase A's. All 20 checks hold ([`acceptance/RESULTS-PHASE-B.md`](acceptance/RESULTS-PHASE-B.md),
  how to reproduce: [`acceptance/REPRODUCE-PHASE-B.md`](acceptance/REPRODUCE-PHASE-B.md)).

## Status: the FVLLMP federation (started)

- **Tasks through the federation:** GenHub2 sends tasks to the FVLLMP node it runs on, which runs them on itself or
  on a peer: GA4GH TES and content-addressed data (`gh_fed`, `gh_fedexec`, executor setting `federation`).
- **The first container tasks:** distance tiles and bootstrap replicates, in the arm64 `genhub2-task` image.
- **First check:** a task from DGX-A ran on DGX-B, its output came back checked by hash. GenHub2's own tasks follow
  once the image is allowed on the nodes ([`acceptance/FEDERATION.md`](acceptance/FEDERATION.md)).

Next:
- **GenHub2's tasks on DGX-B:** identical results to one node, through the federation;
- **phase C:** two sites through the federation, with sharing, accounts, roles and MFA.

## Methods

Each method is a PQCF task. Each one added to the first set was measured against what it adds to, on the same data,
in [`acceptance/gh_methods_check.erl`](acceptance/gh_methods_check.erl) (results in
[`acceptance/RESULTS.md`](acceptance/RESULTS.md)).

| step | methods | added |
| --- | --- | --- |
| host removal | minimap2 against GRCh38; [Hostile](https://doi.org/10.1093/bioinformatics/btad728) against T2T + HLA, masked for viruses (default) | Hostile: keeps viral reads that GRCh38's analysis set would remove (it contains EBV) |
| read composition | [Kraken 2](https://doi.org/10.1186/s13059-019-1891-0) + [Bracken](https://doi.org/10.7717/peerj-cs.104), prebuilt viral database | species and their shares in mixed samples |
| primer trimming | [iVar](https://doi.org/10.1186/s13059-018-1618-7) `trim -e`, with a named scheme (ARTIC V4.1) | amplicon sequencing: primer bases kept out of the consensus |
| classification | MinHash ([Mash](https://doi.org/10.1186/s13059-016-0997-x)) against RefSeq; for MinHash's weak calls, [DIAMOND](https://doi.org/10.1038/s41592-021-01101-x) blastx against all RefSeq viral proteins | proteins: divergent viruses that nucleotide matching misses |
| lineages | [Nextclade](https://doi.org/10.21105/joss.03773): SARS-CoV-2, influenza HA, RSV A/B, mpox, Ebola, measles, dengue, hMPV, rubella, mumps, West Nile; `nextclade sort` picks the dataset | lineages beyond SARS-CoV-2 |
| trees | neighbour-joining (gh2k); [FastTree](https://doi.org/10.1371/journal.pone.0009490); [VeryFastTree](https://doi.org/10.1093/gigascience/giaa055); bootstrap replicates ([Felsenstein 1985](https://doi.org/10.1111/j.1558-5646.1985.tb00420.x)) for neighbour-joining | VeryFastTree: maximum likelihood of 1,000 genomes in 250 s (FastTree 700 s), within the 5-minute target; replicates: support for every branch, one task each |
| placement | [UShER](https://doi.org/10.1038/s41588-021-00862-7) into a mutation-annotated tree, labelled with lineages | a new genome placed in seconds, without rebuilding the tree |

## Build and test

```sh
docker build -t pqcf-dev ~/pqcf && docker build -t pqcf-variants ~/pqcf/research/variants/docker
docker build -t genhub2-dev docker
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:$PWD" -w "$PWD" -e HOME="$PWD/.cache-home" genhub2-dev rebar3 eunit
sh acceptance/run.sh <GRCh38 minimap2 index> <GRCh38 FASTA>
sh acceptance/run_gateway.sh          # starts emqx/emqx:5.8.9 on 127.0.0.1:21883 for the check, then stops it
sh acceptance/run_phase_b.sh          # two nodes on this machine (after run.sh, which builds the bundles)
sh acceptance/run_federation.sh       # tasks through the FVLLMP node this machine runs (acceptance/FEDERATION.md)
```

To run a site: set `{genhub2, [{http, #{ip => ..., port => ...}}, {mqtt, #{host => "127.0.0.1", port => 1883}}]}` and
start the `genhub2` application. The page is then at the gateway's address.

## Licence

Apache License 2.0 (see `LICENSE` and `NOTICE`). The external programs GenHub2 calls keep their own licences, and none
is linked into GenHub2: minimap2, samtools, Nextclade, Kraken 2, Hostile, UShER (MIT); MAFFT (BSD); FastTree, VeryFastTree, DIAMOND, iVar,
Bracken (GPL). The libraries in the release are permissive:
cowboy, cowlib, ranch, gun (ISC), getopt (BSD), emqtt (Apache 2.0); EMQX 5.8.9 (Apache 2.0) runs as its own service.
