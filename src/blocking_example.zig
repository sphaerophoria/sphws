const std = @import("std");
const sphws = @import("sphws.zig");
const sphtud = @import("sphtud");

pub fn main() !void {
    // I think we waste a lot of memory building the ca_bundle, but whatever.
    // We have 8M of stack space to waste
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var rng = std.Random.DefaultPrng.init(seed);

    const uri_meta = try sphws.UriMetadata.fromString(alloc, "wss://echo.websocket.org");

    var ca_bundle = std.crypto.Certificate.Bundle{};
    try ca_bundle.rescan(alloc);

    const connection = try alloc.create(sphtud.net.TlsStream(4096, 4096));
    const std_stream = try std.net.tcpConnectToHost(arena.allocator(), uri_meta.host, 443);
    try connection.initPinned(std_stream, uri_meta.host, ca_bundle);

    std.debug.print("Connected!\n", .{});

    var ws = try sphws.Websocket.init(connection.reader(), connection.writer(), uri_meta.host, uri_meta.path, rng.random());
    try connection.flush();

    var body_buf: [16384]u8 = undefined;
    while (true) {
        const res = try ws.poll(&body_buf);

        // The websocket abstraction does not flush, but may try to write
        // things out. We check manually if anything was written and flush the
        // pipeline if needed
        try connection.flush();

        switch (res) {
            .initialized => {
                ws.sendFrame(.{
                    .op = .text,
                    .data = "hello world",
                }) catch {};
                continue;
            },
            .redirect => {
                // Need to...
                // * re-parse URI
                // * close/open connection to new place (if host/port/scheme combo changed)
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

        std.Thread.sleep(1000000000);
        ws.sendFrame(.{
            .op = .text,
            .data = "hello world",
        }) catch {};
    }
}
