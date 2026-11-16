//! A neighbour-joining tree (Saitou and Nei 1987, doi:10.1093/oxfordjournals.molbev.a040454) of aligned genomes
//! (FS 5.2, task tree), with Jukes-Cantor distances (doi:10.1016/B978-1-4832-3211-9.50009-7).
//!
//! Distances: p = mismatches / sites compared, a site compared when both genomes have A, C, G or T there; then
//! d = -3/4 ln(1 - 4p/3), and d = 5 when p >= 3/4 (saturated). Genomes of one outbreak differ from each other in few
//! sites, so each genome is kept as its differences from the alignment's majority base per column plus the intervals
//! where it has no base (N, gaps): a pair's distance then costs the number of differences and intervals, not the
//! genome's length.
//!
//! The tree is unrooted, in Newick, with the last three nodes joined at the top. Ties in the join criterion go to the
//! lowest pair of indices, so the same alignment gives the same tree, byte for byte.

use crate::fasta::{self, code};
use crate::minhash::par_map;

const SATURATED: f64 = 5.0;

struct Sparse {
    /// (column, base code), ascending, where the base is A/C/G/T and not the column's majority
    diffs: Vec<(u32, u8)>,
    /// [start, end) columns without a base, ascending, disjoint
    unknown: Vec<(u32, u32)>,
}

pub fn run(path: &str) -> Result<i32, String> {
    let recs = match aligned(path, "nj")? {
        Some(r) => r,
        None => return Ok(2),
    };
    let seqs: Vec<&[u8]> = recs.iter().map(|r| r.seq.as_slice()).collect();
    let d = distances(&seqs);
    println!("{}", newick(&names(&recs), d));
    Ok(0)
}

/// The records of an alignment, or None (said on standard error) when it is empty or its rows differ in length.
pub fn aligned(path: &str, cmd: &str) -> Result<Option<Vec<fasta::Record>>, String> {
    let recs = fasta::read(path)?;
    if recs.is_empty() {
        eprintln!("gh2k {cmd}: no sequences");
        return Ok(None);
    }
    let len = recs[0].seq.len();
    if let Some(r) = recs.iter().find(|r| r.seq.len() != len) {
        eprintln!(
            "gh2k {cmd}: not aligned: {} has {} columns, {} has {}",
            recs[0].id,
            len,
            r.id,
            r.seq.len()
        );
        return Ok(None);
    }
    Ok(Some(recs))
}

/// The leaf names of an alignment's records, as Newick allows them.
pub fn names(recs: &[fasta::Record]) -> Vec<String> {
    recs.iter().map(|r| clean(&r.id)).collect()
}

fn clean(s: &str) -> String {
    s.chars()
        .map(|c| {
            if "():;,[]'".contains(c) || c.is_whitespace() {
                '_'
            } else {
                c
            }
        })
        .collect()
}

/// The Jukes-Cantor distance matrix of aligned sequences (row-major, n x n).
pub fn distances(seqs: &[&[u8]]) -> Vec<f64> {
    let n = seqs.len();
    let sparse = sparse_all(seqs);
    let len = seqs.first().map_or(0, |s| s.len());
    let rows: Vec<usize> = (0..n).collect();
    let upper: Vec<Vec<f64>> = par_map(&rows, |&i| {
        (i + 1..n)
            .map(|j| pair(&sparse[i], &sparse[j], len))
            .collect()
    });
    let mut d = vec![0.0; n * n];
    for (i, row) in upper.iter().enumerate() {
        for (k, &v) in row.iter().enumerate() {
            let j = i + 1 + k;
            d[i * n + j] = v;
            d[j * n + i] = v;
        }
    }
    d
}

/// A block of the distance matrix: rows [i0, i1) against columns [j0, j1), row-major. A pair's distance depends only
/// on the two sequences (the majority base is only how they are stored), so a block computed on its own has exactly
/// the values of the whole matrix.
pub fn block(seqs: &[&[u8]], i0: usize, i1: usize, j0: usize, j1: usize) -> Vec<f64> {
    let len = seqs.first().map_or(0, |s| s.len());
    let majority = majority(seqs);
    let mut wanted: Vec<usize> = (i0..i1).chain(j0..j1).collect();
    wanted.sort_unstable();
    wanted.dedup();
    let sp: Vec<Sparse> = par_map(&wanted, |&k| to_sparse(seqs[k], &majority));
    let at = |k: usize| &sp[wanted.binary_search(&k).unwrap()];
    let rows: Vec<usize> = (i0..i1).collect();
    par_map(&rows, |&i| {
        (j0..j1)
            .map(|j| if i == j { 0.0 } else { pair(at(i), at(j), len) })
            .collect::<Vec<f64>>()
    })
    .concat()
}

