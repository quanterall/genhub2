//! Trees spread over many tasks (FS 5.2: distance blocks and bootstrap replicates are independent tasks).
//!
//!   dist ALIGNED I0 I1 J0 J1 OUT    a tile of the Jukes-Cantor distance matrix: rows [I0, I1) against columns
//!                                   [J0, J1), written as "GHD1", then n, I0, I1, J0, J1 (u32, little endian), then the
//!                                   distances (f64, little endian, row-major)
//!   njtiles ALIGNED TILE...         neighbour-joining on the matrix put together from tiles that cover every pair;
//!                                   the same tree, byte for byte, as `nj ALIGNED`
//!   boot ALIGNED SEED [OUT]         one bootstrap replicate (Felsenstein 1985, doi:10.1111/j.1558-5646.1985.tb00420.x):
//!                                   the alignment's columns drawn with replacement by SplitMix64 from SEED, then
//!                                   distances and neighbour-joining as `nj`
//!   boots ALIGNED FIRST COUNT OUT   COUNT replicates, seeds FIRST.., one tree a line: the lines of `boot` for those
//!                                   seeds, in order (a batch for one task)
//!   support TREE REPLICATES...      TREE with each internal branch labelled by the percentage of replicate trees that
//!                                   contain its split (each REPLICATES file holds one tree a line)

use crate::fasta;
use crate::nj;
use crate::simulate::Rng;
use std::collections::HashMap;

const MAGIC: &[u8; 4] = b"GHD1";

