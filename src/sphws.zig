/// Websocket abstraction
///
/// Generally tries to keep the reader in a consistent state on read failures.
/// Write failures probably leave the stream in an inconsistent state and
/// should result in the connection being torn down
const std = @import("std");

pub const conn = @import("connection.zig");

pub const Websocket = struct {
    state: union(enum) {
        wait_http_response: AcceptKey,
        default,
        outstanding_data: MaskedReader,
    },
    rand: std.Random,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    pub fn init(reader: *std.Io.Reader, writer: *std.Io.Writer, host: []const u8, path: []const u8, random: std.Random) !Websocket {
        const accept_key = try sendWsUpgradeReq(writer, host, path, random);

        return .{
            .state = .{ .wait_http_response = accept_key },
            .rand = random,
            .reader = reader,
            .writer = writer,
        };
    }

    pub const PollResponse = union(enum) {
        initialized,
        redirect: []const u8,
        frame: Frame,
        none,
    };

    // reader_buf needs to be big enough to hold the largest ping data packet.
    // Technically this can be any size, but surely your endpoint will be
    // sending something relatively small in their pings
    pub fn poll(self: *Websocket, reader_buf: []u8) !PollResponse {
        return self.pollInner(reader_buf);
    }

    const HttpResponse = struct {
        header: std.http.Client.Response.Head,
        body: []const u8,
    };

    fn pollHttpResponse(r: *std.Io.Reader) !HttpResponse {
        // This is relatively inefficient and stupid, but will happen one time on ws
        // init. This shouldn't be a major noticeable part of our runtime so just leave
        // the stupidest impl we could think of here

        var header_end: usize = 0;
        var header: std.http.Client.Response.Head = undefined;

        // Parse head
        while (true) {
            const buf = r.buffered();
            header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
                try r.fillMore();
                continue;
            };
            header_end += 4;

            header = try .parse(buf[0..header_end]);
            break;
        }

        // Buffer body
        while (true) {
            const buf = r.buffered();
            const content_len = header.content_length orelse 0;

            const desired_len = header_end + content_len;
            if (buf.len >= desired_len) {
                r.toss(desired_len);
                return .{
                    .header = header,
                    .body = buf[header_end..][0..content_len],
                };
            }
            try r.fillMore();
        }
    }

    fn pollInner(self: *Websocket, reader_buf: []u8) !PollResponse {
        while (true) {
            switch (self.state) {
                .wait_http_response => |accept_key| {
                    const response = try pollHttpResponse(self.reader);

                    if (response.header.status.class() == .redirect) {
                        const loc = response.header.location orelse return error.MissingHeader;
                        return .{ .redirect = loc };
                    }

                    try validateUpgrade(response, &accept_key);

                    self.state = .default;

                    return .initialized;
                },
                .default => switch (try self.pollInitialized(reader_buf)) {
                    .cont => continue,
                    .wait => return .none,
                    .frame => |f| return .{ .frame = f },
                },
                .outstanding_data => |*mr| {
                    _ = try mr.inner.interface.discardRemaining();
                    self.state = .default;
                },
            }
        }
    }

    fn validateUpgrade(response: HttpResponse, expected_accept: *const AcceptKey) !void {
        if (response.header.status != .switching_protocols) return error.InvalidStatusCode;

        var accepted_field_present = false;
        var header_it = response.header.iterateHeaders();
        var lower_buf: [128]u8 = undefined;

        while (header_it.next()) |header|{
            const lower_name = std.ascii.lowerString(&lower_buf, header.name);

            if (std.mem.eql(u8, lower_name, "sec-websocket-accept")) {
                accepted_field_present = true;
                var decoded: [expected_accept.len]u8 = undefined;
                std.base64.standard.Decoder.decode(&decoded, header.value) catch return error.InvalidAccept;

                if (!std.mem.eql(u8, expected_accept, &decoded)) {
                    return error.InvalidAccept;
                }
            }
        }

        if (!accepted_field_present) {
            return error.NoAcceptHeader;
        }

    }
    pub const Op = union(enum) {
        continuation,
        text,
        binary,
        close,
        unknown: u4,
    };

    pub const WsFrameOptions = struct {
        op: Op,
        data: []const u8,
    };

    fn canSend(self: *Websocket) bool {
        return switch (self.state) {
            .default, .outstanding_data => true,
            .wait_http_response => false,
        };
    }

    pub fn sendFrame(self: *Websocket, options: WsFrameOptions) !void {
        if (!self.canSend()) return error.Uninitialized;
        return self.sendFrameInternal(.fromOp(options.op), options.data);
    }

    fn sendFrameHeader(w: *std.Io.Writer, op: ProtocolOp, data_len: usize, rand: std.Random) !MaskingKey {
        const common_len: u7 = switch (data_len) {
            0...125 => @intCast(data_len),
            126...std.math.maxInt(u16) => 126,
            std.math.maxInt(u16) + 1...std.math.maxInt(u64) => 127,
        };

        // For now we hardcode fin, it's likely that we will need to expose this at
        // some point
        try w.writeStruct(WsCommonHeader{
            .fin = 1,
            .rsv1 = 0,
            .rsv2 = 0,
            .rsv3 = 0,
            .op = op,
            .payload_len = common_len,
            .mask = 1,
        }, .big);

        const masking_key = blk: {
            var masking_key: MaskingKey = undefined;
            rand.bytes(&masking_key);
            break :blk masking_key;
        };

        switch (common_len) {
            0...125 => {},
            126 => {
                try w.writeInt(u16, @intCast(data_len), .big);
            },
            127 => {
                try w.writeInt(u64, @intCast(data_len), .big);
            },
        }

        try w.writeAll(&masking_key);

        return masking_key;
    }

    fn sendFrameInternal(self: *Websocket, op: ProtocolOp, data: []const u8) !void {
        var w = self.writer;

        const masking_key = try sendFrameHeader(w, op, data.len, self.rand);

        for (data, 0..) |b, i| {
            try w.writeByte(b ^ masking_key[i % 4]);
        }
    }

    const Frame = struct {
        op: Op,
        data: *std.Io.Reader,
    };

    const WsHeader = struct {
        fin: bool,
        op: ProtocolOp,
        len: usize,
        mask: MaskingKey,

        const min_size = 2;

        fn read(r: *std.Io.Reader) !WsHeader {
            const common = try r.takeStruct(WsCommonHeader, .big);

            const len = switch (common.payload_len) {
                0...125 => common.payload_len,
                126 => try r.takeInt(u16, .big),
                127 => try r.takeInt(u64, .big),
            };

            var mask: MaskingKey = @splat(0);
            if (common.mask == 1) {
                mask = (try r.takeArray(4)).*;
            }

            return .{
                .fin = common.fin == 1,
                .op = common.op,
                .len = len,
                .mask = mask,
            };
        }
    };

    const PollInitializedResponse = union(enum) {
        frame: Frame,
        cont,
        wait,
    };

    const RequiredData = struct {
        header: WsHeader,
        data: []const u8,
    };

    /// Reads data that is required to be available before we consider acting. This
    /// is a variable sized read depending on the data
    ///
    /// e.g. of cases where we will not return
    /// * WsCommonHeader is available but payload/mask are not
    /// * Entire header is available, but we do not have sufficient data to respond
    ///   to a ping
    fn readRequired(r: *std.Io.Reader) !RequiredData {
        while (true) {
            return readRequiredInner(r) catch |e| switch (e) {
                error.EndOfStream => {
                    try r.fillMore();
                    continue;
                },
                else => return e,
            };
        }
    }

    fn readRequiredInner(r: *std.Io.Reader) !RequiredData {
        const buf = try r.peekGreedy(WsHeader.min_size);

        var fixed = std.Io.Reader.fixed(buf);

        const header = try WsHeader.read(&fixed);

        var data: []const u8 = &.{};

        // If we get a ping, we require the entire data to be available to us
        // before we send the pong. Otherwise external callers may see us in an
        // inconsistent state
        if (header.op == .ping) {
            data = try fixed.take(header.len);
        }

        r.toss(fixed.seek);

        return .{
            .header = header,
            .data = data,
        };
    }

    fn pollInitialized(self: *Websocket, reader_buf: []u8) !PollInitializedResponse {
        const r = self.reader;

        const required = try readRequired(r);

        const masked_reader = MaskedReader{
            .inner = r.limited(.limited(required.header.len), &.{}),
            .reader = .{
                .buffer = reader_buf,
                .seek = 0,
                .end = 0,
                .vtable = &.{
                    .stream = MaskedReader.stream,
                    .discard = MaskedReader.discard,
                },
            },
            // Could special case missing mask for easier piping but for now does
            // not feel necessary
            .mask = required.header.mask,
            .i = 0,
        };

        const out_op: Op = switch (required.header.op) {
            .continuation => .continuation,
            .text => .text,
            .binary => .binary,
            .close => .close,
            .ping => {
                try self.sendFrameInternal(.pong, required.data);
                return .cont;
            },
            else => |t| .{ .unknown = @intFromEnum(t) },
        };

        // We expect all the data to be passed to the user directly through the
        // masked reader. If we make it here and we read any data as part of our
        // initial read that is a mistake
        std.debug.assert(required.data.len == 0);

        self.state = .{ .outstanding_data = masked_reader };

        return .{ .frame = .{
            .op = out_op,
            .data = &self.state.outstanding_data.reader,
        } };
    }

    const MaskedReader = struct {
        inner: std.Io.Reader.Limited,
        reader: std.Io.Reader,
        mask: MaskingKey,
        i: usize,

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *MaskedReader = @fieldParentPtr("reader", r);

            const out = limit.slice(try w.writableSliceGreedy(1));
            const read_bytes = try self.inner.interface.readSliceShort(out);

            if (read_bytes == 0) return error.EndOfStream;

            for (out[0..read_bytes], self.i..) |*b, i| {
                b.* = b.* ^ self.mask[i % self.mask.len];
            }
            self.i += read_bytes;

            w.advance(read_bytes);

            return read_bytes;
        }

        fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
            const self: *MaskedReader = @fieldParentPtr("reader", r);

            const discarded = try self.inner.interface.discard(limit);
            self.i += discarded;

            return discarded;
        }
    };

    const ProtocolOp = enum(u4) {
        continuation = 0,
        text = 1,
        binary = 2,
        close = 8,
        ping = 9,
        pong = 10,
        _,

        fn fromOp(op: Op) ProtocolOp {
            return switch (op) {
                .continuation => .continuation,
                .text => .text,
                .binary => .binary,
                .close => .close,
                .unknown => |t| @enumFromInt(t),
            };
        }
    };

    const WsCommonHeader = packed struct(u16) {
        payload_len: u7,
        mask: u1,
        op: ProtocolOp,
        rsv3: u1,
        rsv2: u1,
        rsv1: u1,
        fin: u1,
    };

    const MaskingKey = [4]u8;

    const WebsocketKey = [std.base64.standard.Encoder.calcSize(16)]u8;
    const AcceptKey = [std.crypto.hash.Sha1.digest_length]u8;

    pub fn makeSecWebsocketKey(rng: std.Random) WebsocketKey {
        var buf: WebsocketKey = undefined;
        var rand_val: [16]u8 = undefined;
        rng.bytes(&rand_val);
        _ = std.base64.standard.Encoder.encode(&buf, &rand_val);
        return buf;
    }

    pub fn genAcceptKey(key: *const WebsocketKey) AcceptKey {
        var ret: AcceptKey = undefined;

        const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key);
        sha1.update(guid);
        sha1.final(&ret);
        return ret;
    }

    fn sendWsUpgradeReq(w: *std.Io.Writer, host: []const u8, path: []const u8, rand: std.Random) !AcceptKey {
        const sec_websocket_key = makeSecWebsocketKey(rand);

        const send_path = if (path.len > 0) path else "/";

        try w.print("GET {[path]s} HTTP/1.1\r\n" ++
            "Host: {[host]s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {[sec_websocket_key]s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n", .{
            .host = host,
            .path = send_path,
            .sec_websocket_key = sec_websocket_key,
        });

        return genAcceptKey(&sec_websocket_key);
    }

    fn readerWriter(reader: *std.Io.Reader) std.Io.Writer {
        return std.Io.Writer{
            .buffer = reader.buffer,
            .end = reader.end,
            .vtable = &.{ .drain = std.Io.Writer.fixedDrain },
        };
    }

    const Fixture = struct {
        read_buf: [1 * 1024 * 1024]u8,
        write_buf: [1 * 1024 * 1024]u8,
        reader_buf: [1 * 1024 * 1024]u8,

        // Where the websocket reads from
        reader: std.Io.Reader,
        // Writer for the reader above
        rw: std.Io.Writer,

        // Where the websocket writes to
        writer: std.Io.Writer,

        rng: std.Random.DefaultPrng,
        ws: Websocket,

        pub fn initPinnedNoInitResponse(self: *Fixture) !void {
            self.rng = std.Random.DefaultPrng.init(0);
            self.reader = std.Io.Reader.fixed(&self.read_buf);
            self.reader.end = 0;
            self.writer = std.Io.Writer.fixed(&self.write_buf);
            self.rw = .{
                .buffer = self.reader.buffer,
                .end = self.reader.end,
                .vtable = &.{ .drain = std.Io.Writer.fixedDrain },
            };
            self.ws = try Websocket.init(&self.reader, &self.writer, "example.com", "/websocket", self.rng.random());
            self.rw = readerWriter(&self.reader);
        }

        pub fn initPinned(self: *Fixture) !void {
            try self.initPinnedNoInitResponse();
            try std.testing.expectEqualStrings(
                "GET /websocket HTTP/1.1\r\n" ++
                    "Host: example.com\r\n" ++
                    "Upgrade: websocket\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Sec-WebSocket-Key: 3yMLSWFdF1MH1YDDPW/aYQ==\r\n" ++
                    "Sec-WebSocket-Version: 13\r\n" ++
                    "\r\n",
                self.ws.writer.buffered(),
            );

            self.ws.writer.end = 0;


            try self.rw.writeAll("HTTP/1.1 101 Switching Protocols\r\n" ++
                "Connection: upgrade\r\n" ++
                "Date: Sun, 01 Feb 2026 04:22:32 GMT\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Sec-WebSocket-Accept: 9bQuZIN64KrRsqgxuR1CxYN94zQ=\r\n" ++
                "X-Cache: Miss from clou");

            self.reader.end = self.rw.end;

            try std.testing.expectError(error.EndOfStream, self.ws.poll(&self.reader_buf));

            // On error nothing should have been consumed
            try std.testing.expectEqual(0, self.reader.seek);

            try self.rw.writeAll("dfront\r\n" ++
                "Via: 1.1 7f87c3226337683c77e598f9242c4036.cloudfront.net (CloudFront)\r\n" ++
                "X-Amz-Cf-Pop: YVR52-P3\r\n" ++
                "X-Amz-Cf-Id: 1qOctC_4OPKl4ZXjIEljt0selp3eGx4F7If3IcyKbCfZ0rHvkt3XVQ==\r\n" ++
                "\r\n");

            self.reader.end = self.rw.end;

            {
                const response = try self.ws.poll(&self.reader_buf);
                try std.testing.expect(response == .initialized);
            }

            // Initialization handshake complete
            try std.testing.expect(self.ws.state == .default);

            {
                const response = self.ws.poll(&self.reader_buf);
                // Still nothing for us to see
                try std.testing.expectError(error.EndOfStream, response);
            }
        }
    };

    test "read sanity" {
        var fixture: Fixture = undefined;
        try fixture.initPinned();

        try fixture.rw.writeStruct(
            WsCommonHeader{
                .fin = 1,
                .op = .text,
                .payload_len = 12,
                .rsv1 = 0,
                .rsv2 = 0,
                .rsv3 = 0,
                .mask = 1,
            },
            .big,
        );

        const mask: []const u8 = &.{ 0xca, 0xfe, 0xf0, 0x0d };
        try fixture.rw.writeAll(mask);
        for ("hello world", 0..) |b, i| {
            try fixture.rw.writeByte(b ^ mask[i % 4]);
        }

        // First only give it a half read
        fixture.reader.end += 2;

        {
            const response = fixture.ws.poll(&fixture.reader_buf);
            try std.testing.expectError(error.EndOfStream, response);
        }

        // Now give it the full header
        fixture.reader.end += 4;

        {
            const response = try fixture.ws.poll(&fixture.reader_buf);
            try std.testing.expect(response == .frame);

            var data_buf: [10]u8 = undefined;
            {
                const data_res = try response.frame.data.readSliceShort(&data_buf);
                // No data available
                try std.testing.expectEqual(0, data_res);
            }

            std.debug.assert(fixture.reader.end == fixture.reader.seek);

            // A little bit of the data
            fixture.reader.end += 5;

            {
                const data_res = try response.frame.data.readSliceShort(&data_buf);
                try std.testing.expectEqualStrings("hello", data_buf[0..data_res]);
            }

            // And now the rest
            fixture.reader.end = fixture.rw.end;

            {
                const data_res = try response.frame.data.readSliceShort(&data_buf);
                // And the rest
                try std.testing.expectEqualStrings(" world", data_buf[0..data_res]);
            }
        }

        {
            const response = fixture.ws.poll(&fixture.reader_buf);
            try std.testing.expectError(error.EndOfStream, response);
            // Should be ready to read again
            try std.testing.expectEqual(fixture.ws.state, .default);
        }
    }

    test "ping pong" {
        var fixture: Fixture = undefined;
        try fixture.initPinned();

        try fixture.rw.writeStruct(
            WsCommonHeader{
                .fin = 1,
                .op = .ping,
                .payload_len = 5,
                .rsv1 = 0,
                .rsv2 = 0,
                .rsv3 = 0,
                .mask = 0,
            },
            .big,
        );

        try fixture.rw.writeAll(
            "hello",
        );

        // Full header available, but data is not present yet
        fixture.reader.end += 4;

        {
            const res = fixture.ws.poll(&fixture.reader_buf);
            try std.testing.expectError(error.EndOfStream, res);
        }

        // We should see no change in the writer buf because we have only received half a ping
        try std.testing.expectEqual(0, fixture.writer.end);

        // Full ping message available
        fixture.reader.end = fixture.rw.end;

        {
            const res = fixture.ws.poll(&fixture.reader_buf);
            try std.testing.expectError(error.EndOfStream, res);
        }

        var wr = std.Io.Reader.fixed(fixture.writer.buffered());

        const header = try wr.takeStruct(WsCommonHeader, .big);
        try std.testing.expectEqual(.pong, header.op);

        const mask = try wr.take(4);
        const pong_data = try wr.take(5);
        for (pong_data, 0..) |*b, i| {
            b.* ^= mask[i % 4];
        }
        try std.testing.expectEqualStrings("hello", pong_data);
    }

    test "unsupported opcode" {
        var fixture: Fixture = undefined;
        try fixture.initPinned();

        try fixture.rw.writeStruct(
            WsCommonHeader{
                .fin = 1,
                .op = @enumFromInt(5),
                .payload_len = 0,
                .rsv1 = 0,
                .rsv2 = 0,
                .rsv3 = 0,
                .mask = 0,
            },
            .big,
        );

        fixture.reader.end = fixture.rw.end;

        {
            const res = try fixture.ws.poll(&fixture.reader_buf);
            try std.testing.expect(res == .frame);
            try std.testing.expect(res.frame.op == .unknown);
            try std.testing.expectEqual(5, res.frame.op.unknown);
        }
    }

    test "redirect" {
        var fixture: Fixture = undefined;
        try fixture.initPinnedNoInitResponse();

        try fixture.rw.writeAll(
            "HTTP/1.1 302 Some redirect\r\n" ++
            "Location: /websocket2\r\n" ++
            "Date: Sun, 01 Feb 2026 04:22:32 GMT\r\n" ++
            "\r\n"
        );

        fixture.reader.end = fixture.rw.end;


        const res = try fixture.ws.poll(&fixture.reader_buf);
        try std.testing.expect(res == .redirect);
        try std.testing.expectEqualStrings("/websocket2", res.redirect);
    }

    test "connection invalid status" {
        var fixture: Fixture = undefined;
        try fixture.initPinnedNoInitResponse();

        try fixture.rw.writeAll(
            "HTTP/1.1 200 OK\r\n" ++
            "Location: /websocket2\r\n" ++
            "Date: Sun, 01 Feb 2026 04:22:32 GMT\r\n" ++
            "\r\n"
        );

        fixture.reader.end = fixture.rw.end;

        const res = fixture.ws.poll(&fixture.reader_buf);
        try std.testing.expectError(error.InvalidStatusCode, res);
    }

    test "connection missing accept" {
        var fixture: Fixture = undefined;
        try fixture.initPinnedNoInitResponse();

        try fixture.rw.writeAll(
            "HTTP/1.1 101 Upgrade time\r\n" ++
            "Location: /websocket2\r\n" ++
            "Date: Sun, 01 Feb 2026 04:22:32 GMT\r\n" ++
            "\r\n"
        );

        fixture.reader.end = fixture.rw.end;

        const res = fixture.ws.poll(&fixture.reader_buf);
        try std.testing.expectError(error.NoAcceptHeader, res);
    }

    test "connection invalid accept not base64" {
        var fixture: Fixture = undefined;
        try fixture.initPinnedNoInitResponse();

        try fixture.rw.writeAll(
            "HTTP/1.1 101 Upgrade time\r\n" ++
            "Location: /websocket2\r\n" ++
            "Date: Sun, 01 Feb 2026 04:22:32 GMT\r\n" ++
            "Sec-WebSocket-Accept: hello\r\n" ++
            "\r\n"
        );

        fixture.reader.end = fixture.rw.end;

        const res = fixture.ws.poll(&fixture.reader_buf);
        try std.testing.expectError(error.InvalidAccept, res);
    }

    test "connection invalid accept replay" {
        var fixture: Fixture = undefined;
        try fixture.initPinnedNoInitResponse();

        try fixture.rw.writeAll(
            "HTTP/1.1 101 Upgrade time\r\n" ++
            "Location: /websocket2\r\n" ++
            "Date: Sun, 01 Feb 2026 04:22:32 GMT\r\n" ++
            "Sec-WebSocket-Accept: mKllBAplNaSygANYWdgPLtojp5k=\r\n" ++
            "\r\n"
        );

        fixture.reader.end = fixture.rw.end;

        const res = fixture.ws.poll(&fixture.reader_buf);
        try std.testing.expectError(error.InvalidAccept, res);
    }
};


pub const WsScheme = enum {
    ws,
    wss,

    pub fn fromUri(uri: std.Uri) !WsScheme {
        return std.meta.stringToEnum(WsScheme, uri.scheme) orelse return error.UnknownScheme;

    }
};

pub fn resolveWsPort(uri: std.Uri) !u16 {
    if (uri.port) |p| return p;

    const scheme = try WsScheme.fromUri(uri);
    switch (scheme) {
        .ws => return 80,
        .wss => return 443,
    }
}

pub const UriMetadata = struct {
    host: []const u8,
    scheme: WsScheme,
    port: u16,
    path: []const u8,

    pub fn fromString(alloc: std.mem.Allocator, s: []const u8) !UriMetadata {
        const uri = try std.Uri.parse(s);
        return .fromUri(alloc, uri);
    }

    pub fn fromUri(alloc: std.mem.Allocator, uri: std.Uri) !UriMetadata {
        return .{
            .host = try uri.getHostAlloc(alloc),
            .port = try resolveWsPort(uri),
            .path = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(uri.path, .formatEscaped)}),
            .scheme = try WsScheme.fromUri(uri),
        };
    }
};
