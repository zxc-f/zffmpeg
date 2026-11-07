// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a fixture tool, not part of the port.
//
// Encodes interleaved s16le samples from standard input into HE-AAC (SBR,
// AOT 5) or HE-AACv2 (SBR and PS, AOT 29) ADTS on standard output with the
// Fraunhofer FDK AAC library, the system's libfdk-aac, for the T30c and
// T30d fixtures (zig/testing/fixtures/aac/aac_fdk_*.aac), which the pinned
// FFmpeg cannot make: its native AAC encoder writes AAC-LC only. FFmpeg's
// own decoder stays the oracle; this tool only writes the streams, and its
// output is committed with the hashes generate.py records (AAC_FDK), so
// the library is needed only to remake them:
//
//   cc zig/testing/reference/heaac_encode.c -lfdk-aac -o heaac-encode
//   ./heaac-encode <aot> <sample_rate> <channels> <bit_rate> < in.s16 > out.aac
//
// aac_fixtures.sh runs it. The signaling is implicit (the ADTS header
// carries the AAC-LC core and its rate, the SBR and PS data ride in fill
// elements), as ADTS requires. The files depend on the library's version
// (recorded in generate.py); afterburner and the bit rate mode are fixed.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <fdk-aac/aacenc_lib.h>

static int set(HANDLE_AACENCODER h, AACENC_PARAM param, UINT value, const char *name)
{
    AACENC_ERROR err = aacEncoder_SetParam(h, param, value);
    if (err != AACENC_OK) {
        fprintf(stderr, "heaac-encode: %s %u refused (0x%x)\n", name, value, err);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: heaac-encode <aot> <sample_rate> <channels> <bit_rate>\n");
        return 2;
    }
    const int aot = atoi(argv[1]), rate = atoi(argv[2]), channels = atoi(argv[3]), bit_rate = atoi(argv[4]);
    CHANNEL_MODE mode;
    switch (channels) {
    case 1: mode = MODE_1; break;
    case 2: mode = MODE_2; break;
    case 6: mode = MODE_1_2_2_1; break;
    default:
        fprintf(stderr, "heaac-encode: %d channels not supported\n", channels);
        return 2;
    }
    HANDLE_AACENCODER h;
    if (aacEncOpen(&h, 0, channels) != AACENC_OK)
        return 1;
    if (set(h, AACENC_AOT, aot, "aot") || set(h, AACENC_SAMPLERATE, rate, "sample rate") ||
        set(h, AACENC_CHANNELMODE, mode, "channel mode") || set(h, AACENC_CHANNELORDER, 1, "channel order") ||
        set(h, AACENC_BITRATEMODE, 0, "bit rate mode") || set(h, AACENC_BITRATE, bit_rate, "bit rate") ||
        set(h, AACENC_TRANSMUX, TT_MP4_ADTS, "transport") || set(h, AACENC_SIGNALING_MODE, 0, "signaling") ||
        set(h, AACENC_AFTERBURNER, 1, "afterburner"))
        return 1;
    if (aacEncEncode(h, NULL, NULL, NULL, NULL) != AACENC_OK) {
        fprintf(stderr, "heaac-encode: the encoder does not open with these parameters\n");
        return 1;
    }
    AACENC_InfoStruct info;
    if (aacEncInfo(h, &info) != AACENC_OK)
        return 1;

    const int frame = (int)info.frameLength * channels;
    int16_t *in = calloc(frame, sizeof(*in));
    uint8_t out[20480];
    int eof = 0;
    while (1) {
        int got = 0;
        if (!eof) {
            got = (int)fread(in, sizeof(*in), frame, stdin);
            if (got < frame)
                eof = 1;
        }
        AACENC_BufDesc in_desc = { 0 }, out_desc = { 0 };
        AACENC_InArgs in_args = { 0 };
        AACENC_OutArgs out_args = { 0 };
        void *in_ptr = in, *out_ptr = out;
        INT in_id = IN_AUDIO_DATA, in_size = got * (int)sizeof(*in), in_elem = sizeof(*in);
        INT out_id = OUT_BITSTREAM_DATA, out_size = sizeof(out), out_elem = 1;
        in_desc.numBufs = 1;
        in_desc.bufs = &in_ptr;
        in_desc.bufferIdentifiers = &in_id;
        in_desc.bufSizes = &in_size;
        in_desc.bufElSizes = &in_elem;
        out_desc.numBufs = 1;
        out_desc.bufs = &out_ptr;
        out_desc.bufferIdentifiers = &out_id;
        out_desc.bufSizes = &out_size;
        out_desc.bufElSizes = &out_elem;
        // A count of -1 flushes the encoder at the end.
        in_args.numInSamples = eof && got == 0 ? -1 : got;
        AACENC_ERROR err = aacEncEncode(h, in_args.numInSamples < 0 ? NULL : &in_desc, &out_desc, &in_args, &out_args);
        if (err == AACENC_ENCODE_EOF)
            break;
        if (err != AACENC_OK) {
            fprintf(stderr, "heaac-encode: encoding failed (0x%x)\n", err);
            return 1;
        }
        if (out_args.numOutBytes > 0)
            fwrite(out, 1, out_args.numOutBytes, stdout);
        if (eof && got == 0 && out_args.numOutBytes == 0)
            break;
        if (eof && got > 0)
            got = 0;
    }
    free(in);
    aacEncClose(&h);
    return 0;
}
