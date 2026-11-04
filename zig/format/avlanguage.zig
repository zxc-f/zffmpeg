// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/avlanguage.c (lang_table and
// ff_convert_lang_to) at the pinned reference revision.
// Copyright (c) 2008 Ivo van Poorten
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! The three-letter codes for which FFmpeg's
//! `ff_convert_lang_to(code, AV_LANG_ISO639_2_BIBL)` finds a bibliographic
//! ISO 639-2 code: every bibliographic code and every terminological one
//! whose equivalent chain reaches one (TODO.md T29a, for ID3v2's COMM
//! keys). Computed from avlanguage.c's table by following its lookup; its
//! two-letter ISO 639-1 codes never match a three-letter text.

const std = @import("std");

/// The 504 codes, sorted.
pub const iso639_2_codes = [_]*const [3]u8{
    "aar", "abk", "ace", "ach", "ada", "ady", "afa", "afh", "afr", "ain", "aka", "akk",
    "alb", "ale", "alg", "alt", "amh", "ang", "anp", "apa", "ara", "arc", "arg", "arm",
    "arn", "arp", "art", "arw", "asm", "ast", "ath", "aus", "ava", "ave", "awa", "aym",
    "aze", "bad", "bai", "bak", "bal", "bam", "ban", "baq", "bas", "bat", "bej", "bel",
    "bem", "ben", "ber", "bho", "bih", "bik", "bin", "bis", "bla", "bnt", "bod", "bos",
    "bra", "bre", "btk", "bua", "bug", "bul", "bur", "byn", "cad", "cai", "car", "cat",
    "cau", "ceb", "cel", "ces", "cha", "chb", "che", "chg", "chi", "chk", "chm", "chn",
    "cho", "chp", "chr", "chu", "chv", "chy", "cmc", "cop", "cor", "cos", "cpe", "cpf",
    "cpp", "cre", "crh", "crp", "csb", "cus", "cym", "cze", "dak", "dan", "dar", "day",
    "del", "den", "deu", "dgr", "din", "div", "doi", "dra", "dsb", "dua", "dum", "dut",
    "dyu", "dzo", "efi", "egy", "eka", "ell", "elx", "eng", "enm", "epo", "est", "eus",
    "ewe", "ewo", "fan", "fao", "fas", "fat", "fij", "fil", "fin", "fiu", "fon", "fra",
    "fre", "frm", "fro", "frr", "frs", "fry", "ful", "fur", "gaa", "gay", "gba", "gem",
    "geo", "ger", "gez", "gil", "gla", "gle", "glg", "glv", "gmh", "goh", "gon", "gor",
    "got", "grb", "grc", "gre", "grn", "gsw", "guj", "gwi", "hai", "hat", "hau", "haw",
    "heb", "her", "hil", "him", "hin", "hit", "hmn", "hmo", "hrv", "hsb", "hun", "hup",
    "hye", "iba", "ibo", "ice", "ido", "iii", "ijo", "iku", "ile", "ilo", "ina", "inc",
    "ind", "ine", "inh", "ipk", "ira", "iro", "isl", "ita", "jav", "jbo", "jpn", "jpr",
    "jrb", "kaa", "kab", "kac", "kal", "kam", "kan", "kar", "kas", "kat", "kau", "kaw",
    "kaz", "kbd", "kha", "khi", "khm", "kho", "kik", "kin", "kir", "kmb", "kok", "kom",
    "kon", "kor", "kos", "kpe", "krc", "krl", "kro", "kru", "kua", "kum", "kur", "kut",
    "lad", "lah", "lam", "lao", "lat", "lav", "lez", "lim", "lin", "lit", "lol", "loz",
    "ltz", "lua", "lub", "lug", "lui", "lun", "luo", "lus", "mac", "mad", "mag", "mah",
    "mai", "mak", "mal", "man", "mao", "map", "mar", "mas", "may", "mdf", "mdr", "men",
    "mga", "mic", "min", "mis", "mkd", "mkh", "mlg", "mlt", "mnc", "mni", "mno", "moh",
    "mon", "mos", "mri", "msa", "mul", "mun", "mus", "mwl", "mwr", "mya", "myn", "myv",
    "nah", "nai", "nap", "nau", "nav", "nbl", "nde", "ndo", "nds", "nep", "new", "nia",
    "nic", "niu", "nld", "nno", "nob", "nog", "non", "nor", "nqo", "nso", "nub", "nwc",
    "nya", "nym", "nyn", "nyo", "nzi", "oci", "oji", "ori", "orm", "osa", "oss", "ota",
    "oto", "paa", "pag", "pal", "pam", "pan", "pap", "pau", "peo", "per", "phi", "phn",
    "pli", "pol", "pon", "por", "pra", "pro", "pus", "que", "raj", "rap", "rar", "roa",
    "roh", "rom", "ron", "rum", "run", "rup", "rus", "sad", "sag", "sah", "sai", "sal",
    "sam", "san", "sas", "sat", "scn", "sco", "sel", "sem", "sga", "sgn", "shn", "sid",
    "sin", "sio", "sit", "sla", "slk", "slo", "slv", "sma", "sme", "smi", "smj", "smn",
    "smo", "sms", "sna", "snd", "snk", "sog", "som", "son", "sot", "spa", "sqi", "srd",
    "srn", "srp", "srr", "ssa", "ssw", "suk", "sun", "sus", "sux", "swa", "swe", "syc",
    "syr", "tah", "tai", "tam", "tat", "tel", "tem", "ter", "tet", "tgk", "tgl", "tha",
    "tib", "tig", "tir", "tiv", "tkl", "tlh", "tli", "tmh", "tog", "ton", "tpi", "tsi",
    "tsn", "tso", "tuk", "tum", "tup", "tur", "tut", "tvl", "twi", "tyv", "udm", "uga",
    "uig", "ukr", "umb", "und", "urd", "uzb", "vai", "ven", "vie", "vol", "vot", "wak",
    "wal", "war", "was", "wel", "wen", "wln", "wol", "xal", "xho", "yao", "yap", "yid",
    "yor", "ypk", "zap", "zbl", "zen", "zha", "zho", "znd", "zul", "zun", "zxx", "zza",
};

/// Whether `ff_convert_lang_to(code, AV_LANG_ISO639_2_BIBL)` is not null
/// for this text: an exact, case-sensitive match of a three-letter code.
pub fn isIso6392(code: []const u8) bool {
    if (code.len != 3) return false;
    var lo: usize = 0;
    var hi: usize = iso639_2_codes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, iso639_2_codes[mid], code)) {
            .eq => return true,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return false;
}

test "bibliographic and terminological codes match; others do not" {
    try std.testing.expect(isIso6392("eng"));
    try std.testing.expect(isIso6392("fre"));
    try std.testing.expect(isIso6392("fra"));
    try std.testing.expect(isIso6392("deu"));
    try std.testing.expect(!isIso6392("Eng"));
    try std.testing.expect(!isIso6392("en"));
    try std.testing.expect(!isIso6392("xyz"));
}
