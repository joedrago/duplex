//! libav*-driven demux→[passthrough or transcode]→mux pump.
//!
//! Runs on a dedicated blocking std::thread, owns the input/output
//! AVFormatContexts, codecs and filter graph, and writes muxed bytes
//! through a custom AVIOContext directly into the parent Stream's
//! segment buffer. Backpressure: pauses on the parent's Condvar
//! whenever the buffer is more than LOOKAHEAD_SEGMENTS ahead of
//! `last_requested_seg`.
//!
//! Two routes for audio: copy-through when the source is already AAC,
//! or decode → pan downmix (5.1→2.0) → aresample → AAC re-encode for
//! surround AC3/EAC3/TrueHD/DTS sources. Video is always `-c:v copy`.

use std::ffi::CString;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;
use rsmpeg::avcodec::{AVCodec, AVCodecContext, AVPacket};
use rsmpeg::avfilter::{AVFilter, AVFilterContextMut, AVFilterGraph, AVFilterInOut};
use rsmpeg::avformat::{
    AVFormatContextInput, AVFormatContextOutput, AVIOContextContainer, AVIOContextCustom,
};
use rsmpeg::avutil::{AVDictionary, AVMem};
use rsmpeg::error::RsmpegError;
use rsmpeg::ffi;

use super::{Shared, LOOKAHEAD_SEGMENTS};

pub(crate) struct Config {
    pub(crate) file: PathBuf,
    pub(crate) audio_idx: u32,
    pub(crate) transcode: bool,
    pub(crate) start_time: f64,
    pub(crate) start_seg: usize,
}

pub(crate) fn run(cfg: Config, shared: Arc<Shared>) {
    if let Err(e) = run_inner(cfg, &shared) {
        tracing::warn!("stream pump error: {e:#}");
        let mut s = shared.state.lock().unwrap();
        s.error = Some(format!("{e:#}"));
        drop(s);
        shared.new_data.notify_waiters();
    }
}

