use rsmpeg::avformat::AVFormatContextInput;
use std::ffi::CString;

fn main() -> anyhow::Result<()> {
    let path = std::env::args().nth(1).expect("usage: rsmpeg_smoke <path>");
    let cpath = CString::new(path.as_str())?;
    let mut input = AVFormatContextInput::open(&cpath)?;
    eprintln!("nb_streams = {}", input.nb_streams);
    for (i, s) in input.streams().iter().enumerate() {
        let cp = s.codecpar();
        eprintln!(
            "  stream {i}: codec_id={:?} codec_type={:?} time_base={}/{}",
            cp.codec_id, cp.codec_type, s.time_base.num, s.time_base.den
        );
    }
    let mut packets = 0usize;
    let mut bytes = 0u64;
    while let Some(p) = input.read_packet()? {
        packets += 1;
        bytes += p.size as u64;
        if packets >= 200 { break; }
    }
    eprintln!("read {packets} packets, {bytes} bytes");
    Ok(())
}
