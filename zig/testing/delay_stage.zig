// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! A controlled buffering stage that tests the send/receive contract of
//! core/stage.zig where PCM cannot (TODO.md T14a): retained input, delayed and
//! multiple outputs, backpressure, draining, reset and allocation failure.
//!
//! `DelayStage` copies each accepted packet into a bounded queue (the copy is
//! owned; the caller's packet is not retained), holds back the newest `delay`
//! inputs until `finishInput`, and gives each input as `split` output packets
//! of equal size, timestamped by a running byte count that `reset` restarts.
//! A received packet borrows the stage and stays valid until the next call.

const std = @import("std");
const stage = @import("../core/stage.zig");
const time = @import("../core/time.zig");
const Packet = @import("../core/packet.zig").Packet;

pub const DelayStage = struct {
    gpa: std.mem.Allocator,
    /// Ring buffer of owned copies; `count` items from `head`.
    queue: []Packet.Owned,
    head: usize = 0,
    count: usize = 0,
    delay: usize,
    split: usize,
    /// Outputs already given from the front item.
    parts_given: usize = 0,
    /// The front item's last output was given; free it on the next call.
    release_front: bool = false,
    /// Bytes given so far: the timing state `reset` restarts.
    next_pts: i64 = 0,
    state: stage.State = .accepting,

    pub const Error = stage.SendError || std.mem.Allocator.Error || error{
        /// The packet's size is not a multiple of `split`.
        UnevenSplit,
    };

    /// `capacity` must exceed `delay`, so a full queue always has output ready.
    pub fn init(gpa: std.mem.Allocator, capacity: usize, delay: usize, split: usize) std.mem.Allocator.Error!DelayStage {
        std.debug.assert(capacity > delay and split > 0);
        return .{ .gpa = gpa, .queue = try gpa.alloc(Packet.Owned, capacity), .delay = delay, .split = split };
    }

    pub fn deinit(s: *DelayStage) void {
        s.dropAll();
        s.gpa.free(s.queue);
        s.* = undefined;
    }

    pub fn send(s: *DelayStage, packet: Packet) Error!stage.Send {
        s.releaseGiven();
        if (s.state != .accepting) return error.InputAfterEnd;
        if (packet.data.len % s.split != 0) return error.UnevenSplit;
        if (s.count == s.queue.len) return .full;
        // On failure nothing was allocated and the queue is unchanged.
        const owned = try packet.clone(s.gpa);
        s.queue[(s.head + s.count) % s.queue.len] = owned;
        s.count += 1;
        return .accepted;
    }

    pub fn finishInput(s: *DelayStage) void {
        if (s.state == .accepting) s.state = .draining;
    }

    pub fn receive(s: *DelayStage) stage.Receive(Packet) {
        s.releaseGiven();
        const ready = s.count > s.delay or (s.state != .accepting and s.count > 0);
        if (!ready) {
            if (s.state == .accepting) return .need_input;
            s.state = .drained;
            return .drained;
        }
        const front = s.queue[s.head].packet;
        const part_len = front.data.len / s.split;
        var part = front;
        part.data = front.data[s.parts_given * part_len ..][0..part_len];
        part.pts = s.next_pts;
        part.duration = @intCast(part_len);
        s.next_pts += @intCast(part_len);
        s.parts_given += 1;
        if (s.parts_given == s.split) s.release_front = true;
        return .{ .output = part };
    }

    pub fn reset(s: *DelayStage) void {
        s.dropAll();
        s.next_pts = 0;
        s.state = .accepting;
    }

    /// Frees the front item once all its outputs were given; its last output
    /// stayed valid until this call.
    fn releaseGiven(s: *DelayStage) void {
        if (!s.release_front) return;
        s.queue[s.head].deinit();
        s.head = (s.head + 1) % s.queue.len;
        s.count -= 1;
        s.parts_given = 0;
        s.release_front = false;
    }

    fn dropAll(s: *DelayStage) void {
        while (s.count > 0) {
            s.queue[s.head].deinit();
            s.head = (s.head + 1) % s.queue.len;
            s.count -= 1;
        }
        s.head = 0;
        s.parts_given = 0;
        s.release_front = false;
    }
};

const tb: time.TimeBase = .{ .num = 1, .den = 1000 };

fn bytesPacket(data: []const u8) Packet {
    return .{ .data = data, .time_base = tb };
}

