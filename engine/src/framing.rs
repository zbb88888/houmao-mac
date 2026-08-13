//! 帧读写：`[4 字节大端无符号长度][CBOR 载荷]`。
//!
//! 与 pi-protocol 一致。传输层（Unix socket）负责字节序保序；本模块只管分帧。

use std::io::{self, Read, Write};

/// 单帧载荷上限（16 MiB），与 pi 默认一致，防止恶意长度导致 OOM。
pub const MAX_FRAME_LEN: u32 = 16 * 1024 * 1024;

/// 写一帧：先写 4 字节大端长度，再写载荷，最后 flush。
pub fn write_frame<W: Write>(w: &mut W, payload: &[u8]) -> io::Result<()> {
    if payload.len() as u64 > MAX_FRAME_LEN as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds MAX_FRAME_LEN",
        ));
    }
    w.write_all(&(payload.len() as u32).to_be_bytes())?;
    w.write_all(payload)?;
    w.flush()
}

/// 读一帧。流正常结束（读长度时遇 EOF）返回 `Ok(None)`；
/// 读到一半 EOF（截断）返回错误。
pub fn read_frame<R: Read>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match r.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len_buf);
    if len > MAX_FRAME_LEN {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "declared frame length exceeds MAX_FRAME_LEN",
        ));
    }
    let mut buf = vec![0u8; len as usize];
    r.read_exact(&mut buf)?;
    Ok(Some(buf))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn frame_round_trip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"hello").unwrap();
        write_frame(&mut buf, b"").unwrap();
        let mut cur = Cursor::new(buf);
        assert_eq!(
            read_frame(&mut cur).unwrap().as_deref(),
            Some(&b"hello"[..])
        );
        assert_eq!(read_frame(&mut cur).unwrap().as_deref(), Some(&b""[..]));
        assert_eq!(read_frame(&mut cur).unwrap(), None); // 干净 EOF
    }

    #[test]
    fn oversized_declared_length_rejected() {
        let mut cur = Cursor::new((MAX_FRAME_LEN + 1).to_be_bytes().to_vec());
        assert!(read_frame(&mut cur).is_err());
    }
}