fn run_inner(cfg: Config, shared: &Arc<Shared>) -> Result<()> {
    let mut input =
        AVFormatContextInput::open(&CString::new(cfg.file.to_string_lossy().as_bytes())?)
            .context("open input")?;

    let (video_in_idx, audio_in_idx) = pick_streams(&input, cfg.audio_idx)?;
    let video_time_base = input.streams().get(video_in_idx).unwrap().time_base;
    let audio_in_time_base = input.streams().get(audio_in_idx).unwrap().time_base;

    if cfg.start_time > 0.0 {
        let ts = (cfg.start_time / av_q2d(video_time_base)) as i64;
        let seek_t0 = std::time::Instant::now();
        unsafe {
            let ret = ffi::av_seek_frame(
                input.as_mut_ptr(),
                video_in_idx as i32,
                ts,
                ffi::AVSEEK_FLAG_BACKWARD as i32,
            );
            if ret < 0 {
                bail!("av_seek_frame failed: {ret}");
            }
        }
        tracing::debug!(
            seek_ms = seek_t0.elapsed().as_millis(),
            start_time = cfg.start_time,
            "seek complete"
        );
    }

    // Set up audio decoder + encoder + filter graph only when transcoding.
    let mut audio_chain = if cfg.transcode {
        Some(build_audio_chain(&input, audio_in_idx).context("build audio transcode chain")?)
    } else {
        None
    };

    // Output context: writes muxed bytes through our segment writer.
    let writer = Arc::new(std::sync::Mutex::new(SegmentWriter::new(
        shared.clone(),
        cfg.start_seg,
    )));
    let writer_for_cb = writer.clone();

    let io_buf = AVMem::new(64 * 1024);
    let avio = AVIOContextCustom::alloc_context(
        io_buf,
        true,
        Vec::new(),
        None,
        Some(Box::new(move |_opaque, buf| {
            writer_for_cb.lock().unwrap().push(buf);
            buf.len() as i32
        })),
        None,
    );

    let fmt_name = CString::new("mp4")?;
    let mut output = AVFormatContextOutput::builder()
        .format_name(&fmt_name)
        .io_context(AVIOContextContainer::Custom(avio))
        .build()
        .context("create output")?;

    // Output streams. Video: matches input codecpar. Audio: matches the
    // encoder's codecpar in the transcode case, otherwise input.
    let video_out_idx;
    let audio_out_idx;
    {
        let mut out_stream = output.new_stream();
        let in_cp = input.streams().get(video_in_idx).unwrap().codecpar();
        let mut cp = rsmpeg::avcodec::AVCodecParameters::new();
        cp.copy(&in_cp);
        out_stream.set_codecpar(cp);
        unsafe {
            (*out_stream.as_mut_ptr()).time_base = video_time_base;
        }
        video_out_idx = out_stream.index;
    }
    {
        let mut out_stream = output.new_stream();
        if let Some(chain) = audio_chain.as_ref() {
            // Use the encoder's parameters.
            let cp = chain.encoder.extract_codecpar();
            out_stream.set_codecpar(cp);
            unsafe {
                (*out_stream.as_mut_ptr()).time_base = ffi::AVRational {
                    num: 1,
                    den: chain.encoder.sample_rate,
                };
            }
        } else {
            let in_cp = input.streams().get(audio_in_idx).unwrap().codecpar();
            let mut cp = rsmpeg::avcodec::AVCodecParameters::new();
            cp.copy(&in_cp);
            out_stream.set_codecpar(cp);
            unsafe {
                (*out_stream.as_mut_ptr()).time_base = audio_in_time_base;
            }
        }
        audio_out_idx = out_stream.index;
    }

    let opts = AVDictionary::new(
        &CString::new("movflags")?,
        &CString::new("+empty_moov+delay_moov+frag_keyframe+default_base_moof+omit_tfhd_offset")?,
        0,
    );
    let mut opts_slot = Some(opts);
    output
        .write_header(&mut opts_slot)
        .context("write_header")?;

    let video_out_tb = output
        .streams()
        .get(video_out_idx as usize)
        .unwrap()
        .time_base;
    let audio_out_tb = output
        .streams()
        .get(audio_out_idx as usize)
        .unwrap()
        .time_base;

    let mut pkt_count: usize = 0;
    loop {
        // Backpressure: wait until consumer needs more.
        {
            let mut s = shared.state.lock().unwrap();
            while !s.should_stop {
                let edge = s.leading_edge.unwrap_or(cfg.start_seg.saturating_sub(1));
                let ahead = edge.saturating_sub(s.last_requested_seg);
                if ahead < LOOKAHEAD_SEGMENTS {
                    break;
                }
                tracing::debug!(
                    leading_edge = edge,
                    last_requested = s.last_requested_seg,
                    ahead,
                    "pump: backpressure wait"
                );
                s = shared.drain.wait(s).unwrap();
            }
            if s.should_stop {
                break;
            }
        }

        let mut packet = match input.read_packet() {
            Ok(Some(p)) => p,
            Ok(None) => break,
            Err(e) => bail!("read_packet: {e}"),
        };

        let pkt_stream_idx = packet.stream_index as usize;
        if pkt_stream_idx == video_in_idx {
            // Estimate PTS from DTS if unset, to avoid muxer warnings.
            if unsafe { (*packet.as_ptr()).pts == ffi::AV_NOPTS_VALUE } {
                unsafe { (*packet.as_mut_ptr()).pts = (*packet.as_ptr()).dts };
            }
            packet.set_stream_index(video_out_idx);
            unsafe {
                ffi::av_packet_rescale_ts(packet.as_mut_ptr(), video_time_base, video_out_tb);
            }
            if let Err(e) = output.interleaved_write_frame(&mut packet) {
                bail!("interleaved_write_frame (video): {e}");
            }
        } else if pkt_stream_idx == audio_in_idx {
            if let Some(chain) = audio_chain.as_mut() {
                process_audio_transcode(chain, &packet, &mut output, audio_out_idx, audio_out_tb)?;
            } else {
                packet.set_stream_index(audio_out_idx);
                unsafe {
                    ffi::av_packet_rescale_ts(
                        packet.as_mut_ptr(),
                        audio_in_time_base,
                        audio_out_tb,
                    );
                }
                if let Err(e) = output.interleaved_write_frame(&mut packet) {
                    bail!("interleaved_write_frame (audio): {e}");
                }
            }
        }
        pkt_count += 1;
        if pkt_count % 1000 == 0 {
            tracing::debug!(packets = pkt_count, "pump: processing");
        }
    }

    // Flush the transcode chain on clean EOF so trailing audio frames
    // make it into the output.
    if let Some(chain) = audio_chain.as_mut() {
        flush_audio_transcode(chain, &mut output, audio_out_idx, audio_out_tb)?;
    }
    let _ = output.write_trailer();
    writer.lock().unwrap().flush_remaining();
    Ok(())
}