fn majority(seqs: &[&[u8]]) -> Vec<u8> {
    let len = seqs.first().map_or(0, |s| s.len());
    let mut majority = vec![255u8; len];
    for (c, m) in majority.iter_mut().enumerate() {
        let mut counts = [0u32; 4];
        for s in seqs {
            if let Some(x) = code(s[c]) {
                counts[x as usize] += 1;
            }
        }
        let best = (0..4)
            .max_by_key(|&i| (counts[i], std::cmp::Reverse(i)))
            .unwrap();
        if counts[best] > 0 {
            *m = best as u8;
        }
    }
    majority
}

fn sparse_all(seqs: &[&[u8]]) -> Vec<Sparse> {
    let majority = majority(seqs);
    par_map(seqs, |s| to_sparse(s, &majority))
}

fn to_sparse(s: &[u8], majority: &[u8]) -> Sparse {
    let mut diffs = Vec::new();
    let mut unknown: Vec<(u32, u32)> = Vec::new();
    for (c, &b) in s.iter().enumerate() {
        match code(b) {
            Some(x) if x as u8 != majority[c] => diffs.push((c as u32, x as u8)),
            Some(_) => {}
            None => match unknown.last_mut() {
                Some(last) if last.1 == c as u32 => last.1 += 1,
                _ => unknown.push((c as u32, c as u32 + 1)),
            },
        }
    }
    Sparse { diffs, unknown }
}

fn covered(iv: &[(u32, u32)], c: u32) -> bool {
    let k = iv.partition_point(|&(_, e)| e <= c);
    k < iv.len() && iv[k].0 <= c
}

fn union_len(a: &[(u32, u32)], b: &[(u32, u32)]) -> u64 {
    let (mut i, mut j, mut total, mut end) = (0, 0, 0u64, 0u32);
    while i < a.len() || j < b.len() {
        let next = if j >= b.len() || (i < a.len() && a[i].0 <= b[j].0) {
            i += 1;
            a[i - 1]
        } else {
            j += 1;
            b[j - 1]
        };
        let s = next.0.max(end);
        if next.1 > s {
            total += (next.1 - s) as u64;
            end = next.1;
        }
    }
    total
}

fn pair(a: &Sparse, b: &Sparse, len: usize) -> f64 {
    let compared = len as u64 - union_len(&a.unknown, &b.unknown);
    let (mut i, mut j, mut mism) = (0, 0, 0u64);
    while i < a.diffs.len() || j < b.diffs.len() {
        let (ca, cb) = (a.diffs.get(i).map(|x| x.0), b.diffs.get(j).map(|x| x.0));
        match (ca, cb) {
            (Some(x), Some(y)) if x == y => {
                if a.diffs[i].1 != b.diffs[j].1 {
                    mism += 1;
                }
                i += 1;
                j += 1;
            }
            (Some(x), y) if y.is_none_or(|y| x < y) => {
                if !covered(&b.unknown, x) {
                    mism += 1;
                }
                i += 1;
            }
            (_, Some(y)) => {
                if !covered(&a.unknown, y) {
                    mism += 1;
                }
                j += 1;
            }
            _ => unreachable!(),
        }
    }
    if compared == 0 {
        return SATURATED;
    }
    let p = mism as f64 / compared as f64;
    if p >= 0.75 {
        SATURATED
    } else {
        (-0.75 * (1.0 - 4.0 * p / 3.0).ln()).min(SATURATED)
    }
}

