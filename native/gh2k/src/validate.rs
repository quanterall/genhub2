//! Validation and normalisation of an uploaded FASTA or FASTQ file (FS 3.1, task validate).
//!
//! Accepted: FASTA or FASTQ, sequences in IUPAC nucleotide codes (A C G T U N R Y K M S W B D H V, any case).
//! Normalised: upper case, one sequence line per record, RNA (U) written as cDNA (T). Rejected: an unknown format,
//! other characters, a file mixing T and U, empty records, FASTQ records whose quality line is not as long as the
//! sequence or holds characters outside '!'..'~'. The report (JSON on standard output) gives the counts and the
//! first ten problems; the normalised file is written only when there are none.

use crate::json_str;
use std::io::Write;

const IUPAC: &[u8] = b"ACGTUNRYKMSWBDHV";
const MAX_PROBLEMS: usize = 10;

struct Rec<'a> {
    name: &'a [u8],
    seq: Vec<u8>,
    qual: Option<&'a [u8]>,
}

pub fn run(input: &str, output: &str) -> Result<i32, String> {
    let data = std::fs::read(input).map_err(|e| format!("{input}: {e}"))?;
    let mut problems: Vec<String> = Vec::new();
    let first = data.iter().find(|b| !b.is_ascii_whitespace()).copied();
    let (format, recs) = match first {
        Some(b'>') => ("fasta", fasta(&data, &mut problems)),
        Some(b'@') => ("fastq", fastq(&data, &mut problems)),
        Some(_) => ("unknown", {
            problems.push("not FASTA (>) or FASTQ (@)".into());
            Vec::new()
        }),
        None => ("unknown", {
            problems.push("empty file".into());
            Vec::new()
        }),
    };
    let (mut has_t, mut has_u) = (false, false);
    let (mut bases, mut n, mut gc, mut qsum, mut qn) = (0u64, 0u64, 0u64, 0u64, 0u64);
    let (mut min_len, mut max_len) = (u64::MAX, 0u64);
    for (i, r) in recs.iter().enumerate() {
        if r.seq.is_empty() {
            problem(
                &mut problems,
                format!("record {} ({}): empty sequence", i + 1, name(r.name)),
            );
        }
        for (p, &b) in r.seq.iter().enumerate() {
            if !IUPAC.contains(&b) {
                problem(
                    &mut problems,
                    format!(
                        "record {} ({}): character {:?} at position {}",
                        i + 1,
                        name(r.name),
                        b as char,
                        p + 1
                    ),
                );
            }
            match b {
                b'T' => has_t = true,
                b'U' => has_u = true,
                b'G' | b'C' | b'S' => gc += 1,
                b'N' => n += 1,
                _ => {}
            }
        }
        if let Some(q) = r.qual {
            if q.len() != r.seq.len() {
                problem(
                    &mut problems,
                    format!(
                        "record {} ({}): quality length {} for {} bases",
                        i + 1,
                        name(r.name),
                        q.len(),
                        r.seq.len()
                    ),
                );
            }
            for &c in q {
                if !(b'!'..=b'~').contains(&c) {
                    problem(
                        &mut problems,
                        format!(
                            "record {} ({}): quality character {:?}",
                            i + 1,
                            name(r.name),
                            c as char
                        ),
                    );
                    break;
                }
                qsum += (c - b'!') as u64;
                qn += 1;
            }
        }
        let l = r.seq.len() as u64;
        bases += l;
        min_len = min_len.min(l);
        max_len = max_len.max(l);
    }
    if has_t && has_u {
        problem(&mut problems, "both T and U: neither DNA nor RNA".into());
    }
    let kind = if has_u { "rna" } else { "dna" };
    let ok = problems.is_empty() && !recs.is_empty();
    if ok {
        write(output, &recs).map_err(|e| format!("{output}: {e}"))?;
    }
    let mean_q = if qn > 0 {
        format!("{:.2}", qsum as f64 / qn as f64)
    } else {
        "null".into()
    };
    let frac = |x: u64| {
        if bases > 0 {
            format!("{:.6}", x as f64 / bases as f64)
        } else {
            "0".into()
        }
    };
    println!(
        "{{\"ok\":{},\"format\":\"{}\",\"type\":\"{}\",\"records\":{},\"bases\":{},\"min_length\":{},\"max_length\":{},\
         \"n_fraction\":{},\"gc_fraction\":{},\"mean_quality\":{},\"problems\":[{}]}}",
        ok,
        format,
        kind,
        recs.len(),
        bases,
        if recs.is_empty() { 0 } else { min_len },
        max_len,
        frac(n),
        frac(gc),
        mean_q,
        problems.iter().map(|p| json_str(p)).collect::<Vec<_>>().join(",")
    );
    Ok(if ok { 0 } else { 2 })
}