struct AudioChain {
    decoder: AVCodecContext,
    encoder: AVCodecContext,
    graph: AVFilterGraph,
    src_name: CString,
    sink_name: CString,
}

fn build_audio_chain(input: &AVFormatContextInput, audio_in_idx: usize) -> Result<AudioChain> {
    let in_stream = input.streams().get(audio_in_idx).unwrap();
    let src_time_base = in_stream.time_base;
    let in_cp = in_stream.codecpar();

    let decoder_codec = AVCodec::find_decoder(in_cp.codec_id)
        .ok_or_else(|| anyhow!("no decoder for codec id {:?}", in_cp.codec_id))?;
    let mut decoder = AVCodecContext::new(&decoder_codec);
    decoder
        .apply_codecpar(&in_cp)
        .context("apply audio codecpar")?;
    unsafe {
        (*decoder.as_mut_ptr()).pkt_timebase = src_time_base;
    }
    decoder.open(None).context("open audio decoder")?;

    let encoder_codec = AVCodec::find_encoder(ffi::AV_CODEC_ID_AAC)
        .ok_or_else(|| anyhow!("no AAC encoder available"))?;
    let mut encoder = AVCodecContext::new(&encoder_codec);
    unsafe {
        let raw = encoder.as_mut_ptr();
        (*raw).sample_rate = 48000;
        (*raw).bit_rate = 192_000;
        (*raw).sample_fmt = ffi::AV_SAMPLE_FMT_FLTP;
        let mut layout: ffi::AVChannelLayout = std::mem::zeroed();
        ffi::av_channel_layout_default(&mut layout, 2);
        (*raw).ch_layout = layout;
        (*raw).time_base = ffi::AVRational { num: 1, den: 48000 };
    }
    encoder.open(None).context("open AAC encoder")?;

    // Audio filter graph: abuffer → pan downmix → aresample → aformat → abuffersink.
    let graph = AVFilterGraph::new();

    let in_ch_layout_desc = describe_ch_layout(&in_cp.ch_layout())?;
    let in_sample_rate = in_cp.sample_rate;
    let in_sample_fmt = in_cp.format;
    let in_sample_fmt_name = sample_fmt_name(in_sample_fmt)?;
    let src_args = CString::new(format!(
        "sample_rate={}:sample_fmt={}:channel_layout={}:time_base={}/{}",
        in_sample_rate,
        in_sample_fmt_name.to_string_lossy(),
        in_ch_layout_desc.to_string_lossy(),
        src_time_base.num,
        src_time_base.den,
    ))?;

    let abuffer =
        AVFilter::get_by_name(c"abuffer").ok_or_else(|| anyhow!("abuffer filter missing"))?;
    let abuffersink = AVFilter::get_by_name(c"abuffersink")
        .ok_or_else(|| anyhow!("abuffersink filter missing"))?;

    let src_name = CString::new("src")?;
    let sink_name = CString::new("sink")?;
    {
        let mut src_ctx: AVFilterContextMut<'_> = graph
            .create_filter_context(&abuffer, &src_name, Some(&src_args))
            .context("create abuffer")?;
        // Allocate (don't initialize) so we can set options first.
        let mut sink_ctx: AVFilterContextMut<'_> = graph
            .alloc_filter_context(&abuffersink, &sink_name)
            .ok_or_else(|| anyhow!("failed to alloc abuffersink"))?;
        // In ffmpeg 7+, sample_fmts and sample_rates are binary array options.
        sink_ctx
            .opt_set_array(
                c"sample_formats",
                0,
                Some(&[ffi::AV_SAMPLE_FMT_FLTP]),
                ffi::AV_OPT_TYPE_SAMPLE_FMT,
            )
            .context("sink sample_formats")?;
        sink_ctx
            .opt_set_array(c"samplerates", 0, Some(&[48000i64]), ffi::AV_OPT_TYPE_INT64)
            .context("sink samplerates")?;
        let mut layout: ffi::AVChannelLayout = unsafe { std::mem::zeroed() };
        unsafe { ffi::av_channel_layout_default(&mut layout, 2) };
        sink_ctx
            .opt_set_array(
                c"channel_layouts",
                0,
                Some(&[layout]),
                ffi::AV_OPT_TYPE_CHLAYOUT,
            )
            .context("sink channel_layouts")?;
        // Match sink frame size to encoder's expected frame size.
        let encoder_frame_size = unsafe { (*encoder.as_ptr()).frame_size } as u32;
        sink_ctx.buffersink_set_frame_size(encoder_frame_size);
        sink_ctx.init_str(None).context("init abuffersink")?;

        let filter_spec = CString::new(
            "pan=stereo|FL=1.0*FL+0.707*FC+0.707*SL+0.707*BL|FR=1.0*FR+0.707*FC+0.707*SR+0.707*BR,aresample=async=1,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo",
        )?;
        let outputs = AVFilterInOut::new(&CString::new("in")?, &mut src_ctx, 0);
        let inputs = AVFilterInOut::new(&CString::new("out")?, &mut sink_ctx, 0);
        graph
            .parse_ptr(&filter_spec, Some(inputs), Some(outputs))
            .context("filter graph parse")?;
    }
    graph.config().context("filter graph config")?;

    let _ = src_time_base;
    Ok(AudioChain {
        decoder,
        encoder,
        graph,
        src_name,
        sink_name,
    })
}

