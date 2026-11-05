// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libswresample/swresample.c (swr_init, swr_convert_internal) and
// libavfilter/af_aresample.c (filter_frame, flush_frame, activate) at the
// pinned reference revision describe the behavior.
//! A sample rate change with everything libswresample does around it
//! (TODO.md T24), as FFmpeg's `aresample` filter runs it: the input into the
//! internal format, the channel mix before or after the resampler
//! (`resample_first`), the resampler, the dither, and the output format.
//!
//! Frames come either as `aresample`'s input frames, each one call
//! (`filterFrame`, then `flushFrame`, as a filter graph runs it, T25a), or
//! as a stream that `take` cuts into FFmpeg's decoder frames
//! (`frame_frames` each, the last one shorter), each making one
//! `swr_convert` call with room for
//! `n_in * ratio + 32` frames, more by the delay when there is one; a call
//! that fills its room is followed by calls of 4096 frames without input
//! until one gives nothing, and the end of the input by flushing calls of
//! 4096 frames. The dither's noise follows those calls, so a dithered result
//! equals FFmpeg's call by call. Samples come out of the resampler within its
//! declared tolerance (resample.zig). Allocates its buffers and the
//! resampler's.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples = @import("../core/samples.zig");
const audioconvert = @import("audioconvert.zig");
const dither = @import("dither.zig");
const rematrix = @import("rematrix.zig");
const resample = @import("resample.zig");

pub const Error = resample.Error || rematrix.Error;

pub const Options = struct {
    resampler: resample.Options = .{},
    dither: dither.Options = .{},
};

/// The engine of the internal format.
const Engines = union(enum) {
    s16p: resample.Engine(.s16p),
    s32p: resample.Engine(.s32p),
    fltp: resample.Engine(.fltp),
    dblp: resample.Engine(.dblp),
};

