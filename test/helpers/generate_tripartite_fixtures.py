#!/usr/bin/env python3
"""
Generates synthetic and modified audio fixtures for testing:
1. Giant cover art (> 256 KB) in MP3 and FLAC.
2. EOF chirp prevention (trailing APEv2/ID3v1 with fake syncwords 0xFF 0xFB).
3. Non-Fast-Start MP4/M4A (ftyp -> mdat -> moov at EOF).
4. WAV with trailing chunks (LIST/INFO post-data).
"""

import os
import struct

def generate_fixtures(output_dir="test/fixtures/tripartite"):
    os.makedirs(output_dir, exist_ok=True)

    # 1. Giant Cover MP3 (> 350 KB ID3v2 APIC)
    print("Generating giant_cover.mp3...")
    with open("example/assets/music/cbr_noxing.mp3", "rb") as f:
        mp3_audio = f.read()

    apic_payload_len = 350000
    frame_payload = b"\x00image/jpeg\x00\x03\x00\xff\xd8\xff\xe0" + (b"\xaa" * (apic_payload_len - 15)) + b"\xff\xd9"
    frame_hdr = b"APIC" + struct.pack(">I", len(frame_payload)) + b"\x00\x00"
    id3_body = frame_hdr + frame_payload
    tag_len = len(id3_body)
    s0 = (tag_len >> 21) & 0x7F
    s1 = (tag_len >> 14) & 0x7F
    s2 = (tag_len >> 7) & 0x7F
    s3 = tag_len & 0x7F
    id3_hdr = b"ID3\x03\x00\x00" + bytes([s0, s1, s2, s3])
    giant_mp3 = id3_hdr + id3_body + mp3_audio

    with open(os.path.join(output_dir, "giant_cover.mp3"), "wb") as f:
        f.write(giant_mp3)

    # 2. Giant Cover FLAC (> 300 KB PICTURE block)
    print("Generating giant_cover.flac...")
    with open("example/assets/music/salida.flac", "rb") as f:
        full_flac = f.read()

    b_len = struct.unpack(">I", b"\x00" + full_flac[5:8])[0]
    streaminfo_block = bytes([0x00]) + full_flac[5:8+b_len]

    pic_len = 300000
    pic_payload = struct.pack(">I", 3)  # Front cover
    pic_payload += struct.pack(">I", 10) + b"image/jpeg"
    pic_payload += struct.pack(">I", 10) + b"Test Cover"
    pic_payload += struct.pack(">IIII", 800, 800, 24, 0)
    jpeg_data = b"\xff\xd8\xff\xe0" + (b"\x55" * (pic_len - 100)) + b"\xff\xd9"
    pic_payload += struct.pack(">I", len(jpeg_data)) + jpeg_data

    pic_len_total = len(pic_payload)
    ps0 = (pic_len_total >> 16) & 0xFF
    ps1 = (pic_len_total >> 8) & 0xFF
    ps2 = pic_len_total & 0xFF
    pic_block = bytes([0x86, ps0, ps1, ps2]) + pic_payload

    # Scan for end of original metadata
    pos = 4
    while True:
        is_last = (full_flac[pos] >> 7) & 1
        sz = struct.unpack(">I", b"\x00" + full_flac[pos+1:pos+4])[0]
        pos += 4 + sz
        if is_last:
            break

    flac_audio = full_flac[pos:pos+200000]
    giant_flac = b"fLaC" + streaminfo_block + pic_block + flac_audio

    with open(os.path.join(output_dir, "giant_cover.flac"), "wb") as f:
        f.write(giant_flac)

    # 3. EOF Chirp MP3 (cbr_noxing.mp3 + APEv2 / ID3v1 with fake 0xFF 0xFB syncwords)
    print("Generating eof_chirp.mp3...")
    fake_frame = b"\xFF\xFB\x90\x64" + (b"\xAA" * 414)
    item_val = fake_frame * 3
    key = b"Comment\x00"
    item = struct.pack("<II", len(item_val), 0) + key + item_val
    tag_body = item
    tag_size = 32 + len(tag_body)
    header = b"APETAGEX" + struct.pack("<III", 2000, tag_size, 1) + struct.pack("<I", 0x80000000) + (b"\x00" * 8)
    footer = b"APETAGEX" + struct.pack("<III", 2000, tag_size, 1) + struct.pack("<I", 0) + (b"\x00" * 8)
    ape = header + tag_body + footer

    id3v1 = bytearray(b"TAG" + (b"\x00" * 125))
    id3v1[3:7] = b"\xFF\xFB\x90\x64"

    eof_chirp = mp3_audio + ape + bytes(id3v1)
    with open(os.path.join(output_dir, "eof_chirp.mp3"), "wb") as f:
        f.write(eof_chirp)

    # 4. Non-Fast-Start MP4 (ftyp -> mdat -> moov at EOF)
    print("Generating non_faststart.m4a...")
    with open("example/assets/music/salida_aac.m4a", "rb") as f:
        full_m4a = f.read()

    ftyp_sz = struct.unpack(">I", full_m4a[:4])[0]
    ftyp = full_m4a[:ftyp_sz]
    moov_sz = struct.unpack(">I", full_m4a[ftyp_sz:ftyp_sz+4])[0]
    moov = bytearray(full_m4a[ftyp_sz:ftyp_sz+moov_sz])
    mdat = full_m4a[ftyp_sz+moov_sz:]

    # Adjust chunk offset table (stco) in moov
    idx = moov.find(b"stco")
    if idx != -1:
        entry_count = struct.unpack(">I", moov[idx+8:idx+12])[0]
        delta = -moov_sz
        for e in range(entry_count):
            off = idx + 12 + e * 4
            old_val = struct.unpack(">I", moov[off:off+4])[0]
            struct.pack_into(">I", moov, off, old_val + delta)

    nfs_m4a = ftyp + mdat + moov
    with open(os.path.join(output_dir, "non_faststart.m4a"), "wb") as f:
        f.write(nfs_m4a)

    # 5. WAV with trailing LIST/INFO chunk
    print("Generating trailing_chunks.wav...")
    with open("example/assets/music/test_24bit.wav", "rb") as f:
        wav_data = f.read()

    info_chunk = b"INAM" + struct.pack("<I", 16) + b"Test Title 1234\x00"
    info_chunk += b"IART" + struct.pack("<I", 16) + b"Test Artist 123\x00"
    list_chunk = b"LIST" + struct.pack("<I", 4 + len(info_chunk)) + b"INFO" + info_chunk

    new_riff_size = len(wav_data) - 8 + len(list_chunk)
    wav_trailing = wav_data[:4] + struct.pack("<I", new_riff_size) + wav_data[8:] + list_chunk
    with open(os.path.join(output_dir, "trailing_chunks.wav"), "wb") as f:
        f.write(wav_trailing)

    # 6. Head 3 MB + Tail 25 KB MP3
    print("Generating head_3mb_tail_25kb.mp3...")
    head_len_target = 3 * 1024 * 1024
    apic_3mb = b"\x00image/jpeg\x00\x03\x00\xff\xd8\xff\xe0" + (b"\xcc" * (head_len_target - 100)) + b"\xff\xd9"
    apic_hdr_3mb = b"APIC" + struct.pack(">I", len(apic_3mb)) + b"\x00\x00"
    id3_body_3mb = apic_hdr_3mb + apic_3mb
    tag_len_3mb = len(id3_body_3mb)
    s0 = (tag_len_3mb >> 21) & 0x7F
    s1 = (tag_len_3mb >> 14) & 0x7F
    s2 = (tag_len_3mb >> 7) & 0x7F
    s3 = tag_len_3mb & 0x7F
    id3_hdr_3mb = b"ID3\x03\x00\x00" + bytes([s0, s1, s2, s3])
    full_head = id3_hdr_3mb + id3_body_3mb

    tail_len_target = 25 * 1024
    tail_body_target = tail_len_target - 64 - 128
    comment_val = b"\xdd" * tail_body_target
    item_3mb = struct.pack("<II", len(comment_val), 0) + b"Comment\x00" + comment_val
    ape_3mb_size = 32 + len(item_3mb)
    ape_hdr_3mb = b"APETAGEX" + struct.pack("<III", 2000, ape_3mb_size, 1) + struct.pack("<I", 0x80000000) + (b"\x00" * 8)
    ape_ftr_3mb = b"APETAGEX" + struct.pack("<III", 2000, ape_3mb_size, 1) + struct.pack("<I", 0) + (b"\x00" * 8)
    ape_tail = ape_hdr_3mb + item_3mb + ape_ftr_3mb
    id3v1_tail = bytearray(b"TAG" + (b"\x00" * 125))

    full_tail = ape_tail + bytes(id3v1_tail)
    head_3mb_tail_25kb = full_head + mp3_audio + full_tail
    with open(os.path.join(output_dir, "head_3mb_tail_25kb.mp3"), "wb") as f:
        f.write(head_3mb_tail_25kb)

    print("All fixtures generated successfully!")

if __name__ == "__main__":
    generate_fixtures()
