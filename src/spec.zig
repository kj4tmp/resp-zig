//! The RESP protocol specificaiton.
//!
//! TODO: separate v2 and v3?

const std = @import("std");
const assert = std.debug.assert;

pub const separator = "\r\n";

pub const DataType = enum(u8) {
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

pub const Value = union(DataType) {
    simple_string: []const u8,
    simple_error: []const u8,
    integer: i64,
    bulk_string: []const u8,
    array: []const Value,
    null: void,
    bool: bool,
    double: f64,
    big_number: []const u8, // TODO: use i128 or something?
    bulk_error: []const u8,
    verbatim_string: struct {
        encoding: [3]u8,
        data: []const u8,
    },
    map: []const MapItem,
    set: []const Value,
    push: []const Value,

    pub const MapItem = struct {
        key: Value,
        value: Value,
    };
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

pub fn decodeAlloc(allocator: std.mem.Allocator, in: []const u8, max_size: usize) !Decoded(Value) {
    var fbs = std.io.fixedBufferStream(in);
    const reader = fbs.reader();
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const res = decodeRecursive(arena.allocator(), reader, max_size) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid, error.EndOfStream, error.StreamTooLong, error.InvalidCharacter, error.Overflow, error.NoSpaceLeft => return error.Invalid,
    };
    if (try fbs.getPos() != try fbs.getEndPos()) return error.InvalidRESP;
    return Decoded(Value){ .arena = arena, .value = res };
}

/// This function doesn't free. The caller is responsible for using
/// an arena.
pub fn decodeRecursive(allocator: std.mem.Allocator, reader: anytype, max_size: usize) !Value {
    const byte = try reader.readByte();
    const data_type = std.meta.intToEnum(DataType, byte) catch return error.Invalid;

    switch (data_type) {
        .simple_string => {
            var array_list = std.ArrayList(u8).init(allocator);
            defer array_list.deinit();
            try reader.streamUntilDelimiter(array_list.writer(), '\r', max_size);
            const slice = try array_list.toOwnedSlice();
            try reader.skipBytes(1, .{});
            return Value{ .simple_string = slice };
        },
        .simple_error => {
            var array_list = std.ArrayList(u8).init(allocator);
            defer array_list.deinit();
            try reader.streamUntilDelimiter(array_list.writer(), '\r', max_size);
            const slice = try array_list.toOwnedSlice();
            try reader.skipBytes(1, .{});
            return Value{ .simple_error = slice };
        },
        .integer => {
            var buf: [100]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try reader.streamUntilDelimiter(fbs.writer(), '\r', null);
            const int = try std.fmt.parseInt(i64, fbs.getWritten(), 10);
            try reader.skipBytes(1, .{});
            return Value{ .integer = int };
        },
        .bulk_string => {
            const length = try decodeElementCount(reader, i64);
            // this is stupid
            if (length == -1) {
                return Value{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const string = try allocator.alloc(u8, @intCast(length));
            try reader.readNoEof(string);
            try reader.skipBytes(2, .{});
            return Value{ .bulk_string = string };
        },
        .array => {
            const length = try decodeElementCount(reader, i64);
            if (length == -1) {
                return Value{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const array = try allocator.alloc(Value, @intCast(length));
            for (array) |*element| {
                element.* = try decodeRecursive(allocator, reader, max_size);
            }
            return Value{ .array = array };
        },
        .null => {
            try reader.skipBytes(2, .{});
            return Value{ .null = {} };
        },
        .bool => {
            const value: bool = switch (try reader.readByte()) {
                't' => true,
                'f' => false,
                else => return error.Invalid,
            };
            try reader.skipBytes(2, .{});
            return Value{ .bool = value };
        },
        .double => {
            var buf: [100]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try reader.streamUntilDelimiter(fbs.writer(), '\r', null);
            const double = try std.fmt.parseFloat(f64, fbs.getWritten());
            try reader.skipBytes(1, .{});
            return Value{ .double = double };
        },
        .big_number => {
            var array_list = std.ArrayList(u8).init(allocator);
            defer array_list.deinit();
            try reader.streamUntilDelimiter(array_list.writer(), '\r', max_size);
            const slice = try array_list.toOwnedSlice();
            try reader.skipBytes(1, .{});
            return Value{ .big_number = slice };
        },
        .bulk_error => {
            const length = try decodeElementCount(reader, i64);
            // this is stupid
            if (length == -1) {
                return Value{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const string = try allocator.alloc(u8, @intCast(length));
            try reader.readNoEof(string);
            try reader.skipBytes(2, .{});
            return Value{ .bulk_error = string };
        },
        .verbatim_string => {
            const length = try decodeElementCount(reader, i64);
            // this is stupid
            if (length == -1) {
                return Value{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const string = try allocator.alloc(u8, @intCast(length));
            try reader.readNoEof(string);
            try reader.skipBytes(2, .{});
            if (length < 4) {
                return Value{ .bulk_string = string };
            } else {
                var encoding: [3]u8 = undefined;
                @memcpy(&encoding, string[0..3]);
                return Value{ .verbatim_string = .{ .data = string[4..], .encoding = encoding } };
            }
        },
        .map => {
            const length = try decodeElementCount(reader, u64);
            if (length > max_size) return error.StreamTooLong;
            comptime assert(@TypeOf(max_size) == usize);
            assert(length <= std.math.maxInt(usize));
            const map = try allocator.alloc(Value.MapItem, @intCast(length));
            for (map) |*kv| {
                kv.key = try decodeRecursive(allocator, reader, max_size);
                kv.value = try decodeRecursive(allocator, reader, max_size);
            }
            return Value{ .map = map };
        },
        .set => {
            const length = try decodeElementCount(reader, i64);
            if (length == -1) {
                return Value{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const set = try allocator.alloc(Value, @intCast(length));
            for (set) |*element| {
                element.* = try decodeRecursive(allocator, reader, max_size);
            }
            return Value{ .set = set };
        },
        .push => {
            const length = try decodeElementCount(reader, i64);
            if (length == -1) {
                return Value{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const push = try allocator.alloc(Value, @intCast(length));
            for (push) |*element| {
                element.* = try decodeRecursive(allocator, reader, max_size);
            }
            return Value{ .push = push };
        },
    }
}

// TODO: better error naming

/// Stream data from reader to writer for one RESP Value.
/// Includes all the bytes in the RESP value, including all delimeters / separators.
pub fn streamUntilEoResp(reader: anytype, writer: anytype) !void {
    const byte = try reader.readByte();
    const data_type = std.meta.intToEnum(DataType, byte) catch return error.InvalidRESP;
    try writer.writeByte(byte);

    return switch (data_type) {
        .simple_string, .simple_error, .integer, .double, .big_number => {
            try reader.streamUntilDelimiter(writer, '\r', null);
            try writer.writeAll(separator);
            try reader.skipBytes(1, .{});
        },
        .bulk_string, .bulk_error, .verbatim_string => {
            var buf: [100]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try reader.streamUntilDelimiter(fbs.writer(), '\r', null);
            const slice = fbs.getWritten();
            try writer.writeAll(slice);
            try reader.skipBytes(1, .{});
            try writer.writeAll(separator);
            const length = try std.fmt.parseInt(i64, slice, 10);

            // this is stupid
            if (length == -1) {
                return;
            } else if (length < -1) return error.InvalidRESP;

            if (length > std.math.maxInt(usize)) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            var limited = std.io.limitedReader(reader, @intCast(length));
            const limited_reader = limited.reader();

            var fifo = std.fifo.LinearFifo(u8, .{ .Static = 128 }).init();
            try fifo.pump(limited_reader, writer);
            try reader.skipBytes(2, .{});
            try writer.writeAll(separator);
        },
        .array, .map, .set, .push => |tag| {
            var buf: [100]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try reader.streamUntilDelimiter(fbs.writer(), '\r', null);
            try writer.writeAll(fbs.getWritten());
            try reader.skipBytes(1, .{});
            try writer.writeAll(separator);
            const length = try std.fmt.parseInt(i64, fbs.getWritten(), 10);

            // this is stupid
            if (length == -1) {
                return;
            } else if (length < -1) return error.Invalid;

            if (length > std.math.maxInt(usize)) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            for (0..@intCast(length)) |_| {
                switch (tag) {
                    .array, .set, .push => try streamUntilEoResp(reader, writer),
                    .map => {
                        try streamUntilEoResp(reader, writer);
                        try streamUntilEoResp(reader, writer);
                    },
                    else => unreachable,
                }
            }
        },
        .null => {
            try reader.skipBytes(2, .{});
            try writer.writeAll(separator);
        },
        .bool => {
            try writer.writeByte(try reader.readByte());
            try reader.skipBytes(2, .{});
            try writer.writeAll(separator);
        },
    };
}

test streamUntilEoResp {
    const valid_resps: []const []const u8 = &.{
        "+OK\r\n",
        "-Error message\r\n",
        "-ERR unknown command 'asdf'\r\n",
        "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n",
        ":0\r\n",
        ":1000\r\n",
        "$5\r\nhello\r\n",
        "$0\r\n\r\n",
        "*0\r\n",
        "*2\r\n$5\r\nhello\r\n$5\r\nworld\r\n",
        "*3\r\n:1\r\n:2\r\n:3\r\n",
        "*5\r\n:1\r\n:2\r\n:3\r\n:4\r\n$5\r\nhello\r\n",
        "*2\r\n*3\r\n:1\r\n:2\r\n:3\r\n*2\r\n+Hello\r\n-World\r\n",
        "_\r\n",
        "$-1\r\n",
        "*-1\r\n",
        "*3\r\n$5\r\nhello\r\n$-1\r\n$5\r\nworld\r\n",
        "#t\r\n",
        "#f\r\n",
        ",1.23\r\n",
        ":10\r\n",
        ",10\r\n",
        ",inf\r\n",
        ",-inf\r\n",
        ",nan\r\n",
        "(3492890328409238509324850943850943825024385\r\n",
        "!21\r\nSYNTAX invalid syntax\r\n",
        "=15\r\ntxt:Some string\r\n",
        "%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n",
    };

    for (valid_resps) |resp| {
        var buf: [1000]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        var fbs_valid = std.io.fixedBufferStream(resp);
        const reader = fbs_valid.reader();
        try streamUntilEoResp(reader, writer);
        try std.testing.expectEqualSlices(u8, resp, fbs.getWritten());
    }
}

fn decodeElementCount(reader: anytype, int_type: type) !int_type {
    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try reader.streamUntilDelimiter(fbs.writer(), '\r', null);
    const slice = fbs.getWritten();
    const int = try std.fmt.parseInt(int_type, slice, 10);
    try reader.skipBytes(1, .{});
    return int;
}

test "decode push" {
    const data = ">2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    const expected: Value = .{ .push = &.{ Value{ .bulk_string = "hello" }, Value{ .bulk_string = "world" } } };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode set" {
    const data = "~2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    const expected: Value = .{ .set = &.{ Value{ .bulk_string = "hello" }, Value{ .bulk_string = "world" } } };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode map" {
    const data = "%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n";
    const expected: Value = .{ .map = &.{
        .{ .key = Value{ .simple_string = "first" }, .value = Value{ .integer = 1 } },
        .{ .key = Value{ .simple_string = "second" }, .value = Value{ .integer = 2 } },
    } };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode invalid verbatim string as bulk string" {
    const data = "=3\r\ntxt\r\n";
    const expected: Value = .{ .bulk_string = "txt" };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode empty verbatim string" {
    const data = "=4\r\ntxt:\r\n";
    const expected: Value = .{ .verbatim_string = .{ .data = "", .encoding = .{ 't', 'x', 't' } } };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode verbatim string" {
    const data = "=15\r\ntxt:Some string\r\n";
    const expected: Value = .{ .verbatim_string = .{ .data = "Some string", .encoding = .{ 't', 'x', 't' } } };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode bulk error" {
    const data = "!21\r\nSYNTAX invalid syntax\r\n";
    const expected: Value = .{ .bulk_error = "SYNTAX invalid syntax" };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode bug number" {
    const data = "(3492890328409238509324850943850943825024385\r\n";
    const expected: Value = .{ .big_number = "3492890328409238509324850943850943825024385" };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode nan" {
    const data = ",nan\r\n";
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expect(std.math.isNan(decoded.value.double));
}

test "decode -inf" {
    const data = ",-inf\r\n";
    const expected: Value = .{ .double = -std.math.inf(f64) };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode inf" {
    const data = ",inf\r\n";
    const expected: Value = .{ .double = std.math.inf(f64) };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode double" {
    const data = ",1.23\r\n";
    const expected: Value = .{ .double = 1.23 };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode true" {
    const data = "#t\r\n";
    const expected: Value = .{ .bool = true };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode false" {
    const data = "#f\r\n";
    const expected: Value = .{ .bool = false };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode null" {
    const data = "_\r\n";
    const expected: Value = .{ .null = {} };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode array" {
    const data = "*2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    const expected: Value = .{ .array = &.{ Value{ .bulk_string = "hello" }, Value{ .bulk_string = "world" } } };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode empty array" {
    const data = "*0\r\n";
    const expected: Value = .{ .array = &.{} };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode null array" {
    const data = "*-1\r\n";
    const expected: Value = .{ .null = {} };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode empty string" {
    const data = "$0\r\n\r\n";
    const expected: Value = .{ .bulk_string = "" };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode null bulk string" {
    const data = "$-1\r\n";
    const expected: Value = .{ .null = {} };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode bulk string" {
    const data = "$5\r\nhello\r\n";
    const expected: Value = .{ .bulk_string = "hello" };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode simple error" {
    const data = "-error message\r\n";
    const expected: Value = .{ .simple_error = "error message" };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode simple string" {
    const data = "+OK\r\n";
    const expected: Value = .{ .simple_string = "OK" };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode integer" {
    const data = ":-123\r\n";
    const expected: Value = .{ .integer = -123 };
    const decoded = try decodeAlloc(std.testing.allocator, data, 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "decode invalid integer" {
    const data = ":-12333333333333333333333333333333333333333333333333333333333333\r\n";
    const decoded_res = decodeAlloc(std.testing.allocator, data, 512);
    try std.testing.expectError(error.Invalid, decoded_res);
}

pub fn encodeSlice(value: Value, out: []u8) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    try encodeRecursive(value, fbs.writer());
    return fbs.getWritten();
}

pub fn encodeRecursive(value: Value, writer: anytype) !void {
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
            var length: std.meta.Int(.unsigned, @typeInfo(usize).int.bits + 1) = @intCast(payload.data.len);
            length += 4;
            try std.fmt.formatInt(length, 10, .lower, .{}, writer);
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
    const resp: Value = Value{
        .push = &.{
            Value{
                .bulk_string = "hello",
            },
            Value{
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
    const resp: Value = Value{
        .set = &.{
            Value{
                .bulk_string = "hello",
            },
            Value{
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
    const resp: Value = .{
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
    const expected = "=15\r\ntxt:Some string\r\n";
    const resp: Value = .{ .verbatim_string = .{ .data = "Some string", .encoding = .{ 't', 'x', 't' } } };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode bulk error" {
    var out: [100]u8 = undefined;
    const expected = "!5\r\nhello\r\n";
    const resp: Value = .{ .bulk_error = "hello" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode big number" {
    var out: [100]u8 = undefined;
    const expected = "(1234567890\r\n";
    const resp: Value = .{ .big_number = "1234567890" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode double" {
    var out: [100]u8 = undefined;
    const expected = ",1.23e0\r\n";
    const resp: Value = .{ .double = 1.23 };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode double nan" {
    var out: [100]u8 = undefined;
    const expected = ",nan\r\n";
    const resp: Value = .{ .double = std.math.nan(f64) };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}
test "encode double inf" {
    var out: [100]u8 = undefined;
    const expected = ",inf\r\n";
    const resp: Value = .{ .double = std.math.inf(f64) };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}
test "encode double -inf" {
    var out: [100]u8 = undefined;
    const expected = ",-inf\r\n";
    const resp: Value = .{ .double = -std.math.inf(f64) };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode array" {
    var out: [100]u8 = undefined;
    const expected = "*2\r\n$5\r\nhello\r\n$6\r\nhello2\r\n";
    const resp: Value = Value{
        .array = &.{
            Value{
                .bulk_string = "hello",
            },
            Value{
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
    const resp: Value = .{ .bulk_string = "hello" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode simple string" {
    var out: [100]u8 = undefined;
    const expected = "+hello world\r\n";
    const resp: Value = .{ .simple_string = "hello world" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode simple error" {
    var out: [100]u8 = undefined;
    const expected = "-error\r\n";
    const resp: Value = .{ .simple_error = "error" };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "encode integer" {
    var out: [100]u8 = undefined;
    const expected = ":-123\r\n";
    const resp: Value = .{ .integer = -123 };
    const slice = try encodeSlice(resp, &out);
    try std.testing.expectEqualSlices(u8, expected, slice);
}
