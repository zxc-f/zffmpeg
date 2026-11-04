// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/id3v1.c (ff_id3v1_genre_str, get_string,
// parse_tag, ff_id3v1_read) at the pinned reference revision.
// Copyright (c) 2003 Fabrice Bellard
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! ID3v1 tags (TODO.md T29a): the 128 bytes at the end of a file, read as
//! FFmpeg's `ff_id3v1_read` reads them into the format's tags, and the
//! genre names ID3v2 also uses for a numeric genre.

const std = @import("std");
const metadata = @import("../core/metadata.zig");

pub const tag_size = 128;
/// `ID3v1_GENRE_MAX`.
pub const genre_max = 191;

/// `ff_id3v1_genre_str`.
pub const genres = [genre_max + 1][]const u8{
    "Blues",
    "Classic Rock",
    "Country",
    "Dance",
    "Disco",
    "Funk",
    "Grunge",
    "Hip-Hop",
    "Jazz",
    "Metal",
    "New Age",
    "Oldies",
    "Other",
    "Pop",
    "R&B",
    "Rap",
    "Reggae",
    "Rock",
    "Techno",
    "Industrial",
    "Alternative",
    "Ska",
    "Death Metal",
    "Pranks",
    "Soundtrack",
    "Euro-Techno",
    "Ambient",
    "Trip-Hop",
    "Vocal",
    "Jazz+Funk",
    "Fusion",
    "Trance",
    "Classical",
    "Instrumental",
    "Acid",
    "House",
    "Game",
    "Sound Clip",
    "Gospel",
    "Noise",
    "AlternRock",
    "Bass",
    "Soul",
    "Punk",
    "Space",
    "Meditative",
    "Instrumental Pop",
    "Instrumental Rock",
    "Ethnic",
    "Gothic",
    "Darkwave",
    "Techno-Industrial",
    "Electronic",
    "Pop-Folk",
    "Eurodance",
    "Dream",
    "Southern Rock",
    "Comedy",
    "Cult",
    "Gangsta",
    "Top 40",
    "Christian Rap",
    "Pop/Funk",
    "Jungle",
    "Native American",
    "Cabaret",
    "New Wave",
    "Psychedelic",
    "Rave",
    "Showtunes",
    "Trailer",
    "Lo-Fi",
    "Tribal",
    "Acid Punk",
    "Acid Jazz",
    "Polka",
    "Retro",
    "Musical",
    "Rock & Roll",
    "Hard Rock",
    "Folk",
    "Folk-Rock",
    "National Folk",
    "Swing",
    "Fast Fusion",
    "Bebop",
    "Latin",
    "Revival",
    "Celtic",
    "Bluegrass",
    "Avantgarde",
    "Gothic Rock",
    "Progressive Rock",
    "Psychedelic Rock",
    "Symphonic Rock",
    "Slow Rock",
    "Big Band",
    "Chorus",
    "Easy Listening",
    "Acoustic",
    "Humour",
    "Speech",
    "Chanson",
    "Opera",
    "Chamber Music",
    "Sonata",
    "Symphony",
    "Booty Bass",
    "Primus",
    "Porn Groove",
    "Satire",
    "Slow Jam",
    "Club",
    "Tango",
    "Samba",
    "Folklore",
    "Ballad",
    "Power Ballad",
    "Rhythmic Soul",
    "Freestyle",
    "Duet",
    "Punk Rock",
    "Drum Solo",
    "A Cappella",
    "Euro-House",
    "Dance Hall",
    "Goa",
    "Drum & Bass",
    "Club-House",
    "Hardcore Techno",
    "Terror",
    "Indie",
    "BritPop",
    "Negerpunk",
    "Polsk Punk",
    "Beat",
    "Christian Gangsta Rap",
    "Heavy Metal",
    "Black Metal",
    "Crossover",
    "Contemporary Christian",
    "Christian Rock",
    "Merengue",
    "Salsa",
    "Thrash Metal",
    "Anime",
    "Jpop",
    "Synthpop",
    "Abstract",
    "Art Rock",
    "Baroque",
    "Bhangra",
    "Big Beat",
    "Breakbeat",
    "Chillout",
    "Downtempo",
    "Dub",
    "EBM",
    "Eclectic",
    "Electro",
    "Electroclash",
    "Emo",
    "Experimental",
    "Garage",
    "Global",
    "IDM",
    "Illbient",
    "Industro-Goth",
    "Jam Band",
    "Krautrock",
    "Leftfield",
    "Lounge",
    "Math Rock",
    "New Romantic",
    "Nu-Breakz",
    "Post-Punk",
    "Post-Rock",
    "Psytrance",
    "Shoegaze",
    "Space Rock",
    "Trop Rock",
    "World Music",
    "Neoclassical",
    "Audiobook",
    "Audio Theatre",
    "Neue Deutsche Welle",
    "Podcast",
    "Indie Rock",
    "G-Funk",
    "Dubstep",
    "Garage Rock",
    "Psybient",
};

