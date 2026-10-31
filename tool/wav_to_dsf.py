#!/usr/bin/env python3
"""
wav_to_dsf.py: Converts a PCM WAV file to a standard DSD Stream File (DSF, DSD64 2.8224 MHz).
Uses 1st-order Sigma-Delta pulse density modulation (PDM) with LSB-first bit packing.
"""

import os
import struct
import sys
import wave

BLOCK_SIZE_PER_CHANNEL = 4096  # Standard DSF block size
SAMPLES_PER_BLOCK = BLOCK_SIZE_PER_CHANNEL * 8  # 32768 DSD samples per channel per block
PCM_PER_BLOCK = SAMPLES_PER_BLOCK // 64  # 512 PCM samples per block at 64x oversampling


def generate_lut():
    """Generates a 256-entry lookup table mapping unsigned 8-bit PCM values to 8 bytes of PDM."""
    lut = []
    for i in range(256):
        # Scale to [-0.95, 0.95]
        v = ((i - 128.0) / 128.0) * 0.95
        acc = 0.0
        pdm = bytearray(8)
        for byte_idx in range(8):
            b = 0
            for bit in range(8):
                acc += v
                if acc >= 0.0:
                    b |= (1 << bit)
                    acc -= 1.0
                else:
                    acc += 1.0
            pdm[byte_idx] = b
        lut.append(bytes(pdm))
    return lut


def convert_wav_to_dsf(input_wav_path, output_dsf_path):
    print(f"Opening input WAV: {input_wav_path}")
    with wave.open(input_wav_path, "rb") as wf:
        channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()

        if channels != 2 or sampwidth != 2:
            raise ValueError(
                f"Expected 16-bit stereo WAV, got {channels} channels, {sampwidth * 8} bits"
            )

        print(
            f"Input WAV: {channels} ch, {framerate} Hz, {sampwidth * 8}-bit, {n_frames} frames"
        )
        raw_pcm = wf.readframes(n_frames)

    lut = generate_lut()

    total_pcm_samples = len(raw_pcm) // 4  # 4 bytes per frame (2 channels * 2 bytes)
    num_blocks = total_pcm_samples // PCM_PER_BLOCK
    actual_pcm_used = num_blocks * PCM_PER_BLOCK

    print(
        f"Encoding {num_blocks} blocks ({actual_pcm_used} PCM frames -> {num_blocks * SAMPLES_PER_BLOCK} DSD samples/ch)..."
    )

    data_bytes_len = num_blocks * BLOCK_SIZE_PER_CHANNEL * 2
    dsd_chunk_size = 28
    fmt_chunk_size = 52
    data_chunk_size = 12 + data_bytes_len
    total_file_size = dsd_chunk_size + fmt_chunk_size + data_chunk_size

    # DSD64 rate: 44.1 kHz * 64 = 2,822,400 Hz
    sampling_freq = 2822400
    sample_count = num_blocks * SAMPLES_PER_BLOCK

    with open(output_dsf_path, "wb") as out:
        # 1. DSD chunk (28 bytes)
        out.write(b"DSD ")
        out.write(struct.pack("<Q", dsd_chunk_size))
        out.write(struct.pack("<Q", total_file_size))
        out.write(struct.pack("<Q", 0))  # metadata offset

        # 2. fmt chunk (52 bytes)
        out.write(b"fmt ")
        out.write(struct.pack("<Q", fmt_chunk_size))
        out.write(struct.pack("<I", 1))  # format version
        out.write(struct.pack("<I", 0))  # format ID (0 = DSD raw)
        out.write(struct.pack("<I", 2))  # channel type (2 = stereo)
        out.write(struct.pack("<I", 2))  # channel num
        out.write(struct.pack("<I", sampling_freq))  # sampling freq
        out.write(struct.pack("<I", 1))  # bits per sample = 1
        out.write(struct.pack("<Q", sample_count))  # sample count per channel
        out.write(struct.pack("<I", BLOCK_SIZE_PER_CHANNEL))  # block size
        out.write(struct.pack("<I", 0))  # reserved

        # 3. data chunk (12 bytes header)
        out.write(b"data")
        out.write(struct.pack("<Q", data_chunk_size))

        # Stream encoded blocks
        for b_idx in range(num_blocks):
            base_offset = b_idx * PCM_PER_BLOCK * 4

            # Channel 0 (left): samples at offset + 0 (low byte), offset + 1 (high byte)
            ch0_pdm = [
                lut[raw_pcm[base_offset + i * 4 + 1]]
                for i in range(PCM_PER_BLOCK)
            ]
            # Channel 1 (right): samples at offset + 2 (low byte), offset + 3 (high byte)
            ch1_pdm = [
                lut[raw_pcm[base_offset + i * 4 + 3]]
                for i in range(PCM_PER_BLOCK)
            ]

            out.write(b"".join(ch0_pdm))
            out.write(b"".join(ch1_pdm))

    print(f"Successfully generated DSF: {output_dsf_path} ({os.path.getsize(output_dsf_path):,} bytes)")


if __name__ == "__main__":
    in_wav = sys.argv[1] if len(sys.argv) > 1 else "/tmp/salida_44100.wav"
    out_dsf = sys.argv[2] if len(sys.argv) > 2 else "example/assets/music/salida.dsf"
    convert_wav_to_dsf(in_wav, out_dsf)