pub fn dist(
    path: &str,
    i0: usize,
    i1: usize,
    j0: usize,
    j1: usize,
    out: &str,
) -> Result<i32, String> {
    let recs = match nj::aligned(path, "dist")? {
        Some(r) => r,
        None => return Ok(2),
    };
    let n = recs.len();
    if i0 > i1 || j0 > j1 || i1 > n || j1 > n {
        eprintln!("gh2k dist: block [{i0}, {i1}) x [{j0}, {j1}) outside 0..{n}");
        return Ok(2);
    }
    let seqs: Vec<&[u8]> = recs.iter().map(|r| r.seq.as_slice()).collect();
    let d = nj::block(&seqs, i0, i1, j0, j1);
    let mut o = Vec::with_capacity(24 + 8 * d.len());
    o.extend_from_slice(MAGIC);
    for x in [n, i0, i1, j0, j1] {
        o.extend_from_slice(&(x as u32).to_le_bytes());
    }
    for v in d {
        o.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(out, o).map_err(|e| format!("{out}: {e}"))?;
    Ok(0)
}

pub fn njtiles(path: &str, tiles: &[&str]) -> Result<i32, String> {
    let recs = match nj::aligned(path, "njtiles")? {
        Some(r) => r,
        None => return Ok(2),
    };
    let n = recs.len();
    let mut d = vec![0.0; n * n];
    let mut set = vec![false; n * n];
    for t in tiles {
        let b = std::fs::read(t).map_err(|e| format!("{t}: {e}"))?;
        let u = |k: usize| u32::from_le_bytes(b[4 + 4 * k..8 + 4 * k].try_into().unwrap()) as usize;
        if b.len() < 24 || &b[..4] != MAGIC || u(0) != n {
            eprintln!("gh2k njtiles: {t} is not a tile of this alignment");
            return Ok(2);
        }
        let (i0, i1, j0, j1) = (u(1), u(2), u(3), u(4));
        if i1 > n || j1 > n || b.len() != 24 + 8 * (i1 - i0) * (j1 - j0) {
            eprintln!("gh2k njtiles: {t}: bad size");
            return Ok(2);
        }
        let mut k = 24;
        for i in i0..i1 {
            for j in j0..j1 {
                let v = f64::from_le_bytes(b[k..k + 8].try_into().unwrap());
                k += 8;
                if i != j {
                    d[i * n + j] = v;
                    d[j * n + i] = v;
                    set[i * n + j] = true;
                    set[j * n + i] = true;
                }
            }
        }
    }
    if let Some(p) = (0..n * n).find(|&p| p / n != p % n && !set[p]) {
        eprintln!("gh2k njtiles: no tile has the pair ({}, {})", p / n, p % n);
        return Ok(2);
    }
    println!("{}", nj::newick(&nj::names(&recs), d));
    Ok(0)
}

pub fn boot(path: &str, seed: u64, out: Option<&str>) -> Result<i32, String> {
    let recs = match nj::aligned(path, "boot")? {
        Some(r) => r,
        None => return Ok(2),
    };
    let tree = format!("{}\n", replicate(&recs, seed));
    match out {
        Some(o) => std::fs::write(o, tree).map_err(|e| format!("{o}: {e}"))?,
        None => print!("{tree}"),
    }
    Ok(0)
}

pub fn boots(path: &str, first: u64, count: u64, out: &str) -> Result<i32, String> {
    let recs = match nj::aligned(path, "boots")? {
        Some(r) => r,
        None => return Ok(2),
    };
    let seeds: Vec<u64> = (first..first + count).collect();
    // the replicates in parallel (each one's distances use the same number of threads: GH2K_THREADS squared at most)
    let trees = crate::minhash::par_map(&seeds, |&s| replicate(&recs, s));
    let text: String = trees.iter().map(|t| format!("{t}\n")).collect();
    std::fs::write(out, text).map_err(|e| format!("{out}: {e}"))?;
    Ok(0)
}

fn replicate(recs: &[fasta::Record], seed: u64) -> String {
    let len = recs[0].seq.len() as u64;
    let mut rng = Rng(seed);
    let cols: Vec<usize> = (0..len).map(|_| rng.below(len.max(1)) as usize).collect();
    let resampled: Vec<Vec<u8>> = recs
        .iter()
        .map(|r| cols.iter().map(|&c| r.seq[c]).collect())
        .collect();
    let seqs: Vec<&[u8]> = resampled.iter().map(|s| s.as_slice()).collect();
    nj::newick(&nj::names(recs), nj::distances(&seqs))
}

pub fn support(tree: &str, reps: &[&str]) -> Result<i32, String> {
    let main = std::fs::read_to_string(tree).map_err(|e| format!("{tree}: {e}"))?;
    let mut lines = Vec::new();
    for r in reps {
        let s = std::fs::read_to_string(r).map_err(|e| format!("{r}: {e}"))?;
        lines.extend(
            s.lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(String::from),
        );
    }
    match supported(main.trim(), &lines) {
        Ok(t) => {
            println!("{t}");
            Ok(0)
        }
        Err(e) => {
            eprintln!("gh2k support: {e}");
            Ok(2)
        }
    }
}

/// The tree with each internal branch labelled by its bootstrap support in percent (rounded down).
fn supported(main: &str, reps: &[String]) -> Result<String, String> {
    let mut t = parse(main)?;
    let mut leaves = Vec::new();
    t.leaves(&mut leaves);
    let mut sorted = leaves.clone();
    sorted.sort();
    let index: HashMap<String, usize> = sorted
        .iter()
        .enumerate()
        .map(|(i, s)| (s.clone(), i))
        .collect();
    if index.len() != leaves.len() {
        return Err("duplicate leaf names".into());
    }
    let n = index.len();
    let mut counts: HashMap<Vec<u64>, usize> = HashMap::new();
    for r in reps {
        let rt = parse(r)?;
        let mut sp = Vec::new();
        rt.splits(&index, n, true, &mut sp)
            .ok_or("a replicate has other leaves")?;
        sp.sort();
        sp.dedup();
        for s in sp {
            *counts.entry(s).or_insert(0) += 1;
        }
    }
    t.label(&index, n, &counts, reps.len(), true)
        .ok_or("bad tree")?;
    Ok(format!("{};", t.write()))
}

struct Node {
    kids: Vec<Node>,
    name: String,
    len: Option<String>,
}

fn parse(s: &str) -> Result<Node, String> {
    let b = s.trim().trim_end_matches(';').as_bytes();
    let mut p = 0;
    let t = node(b, &mut p)?;
    if p != b.len() {
        return Err(format!("unexpected text at {p} of a tree"));
    }
    Ok(t)
}

fn node(b: &[u8], p: &mut usize) -> Result<Node, String> {
    let mut kids = Vec::new();
    if b.get(*p) == Some(&b'(') {
        *p += 1;
        loop {
            kids.push(node(b, p)?);
            match b.get(*p) {
                Some(b',') => *p += 1,
                Some(b')') => {
                    *p += 1;
                    break;
                }
                _ => return Err("unbalanced tree".into()),
            }
        }
    }
    let start = *p;
    while *p < b.len() && !b"(),:;".contains(&b[*p]) {
        *p += 1;
    }
    let name = String::from_utf8_lossy(&b[start..*p]).into_owned();
    let len = if b.get(*p) == Some(&b':') {
        *p += 1;
        let s = *p;
        while *p < b.len() && !b"(),;".contains(&b[*p]) {
            *p += 1;
        }
        Some(String::from_utf8_lossy(&b[s..*p]).into_owned())
    } else {
        None
    };
    Ok(Node { kids, name, len })
}

impl Node {
    fn leaves(&self, out: &mut Vec<String>) {
        if self.kids.is_empty() {
            out.push(self.name.clone());
        }
        for k in &self.kids {
            k.leaves(out);
        }
    }

    /// this subtree's leaves as a bit set; the non-trivial splits below the root pushed to out, each normalised to
    /// the side without leaf 0
    fn splits(
        &self,
        ix: &HashMap<String, usize>,
        n: usize,
        root: bool,
        out: &mut Vec<Vec<u64>>,
    ) -> Option<Vec<u64>> {
        let mut bits = vec![0u64; n.div_ceil(64)];
        if self.kids.is_empty() {
            let i = *ix.get(&self.name)?;
            bits[i / 64] |= 1 << (i % 64);
            return Some(bits);
        }
        for k in &self.kids {
            let kb = k.splits(ix, n, false, out)?;
            bits.iter_mut().zip(kb).for_each(|(a, b)| *a |= b);
        }
        if !root {
            if let Some(s) = split(&bits, n) {
                out.push(s);
            }
        }
        Some(bits)
    }

    fn label(
        &mut self,
        ix: &HashMap<String, usize>,
        n: usize,
        counts: &HashMap<Vec<u64>, usize>,
        reps: usize,
        root: bool,
    ) -> Option<Vec<u64>> {
        let mut bits = vec![0u64; n.div_ceil(64)];
        if self.kids.is_empty() {
            let i = *ix.get(&self.name)?;
            bits[i / 64] |= 1 << (i % 64);
            return Some(bits);
        }
        for k in &mut self.kids {
            let kb = k.label(ix, n, counts, reps, false)?;
            bits.iter_mut().zip(kb).for_each(|(a, b)| *a |= b);
        }
        if !root {
            if let Some(s) = split(&bits, n) {
                let c = counts.get(&s).copied().unwrap_or(0);
                self.name = (100 * c).checked_div(reps).unwrap_or(0).to_string();
            }
        }
        Some(bits)
    }

    fn write(&self) -> String {
        let mut s = String::new();
        if !self.kids.is_empty() {
            s.push('(');
            s.push_str(
                &self
                    .kids
                    .iter()
                    .map(Node::write)
                    .collect::<Vec<_>>()
                    .join(","),
            );
            s.push(')');
        }
        s.push_str(&self.name);
        if let Some(l) = &self.len {
            s.push(':');
            s.push_str(l);
        }
        s
    }
}

/// The split as the side without leaf 0, or None when one side has fewer than two leaves.
fn split(bits: &[u64], n: usize) -> Option<Vec<u64>> {
    let mut s = bits.to_vec();
    if s[0] & 1 == 1 {
        for (w, x) in s.iter_mut().enumerate() {
            *x = !*x;
            let hi = n.saturating_sub(64 * w).min(64);
            if hi < 64 {
                *x &= (1u64 << hi) - 1;
            }
        }
    }
    let k: u32 = s.iter().map(|x| x.count_ones()).sum();
    (k >= 2 && (k as usize) <= n - 2).then_some(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recs() -> Vec<fasta::Record> {
        let seqs = [
            "ACGTACGTACGTACGTACGT",
            "ACGTACGTACGTACGTACGA",
            "ACGTACGAACGTACGTACGA",
            "ACGAACGAACGTTCGTACGA",
            "TCGAACGAACGTTCGTNNNA",
            "TCGAACGAAC--TCGTACCA",
        ];
        seqs.iter()
            .enumerate()
            .map(|(i, s)| fasta::Record {
                id: format!("s{i}"),
                seq: s.as_bytes().to_vec(),
            })
            .collect()
    }

    #[test]
    fn blocks_equal_the_whole_matrix() {
        let r = recs();
        let seqs: Vec<&[u8]> = r.iter().map(|r| r.seq.as_slice()).collect();
        let whole = nj::distances(&seqs);
        let n = seqs.len();
        for (i0, i1, j0, j1) in [(0, 3, 0, 6), (3, 6, 3, 6), (1, 2, 4, 6), (0, 6, 0, 6)] {
            let b = nj::block(&seqs, i0, i1, j0, j1);
            for i in i0..i1 {
                for j in j0..j1 {
                    assert_eq!(
                        b[(i - i0) * (j1 - j0) + (j - j0)].to_bits(),
                        whole[i * n + j].to_bits()
                    );
                }
            }
        }
    }

    #[test]
    fn a_batch_is_its_replicates() {
        let r = recs();
        let dir = std::env::temp_dir().join(format!("gh2k-boots-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (a, o) = (dir.join("a.fa"), dir.join("b.nwk"));
        let fa: String = r
            .iter()
            .map(|x| format!(">{}\n{}\n", x.id, String::from_utf8_lossy(&x.seq)))
            .collect();
        std::fs::write(&a, fa).unwrap();
        boots(a.to_str().unwrap(), 3, 4, o.to_str().unwrap()).unwrap();
        let want: String = (3..7).map(|s| format!("{}\n", replicate(&r, s))).collect();
        assert_eq!(std::fs::read_to_string(&o).unwrap(), want);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn replicates_are_seeded() {
        let r = recs();
        assert_eq!(replicate(&r, 7), replicate(&r, 7));
    }

    #[test]
    fn support_counts_splits() {
        let main = "((a:1,b:1):1,(c:1,d:1):1,e:1);";
        let reps: Vec<String> = [
            "((a,b),(c,d),e);",
            "((a,b),c,(d,e));",
            "((b,a),(e,d),c);",
            "(a,(b,c),(d,e));",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        // {a,b}: replicates 1-3; {c,d}: replicate 1 only
        assert_eq!(
            supported(main, &reps).unwrap(),
            "((a:1,b:1)75:1,(c:1,d:1)25:1,e:1);"
        );
    }

    #[test]
    fn support_needs_the_same_leaves() {
        assert!(supported("((a,b),(c,d),e);", &["((a,b),(c,x),e);".to_string()]).is_err());
    }
}