pub const Swr = struct {
    gpa: std.mem.Allocator,
    in_format: audio.Format,
    out_format: audio.Format,
    internal: audio.SampleFormat,
    /// Owned; null when the layouts are the same.
    remix: ?*rematrix.Remix,
    engine: Engines,
    /// The resampler runs before the mix (`resample_first`): on the input's
    /// channels, so the mix sees fewer frames.
    resample_first: bool,
    dithering: ?dither.Dither,
    /// FFmpeg's decoder frame size for the input: one call per frame.
    frame_frames: u32,
    /// The largest input frame the buffers hold; `filterFrame` grows them.
    capacity: u32,
    /// `aresample`'s ratio, `out_rate / in_rate` in double.
    ratio: f64,
    /// The input of the next call, in the internal format: up to
    /// `frame_frames` frames.
    postin: samples.Buffer,
    postin_frames: u32 = 0,
    /// The mix's output before the resampler, or the resampler's before the
    /// mix.
    mid: samples.Buffer,
    /// The call's output in the internal format, then the output format.
    preout: samples.Buffer,
    out: samples.Buffer,
    /// The largest room a call gets.
    max_room: u32,
    /// Calls without input follow the last one, which filled its room.
    more: bool = false,
    finished: bool = false,
    flushed_out: bool = false,
    storage: []align(8) u8,

    /// Sets up the conversion from `in_format` to `out_format` (any rate,
    /// layout and sample format), its input cut into frames of
    /// `frame_frames`.
    pub fn init(gpa: std.mem.Allocator, in_format: audio.Format, out_format: audio.Format, frame_frames: u32, options: Options) Error!Swr {
        std.debug.assert(frame_frames > 0);
        // Owned once the layouts differ.
        var remix: ?*rematrix.Remix = try gpa.create(rematrix.Remix);
        errdefer if (remix) |r| gpa.destroy(r);
        const shape = try Shape.init(remix.?, in_format, out_format);
        if (!shape.mixes) {
            gpa.destroy(remix.?);
            remix = null;
        }
        var engine: Engines = switch (shape.internal) {
            inline .s16p, .s32p, .fltp, .dblp => |f| @unionInit(Engines, @tagName(f), try resample.Engine(f).init(gpa, shape.engine_channels, in_format.sample_rate, out_format.sample_rate, options.resampler)),
            else => unreachable,
        };
        errdefer switch (engine) {
            inline else => |*e| e.deinit(),
        };
        const buffers = try Buffers.allocate(gpa, shape.internal, in_format.channelCount(), out_format, shape.resample_first, shape.ratio, frame_frames);
        // The dither's filter is chosen by the output rate (swri_dither_init).
        const dithering = dither.Dither.initInternal(shape.internal, out_format.channelCount(), out_format.sample_rate, out_format.sample_format, options.dither);
        return .{
            .gpa = gpa,
            .in_format = in_format,
            .out_format = out_format,
            .internal = shape.internal,
            .remix = remix,
            .engine = engine,
            .resample_first = shape.resample_first,
            .dithering = dithering,
            .frame_frames = frame_frames,
            .capacity = frame_frames,
            .ratio = shape.ratio,
            .postin = buffers.parts[0],
            .mid = buffers.parts[1],
            .preout = buffers.parts[2],
            .out = buffers.parts[3],
            .max_room = buffers.max_room,
            .storage = buffers.storage,
        };
    }

    /// What `init` refuses, without allocating or building the filter: the
    /// mix, the resampler's filter size and ratio, and the buffers of calls
    /// of `frame_frames` input frames. A conversion checks it before it
    /// creates its output (port.md "CLI policy").
    pub fn check(in_format: audio.Format, out_format: audio.Format, frame_frames: u32, options: Options) Error!void {
        std.debug.assert(frame_frames > 0);
        var remix: rematrix.Remix = undefined;
        const shape = try Shape.init(&remix, in_format, out_format);
        // The counter runs `resample_init`'s checks without the filter.
        var counter = try resample.Counter.init(std.mem.Allocator.failing, shape.engine_channels, in_format.sample_rate, out_format.sample_rate, options.resampler);
        counter.deinit();
        _ = try Buffers.plan(shape.internal, in_format.channelCount(), out_format, shape.resample_first, shape.ratio, frame_frames);
    }

    /// The frames of the first output `take` and `next` give for a stream
    /// of `total` input frames, or null when they give none, counted on the
    /// resampler's counter without samples (the mix and the formats change
    /// no count). A FLAC output's block size is this first output (the
    /// ffmpeg program opens its encoder with the first frame), which a
    /// conversion checks before it creates its output.
    pub fn firstOutputFrames(in_rate: u32, out_rate: u32, frame_frames: u32, total: u64, options: Options) Error!?u32 {
        std.debug.assert(frame_frames > 0);
        var counter = try resample.Counter.init(std.mem.Allocator.failing, 1, in_rate, out_rate, options.resampler);
        defer counter.deinit();
        const out_rate_f: f64 = @floatFromInt(out_rate);
        const in_rate_f: f64 = @floatFromInt(in_rate);
        const ratio = out_rate_f / in_rate_f;
        const max_room = try Buffers.maxRoom(ratio, frame_frames);
        const view: resample.Counter.View = .{};
        // `next`: one call per whole frame, then the last, shorter one. A
        // call that gives nothing did not fill its room (at least 32), so
        // no call without input follows it.
        var left = total;
        while (left > 0) {
            const n_in: u32 = @intCast(@min(left, frame_frames));
            left -= n_in;
            const room = callRoom(n_in, ratio, counter.delay(out_rate), max_room);
            const got = try counter.resample(view, @intCast(room), view, @intCast(n_in));
            if (got > 0) return @intCast(got);
        }
        // The first flushing call.
        try counter.flush();
        const got = try counter.resample(view, 4096, view, 0);
        return if (got > 0) @intCast(got) else null;
    }

    /// `init`'s choices that follow from the formats: the mix, set up in
    /// `remix` when `mixes`, the internal format, and the resampler's place
    /// and channels.
    const Shape = struct {
        mixes: bool,
        internal: audio.SampleFormat,
        resample_first: bool,
        engine_channels: u32,
        /// `aresample`'s ratio, `out_rate / in_rate` in double.
        ratio: f64,

        fn init(remix: *rematrix.Remix, in_format: audio.Format, out_format: audio.Format) Error!Shape {
            const in_channels = in_format.channelCount();
            const out_channels = out_format.channelCount();
            const resampling = in_format.sample_rate != out_format.sample_rate;
            const mixes = try remix.initFor(in_format, out_format.layout, out_format.sample_format, .{}, resampling);
            const mixing = mixes and remix.mixing;
            const internal = if (mixes) remix.internal else dither.internalFormatResampling(in_format.sample_format, out_format.sample_format, mixing, resampling);
            // swr_init: RSC * out / in - RSC < out_rate / in_rate - 1, RSC 1,
            // the channel quotient in integers.
            const quotient: i64 = @divTrunc(out_channels, in_channels);
            const in_rate_f: f32 = @floatFromInt(in_format.sample_rate);
            const out_rate_f: f64 = @floatFromInt(out_format.sample_rate);
            const rate_ratio: f32 = @floatCast(out_rate_f / in_rate_f);
            const lhs: f32 = @floatFromInt(quotient - 1);
            const resample_first = lhs < rate_ratio - 1.0;
            const in_rate_d: f64 = @floatFromInt(in_format.sample_rate);
            return .{
                .mixes = mixes,
                .internal = internal,
                .resample_first = resample_first,
                .engine_channels = if (resample_first) in_channels else out_channels,
                .ratio = out_rate_f / in_rate_d,
            };
        }
    };

    /// The buffers of calls of at most `frames` input frames, in one
    /// allocation.
    const Buffers = struct {
        storage: []align(8) u8,
        parts: [4]samples.Buffer,
        max_room: u32,

        /// The buffers' layouts and their total size, without allocating.
        const Plan = struct {
            parts: [4]samples.Layout,
            total: usize,
            max_room: u32,
        };

        /// filter_frame's room: n_in * ratio + 32, plus at most as much
        /// again or 4096 for the delay.
        fn maxRoom(ratio: f64, frames: u32) Error!u32 {
            const frames_f: f64 = @floatFromInt(frames);
            const first_f = @trunc(frames_f * ratio + 32);
            if (!(first_f < std.math.maxInt(i32) / 2)) return error.UnsupportedFormat;
            const first: u32 = @trunc(first_f);
            return first + @max(4096, first);
        }

        fn plan(internal: audio.SampleFormat, in_channels: u32, out_format: audio.Format, resample_first: bool, ratio: f64, frames: u32) Error!Plan {
            const out_channels = out_format.channelCount();
            const max_room = try maxRoom(ratio, frames);
            const mid_frames = if (resample_first) max_room else frames;
            const mid_channels = if (resample_first) in_channels else out_channels;
            const parts = [_]samples.Layout{
                try layoutOf(internal, in_channels, frames),
                try layoutOf(internal, mid_channels, mid_frames),
                try layoutOf(internal, out_channels, max_room),
                try layoutOf(out_format.sample_format, out_channels, max_room),
            };
            var total: usize = 0;
            for (parts) |layout| total = std.math.add(usize, total, layout.size) catch return error.OutOfMemory;
            return .{ .parts = parts, .total = total, .max_room = max_room };
        }

        fn allocate(gpa: std.mem.Allocator, internal: audio.SampleFormat, in_channels: u32, out_format: audio.Format, resample_first: bool, ratio: f64, frames: u32) Error!Buffers {
            const p = try plan(internal, in_channels, out_format, resample_first, ratio, frames);
            const storage = try gpa.alignedAlloc(u8, .@"8", p.total);
            var b: Buffers = .{ .storage = storage, .parts = undefined, .max_room = p.max_room };
            var offset: usize = 0;
            for (p.parts, 0..) |layout, i| {
                b.parts[i] = samples.Buffer.init(layout, storage[offset..][0..layout.size]) catch unreachable;
                offset += layout.size;
            }
            return b;
        }
    };

    /// Grows the buffers for input frames of `frames`, between calls.
    fn reserve(s: *Swr, frames: u32) Error!void {
        if (frames <= s.capacity) return;
        std.debug.assert(s.postin_frames == 0);
        const b = try Buffers.allocate(s.gpa, s.internal, s.in_format.channelCount(), s.out_format, s.resample_first, s.ratio, frames);
        s.gpa.free(s.storage);
        s.storage = b.storage;
        s.postin = b.parts[0];
        s.mid = b.parts[1];
        s.preout = b.parts[2];
        s.out = b.parts[3];
        s.max_room = b.max_room;
        s.capacity = frames;
    }

    /// `aresample`'s `filter_frame`: one call with the `count` frames of
    /// `in` (in the input format) and room for `count * ratio + 32` frames,
    /// more by the delay when there is one. The output, in the output
    /// format, or null when the call gave nothing; valid until the next
    /// call. A call that fills its room leaves `more` set: `flushFrame`
    /// with `final` false then empties the buffers before the next input.
    /// Do not mix with `take`.
    pub fn filterFrame(s: *Swr, in: samples.View, count: u32) Error!?samples.View {
        std.debug.assert(s.postin_frames == 0);
        try s.reserve(count);
        if (count > 0) audioconvert.convert(s.postin, in, 0, 0, count);
        s.postin_frames = count;
        return s.runInput();
    }

    /// `aresample`'s `flush_frame`: a call of 4096 frames without input,
    /// the resampler flushed first when `final` (the end of the input).
    /// Null when it gave nothing.
    pub fn flushFrame(s: *Swr, final: bool) resample.Error!?samples.View {
        const got = try s.call(0, 4096, final);
        return if (got > 0) s.output(got) else null;
    }

    /// The call of the input in `postin`, as `filter_frame` makes it.
    fn runInput(s: *Swr) resample.Error!?samples.View {
        const n_in = s.postin_frames;
        const room_u = callRoom(n_in, s.ratio, s.delay(), s.max_room);
        const got = try s.call(n_in, room_u, false);
        s.postin_frames = 0;
        // aresample: more data when the room was filled.
        s.more = got == room_u;
        return if (got > 0) s.output(got) else null;
    }

    /// `filter_frame`'s room for a call of `n_in` frames: `n_in` × `ratio`
    /// + 32, more by the `buffered` delay when there is one, within the
    /// buffers' `max_room`.
    fn callRoom(n_in: u32, ratio: f64, buffered: i64, max_room: u32) u32 {
        const n_in_f: f64 = @floatFromInt(n_in);
        var room: i64 = @trunc(n_in_f * ratio + 32);
        if (buffered > 0) room += @min(buffered, @max(4096, room));
        return @intCast(@min(room, max_room));
    }

    /// `swr_get_delay(base)`: the buffered input as samples of `base` per
    /// second, rounded to the nearest.
    pub fn delayIn(s: *const Swr, base: i64) i64 {
        return switch (s.engine) {
            inline else => |*e| e.delay(base),
        };
    }
    /// Lines padded to 8 bytes, so that every plane of the shared, 8-aligned
    /// storage is aligned for its samples.
    fn layoutOf(format: audio.SampleFormat, channels: u32, frames: u32) Error!samples.Layout {
        return samples.Layout.init(format, channels, @max(frames, 1), .{ .line = 8 }) catch error.UnsupportedFormat;
    }

    pub fn deinit(s: *Swr) void {
        switch (s.engine) {
            inline else => |*e| e.deinit(),
        }
        if (s.remix) |r| s.gpa.destroy(r);
        s.gpa.free(s.storage);
        s.* = undefined;
    }

    /// Takes `count` input frames from `in` at `offset` into the next call,
    /// as many as it holds; returns how many it took. A full call must be
    /// run (`runCall`) before more input fits.
    pub fn take(s: *Swr, in: samples.View, offset: u32, count: u32) u32 {
        const n = @min(count, s.frame_frames - s.postin_frames);
        if (n > 0) audioconvert.convert(s.postin, in, s.postin_frames, offset, n);
        s.postin_frames += n;
        return n;
    }

    /// Whether a call of input is ready: a whole frame, or the last part.
    pub fn callReady(s: *const Swr) bool {
        return s.postin_frames == s.frame_frames;
    }

    /// The input has ended: the last, shorter frame is the next call, then
    /// the flushing calls.
    pub fn finish(s: *Swr) void {
        s.finished = true;
    }

    /// The next call's output, in the output format, or null when no call
    /// is due: before a full frame of input, or after the last flushing
    /// call. Valid until the next call.
    pub fn next(s: *Swr) resample.Error!?samples.View {
        while (true) {
            if (s.more) {
                // flush_frame(final = 0): no input, 4096 frames of room.
                const got = try s.call(0, 4096, false);
                if (got > 0) return s.output(got);
                s.more = false;
            }
            if (s.callReady() or (s.finished and s.postin_frames > 0)) {
                if (try s.runInput()) |out| return out;
                continue;
            }
            if (s.finished and !s.flushed_out) {
                // flush_frame(final = 1): calls of 4096 frames until empty.
                const got = try s.call(0, 4096, true);
                if (got > 0) return s.output(got);
                s.flushed_out = true;
            }
            return null;
        }
    }

    fn output(s: *Swr, frames: u32) samples.View {
        return sub(s.out, s.out_format.channelCount(), frames).view();
    }

    /// `swr_get_delay(out_rate)`.
    fn delay(s: *const Swr) i64 {
        return s.delayIn(s.out_format.sample_rate);
    }

    /// One `swr_convert`: `n_in` frames of `postin` (0 for none), at most
    /// `room` frames out, flushing first if `flush`. Leaves the output, in
    /// the output format, at the start of `out`.
    fn call(s: *Swr, n_in: u32, room: u32, flush: bool) resample.Error!u32 {
        return switch (s.engine) {
            inline else => |*e| s.callWith(e, n_in, room, flush),
        };
    }

    fn callWith(s: *Swr, e: anytype, n_in: u32, room: u32, flush: bool) resample.Error!u32 {
        const E = @TypeOf(e.*);
        if (flush) try e.flush();
        const in_channels = s.in_format.channelCount();
        const out_channels = s.out_format.channelCount();
        var produced: u32 = 0;
        if (s.resample_first) {
            // Resample the input's channels into `mid`, then mix into `preout`.
            const got = try e.resample(viewOf(E, s.mid, in_channels, 0), @intCast(room), viewOf(E, s.postin, in_channels, 0), @intCast(n_in));
            produced = @intCast(got);
            if (produced > 0) {
                if (s.remix) |r| {
                    r.apply(sub(s.preout, out_channels, produced), sub(s.mid, in_channels, produced).view(), produced);
                } else {
                    copyFrames(s.preout, s.mid, in_channels, produced);
                }
            }
        } else {
            // Mix the input into `mid`, then resample the output's channels.
            var source = s.postin;
            if (s.remix) |r| {
                if (n_in > 0) r.apply(sub(s.mid, out_channels, n_in), sub(s.postin, in_channels, n_in).view(), n_in);
                source = s.mid;
            }
            const got = try e.resample(viewOf(E, s.preout, out_channels, 0), @intCast(room), viewOf(E, source, out_channels, 0), @intCast(n_in));
            produced = @intCast(got);
        }
        if (produced > 0) {
            const preout = sub(s.preout, out_channels, produced);
            if (s.dithering) |*d| d.applyInternal(preout, produced);
            audioconvert.convert(sub(s.out, out_channels, produced), preout.view(), 0, 0, produced);
        }
        return produced;
    }

    /// The first `frames` frames of a planar buffer (its planes' starts are
    /// unchanged, its counts smaller).
    fn sub(buffer: samples.Buffer, channels: u32, frames: u32) samples.Buffer {
        var layout = buffer.layout;
        std.debug.assert(layout.channels == channels and frames <= layout.samples);
        layout.samples = frames;
        return .{ .layout = layout, .bytes = buffer.bytes };
    }

    fn copyFrames(dst: samples.Buffer, src: samples.Buffer, channels: u32, frames: u32) void {
        const bytes = frames * src.layout.format.bytesPerSample();
        for (0..channels) |c| @memcpy(dst.plane(@intCast(c))[0..bytes], src.plane(@intCast(c))[0..bytes]);
    }

    fn viewOf(comptime E: type, buffer: samples.Buffer, channels: u32, offset: u32) E.View {
        var v: E.View = .{};
        for (0..channels) |c| {
            const plane = buffer.plane(@intCast(c));
            v.planes[c] = @ptrCast(@alignCast(plane[offset * @sizeOf(E.Sample) ..].ptr));
        }
        return v;
    }
};