/// `get_string`: the bytes up to the first NUL, without trailing spaces
/// (from the first space after which only spaces follow), at most 511, as
/// they are (FFmpeg does not convert ISO-8859-1); empty means no tag.
fn field(buf: []const u8, out: *[512]u8) []const u8 {
    var n: usize = 0;
    var first_free_space: ?usize = null;
    for (buf) |c| {
        if (c == 0) break;
        if (n >= out.len - 1) break;
        if (c == ' ') {
            if (first_free_space == null) first_free_space = n;
        } else first_free_space = null;
        out[n] = c;
        n += 1;
    }
    return out[0 .. first_free_space orelse n];
}

/// `parse_tag`: the tags of a 128-byte ID3v1 tag into `tags` (each
/// replacing an earlier one with its key), or nothing when `buf` does not
/// start with `TAG`.
pub fn parse(gpa: std.mem.Allocator, buf: *const [tag_size]u8, tags: *metadata.Dictionary) std.mem.Allocator.Error!void {
    if (!std.mem.eql(u8, buf[0..3], "TAG")) return;
    const fields = [_]struct { key: []const u8, at: usize, len: usize }{
        .{ .key = "title", .at = 3, .len = 30 },
        .{ .key = "artist", .at = 33, .len = 30 },
        .{ .key = "album", .at = 63, .len = 30 },
        .{ .key = "date", .at = 93, .len = 4 },
        .{ .key = "comment", .at = 97, .len = 30 },
    };
    var scratch: [512]u8 = undefined;
    for (fields) |f| {
        const value = field(buf[f.at..][0..f.len], &scratch);
        if (value.len != 0) try put(gpa, tags, f.key, value);
    }
    if (buf[125] == 0 and buf[126] != 0) {
        var text: [3]u8 = undefined;
        try put(gpa, tags, "track", std.fmt.bufPrint(&text, "{d}", .{buf[126]}) catch unreachable);
    }
    if (buf[127] <= genre_max) try put(gpa, tags, "genre", genres[buf[127]]);
}

fn put(gpa: std.mem.Allocator, tags: *metadata.Dictionary, key: []const u8, value: []const u8) std.mem.Allocator.Error!void {
    tags.put(gpa, key, value, .replace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `field` stops at the first NUL, and the keys and genres have none.
        error.InvalidTag => unreachable,
    };
}

test "an ID3v1 tag: trailing spaces trimmed, the track from comment byte 29, the genre named" {
    const gpa = std.testing.allocator;
    var buf: [tag_size]u8 = @splat(0);
    @memcpy(buf[0..3], "TAG");
    @memcpy(buf[3..][0..9], "a title  ");
    @memcpy(buf[33..][0..12], "an  artist  ");
    @memcpy(buf[93..][0..4], "2001");
    @memcpy(buf[97..][0..4], "note");
    buf[126] = 5;
    buf[127] = 13;
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    try parse(gpa, &buf, &tags);
    try std.testing.expectEqualStrings("a title", tags.get("title").?);
    try std.testing.expectEqualStrings("an  artist", tags.get("artist").?);
    try std.testing.expectEqual(null, tags.get("album"));
    try std.testing.expectEqualStrings("2001", tags.get("date").?);
    try std.testing.expectEqualStrings("5", tags.get("track").?);
    try std.testing.expectEqualStrings("Pop", tags.get("genre").?);
    // Genre 255 is none, and without TAG nothing is read.
    buf[127] = 255;
    var none: metadata.Dictionary = .empty;
    defer none.deinit(gpa);
    buf[0] = 'X';
    try parse(gpa, &buf, &none);
    try std.testing.expectEqual(0, none.count());
}
