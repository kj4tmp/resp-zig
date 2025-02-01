const std = @import("std");

const spec = @import("spec.zig");

const cmds = struct {};

pub const Client = struct {
    stream: std.net.Stream,

    pub fn init(stream: std.net.Stream) Client {
        return Client{ .stream = stream };
    }

    pub fn hello(self: *Client, allocator: std.mem.Allocator) !void {
        const writer = self.stream.writer();
        const reader = self.stream.reader();
        const command = spec.RESPType{ .array = &.{
            spec.RESPType{ .bulk_string = "HELLO" },
            spec.RESPType{ .bulk_string = "3" },
        } };
        try spec.encodeRecursive(command, writer);

        var buf: [4096]u8 = undefined;
        const num_bytes = try reader.read(&buf);
        var fbs = std.io.fixedBufferStream(buf[0..num_bytes]);
        const decoded = try spec.decodeAlloc(allocator, fbs.reader(), 256);
        defer decoded.deinit();

        for (decoded.value.map) |kv| {
            std.debug.print("{s}   =   ", .{kv.key.bulk_string});
            std.debug.print("{}\n", .{kv.value});
        }
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }
};

test {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6379);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();
    var client = Client.init(stream);
    try client.hello(std.testing.allocator);
}

test {
    std.testing.refAllDecls(@This());
}
