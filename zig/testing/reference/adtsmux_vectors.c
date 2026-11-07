// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T30a ADTS muxer oracle (zig/testing/vectors/adtsmux.txt): what
// the pinned FFmpeg's adts muxer writes for an AAC stream with the case's
// extradata (an AudioSpecificConfig, or none) and options, given packets of
// deterministic bytes. The lines:
//
//   C <name> <extradata hex or -> <write_mpeg2>
//                     a case
//   H <result>        avformat_write_header: 0 or the error
//   W <size> <side extradata hex or -> <result>
//                     each av_write_frame, its packet's size, the new
//                     extradata it carries as side data, and the result
//   T <result>        av_write_trailer
//   O <size> <md5>    the bytes written
//
// A packet of `size` bytes holds (i * 7 + size) & 0xff at index i, so the
// Zig test makes the same bytes. See zig/testing/reference/README.md for
// the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavcodec/packet.h"
#include "libavformat/avformat.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/md5.h"
#include "libavutil/mem.h"

struct Packet {
    int size;
    const char *side;
};

struct Case {
    const char *name;
    const char *extradata;
    int mpeg2;
    struct Packet packets[6];
};

static int unhex(const char *hex, uint8_t *out)
{
    int n = 0;
    if (!hex || !strcmp(hex, "-"))
        return 0;
    for (; hex[0] && hex[1]; hex += 2) {
        unsigned v;
        sscanf(hex, "%2x", &v);
        out[n++] = (uint8_t)v;
    }
    return n;
}

static void print_result(int ret)
{
    if (ret == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (ret == AVERROR(EINVAL))
        printf("EINVAL");
    else
        printf("%d", ret);
}

static void run(const struct Case *t)
{
    printf("C %s %s %d\n", t->name, t->extradata, t->mpeg2);
    AVFormatContext *oc = NULL;
    avformat_alloc_output_context2(&oc, NULL, "adts", NULL);
    AVStream *st = avformat_new_stream(oc, NULL);
    st->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    st->codecpar->codec_id = AV_CODEC_ID_AAC;
    st->codecpar->sample_rate = 44100;
    av_channel_layout_default(&st->codecpar->ch_layout, 2);
    uint8_t extradata[64];
    int size = unhex(t->extradata, extradata);
    if (size) {
        st->codecpar->extradata = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(st->codecpar->extradata, extradata, size);
        st->codecpar->extradata_size = size;
    }
    avio_open_dyn_buf(&oc->pb);
    AVDictionary *opts = NULL;
    if (t->mpeg2)
        av_dict_set(&opts, "write_mpeg2", "1", 0);
    int ret = avformat_write_header(oc, &opts);
    av_dict_free(&opts);
    printf("H ");
    print_result(ret);
    printf("\n");
    if (ret >= 0) {
        AVPacket *pkt = av_packet_alloc();
        for (int i = 0; i < 6 && t->packets[i].size >= 0; i++) {
            const struct Packet *p = &t->packets[i];
            av_new_packet(pkt, p->size);
            for (int k = 0; k < p->size; k++)
                pkt->data[k] = (uint8_t)((k * 7 + p->size) & 0xff);
            uint8_t side[64];
            int side_size = unhex(p->side, side);
            if (side_size) {
                uint8_t *sd = av_packet_new_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, side_size);
                memcpy(sd, side, side_size);
            }
            ret = av_write_frame(oc, pkt);
            printf("W %d %s ", p->size, p->side ? p->side : "-");
            print_result(ret);
            printf("\n");
            av_packet_unref(pkt);
        }
        av_packet_free(&pkt);
        ret = av_write_trailer(oc);
        printf("T ");
        print_result(ret);
        printf("\n");
    }
    uint8_t *out = NULL;
    int out_size = avio_close_dyn_buf(oc->pb, &out);
    oc->pb = NULL;
    uint8_t digest[16];
    av_md5_sum(digest, out, out_size);
    printf("O %d ", out_size);
    for (int i = 0; i < 16; i++)
        printf("%02x", digest[i]);
    printf("\n");
    av_free(out);
    avformat_free_context(oc);
}

#define END { -1, NULL }

int main(void)
{
    // The PCE configurations: LC, 44.1 kHz, channel configuration 0, the
    // GASpecificConfig's three zero bits, then a PCE (element tag 1, LC,
    // index 4, one front CPE, no others, no mixdowns, an empty or 3-byte
    // comment), byte-aligned before its comment.
    static const struct Case cases[] = {
        { "no_extradata", "-", 0, { { 200, NULL }, { 7, NULL }, { 0, NULL }, { 300, NULL }, END } },
        { "lc_44k_stereo", "1210", 0, { { 200, NULL }, { 1, NULL }, { 0, NULL }, { 8184, NULL }, { 50, NULL }, END } },
        // Past 8191 bytes the 13-bit length spills into the bit before it
        // (put_bits does not mask); past 16383 the muxer refuses.
        { "long_frames", "1210", 0, { { 8185, NULL }, { 16376, NULL }, { 16377, NULL }, { 60, NULL }, END } },
        { "long_frames_no_extradata", "-", 0, { { 16377, NULL }, { 60, NULL }, END } },
        { "main_48k_mono", "0988", 0, { { 100, NULL }, { 150, NULL }, END } },
        { "ssr_8k_6ch", "1db0", 0, { { 64, NULL }, END } },
        { "ltp_7350_8ch", "2638", 0, { { 64, NULL }, END } },
        { "mpeg2", "1210", 1, { { 120, NULL }, { 130, NULL }, END } },
        { "sync_extension_sbr", "121056e598", 0, { { 90, NULL }, END } },
        { "explicit_sbr", "2b920800", 0, { { 90, NULL }, END } },
        { "pce", "1200150400002000", 0, { { 100, NULL }, { 110, NULL }, END } },
        { "pce_comment", "1200150400002003414243", 0, { { 100, NULL }, { 110, NULL }, END } },
        { "pce_too_large", "1200150400002003414243", 0, { { 16370, NULL }, { 16370, NULL }, END } },
        { "side_extradata", "-", 0, { { 40, NULL }, { 100, "1188" }, { 110, NULL }, { 120, "1210" }, END } },
        { "side_bad_extradata", "-", 0, { { 100, "b98c" }, { 110, NULL }, END } },
        { "ld_refused", "b98c", 0, { { 100, NULL }, END } },
        { "eld_refused", "f8e60800", 0, { { 100, NULL }, END } },
        { "escape_rate_refused", "17800ac44010", 0, { { 100, NULL }, END } },
        { "chan_12_refused", "1260", 0, { { 100, NULL }, END } },
        { "frame_960_refused", "1214", 0, { { 100, NULL }, END } },
        { "core_coder_refused", "1212", 0, { { 100, NULL }, END } },
        { "extension_refused", "1211", 0, { { 100, NULL }, END } },
        { "invalid_config", "1278", 0, { { 100, NULL }, END } },
    };
    av_log_set_level(AV_LOG_QUIET);
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run(&cases[i]);
    return 0;
}
