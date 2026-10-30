//! Audio stream format detection, header sniffing and duration estimation in pure Rust.

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContainerFormat {
    Unknown = 0,
    Mp3 = 1,
    Adts = 2,
    Flac = 3,
    OggVorbis = 4,
    OggOpus = 5,
    Wav = 6,
    Mp4 = 7,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoundaryStatus {
    Unsupported = -1,
    NeedMore = 0,
    Found = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoundaryInfo {
    pub container: ContainerFormat,
    pub audio_start: i64,
    pub audio_end: i64,
    pub wav_data_size_field_offset: i64,
    pub mp4_mdat_atom_offset: i64,
    pub mp4_mdat_header_size: u32,
    pub head_has_mpeg_frame: i32,
    pub bytes_per_frame: u32,
    pub needed_bytes: i64,
}

impl Default for BoundaryInfo {
    fn default() -> Self {
        Self::new()
    }
}

impl BoundaryInfo {
    pub const fn new() -> Self {
        Self {
            container: ContainerFormat::Unknown,
            audio_start: -1,
            audio_end: -1,
            wav_data_size_field_offset: -1,
            mp4_mdat_atom_offset: -1,
            mp4_mdat_header_size: 0,
            head_has_mpeg_frame: 0,
            bytes_per_frame: 1,
            needed_bytes: 0,
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }
}

const MAX_HEAD_SCAN: i64 = 64 * 1024 * 1024;
const SYNC_SCAN_LIMIT: i64 = 65536;

pub struct FormatSniffer;

impl FormatSniffer {
    pub fn container_needs_tail_scan(container: ContainerFormat) -> bool {
        matches!(
            container,
            ContainerFormat::Mp3 | ContainerFormat::Adts | ContainerFormat::Flac
        )
    }

    pub fn detect_head_boundary(data: &[u8], total_size: i64) -> (BoundaryStatus, BoundaryInfo) {
        let mut info = BoundaryInfo::new();
        let avail = data.len();

        if avail < 12 {
            let status = Self::need_more(&mut info, 12, total_size, avail);
            return (status, info);
        }

        if (data.starts_with(b"RIFF") || data.starts_with(b"RF64")) && &data[8..12] == b"WAVE" {
            let status = Self::detect_wav(data, total_size, &mut info);
            return (status, info);
        }
        if data.starts_with(b"RIFX") && data.len() >= 12 && &data[8..12] == b"WAVE" {
            let status = Self::detect_rifx(data, total_size, &mut info);
            return (status, info);
        }
        if data.starts_with(&[0x72, 0x69, 0x66, 0x66, 0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0x00, 0x00])
            && data.len() >= 40
            && &data[24..40] == &[0x77, 0x61, 0x76, 0x65, 0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0x00, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a]
        {
            let status = Self::detect_w64(data, total_size, &mut info);
            return (status, info);
        }
        if data.starts_with(b"fLaC") {
            let status = Self::detect_flac(data, total_size, 0, &mut info);
            return (status, info);
        }
        if data.starts_with(b"OggS") {
            let status = Self::detect_ogg(data, total_size, &mut info);
            return (status, info);
        }
        if data.len() >= 8 && &data[4..8] == b"ftyp" {
            let status = Self::detect_mp4(data, total_size, &mut info);
            return (status, info);
        }

        // Leading ID3v2 tags
        let mut p: usize = 0;
        loop {
            if p + 10 > avail {
                let status = Self::need_more(&mut info, (p + 10) as i64, total_size, avail);
                return (status, info);
            }
            let t = &data[p..];
            if t[0] == b'I'
                && t[1] == b'D'
                && t[2] == b'3'
                && t[3] != 0xFF
                && t[4] != 0xFF
                && ((t[6] | t[7] | t[8] | t[9]) & 0x80) == 0
            {
                let tag_size = synchsafe32(&t[6..10]);
                let footer = if (t[5] & 0x10) != 0 { 10 } else { 0 };
                p += 10 + tag_size as usize + footer;
                if p as i64 > MAX_HEAD_SCAN || (total_size > 0 && p as i64 > total_size) {
                    return (BoundaryStatus::Unsupported, info);
                }
                continue;
            }
            break;
        }

        if p + 4 > avail {
            let status = Self::need_more(&mut info, (p + 4) as i64, total_size, avail);
            return (status, info);
        }

        if data[p..].starts_with(b"fLaC") {
            let status = Self::detect_flac(data, total_size, p as i64, &mut info);
            return (status, info);
        }

        let status = Self::detect_mpeg(data, total_size, p as i64, &mut info);
        (status, info)
    }

    pub fn detect_tail_boundary(
        container: ContainerFormat,
        tail: &[u8],
        tail_offset: i64,
        total_size: i64,
        audio_start: i64,
    ) -> (BoundaryStatus, i64) {
        if total_size <= 0 {
            return (BoundaryStatus::Unsupported, total_size);
        }
        if !Self::container_needs_tail_scan(container) {
            return (BoundaryStatus::Found, total_size);
        }
        if tail.is_empty() || tail_offset + tail.len() as i64 != total_size {
            return (BoundaryStatus::Unsupported, total_size);
        }

        let audio_start = audio_start.max(0);
        let mut end = total_size;
        let mut status = BoundaryStatus::Found;
        let mut changed = true;

        while changed {
            changed = false;

            // 1. ID3v1 (128 bytes) & ID3v1 Enhanced (227 bytes)
            if end - 128 >= audio_start {
                if end - 128 < tail_offset {
                    status = BoundaryStatus::NeedMore;
                    break;
                }
                let idx = (end - 128 - tail_offset) as usize;
                let t = &tail[idx..];
                if t.starts_with(b"TAG") {
                    end -= 128;
                    if end - 227 >= audio_start && end - 227 >= tail_offset {
                        let e_idx = (end - 227 - tail_offset) as usize;
                        if tail[e_idx..].starts_with(b"TAG+") {
                            end -= 227;
                        }
                    }
                    changed = true;
                    continue;
                }
            }

            // 2. APEv2 / APEv1 footer (32 bytes)
            if end - 32 >= audio_start && end - 32 >= tail_offset {
                let idx = (end - 32 - tail_offset) as usize;
                if tail[idx..].starts_with(b"APETAGEX") {
                    let f = &tail[idx..];
                    let ape_size = le32(&f[12..16]);
                    let ape_flags = le32(&f[20..24]);
                    let ape_total = ape_size as i64 + if (ape_flags & 0x80000000) != 0 { 32 } else { 0 };
                    if ape_total >= 32 && end - ape_total >= audio_start {
                        end -= ape_total;
                        changed = true;
                        if end < tail_offset {
                            status = BoundaryStatus::NeedMore;
                            break;
                        }
                        continue;
                    }
                }
            }

            // 3. Lyrics3v2: "<6 ascii digits>LYRICS200"
            if end - 15 >= audio_start && end - 15 >= tail_offset {
                let lyr_idx = (end - 9 - tail_offset) as usize;
                if tail[lyr_idx..].starts_with(b"LYRICS200") {
                    let s_idx = (end - 15 - tail_offset) as usize;
                    let s = &tail[s_idx..s_idx + 6];
                    let mut lyrics_size: i64 = 0;
                    let mut valid = true;
                    for &b in s {
                        if !b.is_ascii_digit() {
                            valid = false;
                            break;
                        }
                        lyrics_size = lyrics_size * 10 + (b - b'0') as i64;
                    }
                    let lyr_total = lyrics_size + 6 + 9;
                    if valid && end - lyr_total >= audio_start {
                        end -= lyr_total;
                        changed = true;
                        if end < tail_offset {
                            status = BoundaryStatus::NeedMore;
                            break;
                        }
                        continue;
                    }
                }
            }

            // 4. Appended ID3v2 tag with footer ("3DI")
            if end - 10 >= audio_start && end - 10 >= tail_offset {
                let idx = (end - 10 - tail_offset) as usize;
                let f = &tail[idx..];
                if f.starts_with(b"3DI") && ((f[6] | f[7] | f[8] | f[9]) & 0x80) == 0 {
                    let id3_total = synchsafe32(&f[6..10]) as i64 + 20;
                    if end - id3_total >= audio_start {
                        end -= id3_total;
                        changed = true;
                        if end < tail_offset {
                            status = BoundaryStatus::NeedMore;
                            break;
                        }
                        continue;
                    }
                }
            }
        }

        (status, end)
    }

    pub fn extract_tail_duration_ms(
        container: ContainerFormat,
        sample_rate: u32,
        tail: &[u8],
    ) -> Option<i64> {
        if tail.len() < 27 {
            return None;
        }
        if !matches!(container, ContainerFormat::OggVorbis | ContainerFormat::OggOpus) {
            return None;
        }
        let srate = if container == ContainerFormat::OggOpus { 48000 } else { sample_rate };
        if srate == 0 {
            return None;
        }

        let scan_start = tail.len() - 27;
        for j in (0..=scan_start).rev() {
            if tail[j..].starts_with(b"OggS") && tail[j + 4] == 0 {
                let granule_pos = le64(&tail[j + 6..j + 14]);
                if granule_pos > 0 && granule_pos != u64::MAX {
                    let dur_ms = (granule_pos.saturating_mul(1000) / srate as u64) as i64;
                    if dur_ms > 0 {
                        return Some(dur_ms);
                    }
                }
            }
        }
        None
    }

    pub fn sniff_mp3_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        let avail = data.len();
        if avail < 10 {
            return None;
        }

        if avail >= 4 {
            if data.starts_with(b"RIFF")
                || data.starts_with(b"RF64")
                || data.starts_with(b"fLaC")
                || data.starts_with(b"FORM")
                || data.starts_with(b"OggS")
            {
                return None;
            }
        }
        if avail >= 8 && &data[4..8] == b"ftyp" {
            return None;
        }

        let mut start_offset = 0;
        let mut id3_total_size = 0;

        if data.starts_with(b"ID3") && avail >= 10 {
            let id3_size = synchsafe32(&data[6..10]);
            id3_total_size = 10 + id3_size;
            if (data[5] & 0x10) != 0 {
                id3_total_size += 10;
            }
            start_offset = (id3_total_size as usize).min(avail);
        }

        if start_offset + 4 > avail {
            return None;
        }

        let scan_limit = (start_offset + 32768).min(avail);
        for i in start_offset..scan_limit.saturating_sub(3) {
            let h = &data[i..];
            let mut hdr = MpegHeader::default();
            if !parse_mpeg_header(h, &mut hdr) {
                continue;
            }

            if i + hdr.frame_size as usize + 4 <= avail {
                let mut nh = MpegHeader::default();
                if !parse_mpeg_header(&data[i + hdr.frame_size as usize..], &mut nh) {
                    continue;
                }
            }

            // Check Xing / Info / VBRI header
            let xing_offset = 4 + (if hdr.has_crc { 2 } else { 0 }) + hdr.side_info as usize;
            if hdr.layer == 1 && i + xing_offset + 12 <= avail {
                let tag = &data[i + xing_offset..];
                if tag.starts_with(b"Xing") || tag.starts_with(b"Info") {
                    let flags = be32(&tag[4..8]);
                    if (flags & 0x01) != 0 {
                        let total_mpeg_frames = be32(&tag[8..12]);
                        let samples_per_frame = if hdr.ver == 3 { 1152 } else { 576 };
                        let total_pcm = total_mpeg_frames as u64 * samples_per_frame as u64;
                        let duration_ms = (total_pcm as f64 * 1000.0 / hdr.sample_rate as f64 + 0.5) as i64;
                        let bitrate = if (flags & 0x02) != 0 && duration_ms > 0 {
                            let total_audio_bytes = be32(&tag[12..16]);
                            ((total_audio_bytes as u64 * 8000) / duration_ms as u64) as u32
                        } else if total_size > 0 && duration_ms > 0 {
                            ((total_size as u64 * 8000) / duration_ms as u64) as u32
                        } else {
                            hdr.bitrate_kbps * 1000
                        };
                        return Some((bitrate, duration_ms));
                    }
                }
            }

            // VBRI
            let vbri_offset = 4 + (if hdr.has_crc { 2 } else { 0 }) + 32;
            if hdr.layer == 1 && i + vbri_offset + 18 <= avail {
                let tag = &data[i + vbri_offset..];
                if tag.starts_with(b"VBRI") {
                    let total_mpeg_frames = be32(&tag[14..18]);
                    let samples_per_frame = if hdr.ver == 3 { 1152 } else { 576 };
                    let total_pcm = total_mpeg_frames as u64 * samples_per_frame as u64;
                    let duration_ms = (total_pcm as f64 * 1000.0 / hdr.sample_rate as f64 + 0.5) as i64;
                    let bitrate = if duration_ms > 0 {
                        let total_audio_bytes = be32(&tag[10..14]);
                        ((total_audio_bytes as u64 * 8000) / duration_ms as u64) as u32
                    } else {
                        hdr.bitrate_kbps * 1000
                    };
                    return Some((bitrate, duration_ms));
                }
            }

            // Standard CBR
            let bitrate = hdr.bitrate_kbps * 1000;
            let duration_ms = if total_size > 0 {
                let audio_bytes = if total_size > id3_total_size as i64 {
                    total_size - id3_total_size as i64
                } else {
                    total_size
                };
                ((audio_bytes as u64 * 8000) / bitrate as u64) as i64
            } else {
                0
            };
            return Some((bitrate, duration_ms));
        }

        None
    }

    pub fn sniff_ogg_vorbis_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        if data.len() < 40 || !data.starts_with(b"OggS") {
            return None;
        }

        let scan_limit = data.len().min(4096);
        for i in 0..scan_limit.saturating_sub(27) {
            if data[i..].starts_with(b"\x01vorbis") {
                let sample_rate = le32(&data[i + 12..i + 16]);
                let bitrate_nominal = le32(&data[i + 20..i + 24]) as i32;
                let bitrate_max = le32(&data[i + 16..i + 20]) as i32;

                if total_size > 0 && data.len() as i64 >= total_size && sample_rate > 0 {
                    if let Some(dur_ms) = Self::extract_tail_duration_ms(
                        ContainerFormat::OggVorbis,
                        sample_rate,
                        data,
                    ) {
                        let br = ((total_size as u64 * 8000) / dur_ms as u64) as u32;
                        return Some((br, dur_ms));
                    }
                }

                let br = if bitrate_nominal > 0 {
                    bitrate_nominal as u32
                } else if bitrate_max > 0 {
                    bitrate_max as u32
                } else {
                    0
                };

                if br > 0 {
                    let dur_ms = if total_size > 0 {
                        ((total_size as u64 * 8000) / br as u64) as i64
                    } else {
                        0
                    };
                    return Some((br, dur_ms));
                }
            }
        }
        None
    }

    pub fn sniff_ogg_opus_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        if data.len() < 40 || !data.starts_with(b"OggS") {
            return None;
        }

        let scan_limit = data.len().min(4096);
        for i in 0..scan_limit.saturating_sub(18) {
            if data[i..].starts_with(b"OpusHead") {
                if total_size > 0 && data.len() as i64 >= total_size {
                    if let Some(dur_ms) = Self::extract_tail_duration_ms(
                        ContainerFormat::OggOpus,
                        48000,
                        data,
                    ) {
                        let br = ((total_size as u64 * 8000) / dur_ms as u64) as u32;
                        return Some((br, dur_ms));
                    }
                }

                let channels = data[i + 9];
                let br = if channels >= 2 { 128000 } else { 64000 };
                let dur_ms = if total_size > 0 {
                    ((total_size as u64 * 8000) / br as u64) as i64
                } else {
                    0
                };
                return Some((br, dur_ms));
            }
        }
        None
    }

    pub fn sniff_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        if let Some(res) = Self::sniff_mp3_stream_info(data, total_size) {
            return Some(res);
        }
        if let Some(res) = Self::sniff_ogg_vorbis_stream_info(data, total_size) {
            return Some(res);
        }
        if let Some(res) = Self::sniff_ogg_opus_stream_info(data, total_size) {
            return Some(res);
        }
        None
    }

    // Helper functions
    fn need_more(out: &mut BoundaryInfo, needed: i64, total_size: i64, available: usize) -> BoundaryStatus {
        let mut n = needed;
        if n > MAX_HEAD_SCAN {
            return BoundaryStatus::Unsupported;
        }
        if total_size > 0 && n > total_size {
            n = total_size;
        }
        if n <= available as i64 {
            return BoundaryStatus::Unsupported;
        }
        out.needed_bytes = n;
        BoundaryStatus::NeedMore
    }

    fn detect_wav(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let rf64 = d.starts_with(b"RF64");
        let mut ds64_data: u64 = 0;
        let mut p: usize = 12;

        loop {
            if p + 8 > d.len() {
                return Self::need_more(out, (p + 8) as i64, total, d.len());
            }

            let c = &d[p..];
            let size = le32(&c[4..8]);

            if rf64 && c.starts_with(b"ds64") {
                if p + 24 > d.len() {
                    return Self::need_more(out, (p + 24) as i64, total, d.len());
                }
                ds64_data = le64(&c[16..24]);
            }

            if c.starts_with(b"fmt ") && size >= 14 && p + 22 <= d.len() {
                let block_align = le16(&c[20..22]);
                if block_align > 0 {
                    out.bytes_per_frame = block_align as u32;
                }
            }

            if c.starts_with(b"data") {
                let mut data_size = size as u64;
                if rf64 && size == 0xFFFFFFFF {
                    data_size = ds64_data;
                }

                out.container = ContainerFormat::Wav;
                out.wav_data_size_field_offset = (p + 4) as i64;
                out.audio_start = (p + 8) as i64;
                if data_size == 0 || data_size == 0xFFFFFFFF {
                    out.audio_end = if total > 0 { total } else { -1 };
                } else {
                    out.audio_end = out.audio_start + data_size as i64;
                    if total > 0 && out.audio_end > total {
                        out.audio_end = total;
                    }
                }
                return BoundaryStatus::Found;
            }

            p += 8 + size as usize + (size as usize & 1);
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    fn detect_rifx(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut p: usize = 12;

        loop {
            if p + 8 > d.len() {
                return Self::need_more(out, (p + 8) as i64, total, d.len());
            }

            let c = &d[p..];
            let size = be32(&c[4..8]);

            if c.starts_with(b"fmt ") && size >= 14 && p + 22 <= d.len() {
                let block_align = be16(&c[20..22]);
                if block_align > 0 {
                    out.bytes_per_frame = block_align as u32;
                }
            }

            if c.starts_with(b"data") {
                out.container = ContainerFormat::Wav;
                out.wav_data_size_field_offset = (p + 4) as i64;
                out.audio_start = (p + 8) as i64;
                out.audio_end = out.audio_start + size as i64;
                if total > 0 && out.audio_end > total {
                    out.audio_end = total;
                }
                return BoundaryStatus::Found;
            }

            p += 8 + size as usize + (size as usize & 1);
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    fn detect_w64(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut p: usize = 40;

        loop {
            if p + 24 > d.len() {
                return Self::need_more(out, (p + 24) as i64, total, d.len());
            }

            let c = &d[p..];
            let chunk_size = le64(&c[16..24]) as usize;
            if chunk_size < 24 {
                return BoundaryStatus::Unsupported;
            }

            if &c[0..4] == b"fmt " && chunk_size >= 40 && p + 38 <= d.len() {
                let block_align = le16(&c[36..38]);
                if block_align > 0 {
                    out.bytes_per_frame = block_align as u32;
                }
            }

            if &c[0..4] == b"data" {
                out.container = ContainerFormat::Wav;
                out.wav_data_size_field_offset = (p + 16) as i64;
                out.audio_start = (p + 24) as i64;
                let data_size = chunk_size - 24;
                out.audio_end = out.audio_start + data_size as i64;
                if total > 0 && out.audio_end > total {
                    out.audio_end = total;
                }
                return BoundaryStatus::Found;
            }

            p += (chunk_size + 7) & !7;
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    fn detect_flac(d: &[u8], total: i64, p: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut q = p + 4;
        let mut first = true;

        loop {
            if q + 4 > d.len() as i64 {
                return Self::need_more(out, q + 4, total, d.len());
            }

            let hb = d[q as usize];
            let is_last = (hb & 0x80) != 0;
            let block_type = hb & 0x7F;
            if block_type == 127 || (first && block_type != 0) {
                return BoundaryStatus::Unsupported;
            }

            let len = ((d[q as usize + 1] as u32) << 16)
                | ((d[q as usize + 2] as u32) << 8)
                | (d[q as usize + 3] as u32);
            q += 4 + len as i64;
            first = false;

            if q > MAX_HEAD_SCAN || (total > 0 && q > total) {
                return BoundaryStatus::Unsupported;
            }
            if is_last {
                out.container = ContainerFormat::Flac;
                out.audio_start = q;
                out.audio_end = -1;
                return BoundaryStatus::Found;
            }
        }
    }

    fn detect_ogg(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut p: usize = 0;
        let mut serial: u32 = 0;
        let mut have_serial = false;
        let mut required: usize = 0;
        let mut packets: usize = 0;
        let mut container = ContainerFormat::Unknown;

        loop {
            if p + 27 > d.len() {
                return Self::need_more(out, (p + 27) as i64, total, d.len());
            }
            if !d[p..].starts_with(b"OggS") || d[p + 4] != 0 {
                return BoundaryStatus::Unsupported;
            }

            let nseg = d[p + 26] as usize;
            if p + 27 + nseg > d.len() {
                return Self::need_more(out, (p + 27 + nseg) as i64, total, d.len());
            }

            let mut body: usize = 0;
            for i in 0..nseg {
                body += d[p + 27 + i] as usize;
            }
            let body_start = p + 27 + nseg;
            let page_end = body_start + body;
            let ser = le32(&d[p + 14..p + 18]);

            if !have_serial {
                if (d[p + 5] & 0x02) == 0 {
                    return BoundaryStatus::Unsupported;
                }
                if body_start + 8 > d.len() {
                    return Self::need_more(out, (body_start + 8) as i64, total, d.len());
                }
                if d[body_start..].starts_with(b"\x01vorbis") {
                    required = 3;
                    container = ContainerFormat::OggVorbis;
                    out.container = ContainerFormat::OggVorbis;
                } else if d[body_start..].starts_with(b"OpusHead") {
                    required = 2;
                    container = ContainerFormat::OggOpus;
                    out.container = ContainerFormat::OggOpus;
                } else {
                    return BoundaryStatus::Unsupported;
                }
                serial = ser;
                have_serial = true;
            }

            if ser == serial {
                for i in 0..nseg {
                    if d[p + 27 + i] < 255 {
                        packets += 1;
                        if packets >= required {
                            out.container = container;
                            out.audio_start = page_end as i64;
                            out.audio_end = if total > 0 { total } else { -1 };
                            return BoundaryStatus::Found;
                        }
                    }
                }
            }

            p = page_end;
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    fn detect_mp4(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut p: usize = 0;
        loop {
            if p + 8 > d.len() {
                return Self::need_more(out, (p + 8) as i64, total, d.len());
            }

            let size32 = be32(&d[p..p + 4]);
            let atom_type = &d[p + 4..p + 8];
            let mut atom_size = size32 as u64;
            let mut hdr = 8;

            if size32 == 1 {
                if p + 16 > d.len() {
                    return Self::need_more(out, (p + 16) as i64, total, d.len());
                }
                atom_size = be64(&d[p + 8..p + 16]);
                hdr = 16;
            } else if size32 == 0 {
                atom_size = if total > 0 { (total - p as i64) as u64 } else { 0 };
            }

            if atom_type == b"mdat" {
                out.container = ContainerFormat::Mp4;
                out.mp4_mdat_atom_offset = p as i64;
                out.mp4_mdat_header_size = hdr;
                out.audio_start = (p + hdr as usize) as i64;
                if size32 == 0 {
                    out.audio_end = if total > 0 { total } else { -1 };
                } else {
                    out.audio_end = p as i64 + atom_size as i64;
                    if total > 0 && out.audio_end > total {
                        out.audio_end = total;
                    }
                }
                if out.audio_end >= 0 && out.audio_end < out.audio_start {
                    out.audio_end = out.audio_start;
                }
                return BoundaryStatus::Found;
            }

            if atom_type == b"moof" {
                out.container = ContainerFormat::Mp4;
                out.mp4_mdat_atom_offset = -1;
                out.mp4_mdat_header_size = 0;
                out.audio_start = p as i64;
                out.audio_end = if total > 0 { total } else { -1 };
                return BoundaryStatus::Found;
            }

            if atom_size < hdr as u64 {
                return BoundaryStatus::Unsupported;
            }

            p += atom_size as usize;
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    fn detect_mpeg(d: &[u8], total: i64, p: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let limit = (p + SYNC_SCAN_LIMIT).min(d.len() as i64);

        for i in p..limit {
            if total > 0 && i + 4 > total {
                return BoundaryStatus::Unsupported;
            }
            if i + 7 > d.len() as i64 {
                return Self::need_more(out, i + 7, total, d.len());
            }

            let h = &d[i as usize..];
            if h[0] != 0xFF {
                continue;
            }

            // AAC ADTS
            if is_adts_sync(h) {
                let flen = (((h[3] & 0x03) as u32) << 11) | ((h[4] as u32) << 3) | ((h[5] as u32) >> 5);
                if flen < 7 {
                    continue;
                }
                let next = i + flen as i64;
                if next + 2 <= d.len() as i64 {
                    let next_h = &d[next as usize..];
                    if !is_adts_sync(next_h) && !(next_h[0] == 0xFF && (next_h[1] & 0xF6) == 0xF0) {
                        continue;
                    }
                } else if total <= 0 || next + 2 <= total {
                    return Self::need_more(out, next + 7, total, d.len());
                }
                out.container = ContainerFormat::Adts;
                out.audio_start = i;
                out.audio_end = -1;
                return BoundaryStatus::Found;
            }

            // MPEG audio
            let mut hdr = MpegHeader::default();
            if !parse_mpeg_header(h, &mut hdr) {
                continue;
            }

            let next = i + hdr.frame_size as i64;
            if next + 4 <= d.len() as i64 {
                let mut nh = MpegHeader::default();
                if !parse_mpeg_header(&d[next as usize..], &mut nh) {
                    continue;
                }
            } else if total <= 0 || next + 4 <= total {
                return Self::need_more(out, next + 4, total, d.len());
            }

            out.container = ContainerFormat::Mp3;
            out.audio_start = i;
            out.audio_end = -1;

            // Xing / Info / VBRI: belongs to HEAD
            if hdr.layer == 1 && next <= d.len() as i64 {
                let xing = i + 4 + (if hdr.has_crc { 2 } else { 0 }) + hdr.side_info as i64;
                let vbri = i + 4 + 32;
                let mut is_vbr_frame = false;
                if xing + 4 <= next {
                    let t = &d[xing as usize..];
                    if t.starts_with(b"Xing") || t.starts_with(b"Info") {
                        is_vbr_frame = true;
                    }
                }
                if !is_vbr_frame && vbri + 4 <= next {
                    let t = &d[vbri as usize..];
                    if t.starts_with(b"VBRI") {
                        is_vbr_frame = true;
                    }
                }
                if is_vbr_frame {
                    out.audio_start = next;
                    out.head_has_mpeg_frame = 1;
                }
            }
            return BoundaryStatus::Found;
        }

        BoundaryStatus::Unsupported
    }
}

#[derive(Default)]
struct MpegHeader {
    frame_size: u32,
    side_info: u32,
    layer: u32,
    ver: u32,
    sample_rate: u32,
    bitrate_kbps: u32,
    has_crc: bool,
}

fn parse_mpeg_header(h: &[u8], out: &mut MpegHeader) -> bool {
    const MPEG1_L3: [u32; 16] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
    const MPEG1_L2: [u32; 16] = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0];
    const MPEG1_L1: [u32; 16] = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0];
    const MPEG2_L1: [u32; 16] = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0];
    const MPEG2_L23: [u32; 16] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
    const RATES: [[u32; 3]; 4] = [
        [11025, 12000, 8000],
        [0, 0, 0],
        [22050, 24000, 16000],
        [44100, 48000, 32000],
    ];

    if h.len() < 4 || h[0] != 0xFF || (h[1] & 0xE0) != 0xE0 {
        return false;
    }

    let ver = ((h[1] >> 3) & 0x03) as usize;
    let layer = ((h[1] >> 1) & 0x03) as u32;
    let br_idx = ((h[2] >> 4) & 0x0F) as usize;
    let sr_idx = ((h[2] >> 2) & 0x03) as usize;
    let padding = ((h[2] >> 1) & 0x01) as u32;
    let channel_mode = ((h[3] >> 6) & 0x03) as u32;

    if ver == 1 || layer == 0 || br_idx == 0 || br_idx == 15 || sr_idx == 3 {
        return false;
    }
    if (h[3] & 0x03) == 2 {
        return false;
    }

    let kbps = if ver == 3 {
        if layer == 1 { MPEG1_L3[br_idx] } else if layer == 2 { MPEG1_L2[br_idx] } else { MPEG1_L1[br_idx] }
    } else {
        if layer == 3 { MPEG2_L1[br_idx] } else { MPEG2_L23[br_idx] }
    };

    let sr = RATES[ver][sr_idx];
    if kbps == 0 || sr == 0 {
        return false;
    }

    let fs = if layer == 3 {
        (12 * kbps * 1000 / sr + padding) * 4
    } else if layer == 2 || ver == 3 {
        144 * kbps * 1000 / sr + padding
    } else {
        72 * kbps * 1000 / sr + padding
    };
    if fs < 4 {
        return false;
    }

    out.frame_size = fs;
    out.layer = layer;
    out.ver = ver as u32;
    out.sample_rate = sr;
    out.bitrate_kbps = kbps;
    out.has_crc = (h[1] & 0x01) == 0;
    out.side_info = if layer == 1 {
        if ver == 3 {
            if channel_mode == 3 { 17 } else { 32 }
        } else {
            if channel_mode == 3 { 9 } else { 17 }
        }
    } else {
        0
    };

    true
}

fn is_adts_sync(h: &[u8]) -> bool {
    h.len() >= 3
        && h[0] == 0xFF
        && (h[1] & 0xF6) == 0xF0
        && ((h[2] >> 6) & 0x03) != 3
        && ((h[2] >> 2) & 0x0F) <= 11
}

#[inline]
fn synchsafe32(b: &[u8]) -> u32 {
    ((b[0] as u32 & 0x7F) << 21)
        | ((b[1] as u32 & 0x7F) << 14)
        | ((b[2] as u32 & 0x7F) << 7)
        | (b[3] as u32 & 0x7F)
}

#[inline]
fn le16(b: &[u8]) -> u16 {
    u16::from_le_bytes([b[0], b[1]])
}

#[inline]
fn be16(b: &[u8]) -> u16 {
    u16::from_be_bytes([b[0], b[1]])
}

#[inline]
fn le32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

#[inline]
fn le64(b: &[u8]) -> u64 {
    u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
}

#[inline]
fn be32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

#[inline]
fn be64(b: &[u8]) -> u64 {
    u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
}

// ----------------------------------------------------------------------------
// C ABI compatibility functions
// ----------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn map_boundary_info_reset(info: *mut BoundaryInfo) {
    if !info.is_null() {
        unsafe {
            (*info).reset();
        }
    }
}

#[no_mangle]
pub extern "C" fn map_container_needs_tail_scan(container: ContainerFormat) -> i32 {
    if FormatSniffer::container_needs_tail_scan(container) { 1 } else { 0 }
}

#[no_mangle]
pub unsafe extern "C" fn map_sniffer_detect_head_boundary(
    data: *const u8,
    available: usize,
    total_size: i64,
    out: *mut BoundaryInfo,
) -> BoundaryStatus {
    if out.is_null() {
        return BoundaryStatus::Unsupported;
    }
    unsafe {
        (*out).reset();
    }
    if data.is_null() && available > 0 {
        return BoundaryStatus::Unsupported;
    }
    let slice = if data.is_null() || available == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(data, available) }
    };

    let (status, info) = FormatSniffer::detect_head_boundary(slice, total_size);
    unsafe {
        *out = info;
    }
    status
}

#[no_mangle]
pub unsafe extern "C" fn map_sniffer_detect_tail_boundary(
    container: ContainerFormat,
    tail: *const u8,
    tail_len: usize,
    tail_offset: i64,
    total_size: i64,
    audio_start: i64,
    out_audio_end: *mut i64,
) -> BoundaryStatus {
    if out_audio_end.is_null() || total_size <= 0 {
        return BoundaryStatus::Unsupported;
    }
    unsafe {
        *out_audio_end = total_size;
    }
    if tail.is_null() && tail_len > 0 {
        return BoundaryStatus::Unsupported;
    }
    let slice = if tail.is_null() || tail_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(tail, tail_len) }
    };

    let (status, end) = FormatSniffer::detect_tail_boundary(
        container,
        slice,
        tail_offset,
        total_size,
        audio_start,
    );
    unsafe {
        *out_audio_end = end;
    }
    status
}

#[no_mangle]
pub unsafe extern "C" fn map_sniffer_extract_tail_duration_ms(
    container: ContainerFormat,
    sample_rate: u32,
    tail: *const u8,
    tail_len: usize,
    out_duration_ms: *mut i64,
) -> i32 {
    if out_duration_ms.is_null() || tail.is_null() || tail_len < 27 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(tail, tail_len) };
    if let Some(dur) = FormatSniffer::extract_tail_duration_ms(container, sample_rate, slice) {
        unsafe {
            *out_duration_ms = dur;
        }
        1
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn map_sniff_mp3_stream_info(
    data: *const u8,
    data_size: usize,
    total_size: i64,
    out_bitrate: *mut u32,
    out_duration_ms: *mut i64,
) -> i32 {
    if data.is_null() || out_bitrate.is_null() || out_duration_ms.is_null() {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, data_size) };
    if let Some((br, dur)) = FormatSniffer::sniff_mp3_stream_info(slice, total_size) {
        unsafe {
            *out_bitrate = br;
            *out_duration_ms = dur;
        }
        1
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn map_sniff_ogg_vorbis_stream_info(
    data: *const u8,
    data_size: usize,
    total_size: i64,
    out_bitrate: *mut u32,
    out_duration_ms: *mut i64,
) -> i32 {
    if data.is_null() || out_bitrate.is_null() || out_duration_ms.is_null() {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, data_size) };
    if let Some((br, dur)) = FormatSniffer::sniff_ogg_vorbis_stream_info(slice, total_size) {
        unsafe {
            *out_bitrate = br;
            *out_duration_ms = dur;
        }
        1
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn map_sniff_ogg_opus_stream_info(
    data: *const u8,
    data_size: usize,
    total_size: i64,
    out_bitrate: *mut u32,
    out_duration_ms: *mut i64,
) -> i32 {
    if data.is_null() || out_bitrate.is_null() || out_duration_ms.is_null() {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, data_size) };
    if let Some((br, dur)) = FormatSniffer::sniff_ogg_opus_stream_info(slice, total_size) {
        unsafe {
            *out_bitrate = br;
            *out_duration_ms = dur;
        }
        1
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn map_sniff_stream_info(
    data: *const u8,
    data_size: usize,
    total_size: i64,
    out_bitrate: *mut u32,
    out_duration_ms: *mut i64,
) -> i32 {
    if data.is_null() || out_bitrate.is_null() || out_duration_ms.is_null() {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, data_size) };
    if let Some((br, dur)) = FormatSniffer::sniff_stream_info(slice, total_size) {
        unsafe {
            *out_bitrate = br;
            *out_duration_ms = dur;
        }
        1
    } else {
        0
    }
}