fn problem(ps: &mut Vec<String>, p: String) {
    if ps.len() < MAX_PROBLEMS {
        ps.push(p);
    }
}

fn name(n: &[u8]) -> String {
    String::from_utf8_lossy(n.split(|b| b.is_ascii_whitespace()).next().unwrap_or(b"")).into_owned()
}

fn norm(line: &[u8], seq: &mut Vec<u8>) {
    seq.extend(
        line.iter()
            .filter(|b| !b.is_ascii_whitespace())
            .map(|b| b.to_ascii_uppercase()),
    );
}

fn lines(data: &[u8]) -> impl Iterator<Item = &[u8]> {
    data.split(|&b| b == b'\n')
        .map(|l| l.strip_suffix(b"\r").unwrap_or(l))
}

fn fasta<'a>(data: &'a [u8], problems: &mut Vec<String>) -> Vec<Rec<'a>> {
    let mut recs: Vec<Rec> = Vec::new();
    for (i, line) in lines(data).enumerate() {
        if let Some(h) = line.strip_prefix(b">") {
            recs.push(Rec {
                name: h,
                seq: Vec::new(),
                qual: None,
            });
        } else if let Some(r) = recs.last_mut() {
            norm(line, &mut r.seq);
        } else if !line.iter().all(|b| b.is_ascii_whitespace()) {
            problem(
                problems,
                format!("line {}: sequence before the first header", i + 1),
            );
        }
    }
    recs
}

fn fastq<'a>(data: &'a [u8], problems: &mut Vec<String>) -> Vec<Rec<'a>> {
    let mut ls: Vec<&[u8]> = lines(data).collect();
    while ls.last().is_some_and(|l| l.is_empty()) {
        ls.pop();
    }
    let mut recs = Vec::new();
    let mut i = 0;
    while i < ls.len() {
        if ls[i].is_empty() {
            i += 1;
            continue;
        }
        if i + 3 >= ls.len() {
            problem(problems, format!("line {}: incomplete FASTQ record", i + 1));
            break;
        }
        let (h, s, p, q) = (ls[i], ls[i + 1], ls[i + 2], ls[i + 3]);
        if !h.starts_with(b"@") || !p.starts_with(b"+") {
            problem(
                problems,
                format!(
                    "line {}: not a FASTQ record (@ name, sequence, +, quality)",
                    i + 1
                ),
            );
            break;
        }
        let mut seq = Vec::with_capacity(s.len());
        norm(s, &mut seq);
        recs.push(Rec {
            name: &h[1..],
            seq,
            qual: Some(q),
        });
        i += 4;
    }
    recs
}

fn write(path: &str, recs: &[Rec]) -> std::io::Result<()> {
    let mut w = std::io::BufWriter::new(std::fs::File::create(path)?);
    for r in recs {
        let seq: Vec<u8> = r
            .seq
            .iter()
            .map(|&b| if b == b'U' { b'T' } else { b })
            .collect();
        match r.qual {
            None => {
                w.write_all(b">")?;
                w.write_all(r.name)?;
                w.write_all(b"\n")?;
                w.write_all(&seq)?;
                w.write_all(b"\n")?;
            }
            Some(q) => {
                w.write_all(b"@")?;
                w.write_all(r.name)?;
                w.write_all(b"\n")?;
                w.write_all(&seq)?;
                w.write_all(b"\n+\n")?;
                w.write_all(q)?;
                w.write_all(b"\n")?;
            }
        }
    }
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(input: &[u8]) -> (i32, String) {
        static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("gh2k-validate-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (i, o) = (dir.join("in"), dir.join("out"));
        std::fs::write(&i, input).unwrap();
        let _ = std::fs::remove_file(&o);
        let code = run(i.to_str().unwrap(), o.to_str().unwrap()).unwrap();
        (code, std::fs::read_to_string(&o).unwrap_or_default())
    }

    #[test]
    fn normalises_rna_fasta() {
        assert_eq!(
            check(b">r1 rna\nacgu\nUUA\n"),
            (0, ">r1 rna\nACGTTTA\n".into())
        );
    }

    #[test]
    fn rejects_bad_characters_and_mixed_t_u() {
        assert_eq!(check(b">a\nACGX\n").0, 2);
        assert_eq!(check(b">a\nACGT\n>b\nACGU\n").0, 2);
        assert_eq!(check(b"hello\n").0, 2);
        assert_eq!(check(b"").0, 2);
    }

    #[test]
    fn fastq() {
        assert_eq!(
            check(b"@r1\nacgt\n+\nIIII\n@r2\nAC\n+\nII\n"),
            (0, "@r1\nACGT\n+\nIIII\n@r2\nAC\n+\nII\n".into())
        );
        assert_eq!(check(b"@r1\nACGT\n+\nIII\n").0, 2);
        assert_eq!(check(b"@r1\nACGT\n+\n").0, 2);
    }
}
