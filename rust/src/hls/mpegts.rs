//! Pure-Rust MPEG-2 Transport Stream (.ts) demuxer for HLS segments.
//!
//! Uses a pipeline of `TsPacketIterator` -> `TsDemuxSession` -> `MpegTsDemuxResult`.

const TS_PACKET_SIZE: usize = 188;
const TS_SYNC_BYTE: u8 = 0x47;

const STREAM_TYPE_MP3_1: u8 = 0x03;
const STREAM_TYPE_MP3_2: u8 = 0x04;
const STREAM_TYPE_AAC_ADTS: u8 = 0x0F;
const STREAM_TYPE_AAC_LATM: u8 = 0x11;
const STREAM_TYPE_METADATA_ID3: u8 = 0x15;
const STREAM_TYPE_AC3: u8 = 0x81;
const STREAM_TYPE_EAC3: u8 = 0x87;

#[derive(Debug, Clone, PartialEq)]
pub enum TsAudioCodec {
    AacAdts,
    Mp3,
    Ac3,
    Unknown(u8),
}

impl TsAudioCodec {
    #[inline]
    pub fn from_stream_type(stream_type: u8) -> Self {
        match stream_type {
            STREAM_TYPE_AAC_ADTS | STREAM_TYPE_AAC_LATM => Self::AacAdts,
            STREAM_TYPE_MP3_1 | STREAM_TYPE_MP3_2 => Self::Mp3,
            STREAM_TYPE_AC3 | STREAM_TYPE_EAC3 => Self::Ac3,
            other => Self::Unknown(other),
        }
    }

    pub fn sniff_elementary(data: &[u8]) -> Self {
        if data.len() >= 2 {
            if data[0] == 0xFF && (data[1] & 0xF6) == 0xF0 {
                return Self::AacAdts;
            }
            if data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 {
                return Self::Mp3;
            }
            if data[0] == 0x0B && data[1] == 0x77 {
                return Self::Ac3;
            }
        }
        Self::Unknown(0)
    }
}

#[derive(Debug, Clone)]
pub struct MpegTsDemuxResult {
    pub audio_bytes: Vec<u8>,
    pub codec: TsAudioCodec,
    pub audio_pid: Option<u16>,
    pub id3_bytes: Option<Vec<u8>>,
}

/// Validated 188-byte MPEG-2 TS packet view.
#[derive(Clone, Copy)]
pub struct TsPacket<'a> {
    raw: &'a [u8; TS_PACKET_SIZE],
}

impl<'a> TsPacket<'a> {
    #[inline]
    pub fn parse(slice: &'a [u8]) -> Option<Self> {
        let raw: &'a [u8; TS_PACKET_SIZE] = slice.try_into().ok()?;
        if raw[0] != TS_SYNC_BYTE {
            return None;
        }
        Some(Self { raw })
    }

    #[inline]
    pub fn has_transport_error(&self) -> bool {
        (self.raw[1] & 0x80) != 0
    }

    #[inline]
    pub fn payload_unit_start(&self) -> bool {
        (self.raw[1] & 0x40) != 0
    }

    #[inline]
    pub fn pid(&self) -> u16 {
        (((self.raw[1] & 0x1F) as u16) << 8) | (self.raw[2] as u16)
    }

    #[inline]
    pub fn payload(&self) -> Option<&'a [u8]> {
        let adaptation_ctrl = (self.raw[3] & 0x30) >> 4;
        if (adaptation_ctrl & 0x01) == 0 {
            return None;
        }
        let mut offset = 4usize;
        if (adaptation_ctrl & 0x02) != 0 {
            let adapt_len = self.raw[4] as usize;
            offset = 5 + adapt_len;
        }
        if offset >= TS_PACKET_SIZE {
            return None;
        }
        Some(&self.raw[offset..TS_PACKET_SIZE])
    }
}

/// Input generator yielding sync-aligned 188-byte `TsPacket` instances from a byte slice.
pub struct TsPacketIterator<'a> {
    data: &'a [u8],
    cursor: usize,
}

