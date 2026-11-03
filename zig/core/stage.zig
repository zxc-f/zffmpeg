// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// The send/receive rules follow the contract documented in libavcodec/avcodec.h
// at the pinned reference revision; see port.md "Packets, frames and stages".
//! The send/receive contract of buffering stages: decoders, encoders and,
//! later, filters (TODO.md T14a).
//!
//! A stage takes inputs with `send` and gives outputs with `receive`:
//!
//! - `send` returns `.accepted` when it took the input, which the caller must
//!   not send again, or `.full` when it rejected it without consuming it: the
//!   caller keeps the input and must `receive` first. After `.full`, `receive`
//!   returns an output (FFmpeg's `AVERROR(EAGAIN)` on send).
//! - `receive` returns `.output`, `.need_input` (send more; FFmpeg's
//!   `AVERROR(EAGAIN)` on receive) or, once draining is complete, `.drained`
//!   (FFmpeg's `AVERROR_EOF`) on every later call. A stage never returns
//!   `.full` from `send` and `.need_input` from `receive` in the same state.
//! - `finishInput` starts draining: buffered outputs are still received, then
//!   `.drained`. It is idempotent. `send` after it fails with `InputAfterEnd`.
//! - `reset` drops buffered input, output and timing state and returns to
//!   accepting input. It is not draining.
//!
//! Each stage documents how long a received output stays valid and how inputs
//! are retained (copied, borrowed until a call, or owned).

pub const Send = enum {
    /// The stage took the input; it must not be sent again.
    accepted,
    /// The input was not consumed; receive output, then send it again.
    full,
};

/// What `receive` gives a caller.
pub fn Receive(comptime Output: type) type {
    return union(enum) {
        output: Output,
        /// No output until more input is sent.
        need_input,
        /// Draining is complete; no output will follow until `reset`.
        drained,
    };
}

pub const State = enum {
    /// Inputs are accepted.
    accepting,
    /// `finishInput` was called; buffered outputs remain.
    draining,
    /// Every output was received after `finishInput`.
    drained,
};

/// `send` after `finishInput`, before `reset`.
pub const SendError = error{InputAfterEnd};

/// Fails compilation unless `S` keeps this contract's signatures for inputs
/// of type `Input` and outputs of type `Output`: `send(*S, Input) S.Error!Send`
/// with `InputAfterEnd` in `S.Error`, `receive(*S) Receive(Output)`, and
/// `finishInput(*S) void` and `reset(*S) void`. Registries call it for every
/// stage type they list (TODO.md T16).
pub fn check(comptime S: type, comptime Input: type, comptime Output: type) void {
    comptime {
        if (@TypeOf(S.send) != fn (*S, Input) S.Error!Send) {
            @compileError(@typeName(S) ++ ".send does not have the stage signature");
        }
        // The coercion compiles only if the error is in S.Error.
        const after_end: S.Error = error.InputAfterEnd;
        if (after_end != error.InputAfterEnd) unreachable;
        if (@TypeOf(S.receive) != fn (*S) Receive(Output)) {
            @compileError(@typeName(S) ++ ".receive does not have the stage signature");
        }
        if (@TypeOf(S.finishInput) != fn (*S) void) {
            @compileError(@typeName(S) ++ ".finishInput does not have the stage signature");
        }
        if (@TypeOf(S.reset) != fn (*S) void) {
            @compileError(@typeName(S) ++ ".reset does not have the stage signature");
        }
    }
}
