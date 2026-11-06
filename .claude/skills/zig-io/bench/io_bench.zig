// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: the zig-io skill's measurements
// (.claude/skills/zig-io/references/analysis.md). Not part of the av module.
//! I/O micro-benchmarks on Zig 0.17.0's std.Io, meant to run from the page
//! cache so they measure the library and syscall cost, not the disk.
//! Build with `zig build-exe -OReleaseFast io_bench.zig`; `run_all.sh` runs
//! every table.
//!
//!     io_bench gen <path> <MiB>
//!     io_bench read <path> <pos|stream> <buffer> <chunk>
//!     io_bench fields <path> <pos|stream> <buffer> <slice|take|int> <MiB>
//!     io_bench skip <path> <pos|stream> <buffer> <read> <skip>
//!     io_bench pipe <buffer> <chunk>                 (standard input)
//!     io_bench write <path> <pos|stream> <buffer> <chunk> <MiB>
//!     io_bench copy <src> <dst> <loop|stream> <buffer>
//!     io_bench queue <path> <capacity> <packet> <work>
//!     io_bench serial <path> <packet> <work>
//!
//! `pos` opens `file.reader` (positional), `stream` `file.readerStreaming`.
//! Each command prints one "<name> <N> MiB/s" line.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cmd = args[1];
    var out_buffer: [512]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buffer);
    const w = &out.interface;
    defer w.flush() catch {};

    if (eql(cmd, "gen")) return gen(io, args[2], try num(args[3]));
    if (eql(cmd, "read")) return read(io, w, args[2], args[3], try num(args[4]), try num(args[5]));
    if (eql(cmd, "fields")) return fields(io, w, args[2], args[3], try num(args[4]), args[5], try num(args[6]));
    if (eql(cmd, "skip")) return skip(io, w, args[2], args[3], try num(args[4]), try num(args[5]), try num(args[6]));
    if (eql(cmd, "pipe")) return pipe(io, w, try num(args[2]), try num(args[3]));
    if (eql(cmd, "write")) return write(io, w, args[2], args[3], try num(args[4]), try num(args[5]), try num(args[6]));
    if (eql(cmd, "copy")) return copy(io, w, args[2], args[3], args[4], try num(args[5]));
    if (eql(cmd, "queue")) return queue(io, w, init.gpa, args[2], try num(args[3]), try num(args[4]), try num(args[5]));
    if (eql(cmd, "serial")) return serial(io, w, init.gpa, args[2], try num(args[3]), try num(args[4]));
    return error.UnknownCommand;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn num(text: []const u8) !usize {
    return std.fmt.parseInt(usize, text, 10);
}

fn now(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

fn report(w: *Io.Writer, name: []const u8, bytes: u64, start: Io.Timestamp, end: Io.Timestamp, sink: u64) !void {
    const ns: f64 = @floatFromInt(start.durationTo(end).nanoseconds);
    const mib: f64 = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    try w.print("{s} {d:.0} MiB/s ({d:.1} ms, sink {x})\n", .{ name, mib / (ns / 1e9), ns / 1e6, sink & 0xff });
}

fn gen(io: Io, path: []const u8, mib: usize) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var fw = file.writer(io, &buffer);
    var block: [4096]u8 = undefined;
    var x: u64 = 0x9e3779b97f4a7c15;
    for (0..mib * 256) |_| {
        for (0..block.len / 8) |i| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            std.mem.writeInt(u64, block[i * 8 ..][0..8], x, .little);
        }
        try fw.interface.writeAll(&block);
    }
    try fw.interface.flush();
}

fn openReader(io: Io, file: Io.File, mode: []const u8, buffer: []u8) Io.File.Reader {
    return if (eql(mode, "pos")) file.reader(io, buffer) else file.readerStreaming(io, buffer);
}

