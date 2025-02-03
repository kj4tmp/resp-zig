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
        const command = spec.Value{ .array = &.{
            spec.Value{ .bulk_string = "HELLO" },
            spec.Value{ .bulk_string = "3" },
        } };
        try spec.encodeRecursive(command, writer);

        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try spec.streamUntilEoResp(reader, fbs.writer());
        const decoded = try spec.decodeAlloc(allocator, fbs.getWritten(), 256);
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
    std.testing.refAllDecls(@This());
}
