# GenHub2 on the FVLLMP federation

GenHub2 sends tasks to the FVLLMP node it runs on, and that node runs each one on itself or on a peer, under its
owner's policy (FS 4.5, plan section 5 phase C).
- **The interface:** GA4GH TES 1.1 (a subset: create, get, list, cancel) and content-addressed data, at
  `http://127.0.0.1:18100`, with GenHub2's token.
- **Where results come from:** GenHub2 never calls another node; results come back through its own node, checked
  against their SHA-256.

## What GenHub2 has

- **`gh_fed`:** the client: service-info, usage, data (HEAD before upload, downloads checked) and tasks (submit,
  wait, cancel). The token is read from a file for each request and never written to logs or results. Data on the
  node is named by SHA-256, as in GenHub2's store, so a stored file's hash is its name there too.
- **`gh_fedexec`:** a federation executor for PQCF tasks, the prototype of PQCF's.
  - Tasks whose module gives a container form (`container/1`, `result/2`) go to the node; the others run on PQCF's
    local executor.
  - Results come back in task order. Each has PQCF's provenance record, with `node => <<"federation:", Peer>>`,
    the TES task's id and the image.
  - Each TES task is tagged with the PQCF task's hash.
- **The executor setting:** `{executor, federation}` sends a job's spreadable steps through it (`gh_jobs`). The steps
  on a lab's raw data stay on the site (`gh_pipeline:placement/1`).
- **Container forms:** distance tiles and bootstrap replicates (`gh_phylo`), in the `genhub2-task` image
  ([`docker/task/Dockerfile`](../docker/task/Dockerfile)): only `gh2k` on Debian's slim base, linux/arm64, both
  stages pinned by digest, run as an unprivileged user.
- **Same bytes in the image:** under the nodes' conditions (no network, read-only root, read-only inputs, 256 MB
  `/tmp`, no capabilities, 256 processes), the image writes byte-identical tiles and replicates to GenHub2's own
  build.

## The check

[`gh_federation_check.erl`](gh_federation_check.erl), run by [`run_federation.sh`](run_federation.sh):

```sh
sh acceptance/run_federation.sh                               # part 1 only
sh acceptance/run_federation.sh <registry>/genhub2-task@sha256:...  # and part 2, once the image is allowed
```

1. **The client** with the test image every application may use (alpine): a file of GenHub2's store uploaded by
   its hash, a task that reads it, the output downloaded and checked, and where it ran.
2. **GenHub2's own tasks** through the federation executor: 4 distance tiles of 256 rows and 10 bootstrap replicates
   of the 1,000 SARS-CoV-2 genomes and the reference. The results must be identical to this node's, and the tree from
   the federation's tiles must be phase A's (`b06e5e9f...`). Part 2 needs phase A's data (`run.sh`) and the image
   allowed on the nodes.

The token is read from `$GENHUB2_FED_TOKEN`, by default `~/.config/genhub2/federation/genhub2.token`, mode 600,
outside the repository.

## Results

- **17 November 2026, part 1: all 4 checks hold**
  ([`results/federation-dgx-spark-2026-11-17T0655Z.json`](results/federation-dgx-spark-2026-11-17T0655Z.json)).
  DGX-A had no free slot, so it sent the task to DGX-B, where it ran in 1.4 s. Its output came back through DGX-A,
  checked against its hash.
- **Part 2** waits for `genhub2-task` to be published and allowed on DGX-A and DGX-B.

## Limits today

Set by each node's owner:

| | GenHub2 on DGX-A | DGX-A's tasks on DGX-B |
| --- | --- | --- |
| tasks at once | 1 | 1 |
| CPUs | 2 | 2 |
| RAM | 4 GB | 4 GB |
| disk | 4 GB | 4 GB |
| time per task | 1,800 s | 1,800 s |
| upload quota | 1 GB | 1 GB |