test "a resampled stream equals the resampler's own output, frames as FFmpeg cuts them" {
    const gpa = std.testing.allocator;
    const in_format = try audio.Format.init(44100, 1, .s16);
    const out_format = try audio.Format.init(48000, 1, .s16);
    var swr = try Swr.init(gpa, in_format, out_format, 64, .{});
    defer swr.deinit();
    var input: [1000]i16 = undefined;
    for (&input, 0..) |*v, i| v.* = @intCast(@as(i32, @intCast(i * 37 % 2000)) - 1000);
    const layout = try samples.Layout.init(.s16, 1, input.len, .{ .line = 1 });
    const view = try samples.View.init(layout, std.mem.sliceAsBytes(&input));
    var total: u64 = 0;
    var at: u32 = 0;
    while (at < input.len) {
        at += swr.take(view, at, @intCast(input.len - at));
        while (try swr.next()) |out| total += out.layout.samples;
    }
    swr.finish();
    while (try swr.next()) |out| total += out.layout.samples;
    try std.testing.expectEqual(try resample.outputFrames(input.len, 44100, 48000, .{}), total);
}

/// The first output of a real `Swr` on silence, `total` frames given as a
/// decoder would, `chunk` at a time.
fn firstOutputOf(gpa: std.mem.Allocator, in_format: audio.Format, out_format: audio.Format, frame_frames: u32, total: u32, chunk: u32) !?u32 {
    var swr = try Swr.init(gpa, in_format, out_format, frame_frames, .{});
    defer swr.deinit();
    const layout = try samples.Layout.init(in_format.sample_format, in_format.channelCount(), @max(chunk, 1), .{ .line = 1 });
    const bytes = try gpa.alloc(u8, layout.size);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const view = try samples.View.init(layout, bytes);
    var given: u32 = 0;
    while (given < total) {
        const n = @min(chunk, total - given);
        var at: u32 = 0;
        while (at < n) {
            at += swr.take(view, at, n - at);
            if (try swr.next()) |out| return out.layout.samples;
        }
        given += n;
    }
    swr.finish();
    return if (try swr.next()) |out| out.layout.samples else null;
}