/// Receives until `.need_input` or `.drained`, appending every output's bytes.
fn collect(s: *DelayStage, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !stage.Receive(Packet) {
    while (true) {
        const result = s.receive();
        switch (result) {
            .output => |p| try out.appendSlice(gpa, p.data),
            .need_input, .drained => return result,
        }
    }
}

test "rejected input stays with the caller and a retry is consumed once" {
    const gpa = std.testing.allocator;
    var s: DelayStage = try .init(gpa, 2, 1, 1);
    defer s.deinit();
    try std.testing.expectEqual(stage.Send.accepted, try s.send(bytesPacket("a")));
    try std.testing.expectEqual(stage.Send.accepted, try s.send(bytesPacket("b")));
    try std.testing.expectEqual(stage.Send.full, try s.send(bytesPacket("c")));
    // Full means receiving makes progress.
    try std.testing.expectEqualStrings("a", s.receive().output.data);
    try std.testing.expectEqual(stage.Send.accepted, try s.send(bytesPacket("c")));
    s.finishInput();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expect(try collect(&s, &out, gpa) == .drained);
    try std.testing.expectEqualStrings("bc", out.items);
}

test "accepted input is copied, so the caller may reuse its buffer" {
    const gpa = std.testing.allocator;
    var s: DelayStage = try .init(gpa, 2, 0, 1);
    defer s.deinit();
    var buffer = [_]u8{ 'x', 'y' };
    _ = try s.send(bytesPacket(&buffer));
    buffer = .{ 'z', 'z' };
    try std.testing.expectEqualStrings("xy", s.receive().output.data);
}

test "an output is valid until the next call, and a clone keeps it longer" {
    const gpa = std.testing.allocator;
    var s: DelayStage = try .init(gpa, 2, 0, 2);
    defer s.deinit();
    _ = try s.send(bytesPacket("abcd"));
    const first = s.receive().output;
    var kept = try first.clone(gpa);
    defer kept.deinit();
    const second = s.receive().output;
    try std.testing.expectEqualStrings("cd", second.data);
    // The next call releases the item both outputs borrowed; the clone survives.
    try std.testing.expect(s.receive() == .need_input);
    try std.testing.expectEqualStrings("ab", kept.packet.data);
    try std.testing.expectEqual(0, kept.packet.pts);
    try std.testing.expectEqual(2, kept.packet.duration);
}

test "draining emits delayed output once, then stays drained" {
    const gpa = std.testing.allocator;
    var s: DelayStage = try .init(gpa, 4, 2, 2);
    defer s.deinit();
    _ = try s.send(bytesPacket("ab"));
    _ = try s.send(bytesPacket("cd"));
    // Both inputs are held back by the delay.
    try std.testing.expect(s.receive() == .need_input);
    s.finishInput();
    s.finishInput();
    try std.testing.expectError(error.InputAfterEnd, s.send(bytesPacket("ef")));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expect(try collect(&s, &out, gpa) == .drained);
    try std.testing.expectEqualStrings("abcd", out.items);
    try std.testing.expect(s.receive() == .drained);
    try std.testing.expectError(error.InputAfterEnd, s.send(bytesPacket("ef")));
}

test "reset drops buffered input and timing, and is not draining" {
    const gpa = std.testing.allocator;
    var s: DelayStage = try .init(gpa, 3, 1, 1);
    defer s.deinit();
    _ = try s.send(bytesPacket("a"));
    _ = try s.send(bytesPacket("b"));
    try std.testing.expectEqual(0, s.receive().output.pts);
    s.reset();
    // Nothing buffered survives, nothing is drained, and timing restarts.
    try std.testing.expect(s.receive() == .need_input);
    _ = try s.send(bytesPacket("c"));
    _ = try s.send(bytesPacket("d"));
    const out = s.receive().output;
    try std.testing.expectEqualStrings("c", out.data);
    try std.testing.expectEqual(0, out.pts);
    // Reset after draining accepts input again.
    s.finishInput();
    s.reset();
    try std.testing.expectEqual(stage.Send.accepted, try s.send(bytesPacket("e")));
}

test "every call makes progress or reports a defined wait, and nothing is lost" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..200) |_| {
        const capacity = random.intRangeAtMost(usize, 1, 4);
        const delay = random.intRangeLessThan(usize, 0, capacity);
        const split = random.intRangeAtMost(usize, 1, 3);
        var s: DelayStage = try .init(gpa, capacity, delay, split);
        defer s.deinit();
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);

        var sent: u8 = 0;
        const inputs = random.intRangeAtMost(u8, 0, 12);
        var steps: usize = 0;
        while (true) : (steps += 1) {
            // Each step consumes input, emits output or changes state: a
            // bounded number of steps always finishes.
            try std.testing.expect(steps < 1000);
            if (sent < inputs and random.boolean()) {
                const input: [6]u8 = @splat(sent);
                const data = input[0 .. split * 2];
                switch (try s.send(bytesPacket(data))) {
                    .accepted => {
                        try expected.appendSlice(gpa, data);
                        sent += 1;
                    },
                    // Full implies output is ready.
                    .full => switch (s.receive()) {
                        .output => |p| try got.appendSlice(gpa, p.data),
                        .need_input, .drained => return error.TestUnexpectedResult,
                    },
                }
            } else {
                if (sent == inputs) s.finishInput();
                switch (s.receive()) {
                    .output => |p| try got.appendSlice(gpa, p.data),
                    // Waiting for input implies input is accepted.
                    .need_input => if (sent < inputs) {
                        const data: [6]u8 = @splat(sent);
                        try std.testing.expectEqual(stage.Send.accepted, try s.send(bytesPacket(data[0 .. split * 2])));
                        try expected.appendSlice(gpa, data[0 .. split * 2]);
                        sent += 1;
                    },
                    .drained => break,
                }
            }
        }
        try std.testing.expectEqualSlices(u8, expected.items, got.items);
    }
}

/// A full cycle: send until full, receive part, reset, send, drain, deinit.
fn cycle(gpa: std.mem.Allocator) !void {
    var s: DelayStage = try .init(gpa, 3, 1, 2);
    defer s.deinit();
    _ = try s.send(bytesPacket("ab"));
    _ = try s.send(bytesPacket("cd"));
    _ = try s.send(bytesPacket("ef"));
    _ = s.receive();
    s.reset();
    _ = try s.send(bytesPacket("gh"));
    s.finishInput();
    while (s.receive() != .drained) {}
}

test "allocation failure at every site leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cycle, .{});
}

test "a failed send consumes nothing and leaves the stage usable" {
    var buffer: [512]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var failing: std.testing.FailingAllocator = .init(fixed.allocator(), .{ .fail_index = 1 });
    var s: DelayStage = try .init(failing.allocator(), 2, 0, 1);
    defer s.deinit();
    try std.testing.expectError(error.OutOfMemory, s.send(bytesPacket("a")));
    try std.testing.expect(s.receive() == .need_input);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(stage.Send.accepted, try s.send(bytesPacket("a")));
    try std.testing.expectEqualStrings("a", s.receive().output.data);
}
