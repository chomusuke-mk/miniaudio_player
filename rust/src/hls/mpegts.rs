//! Pure-Rust zero-copy MPEG-2 Transport Stream (.ts) demuxer for HLS segments.
//! Demuxes 188-byte TS packets and extracts raw elementary audio frames (AAC ADTS, MP3, AC-3).

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

#[derive(Debug, Clone)]
pub struct MpegTsDemuxResult {
    pub audio_bytes: Vec<u8>,
    pub codec: TsAudioCodec,
    pub audio_pid: Option<u16>,
    pub id3_bytes: Option<Vec<u8>>,
}

pub struct MpegTsDemuxer;

impl MpegTsDemuxer {
    /// Checks if a buffer begins with or contains MPEG-2 TS packets.
    pub fn is_mpeg_ts(data: &[u8]) -> bool {
        if data.len() < TS_PACKET_SIZE * 2 {
            return data.starts_with(&[TS_SYNC_BYTE]);
        }
        // Verify periodic 188-byte sync bytes
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

    /// Demuxes an MPEG-2 TS byte stream and returns extracted audio and metadata.
    pub fn demux_segment(data: &[u8]) -> MpegTsDemuxResult {
        let mut pmt_pid: Option<u16> = None;
        let mut audio_pid: Option<u16> = None;
        let mut audio_stream_type: Option<u8> = None;
        let mut id3_pid: Option<u16> = None;

        let mut audio_payload: Vec<u8> = Vec::with_capacity(data.len() / 2);
        let mut id3_payload: Vec<u8> = Vec::new();

        // First pass: locate sync byte alignment and inspect PAT/PMT
        let mut cursor = 0;
        let total = data.len();

        // Find initial sync byte
        while cursor + TS_PACKET_SIZE <= total {
            if data[cursor] == TS_SYNC_BYTE {
                // Potential packet
                if cursor + TS_PACKET_SIZE * 2 <= total && data[cursor + TS_PACKET_SIZE] != TS_SYNC_BYTE {
                    // False positive sync byte, try next
                    cursor += 1;
                    continue;
                }
                break;
            }
            cursor += 1;
        }

        while cursor + TS_PACKET_SIZE <= total {
            let packet = &data[cursor..cursor + TS_PACKET_SIZE];
            cursor += TS_PACKET_SIZE;

            if packet[0] != TS_SYNC_BYTE {
                // Re-sync
                while cursor < total && data[cursor] != TS_SYNC_BYTE {
                    cursor += 1;
                }
                continue;
            }

            let tei = (packet[1] & 0x80) != 0;
            if tei {
                continue; // Transport error, skip
            }

            let pusi = (packet[1] & 0x40) != 0;
            let pid = (((packet[1] & 0x1F) as u16) << 8) | (packet[2] as u16);
            let adaptation_ctrl = (packet[3] & 0x30) >> 4;

            // Compute payload offset
            let mut payload_offset = 4;
            if (adaptation_ctrl & 0x02) != 0 {
                // Adaptation field present
                let adapt_len = packet[4] as usize;
                payload_offset = 5 + adapt_len;
            }

            if (adaptation_ctrl & 0x01) == 0 || payload_offset >= TS_PACKET_SIZE {
                // No payload in this packet
                continue;
            }

            let payload = &packet[payload_offset..TS_PACKET_SIZE];

            // 1. PAT (PID 0)
            if pid == 0 {
                if let Some(parsed_pmt_pid) = Self::parse_pat(payload, pusi) {
                    pmt_pid = Some(parsed_pmt_pid);
                }
                continue;
            }

            // 2. PMT (PID matches pmt_pid)
            if Some(pid) == pmt_pid {
                if let Some((a_pid, s_type, m_pid)) = Self::parse_pmt(payload, pusi) {
                    audio_pid = Some(a_pid);
                    audio_stream_type = Some(s_type);
                    if let Some(id3) = m_pid {
                        id3_pid = Some(id3);
                    }
                }
                continue;
            }

            // Fallback: If no PMT was found yet, heuristically check if this is an audio PES
            if audio_pid.is_none() && pusi && payload.len() >= 6 {
                if payload[0] == 0x00 && payload[1] == 0x00 && payload[2] == 0x01 {
                    let stream_id = payload[3];
                    // Stream ID 0xC0..0xDF are ISO/IEC 13818 audio, 0xBD is AC3 / private stream 1
                    if (0xC0..=0xDF).contains(&stream_id) || stream_id == 0xBD {
                        audio_pid = Some(pid);
                    }
                }
            }

            // 3. Audio PES
            if Some(pid) == audio_pid {
                Self::extract_pes_payload(payload, pusi, &mut audio_payload);
                continue;
            }

            // 4. ID3 PES
            if Some(pid) == id3_pid {
                Self::extract_pes_payload(payload, pusi, &mut id3_payload);
            }
        }

        // Determine codec from PMT or elementary stream inspection
        let codec = match audio_stream_type {
            Some(STREAM_TYPE_AAC_ADTS) | Some(STREAM_TYPE_AAC_LATM) => TsAudioCodec::AacAdts,
            Some(STREAM_TYPE_MP3_1) | Some(STREAM_TYPE_MP3_2) => TsAudioCodec::Mp3,
            Some(STREAM_TYPE_AC3) | Some(STREAM_TYPE_EAC3) => TsAudioCodec::Ac3,
            Some(other) => TsAudioCodec::Unknown(other),
            None => Self::detect_elementary_codec(&audio_payload),
        };

        MpegTsDemuxResult {
            audio_bytes: audio_payload,
            codec,
            audio_pid,
            id3_bytes: if id3_payload.is_empty() {
                None
            } else {
                Some(id3_payload)
            },
        }
    }

    /// Parses Program Association Table (PAT) to obtain the Program Map Table (PMT) PID.
    fn parse_pat(payload: &[u8], pusi: bool) -> Option<u16> {
        let mut idx = 0;
        if pusi {
            let pointer = *payload.first()? as usize;
            idx = 1 + pointer;
        }
        if idx + 8 > payload.len() {
            return None;
        }

        let table_id = payload[idx];
        if table_id != 0x00 {
            return None; // Not PAT
        }

        let section_len = (((payload[idx + 1] & 0x0F) as usize) << 8) | (payload[idx + 2] as usize);
        let end = (idx + 3 + section_len).min(payload.len().saturating_sub(4)); // Exclude CRC32

        idx += 8; // Skip header to program loop
        while idx + 4 <= end {
            let prog_num = ((payload[idx] as u16) << 8) | (payload[idx + 1] as u16);
            let prog_pid = (((payload[idx + 2] & 0x1F) as u16) << 8) | (payload[idx + 3] as u16);
            if prog_num != 0 {
                return Some(prog_pid);
            }
            idx += 4;
        }
        None
    }

    /// Parses Program Map Table (PMT) to obtain audio PID, stream type, and optional ID3 PID.
    fn parse_pmt(payload: &[u8], pusi: bool) -> Option<(u16, u8, Option<u16>)> {
        let mut idx = 0;
        if pusi {
            let pointer = *payload.first()? as usize;
            idx = 1 + pointer;
        }
        if idx + 12 > payload.len() {
            return None;
        }

        let table_id = payload[idx];
        if table_id != 0x02 {
            return None; // Not PMT
        }

        let section_len = (((payload[idx + 1] & 0x0F) as usize) << 8) | (payload[idx + 2] as usize);
        let end = (idx + 3 + section_len).min(payload.len().saturating_sub(4)); // Exclude CRC32

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

    /// Appends PES packet data into the target elementary stream buffer,
    /// skipping PES headers when a new packet starts (PUSI = true).
    fn extract_pes_payload(payload: &[u8], pusi: bool, output: &mut Vec<u8>) {
        if pusi {
            if payload.len() >= 6 && payload[0] == 0x00 && payload[1] == 0x00 && payload[2] == 0x01 {
                let stream_id = payload[3];
                // Check if this stream has standard optional PES header (audio/video)
                if stream_id != 0xBE && stream_id != 0xBF {
                    if payload.len() >= 9 {
                        let header_data_len = payload[8] as usize;
                        let es_start = 9 + header_data_len;
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
        }
        // Non-PUSI packet or payload continuation
        output.extend_from_slice(payload);
    }

    /// Sniffs the elementary stream buffer for AAC ADTS or MP3 sync words.
    fn detect_elementary_codec(data: &[u8]) -> TsAudioCodec {
        if data.len() >= 2 {
            // ADTS syncword: 0xFFF (0xFF followed by 0xF0..0xFF)
            if data[0] == 0xFF && (data[1] & 0xF6) == 0xF0 {
                return TsAudioCodec::AacAdts;
            }
            // MP3 syncword: 0xFFE (0xFF followed by 0xE0..0xEF)
            if data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 {
                return TsAudioCodec::Mp3;
            }
            // AC3 syncword: 0x0B77
            if data[0] == 0x0B && data[1] == 0x77 {
                return TsAudioCodec::Ac3;
            }
        }
        TsAudioCodec::Unknown(0)
    }
}