fn process_audio_transcode(
    chain: &mut AudioChain,
    packet: &AVPacket,
    output: &mut AVFormatContextOutput,
    audio_out_idx: i32,
    audio_out_tb: ffi::AVRational,
) -> Result<()> {
    chain
        .decoder
        .send_packet(Some(packet))
        .map_err(|e| match e {
            RsmpegError::DecoderFullError | RsmpegError::DecoderFlushedError => anyhow!("{e}"),
            other => anyhow!("send_packet: {other}"),
        })?;
    drain_decoder(chain, output, audio_out_idx, audio_out_tb)
}

fn drain_decoder(
    chain: &mut AudioChain,
    output: &mut AVFormatContextOutput,
    audio_out_idx: i32,
    audio_out_tb: ffi::AVRational,
) -> Result<()> {
    loop {
        let frame = match chain.decoder.receive_frame() {
            Ok(f) => f,
            Err(RsmpegError::DecoderDrainError) => break,
            Err(RsmpegError::DecoderFlushedError) => break,
            Err(e) => bail!("receive_frame: {e}"),
        };
        {
            let mut src_ctx = chain
                .graph
                .get_filter(&chain.src_name)
                .ok_or_else(|| anyhow!("filter src missing"))?;
            src_ctx
                .buffersrc_add_frame(Some(frame), None)
                .context("buffersrc_add_frame")?;
        }
        pump_filter_to_encoder(chain, output, audio_out_idx, audio_out_tb)?;
    }
    Ok(())
}

fn pump_filter_to_encoder(
    chain: &mut AudioChain,
    output: &mut AVFormatContextOutput,
    audio_out_idx: i32,
    audio_out_tb: ffi::AVRational,
) -> Result<()> {
    loop {
        let frame = {
            let mut sink_ctx = chain
                .graph
                .get_filter(&chain.sink_name)
                .ok_or_else(|| anyhow!("filter sink missing"))?;
            match sink_ctx.buffersink_get_frame(None) {
                Ok(f) => f,
                Err(RsmpegError::BufferSinkDrainError) => break,
                Err(RsmpegError::BufferSinkEofError) => break,
                Err(e) => bail!("buffersink_get_frame: {e}"),
            }
        };
        chain
            .encoder
            .send_frame(Some(&frame))
            .map_err(|e| anyhow!("{e}"))?;
        drain_encoder(chain, output, audio_out_idx, audio_out_tb)?;
    }
    Ok(())
}

