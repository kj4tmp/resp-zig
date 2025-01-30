//! The RESP protocol specificaiton.
//!
//! TODO: separate v2 and v3?

const std = @import("std");

const separator = "\r\n";

const DataType = enum(u8) {
    simple_string = '+',
    simple_error = '-',
    integer = ':',
    bulk_string = '$',
    array = '*',
    null = '_',
    bool = '#',
    double = ',',
    big_number = '(',
    bulk_error = '!',
    verbatim_string = '=',
    map = '%',
    set = '~',
    push = '>',
};

const RESPType = union(DataType) {
    simple_string: []const u8,
    simple_error: []const u8,
    integer: i64,
    bulk_string: []const u8,
    array: []const RESPType,
    null: void,
    bool: bool,
    double: f64,
    big_number: []const u8, // TODO: use i128 or something?
    bulk_error: []const u8,
    verbatim_string: struct {
        encoding: [3]u8,
        data: []const u8,
    },
    map: []const struct {
        key: RESPType,
        value: RESPType,
    },
    set: []const RESPType,
    push: []const RESPType,
};

/// Call deinit() on this to free it.
pub fn Decoded(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,
        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

pub fn decodeAlloc(allocator: std.mem.Allocator, reader: anytype) !RESPType {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const res = decodeRecursive(arena.allocator(), reader) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return error.Invalid,
        error.EndOfStream => return error.Invalid,
    };
    return Decoded(RESPType){ .arena = arena, .value = res };
}

/// This function doesn't free. The caller is responsible for using
/// an arena.
pub fn decodeRecursive(allocator: std.mem.Allocator, reader: anytype) !RESPType {
    const byte = try reader.readByte();
    const data_type = std.meta.intToEnum(DataType, byte) catch return error.Invalid;

    switch (data_type) {
        .integer => {
            try std.
            try std.fmt.parseInt(i64, buf: []const u8, 10)
        },
    }
}

test "decode integer" {
    const data = ":-123\r\n";
    const expected: RESPType = .{ .integer = -123 };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

pub fn encodeSlice(value: RESPType, out: []u8) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    try encodeRecursive(value, fbs.writer());
    return fbs.getWritten();
}

pub fn encodeRecursive(value: RESPType, writer: anytype) !void {
    switch (value) {
        inline else => |_, tag| try writer.writeByte(@intFromEnum(tag)),
    }

    switch (value) {
        .simple_string, .simple_error, .big_number => |payload| {
            try writer.writeAll(payload);
            try writer.writeAll(separator);
        },
        .integer => |payload| {
            try std.fmt.formatInt(payload, 10, .lower, .{}, writer);
            try writer.writeAll(separator);
        },
        .bulk_string, .bulk_error => |payload| {
            try std.fmt.formatInt(payload.len, 10, .lower, .{}, writer);
            try writer.writeAll(separator);
            try writer.writeAll(payload);
            try writer.writeAll(separator);
        },
        .array, .set, .push => |payload| {
            try std.fmt.formatInt(payload.len, 10, .lower, .{}, writer);
            try writer.writeAll(separator);
            for (payload) |element| {
                try encodeRecursive(element, writer);
            }
        },
        .null => try writer.writeAll(separator), // TODO: RESP2 support, null bulk strings, null arrays
        .bool => |payload| {
            switch (payload) {
                true => try writer.writeAll("t" ++ separator),
                false => try writer.writeAll("f" ++ separator),
            }
        },
        .double => |payload| {
            const buffer_size = std.fmt.format_float.bufferSize(.scientific, @TypeOf(payload));
            var buffer: [buffer_size]u8 = undefined;
            const formatted_slice = try std.fmt.formatFloat(&buffer, payload, .{ .mode = .scientific });
            try writer.writeAll(formatted_slice);
            try writer.writeAll(separator);
        },
        .verbatim_string => |payload| {
            try std.fmt.formatInt(payload.data.len, 10, .lower, .{}, writer);
            try writer.writeAll(separator);
            try writer.writeAll(&payload.encoding);
            try writer.writeByte(':');
            try writer.writeAll(payload.data);
            try writer.writeAll(separator);
        },
        .map => |payload| {
            try std.fmt.formatInt(payload.len, 10, .lower, .{}, writer);
            try writer.writeAll(separator);
            for (payload) |kv| {
                try encodeRecursive(kv.key, writer);
                try encodeRecursive(kv.value, writer);
            }
        },
    }
}

