// FIXME: Lets make a blocking example too

const std = @import("std");
const sphtud = @import("sphtud");
const sphws = @import("sphws.zig");

fn isWouldBlock(r: *std.net.Stream.Reader, e: anyerror) bool {
    switch (e) {
        error.ReadFailed => {
            const se = r.getError() orelse return false;
            switch (se) {
                error.WouldBlock => return true,
                else => {},
            }
        },
        else => {},
    }

    return false;
}

const WsEcho = struct {
    ws: sphws.Websocket,
    connection: *sphws.conn.Connection,

    body_buf: [4096]u8,
    timer: std.posix.fd_t,

    pub fn initPinned(self: *WsEcho, connection: *sphws.conn.Connection, rand: std.Random, host: []const u8, path: []const u8) !void {
        self.connection = connection;


        const reader = connection.reader();
        const writer = connection.writer();

        self.ws = try sphws.Websocket.init(reader, writer, host, path, rand);
        try self.connection.flush();

        self.timer = try std.posix.timerfd_create(.REALTIME, .{ .NONBLOCK = true });
        const interval = std.posix.system.itimerspec {
            .it_value = .{
                .sec = 0,
                .nsec = 1.0,
            },
            .it_interval = .{
                .sec = 1,
                .nsec = 0,
            },
        };

        try std.posix.timerfd_settime(
            self.timer,
            .{ .ABSTIME = false },
            &interval,
            null,
        );
    }

    fn handlers(self: *WsEcho) [2]sphtud.event.Loop.Handler {
        return .{
            .{
                .ptr = self,
                .vtable = &.{
                    .poll = pollWs,
                    .close = close,
                },
                .fd = self.connection.streamHandle(),
                .desired_events = .{
                    .read = true,
                    .write = false,
                },
            },
            .{
                .ptr = self,
                .vtable = &.{
                    .poll = pollTimer,
                    .close = close,
                },
                .fd = self.timer,
                .desired_events = .{
                    .read = true,
                    .write = true,
                },
            },
        };
    }

    fn pollWs(ctx: ?*anyopaque, loop: *sphtud.event.Loop, reason: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
        _ = reason;
        _ = loop;

        const self: *WsEcho = @ptrCast(@alignCast(ctx));

        while (true) {
            self.pollWsInner() catch |e| {
                if (isWouldBlock(self.connection.streamReader(), e)) {
                    return .in_progress;
                }

                std.log.err("oh no", .{});
                return .complete;
            };
        }
    }


    fn pollWsInner(self: *WsEcho) !void {
        const res = try self.ws.poll(&self.body_buf);

        // The websocket abstraction does not flush, but may try to write
        // things out. We check manually if anything was written and flush the
        // pipeline if needed
        if (self.connection.hasBufferedData()) {
            try self.connection.flush();
        }

        switch (res) {
            .initialized => {},
            // FIXME: At least indicate what we would do here, even if we don't
            // want to do it
            .redirect => {
                // Need to...
                // * re-parse URI
                // * close/open connection to new place (if host/port/scheme combo changed)
                //   * This would need to happen on a new thread, because TLS
                //     init is blocking and we don't want to block our event loop
                //     on some dumb shit
                // * re-init self.ws
                unreachable;
            },
            .frame => |f| {
                const stderr = std.fs.File.stderr();

                var stderr_buf: [4096]u8 = undefined;
                var stderr_w = stderr.writer(&stderr_buf);
                try stderr_w.interface.print("Got op {t}\n", .{f.op});

                // This guy actually has to handle non-block if it's non-blocking
                _ = try f.data.streamRemaining(&stderr_w.interface);
                try stderr_w.interface.writeAll("\n");

                try stderr_w.interface.flush();
            },
            .none => {},
        }
    }

    fn pollTimer(ctx: ?*anyopaque, loop: *sphtud.event.Loop, reason: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
        _ = reason;
        _ = loop;

        const self: *WsEcho = @ptrCast(@alignCast(ctx));

        self.pollTimerInner() catch {
            std.log.err("uh oh\n", .{});
            return .complete;
        };

        return .in_progress;
    }

    fn pollTimerInner(self: *WsEcho) !void{
        // FIXME: Better error handling
        var count: usize = 0;
        _ = try std.posix.read(self.timer, std.mem.asBytes(&count));

        self.ws.sendFrame(.{
            .op = .text,
            .data = "hello world",
        }) catch {
            std.debug.print("Cannot send yet\n", .{});
            return;
        };
        try self.connection.flush();
    }

    fn close(_: ?*anyopaque) void {
        // Close is handled by deinit, not by event loop
    }
};

pub fn main() !void {
    // I think we waste a lot of memory building the ca_bundle, but whatever.
    // We have 8M of stack space to waste
    var scratch_buf: [2 * 1024 * 1024]u8 = undefined;
    var ba = sphtud.alloc.BufAllocator.init(&scratch_buf);

    const alloc = ba.allocator();
    const scratch = ba.backLinear();

    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var rng = std.Random.DefaultPrng.init(seed);

    const uri_meta = try sphws.UriMetadata.fromString(alloc, "wss://echo.websocket.org");

    var ca_bundle = std.crypto.Certificate.Bundle{};
    try ca_bundle.rescan(alloc);

    const connection = try alloc.create(sphws.conn.Connection);

    try connection.initPinned(scratch.allocator(), ca_bundle, uri_meta);

    std.debug.print("Connected!\n", .{});

    // After the TLS handshake all blocking code has runa nd we can
    try sphtud.event.setNonblock(connection.streamHandle());

    var ws_echo: WsEcho = undefined;
    try ws_echo.initPinned(connection, rng.random(), uri_meta.host, uri_meta.path);

    var loop = try sphtud.event.Loop.init(
        alloc,
        .linear(alloc),
    );

    for (ws_echo.handlers()) |handler| {
        try loop.register(handler);
    }

    std.debug.print("Running event loop\n", .{});

    const cp = scratch.checkpoint();
    while (true) {
        scratch.restore(cp);
        try loop.wait(scratch);
    }
}