test "firstOutputFrames counts the first output a stream gives" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: u32, out: u32, frame_frames: u32, total: u32 }{
        .{ .in = 44100, .out = 48000, .frame_frames = 4096, .total = 10_000 },
        .{ .in = 48000, .out = 44100, .frame_frames = 1152, .total = 5000 },
        .{ .in = 100, .out = 48000, .frame_frames = 2048, .total = 2000 },
        .{ .in = 1, .out = 8000, .frame_frames = 1, .total = 50 },
        .{ .in = 8000, .out = 48000, .frame_frames = 16, .total = 20 },
        .{ .in = 8000, .out = 48000, .frame_frames = 4096, .total = 3 },
        .{ .in = 48000, .out = 8000, .frame_frames = 4096, .total = 0 },
    };
    for (cases) |case| {
        const in_format = try audio.Format.init(case.in, 2, .s16);
        const out_format = try audio.Format.init(case.out, 2, .s16);
        const counted = try Swr.firstOutputFrames(case.in, case.out, case.frame_frames, case.total, .{});
        for ([_]u32{ 1, 333, 8192 }) |chunk| {
            try std.testing.expectEqual(counted, try firstOutputOf(gpa, in_format, out_format, case.frame_frames, case.total, chunk));
        }
    }
}

test "check refuses what init refuses, without allocating" {
    const gpa = std.testing.allocator;
    // A call's room past the buffers' bound: 1 Hz in frames of 4096 to
    // 100 kHz s32 (the review's M15).
    const in_format = try audio.Format.init(1, 1, .u8);
    const out_format = try audio.Format.init(100_000, 1, .s32);
    try std.testing.expectError(error.UnsupportedFormat, Swr.check(in_format, out_format, 4096, .{}));
    try std.testing.expectError(error.UnsupportedFormat, Swr.init(gpa, in_format, out_format, 4096, .{}));
    // A filter libswresample refuses.
    const options: Options = .{ .resampler = .{ .filter_size = std.math.maxInt(i32) } };
    const high = try audio.Format.init(48000, 1, .s16);
    const low = try audio.Format.init(8000, 1, .s16);
    try std.testing.expectError(error.UnsupportedFormat, Swr.check(high, low, 1024, options));
    try std.testing.expectError(error.UnsupportedFormat, Swr.init(gpa, high, low, 1024, options));
    try Swr.check(try audio.Format.init(44100, 2, .s16), try audio.Format.init(48000, 6, .flt), 4096, .{});
}