fn read(io: Io, w: *Io.Writer, path: []const u8, mode: []const u8, buffer_len: usize, chunk: usize) !void {
    const gpa = std.heap.page_allocator;
    const buffer = try gpa.alloc(u8, buffer_len);
    defer gpa.free(buffer);
    const dest = try gpa.alloc(u8, chunk);
    defer gpa.free(dest);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const start = now(io);
    var fr = openReader(io, file, mode, buffer);
    var total: u64 = 0;
    var sink: u64 = 0;
    while (true) {
        const n = try fr.interface.readSliceShort(dest);
        total += n;
        if (n > 0) sink +%= dest[n - 1];
        if (n < dest.len) break;
    }
    try report(w, "read", total, start, now(io), sink);
}

fn fields(io: Io, w: *Io.Writer, path: []const u8, mode: []const u8, buffer_len: usize, how: []const u8, mib: usize) !void {
    const gpa = std.heap.page_allocator;
    const buffer = try gpa.alloc(u8, buffer_len);
    defer gpa.free(buffer);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const count = mib * (1 << 20) / 4;
    const start = now(io);
    var fr = openReader(io, file, mode, buffer);
    const r = &fr.interface;
    var sink: u32 = 0;
    if (eql(how, "slice")) {
        for (0..count) |_| {
            var field: [4]u8 = undefined;
            try r.readSliceAll(&field);
            sink +%= std.mem.readInt(u32, &field, .little);
        }
    } else if (eql(how, "take")) {
        for (0..count) |_| sink +%= std.mem.readInt(u32, (try r.takeArray(4)), .little);
    } else {
        for (0..count) |_| sink +%= try r.takeInt(u32, .little);
    }
    try report(w, "fields", count * 4, start, now(io), sink);
}

fn skip(io: Io, w: *Io.Writer, path: []const u8, mode: []const u8, buffer_len: usize, read_len: usize, skip_len: usize) !void {
    const gpa = std.heap.page_allocator;
    const buffer = try gpa.alloc(u8, buffer_len);
    defer gpa.free(buffer);
    const dest = try gpa.alloc(u8, read_len);
    defer gpa.free(dest);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const start = now(io);
    var fr = openReader(io, file, mode, buffer);
    var total: u64 = 0;
    var sink: u64 = 0;
    while (true) {
        const n = try fr.interface.readSliceShort(dest);
        total += n;
        if (n > 0) sink +%= dest[n - 1];
        if (n < dest.len) break;
        const skipped = try fr.interface.discardShort(skip_len);
        total += skipped;
        if (skipped < skip_len) break;
    }
    try report(w, "skip", total, start, now(io), sink);
}

fn pipe(io: Io, w: *Io.Writer, buffer_len: usize, chunk: usize) !void {
    const gpa = std.heap.page_allocator;
    const buffer = try gpa.alloc(u8, buffer_len);
    defer gpa.free(buffer);
    const dest = try gpa.alloc(u8, chunk);
    defer gpa.free(dest);
    const start = now(io);
    var fr = Io.File.stdin().readerStreaming(io, buffer);
    var total: u64 = 0;
    var sink: u64 = 0;
    while (true) {
        const n = try fr.interface.readSliceShort(dest);
        total += n;
        if (n > 0) sink +%= dest[n - 1];
        if (n < dest.len) break;
    }
    try report(w, "pipe", total, start, now(io), sink);
}

fn write(io: Io, w: *Io.Writer, path: []const u8, mode: []const u8, buffer_len: usize, chunk: usize, mib: usize) !void {
    const gpa = std.heap.page_allocator;
    const buffer = try gpa.alloc(u8, buffer_len);
    defer gpa.free(buffer);
    const src = try gpa.alloc(u8, chunk);
    defer gpa.free(src);
    for (src, 0..) |*b, i| b.* = @truncate(i *% 31);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    const total: u64 = @as(u64, mib) << 20;
    const start = now(io);
    var fw = if (eql(mode, "pos")) file.writer(io, buffer) else file.writerStreaming(io, buffer);
    var done: u64 = 0;
    while (done < total) : (done += chunk) try fw.interface.writeAll(src);
    try fw.interface.flush();
    try report(w, "write", done, start, now(io), 0);
}