/// Neighbour-joining on the n x n matrix d; the tree in Newick.
pub fn newick(names: &[String], mut d: Vec<f64>) -> String {
    let n = names.len();
    let fmt = |x: f64| format!("{:.6}", x.max(0.0));
    let mut label: Vec<String> = names.to_vec();
    if n == 1 {
        return format!("({});", label[0]);
    }
    if n == 2 {
        return format!(
            "({}:{},{}:{});",
            label[0],
            fmt(d[1] / 2.0),
            label[1],
            fmt(d[1] / 2.0)
        );
    }
    let mut active: Vec<usize> = (0..n).collect();
    let mut r: Vec<f64> = (0..n).map(|i| (0..n).map(|j| d[i * n + j]).sum()).collect();
    while active.len() > 3 {
        let m = active.len() as f64;
        let (mut bi, mut bj, mut best) = (0, 0, f64::INFINITY);
        for (x, &i) in active.iter().enumerate() {
            for &j in &active[x + 1..] {
                let q = (m - 2.0) * d[i * n + j] - r[i] - r[j];
                if q < best {
                    (bi, bj, best) = (i, j, q);
                }
            }
        }
        let dij = d[bi * n + bj];
        let mut li = dij / 2.0 + (r[bi] - r[bj]) / (2.0 * (m - 2.0));
        // joined distances can come out slightly negative; branch lengths stay in [0, max(dij, 0)]
        li = li.max(0.0).min(dij.max(0.0));
        let lj = dij - li;
        label[bi] = format!("({}:{},{}:{})", label[bi], fmt(li), label[bj], fmt(lj));
        active.retain(|&x| x != bj);
        for &k in &active {
            if k == bi {
                continue;
            }
            let duk = (d[bi * n + k] + d[bj * n + k] - dij) / 2.0;
            r[k] += duk - d[bi * n + k] - d[bj * n + k];
            d[bi * n + k] = duk;
            d[k * n + bi] = duk;
        }
        r[bi] = active
            .iter()
            .filter(|&&k| k != bi)
            .map(|&k| d[bi * n + k])
            .sum();
    }
    let (a, b, c) = (active[0], active[1], active[2]);
    let (dab, dac, dbc) = (d[a * n + b], d[a * n + c], d[b * n + c]);
    format!(
        "({}:{},{}:{},{}:{});",
        label[a],
        fmt((dab + dac - dbc) / 2.0),
        label[b],
        fmt((dab + dbc - dac) / 2.0),
        label[c],
        fmt((dac + dbc - dab) / 2.0)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distances_count_compared_sites() {
        let s: Vec<&[u8]> = vec![b"ACGTACGTAC", b"ACGTACGTAA", b"ACNNACGTAA", b"AC--ACGTAC"];
        let d = distances(&s);
        let jc = |p: f64| -0.75 * (1.0 - 4.0 * p / 3.0).ln();
        assert!((d[1] - jc(0.1)).abs() < 1e-12);
        assert!((d[2] - jc(1.0 / 8.0)).abs() < 1e-12);
        assert!((d[3] - 0.0).abs() < 1e-12);
        assert!((d[4 + 2] - 0.0).abs() < 1e-12);
        assert!((d[2 * 4 + 3] - jc(1.0 / 8.0)).abs() < 1e-12);
    }

    #[test]
    fn additive_tree_is_recovered() {
        // ((a:1,b:2):1,c:3,d:4) as distances; neighbour-joining is exact on additive distances
        let names: Vec<String> = ["a", "b", "c", "d"].iter().map(|s| s.to_string()).collect();
        let d = vec![
            0.0, 3.0, 5.0, 6.0, 3.0, 0.0, 6.0, 7.0, 5.0, 6.0, 0.0, 7.0, 6.0, 7.0, 7.0, 0.0,
        ];
        assert_eq!(
            newick(&names, d),
            "((a:1.000000,b:2.000000):1.000000,c:3.000000,d:4.000000);"
        );
    }

    #[test]
    fn non_additive_distances_do_not_panic() {
        let names: Vec<String> = ["a", "b", "c", "d", "e"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        // a and b identical, the rest far apart: joined distances go negative
        let d = vec![
            0.0, 0.0, 1.0, 1.0, 1.0, //
            0.0, 0.0, 1.0, 1.0, 1.0, //
            1.0, 1.0, 0.0, 0.01, 2.0, //
            1.0, 1.0, 0.01, 0.0, 2.0, //
            1.0, 1.0, 2.0, 2.0, 0.0,
        ];
        let t = newick(&names, d);
        assert!(t.ends_with(");") && !t.contains("-"), "{t}");
    }
}