fn drain_encoder(
    chain: &mut AudioChain,
    output: &mut AVFormatContextOutput,
    audio_out_idx: i32,
    audio_out_tb: ffi::AVRational,
) -> Result<()> {
    let enc_tb = unsafe { (*chain.encoder.as_ptr()).time_base };
    loop {
        let mut pkt = match chain.encoder.receive_packet() {
            Ok(p) => p,
            Err(RsmpegError::EncoderDrainError) => break,
            Err(RsmpegError::EncoderFlushedError) => break,
            Err(e) => bail!("encoder receive_packet: {e}"),
        };
        pkt.set_stream_index(audio_out_idx);
        unsafe {
            ffi::av_packet_rescale_ts(pkt.as_mut_ptr(), enc_tb, audio_out_tb);
        }
        if let Err(e) = output.interleaved_write_frame(&mut pkt) {
            bail!("interleaved_write_frame (encoded audio): {e}");
        }
    }
    Ok(())
}

fn flush_audio_transcode(
    chain: &mut AudioChain,
    output: &mut AVFormatContextOutput,
    audio_out_idx: i32,
    audio_out_tb: ffi::AVRational,
) -> Result<()> {
    // Flush decoder.
    let _ = chain.decoder.send_packet(None);
    drain_decoder(chain, output, audio_out_idx, audio_out_tb)?;
    // Flush filter graph.
    {
        let mut src_ctx = chain
            .graph
            .get_filter(&chain.src_name)
            .ok_or_else(|| anyhow!("filter src missing"))?;
        let _ = src_ctx.buffersrc_add_frame(None, None);
    }
    pump_filter_to_encoder(chain, output, audio_out_idx, audio_out_tb)?;
    // Flush encoder.
    let _ = chain.encoder.send_frame(None);
    drain_encoder(chain, output, audio_out_idx, audio_out_tb)
}

fn pick_streams(input: &AVFormatContextInput, requested_audio_idx: u32) -> Result<(usize, usize)> {
    let mut video_idx: Option<usize> = None;
    let mut audio_idx: Option<usize> = None;
    for (i, s) in input.streams().iter().enumerate() {
        let ct = s.codecpar().codec_type();
        if ct.is_video() && video_idx.is_none() {
            video_idx = Some(i);
        }
        if ct.is_audio() && i == requested_audio_idx as usize {
            audio_idx = Some(i);
        }
    }
    if audio_idx.is_none() {
        for (i, s) in input.streams().iter().enumerate() {
            if s.codecpar().codec_type().is_audio() {
                audio_idx = Some(i);
                break;
            }
        }
    }
    Ok((
        video_idx.ok_or_else(|| anyhow!("no video stream"))?,
        audio_idx.ok_or_else(|| anyhow!("no audio stream"))?,
    ))
}

fn av_q2d(q: ffi::AVRational) -> f64 {
    q.num as f64 / q.den as f64
}

fn describe_ch_layout(layout: &rsmpeg::avutil::AVChannelLayoutRef<'_>) -> Result<CString> {
    let mut buf = [0i8; 256];
    let n = unsafe {
        ffi::av_channel_layout_describe(layout.as_ptr(), buf.as_mut_ptr() as *mut _, buf.len())
    };
    if n < 0 {
        bail!("av_channel_layout_describe failed: {n}");
    }
    let n = n as usize;
    if n == 0 {
        bail!("av_channel_layout_describe returned empty string");
    }
    // n includes the null terminator; slice it off so CString::new doesn't reject the input
    let bytes: Vec<u8> = buf[..n - 1].iter().map(|b| *b as u8).collect();
    CString::new(bytes).context("layout describe → CString")
}

