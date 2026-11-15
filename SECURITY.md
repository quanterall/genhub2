# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub: the repository's **Security** tab, **Report a
vulnerability** (<https://github.com/quanterall/genhub2/security/advisories/new>). Do not open a public issue for
them.

Please include what is affected (module, version or commit), how to reproduce it, and what an attacker gains. We
acknowledge a report within five working days, agree a disclosure date with you, and credit you in the advisory
unless you prefer otherwise.

## Supported versions

GenHub2 is in phase A (one node). Security fixes go to `main` only; there are no released versions yet.

## What is in scope

- the job service and its uploads: file validation (`gh_validate`, the `gh2k` kernels), the store;
- the analyses' external tools, run as supervised programs (minimap2, samtools, Nextclade, FastTree, DIAMOND and
  the others pinned in `docker/Dockerfile`);
- the removal of human reads (`gh_dehost`), which must run at the lab before anything leaves it;
- PQCF's executors, through which every analysis runs (report those to
  [PQCF](https://github.com/quanterall/pqcf/security/advisories/new)).

**Patient data.** Removing human reads reduces what a sample reveals; on its own it is not a complete privacy
guarantee. GenHub2 is research software, not a validated diagnostic product. The federation of lab nodes (phase B
onwards) will come with a documented threat model and security architecture: mutual TLS between nodes, which data
may leave a lab, authorisation and resource limits for tasks.
