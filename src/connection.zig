const std = @import("std");
const sphws = @import("sphws.zig");

pub const Connection = union(enum) {
    clear: ClearConnection,
    tls: TlsConnection,

    // FIXME: Maybe this should take URI and an alloc and store the pieces we want? Maybe that happens one layer up
    pub fn initPinned(self: *Connection, scratch: std.mem.Allocator, ca_bundle: std.crypto.Certificate.Bundle, uri_meta: sphws.UriMetadata) !void {
        switch (uri_meta.scheme) {
            .ws => {
                self.* = .{ .clear = undefined };
                try self.clear.initPinned(scratch, uri_meta);
            },
            .wss => {
                self.* = .{ .tls = undefined };
                try self.tls.initPinned(scratch, ca_bundle, uri_meta);
            }
        }
    }

    pub fn deinit(self: *Connection) void {
        switch (self) {
            inline else => |e| return e.deinit(),
        }
    }

    pub fn streamHandle(self: *const Connection) std.posix.fd_t {
        return switch (self.*) {
            inline else => |e| e.stream.handle,
        };
    }

    pub fn streamReader(self: *Connection) *std.net.Stream.Reader{
        return switch (self.*) {
            inline else => |*e| &e.stream_reader,
        };
    }

    pub fn reader(self: *Connection) *std.Io.Reader {
        return switch (self.*) {
            .clear => |*c| c.stream_reader.interface(),
            .tls => |*t| &t.tls_client.reader,

        };
    }

    pub fn writer(self: *Connection) *std.Io.Writer {
        return switch (self.*) {
            .clear => |*c| &c.stream_writer.interface,
            .tls => |*t| &t.tls_client.writer,
        };
    }

    pub fn hasBufferedData(self: *Connection) bool {
        switch (self.*) {
            inline else => |*e| return e.hasBufferedData(),
        }
    }

    pub fn flush(self: *Connection) !void {
        switch (self.*) {
            inline else => |*e| return e.flush(),
        }
    }
};

// Basically a copy paste of the stuff in std.http.Client.Tls. Note that they
// had their write names flipped from how I would use them so I swapped them.
//
// I'm not entirely convinced on the buffer sizes, but whatever, just use what
// they used to avoid a headache
//
// FIXME: This should probably be part of the library, we might want to provide
// sphws.init("wss://...") that automatically picks tls or raw
pub const TlsConnection = struct {
    tls_read_buffer: [tls_read_buffer_len]u8,
    tls_write_buffer: [write_buffer_size]u8,

    socket_write_buffer: [tls_buffer_size]u8,
    socket_read_buffer: [tls_buffer_size]u8,

    stream: std.net.Stream,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,

    tls_client: std.crypto.tls.Client,

    const tls_buffer_size = std.crypto.tls.Client.min_buffer_len;
    const read_buffer_size = 8192;
    const write_buffer_size = 1024;

    // The TLS client wants enough buffer for the max encrypted frame
    // size, and the HTTP body reader wants enough buffer for the
    // entire HTTP header. This means we need a combined upper bound.
    const tls_read_buffer_len = tls_buffer_size + read_buffer_size;

    pub fn initPinned(self: *TlsConnection, scratch: std.mem.Allocator, ca_bundle: std.crypto.Certificate.Bundle, uri_meta: sphws.UriMetadata) !void {
        self.stream = try std.net.tcpConnectToHost(scratch, uri_meta.host, uri_meta.port);

        self.stream_reader = self.stream.reader(&self.socket_read_buffer);
        self.stream_writer = self.stream.writer(&self.socket_write_buffer);

        self.tls_client = try std.crypto.tls.Client.init(
            self.stream_reader.interface(),
            &self.stream_writer.interface,
            .{
                .host = .{ .explicit = uri_meta.host },
                .ca = .{ .bundle = ca_bundle },
                .ssl_key_log = null,
                .read_buffer = &self.tls_read_buffer,
                .write_buffer = &self.tls_write_buffer,
                // This is appropriate for HTTPS because the HTTP headers contain
                // the content length which is used to detect truncation attacks.
                .allow_truncation_attacks = true,
            },
        );
    }

    pub fn deinit(self: *TlsConnection) void {
        self.stream.close();
    }

    pub fn hasBufferedData(self: *TlsConnection) bool {
        return self.stream_writer.interface.buffered().len > 0 or
            self.tls_client.writer.buffered().len > 0;
    }


    pub fn flush(self: *TlsConnection) !void {
        try self.tls_client.writer.flush();
        try self.stream_writer.interface.flush();
    }
};

const ClearConnection = struct {
    socket_write_buffer: [4096]u8,
    socket_read_buffer: [4096]u8,

    stream: std.net.Stream,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,

    pub fn initPinned(self: *ClearConnection, scratch: std.mem.Allocator, uri_meta: sphws.UriMetadata) !void {
        self.stream = try std.net.tcpConnectToHost(scratch, uri_meta.host, uri_meta.port);

        self.stream_reader = self.stream.reader(&self.socket_read_buffer);
        self.stream_writer = self.stream.writer(&self.socket_write_buffer);
    }

    pub fn deinit(self: *ClearConnection) void {
        self.stream.close();
    }

    pub fn hasBufferedData(self: *ClearConnection) bool {
        return self.stream_writer.interface.buffered().len > 0;
    }

    pub fn flush(self: *ClearConnection) !void {
        try self.stream_writer.interface.flush();
    }
};


