//! FASTA reading for the kernels that take already validated input (validate.rs checks uploads).

pub struct Record {
    /// the header's first word (the accession)
    pub id: String,
    /// upper case, without line breaks
    pub seq: Vec<u8>,
}

pub fn read(path: &str) -> Result<Vec<Record>, String> {
    let data = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    Ok(parse(&data))
}

pub fn parse(data: &[u8]) -> Vec<Record> {
    let mut out: Vec<Record> = Vec::new();
    for line in data.split(|&b| b == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if let Some(h) = line.strip_prefix(b">") {
            let h = String::from_utf8_lossy(h);
            let id = h.split_whitespace().next().unwrap_or("").to_string();
            out.push(Record {
                id,
                seq: Vec::new(),
            });
        } else if let Some(r) = out.last_mut() {
            r.seq.extend(
                line.iter()
                    .filter(|b| !b.is_ascii_whitespace())
                    .map(|b| b.to_ascii_uppercase()),
            );
        }
    }
    out
}

/// 2-bit code of a base, None for anything but A, C, G, T.
#[inline]
pub fn code(b: u8) -> Option<u64> {
    match b {
        b'A' => Some(0),
        b'C' => Some(1),
        b'G' => Some(2),
        b'T' => Some(3),
        _ => None,
    }
}

pub fn revcomp(s: &[u8]) -> Vec<u8> {
    s.iter()
        .rev()
        .map(|&b| match b {
            b'A' => b'T',
            b'C' => b'G',
            b'G' => b'C',
            b'T' => b'A',
            o => o,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_records() {
        let r = parse(b">a x\nac\ngt\r\n>b\nNN\n");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].id, "a");
        assert_eq!(r[0].seq, b"ACGT");
        assert_eq!(r[1].seq, b"NN");
        assert_eq!(revcomp(b"AACGN"), b"NCGTT");
    }
}