test "encode push" {
    var out: [100]u8 = undefined;
    const expected = ">2\r\n$5\r\nhello\r\n$6\r\nhello2\r\n";
    const resp: RESPType = RESPType{
        .push = &.{
            RESPType{
                .bulk_string = "hello",
            },
            RESPType{
                .bulk_string = "hello2",
            },
        },
    };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode set" {
    var out: [100]u8 = undefined;
    const expected = "~2\r\n$5\r\nhello\r\n$6\r\nhello2\r\n";
    const resp: RESPType = RESPType{
        .set = &.{
            RESPType{
                .bulk_string = "hello",
            },
            RESPType{
                .bulk_string = "hello2",
            },
        },
    };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode map" {
    var out: [100]u8 = undefined;
    const expected = "%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n";
    const resp: RESPType = .{
        .map = &.{
            .{
                .key = .{ .simple_string = "first" },
                .value = .{ .integer = 1 },
            },
            .{
                .key = .{ .simple_string = "second" },
                .value = .{ .integer = 2 },
            },
        },
    };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode verbatim string" {
    var out: [100]u8 = undefined;
    const expected = "=5\r\ntxt:hello\r\n";
    const resp: RESPType = .{ .verbatim_string = .{ .data = "hello", .encoding = .{ 't', 'x', 't' } } };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode bulk error" {
    var out: [100]u8 = undefined;
    const expected = "!5\r\nhello\r\n";
    const resp: RESPType = .{ .bulk_error = "hello" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode big number" {
    var out: [100]u8 = undefined;
    const expected = "(1234567890\r\n";
    const resp: RESPType = .{ .big_number = "1234567890" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode double" {
    var out: [100]u8 = undefined;
    const expected = ",1.23e0\r\n";
    const resp: RESPType = .{ .double = 1.23 };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode double nan" {
    var out: [100]u8 = undefined;
    const expected = ",nan\r\n";
    const resp: RESPType = .{ .double = std.math.nan(f64) };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}
test "encode double inf" {
    var out: [100]u8 = undefined;
    const expected = ",inf\r\n";
    const resp: RESPType = .{ .double = std.math.inf(f64) };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}
test "encode double -inf" {
    var out: [100]u8 = undefined;
    const expected = ",-inf\r\n";
    const resp: RESPType = .{ .double = -std.math.inf(f64) };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode array" {
    var out: [100]u8 = undefined;
    const expected = "*2\r\n$5\r\nhello\r\n$6\r\nhello2\r\n";
    const resp: RESPType = RESPType{
        .array = &.{
            RESPType{
                .bulk_string = "hello",
            },
            RESPType{
                .bulk_string = "hello2",
            },
        },
    };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode bulk string" {
    var out: [100]u8 = undefined;
    const expected = "$5\r\nhello\r\n";
    const resp: RESPType = .{ .bulk_string = "hello" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode simple string" {
    var out: [100]u8 = undefined;
    const expected = "+hello world\r\n";
    const resp: RESPType = .{ .simple_string = "hello world" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode simple error" {
    var out: [100]u8 = undefined;
    const expected = "-error\r\n";
    const resp: RESPType = .{ .simple_error = "error" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode integer" {
    var out: [100]u8 = undefined;
    const expected = ":-123\r\n";
    const resp: RESPType = .{ .integer = -123 };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}
