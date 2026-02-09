const std = @import("std");
const sphtud = @import("sphtud");
const sphws = @import("sphws.zig");

const id_list = struct {
    const websocket = 1;
    const timer = 2;

};

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
    tls: *sphtud.net.TlsStream(4096, 4096),

    body_buf: [4096]u8,
    timer: std.posix.fd_t,

    pub fn initPinned(self: *WsEcho, loop: *sphtud.event.Loop2, conn: *sphtud.net.TlsStream(4096, 4096), rand: std.Random, host: []const u8, path: []const u8) !void {
        self.tls = conn;
        self.ws = try sphws.Websocket.init(conn.reader(), conn.writer(), host, path, rand);
        try conn.flush();

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

        try loop.register(.{
            .handle = self.tls.stream.handle(),
            .id = id_list.websocket,
            .read = true,
            .write = false,
        });

        try loop.register(.{
            .handle = self.timer,
            .id = id_list.timer,
            .read = true,
            .write = false,
        });
    }


    fn poll(self: *WsEcho, event: usize) !void {
        switch (event) {
            id_list.timer => try self.pollTimer(),
            id_list.websocket => {
                while (true) {
                    self.pollWsInner() catch |e| {
                        if (self.tls.isWouldBlock(e)) return;
                        return e;
                    };
                }
            },
            else => unreachable,
        }
    }


    fn pollWsInner(self: *WsEcho) !void {
        const res = try self.ws.poll(&self.body_buf);

        // The websocket abstraction does not flush, but may try to write
        // things out. We check manually if anything was written and flush the
        // pipeline if needed
        try self.tls.flush();

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
            .message => |f| {
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

    fn pollTimer(self: *WsEcho) !void{
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
        try self.tls.flush();
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

    const std_stream = try std.net.tcpConnectToHost(scratch.allocator(), uri_meta.host, 443);
    const connection = try alloc.create(sphtud.net.TlsStream(4096, 4096));
    try connection.initPinned(std_stream, uri_meta.host, ca_bundle);


    std.debug.print("Connected!\n", .{});

    // After the TLS handshake all blocking code has run
    try sphtud.event.setNonblock(connection.handle());

    var loop = try sphtud.event.Loop2.init();

    var ws_echo: WsEcho = undefined;
    try ws_echo.initPinned(&loop, connection, rng.random(), uri_meta.host, uri_meta.path);

    std.debug.print("Running event loop\n", .{});

    const cp = scratch.checkpoint();
    while (true) {
        scratch.restore(cp);

        const event = try loop.poll();
        try ws_echo.poll(event);
    }
}