impl<'a> TsPacketIterator<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        let mut iter = Self { data, cursor: 0 };
        iter.align_initial_sync();
        iter
    }

    fn align_initial_sync(&mut self) {
        let total = self.data.len();
        while self.cursor + TS_PACKET_SIZE <= total {
            if self.data[self.cursor] == TS_SYNC_BYTE {
                let next_sync = self.cursor + TS_PACKET_SIZE;
                if next_sync + TS_PACKET_SIZE > total || self.data[next_sync] == TS_SYNC_BYTE {
                    break;
                }
            }
            self.cursor += 1;
        }
    }
}

impl<'a> Iterator for TsPacketIterator<'a> {
    type Item = TsPacket<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        let total = self.data.len();
        while self.cursor + TS_PACKET_SIZE <= total {
            if self.data[self.cursor] != TS_SYNC_BYTE {
                self.cursor += 1;
                continue;
            }
            let slice = &self.data[self.cursor..self.cursor + TS_PACKET_SIZE];
            self.cursor += TS_PACKET_SIZE;
            if let Some(pkt) = TsPacket::parse(slice) {
                if !pkt.has_transport_error() {
                    return Some(pkt);
                }
            }
        }
        None
    }
}

/// Stateful MPEG-TS demuxing pipeline processing PSI tables (PAT/PMT) and PES streams.
pub struct TsDemuxSession {
    pmt_pid: Option<u16>,
    audio_pid: Option<u16>,
    audio_stream_type: Option<u8>,
    id3_pid: Option<u16>,
    audio_payload: Vec<u8>,
    id3_payload: Vec<u8>,
}

impl TsDemuxSession {
    pub fn with_capacity(estimated_audio_bytes: usize) -> Self {
        Self {
            pmt_pid: None,
            audio_pid: None,
            audio_stream_type: None,
            id3_pid: None,
            audio_payload: Vec::with_capacity(estimated_audio_bytes),
            id3_payload: Vec::new(),
        }
    }

    pub fn process_packet(&mut self, packet: TsPacket<'_>) {
        let Some(payload) = packet.payload() else {
            return;
        };
        let pid = packet.pid();
        let pusi = packet.payload_unit_start();

        if pid == 0 {
            if let Some(parsed_pmt) = Self::parse_pat(payload, pusi) {
                self.pmt_pid = Some(parsed_pmt);
            }
            return;
        }

        if Some(pid) == self.pmt_pid {
            if let Some((a_pid, s_type, m_pid)) = Self::parse_pmt(payload, pusi) {
                self.audio_pid = Some(a_pid);
                self.audio_stream_type = Some(s_type);
                if let Some(id3) = m_pid {
                    self.id3_pid = Some(id3);
                }
            }
            return;
        }

        if self.audio_pid.is_none() && pusi && Self::is_audio_pes_start(payload) {
            self.audio_pid = Some(pid);
        }

        if Some(pid) == self.audio_pid {
            Self::append_pes_payload(payload, pusi, &mut self.audio_payload);
        } else if Some(pid) == self.id3_pid {
            Self::append_pes_payload(payload, pusi, &mut self.id3_payload);
        }
    }

    pub fn finalize(self) -> MpegTsDemuxResult {
        let codec = self
            .audio_stream_type
            .map(TsAudioCodec::from_stream_type)
            .unwrap_or_else(|| TsAudioCodec::sniff_elementary(&self.audio_payload));

        MpegTsDemuxResult {
            audio_bytes: self.audio_payload,
            codec,
            audio_pid: self.audio_pid,
            id3_bytes: if self.id3_payload.is_empty() {
                None
            } else {
                Some(self.id3_payload)
            },
        }
    }

    fn is_audio_pes_start(payload: &[u8]) -> bool {
        if payload.len() < 6 || payload[0] != 0x00 || payload[1] != 0x00 || payload[2] != 0x01 {
            return false;
        }
        let stream_id = payload[3];
        (0xC0..=0xDF).contains(&stream_id) || stream_id == 0xBD
    }