fn copy(io: Io, w: *Io.Writer, src_path: []const u8, dst_path: []const u8, how: []const u8, buffer_len: usize) !void {
    const gpa = std.heap.page_allocator;
    const rbuf = try gpa.alloc(u8, buffer_len);
    defer gpa.free(rbuf);
    const wbuf = try gpa.alloc(u8, buffer_len);
    defer gpa.free(wbuf);
    const src = try Io.Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);
    const dst = try Io.Dir.cwd().createFile(io, dst_path, .{});
    defer dst.close(io);
    const start = now(io);
    var fr = src.reader(io, rbuf);
    var fw = dst.writer(io, wbuf);
    var total: u64 = 0;
    if (eql(how, "stream")) {
        // Reader.stream reaches File.Writer.sendFile: copy_file_range/sendfile.
        total = try fr.interface.streamRemaining(&fw.interface);
    } else {
        var chunk: [1 << 16]u8 = undefined;
        while (true) {
            const n = try fr.interface.readSliceShort(&chunk);
            try fw.interface.writeAll(chunk[0..n]);
            total += n;
            if (n < chunk.len) break;
        }
    }
    try fw.interface.flush();
    try report(w, "copy", total, start, now(io), 0);
}

/// CPU work per packet, standing in for a decoder.
fn work(packet: []const u8, rounds: usize) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (0..rounds) |_| {
        for (packet) |b| h = (h ^ b) *% 0x100000001b3;
    }
    return h;
}

fn serial(io: Io, w: *Io.Writer, gpa: std.mem.Allocator, path: []const u8, packet: usize, rounds: usize) !void {
    const buffer = try gpa.alloc(u8, 1 << 16);
    defer gpa.free(buffer);
    const dest = try gpa.alloc(u8, packet);
    defer gpa.free(dest);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const start = now(io);
    var fr = file.reader(io, buffer);
    var total: u64 = 0;
    var sink: u64 = 0;
    while (true) {
        const n = try fr.interface.readSliceShort(dest);
        total += n;
        sink +%= work(dest[0..n], rounds);
        if (n < dest.len) break;
    }
    try report(w, "serial", total, start, now(io), sink);
}

const Packet = struct { index: u32, len: u32 };

fn consumer(io: Io, full: *Io.Queue(Packet), free: *Io.Queue(u32), pool: []u8, packet: usize, rounds: usize, sink: *u64) Io.Cancelable!void {
    while (true) {
        const p = full.getOne(io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => |e| return e,
        };
        sink.* +%= work(pool[p.index * packet ..][0..p.len], rounds);
        free.putOne(io, p.index) catch return;
    }
}

/// A demux thread and a decode thread joined by a bounded queue, as FFmpeg's
/// scheduler joins them; buffers return through a second queue.
fn queue(io: Io, w: *Io.Writer, gpa: std.mem.Allocator, path: []const u8, capacity: usize, packet: usize, rounds: usize) !void {
    const slots = capacity + 2;
    const pool = try gpa.alloc(u8, slots * packet);
    defer gpa.free(pool);
    const full_storage = try gpa.alloc(Packet, capacity);
    defer gpa.free(full_storage);
    const free_storage = try gpa.alloc(u32, slots);
    defer gpa.free(free_storage);
    var full: Io.Queue(Packet) = .init(full_storage);
    var free: Io.Queue(u32) = .init(free_storage);
    for (0..slots) |i| try free.putOne(io, @intCast(i));

    const buffer = try gpa.alloc(u8, 1 << 16);
    defer gpa.free(buffer);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const start = now(io);
    var sink: u64 = 0;
    var future = try io.concurrent(consumer, .{ io, &full, &free, pool, packet, rounds, &sink });
    var fr = file.reader(io, buffer);
    var total: u64 = 0;
    while (true) {
        const index = try free.getOne(io);
        const dest = pool[index * packet ..][0..packet];
        const n = try fr.interface.readSliceShort(dest);
        total += n;
        try full.putOne(io, .{ .index = index, .len = @intCast(n) });
        if (n < packet) break;
    }
    full.close(io);
    try future.await(io);
    try report(w, "queue", total, start, now(io), sink);
}