fn sample_fmt_name(sample_fmt: i32) -> Result<CString> {
    let ptr = unsafe { ffi::av_get_sample_fmt_name(sample_fmt) };
    if ptr.is_null() {
        bail!("unknown sample_fmt {sample_fmt}");
    }
    let cstr = unsafe { std::ffi::CStr::from_ptr(ptr) };
    Ok(cstr.to_owned())
}

/// Accumulates muxer output bytes and slices them into init segment +
/// moof+mdat media segments as they arrive.
struct SegmentWriter {
    shared: Arc<Shared>,
    next_seg: usize,
    start_seg: usize,
    init_done: bool,
    first_seg_logged: bool,
    pre_init_buf: Vec<u8>,
    pending_moof: Option<Vec<u8>>,
    scratch: Vec<u8>,
    start_instant: std::time::Instant,
}

impl SegmentWriter {
    fn new(shared: Arc<Shared>, start_seg: usize) -> Self {
        Self {
            shared,
            next_seg: start_seg,
            start_seg,
            init_done: false,
            first_seg_logged: false,
            pre_init_buf: Vec::with_capacity(64 * 1024),
            pending_moof: None,
            scratch: Vec::new(),
            start_instant: std::time::Instant::now(),
        }
    }

    fn push(&mut self, buf: &[u8]) {
        self.scratch.extend_from_slice(buf);
        loop {
            let Some((kind, total_size)) = peek_box_size(&self.scratch) else {
                break;
            };
            if self.scratch.len() < total_size {
                break;
            }
            let box_bytes: Vec<u8> = self.scratch.drain(..total_size).collect();
            self.consume_box(kind, box_bytes);
        }
    }

    fn consume_box(&mut self, kind: [u8; 4], bytes: Vec<u8>) {
        match &kind {
            b"moof" => {
                self.pending_moof = Some(bytes);
            }
            b"mdat" => {
                if let Some(moof) = self.pending_moof.take() {
                    let mut combined = Vec::with_capacity(moof.len() + bytes.len());
                    combined.extend_from_slice(&moof);
                    combined.extend_from_slice(&bytes);
                    let mut s = self.shared.state.lock().unwrap();
                    if !self.init_done && !self.pre_init_buf.is_empty() {
                        s.init_segment = Some(Bytes::from(std::mem::take(&mut self.pre_init_buf)));
                        self.init_done = true;
                        tracing::debug!(
                            init_ms = self.start_instant.elapsed().as_millis(),
                            "init segment ready"
                        );
                    }
                    s.segments.insert(self.next_seg, Bytes::from(combined));
                    s.leading_edge = Some(self.next_seg);
                    let seg = self.next_seg;
                    self.next_seg += 1;
                    drop(s);
                    if !self.first_seg_logged && seg == self.start_seg {
                        tracing::debug!(
                            segment = seg,
                            first_seg_ms = self.start_instant.elapsed().as_millis(),
                            "first segment ready"
                        );
                        self.first_seg_logged = true;
                    }
                    self.shared.new_data.notify_waiters();
                }
            }
            _ => {
                if !self.init_done {
                    self.pre_init_buf.extend_from_slice(&bytes);
                }
            }
        }
    }

    fn flush_remaining(&mut self) {
        if !self.scratch.is_empty() {
            tracing::debug!(
                target: "ffmpeg",
                tail_bytes = self.scratch.len(),
                "pump flushed without complete trailing box",
            );
        }
    }
}

fn peek_box_size(buf: &[u8]) -> Option<([u8; 4], usize)> {
    if buf.len() < 8 {
        return None;
    }
    let size_field = u32::from_be_bytes(buf[..4].try_into().ok()?);
    let mut kind = [0u8; 4];
    kind.copy_from_slice(&buf[4..8]);
    let total = match size_field {
        0 => return None,
        1 => {
            if buf.len() < 16 {
                return None;
            }
            u64::from_be_bytes(buf[8..16].try_into().ok()?) as usize
        }
        n if n < 8 => return None,
        n => n as usize,
    };
    Some((kind, total))
}