    fn parse_pat(payload: &[u8], pusi: bool) -> Option<u16> {
        let mut idx = if pusi { 1 + (*payload.first()? as usize) } else { 0 };
        if idx + 8 > payload.len() || payload[idx] != 0x00 {
            return None;
        }

        let section_len = (((payload[idx + 1] & 0x0F) as usize) << 8) | (payload[idx + 2] as usize);
        let end = (idx + 3 + section_len).min(payload.len().saturating_sub(4));

        idx += 8;
        while idx + 4 <= end {
            let prog_num = u16::from_be_bytes([payload[idx], payload[idx + 1]]);
            let prog_pid = (((payload[idx + 2] & 0x1F) as u16) << 8) | (payload[idx + 3] as u16);
            if prog_num != 0 {
                return Some(prog_pid);
            }
            idx += 4;
        }
        None
    }

    fn parse_pmt(payload: &[u8], pusi: bool) -> Option<(u16, u8, Option<u16>)> {
        let mut idx = if pusi { 1 + (*payload.first()? as usize) } else { 0 };
        if idx + 12 > payload.len() || payload[idx] != 0x02 {
            return None;
        }

        let section_len = (((payload[idx + 1] & 0x0F) as usize) << 8) | (payload[idx + 2] as usize);
        let end = (idx + 3 + section_len).min(payload.len().saturating_sub(4));
        let prog_info_len =
            (((payload[idx + 10] & 0x0F) as usize) << 8) | (payload[idx + 11] as usize);
        idx += 12 + prog_info_len;

        let mut audio_result: Option<(u16, u8)> = None;
        let mut id3_pid: Option<u16> = None;

        while idx + 5 <= end {
            let stream_type = payload[idx];
            let elem_pid = (((payload[idx + 1] & 0x1F) as u16) << 8) | (payload[idx + 2] as u16);
            let es_info_len =
                (((payload[idx + 3] & 0x0F) as usize) << 8) | (payload[idx + 4] as usize);

            match stream_type {
                STREAM_TYPE_AAC_ADTS
                | STREAM_TYPE_AAC_LATM
                | STREAM_TYPE_MP3_1
                | STREAM_TYPE_MP3_2
                | STREAM_TYPE_AC3
                | STREAM_TYPE_EAC3 => {
                    if audio_result.is_none() {
                        audio_result = Some((elem_pid, stream_type));
                    }
                }
                STREAM_TYPE_METADATA_ID3 => {
                    id3_pid = Some(elem_pid);
                }
                _ => {}
            }
            idx += 5 + es_info_len;
        }

        audio_result.map(|(a_pid, s_type)| (a_pid, s_type, id3_pid))
    }

    fn append_pes_payload(payload: &[u8], pusi: bool, output: &mut Vec<u8>) {
        if pusi && payload.len() >= 6 && payload[0..3] == [0x00, 0x00, 0x01] {
            let stream_id = payload[3];
            if stream_id != 0xBE && stream_id != 0xBF {
                if payload.len() >= 9 {
                    let es_start = 9 + (payload[8] as usize);
                    if es_start < payload.len() {
                        output.extend_from_slice(&payload[es_start..]);
                        return;
                    }
                }
            } else if payload.len() > 6 {
                output.extend_from_slice(&payload[6..]);
                return;
            }
        }
        output.extend_from_slice(payload);
    }
}

pub struct MpegTsDemuxer;

impl MpegTsDemuxer {
    /// Checks if a buffer begins with or contains sync-aligned 188-byte MPEG-2 TS packets.
    pub fn is_mpeg_ts(data: &[u8]) -> bool {
        if data.len() < TS_PACKET_SIZE * 2 {
            return data.starts_with(&[TS_SYNC_BYTE]);
        }
        for offset in 0..TS_PACKET_SIZE.min(data.len() - TS_PACKET_SIZE) {
            if data[offset] == TS_SYNC_BYTE
                && data[offset + TS_PACKET_SIZE] == TS_SYNC_BYTE
                && (data.len() < offset + TS_PACKET_SIZE * 2
                    || data[offset + TS_PACKET_SIZE * 2] == TS_SYNC_BYTE)
            {
                return true;
            }
        }
        false
    }

    /// Demuxes an MPEG-2 TS byte stream through a `TsPacketIterator` -> `TsDemuxSession` pipeline.
    pub fn demux_segment(data: &[u8]) -> MpegTsDemuxResult {
        let mut session = TsDemuxSession::with_capacity(data.len() / 2);
        for packet in TsPacketIterator::new(data) {
            session.process_packet(packet);
        }
        session.finalize()
    }
}
