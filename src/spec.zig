//! The RESP protocol specificaiton.
//!
//! TODO: separate v2 and v3?

const std = @import("std");
const assert = std.debug.assert;

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
    map: []const MapItem,
    set: []const RESPType,
    push: []const RESPType,

    pub const MapItem = struct {
        key: RESPType,
        value: RESPType,
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

pub fn decodeAlloc(allocator: std.mem.Allocator, reader: anytype, max_size: usize) !Decoded(RESPType) {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const res = decodeRecursive(arena.allocator(), reader, max_size) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid, error.EndOfStream, error.StreamTooLong, error.InvalidCharacter, error.Overflow => return error.Invalid,
    };
    return Decoded(RESPType){ .arena = arena, .value = res };
}

/// This function doesn't free. The caller is responsible for using
/// an arena.
pub fn decodeRecursive(allocator: std.mem.Allocator, reader: anytype, max_size: usize) error{ OutOfMemory, Invalid, EndOfStream, StreamTooLong, InvalidCharacter, Overflow }!RESPType {
    const byte = try reader.readByte();
    const data_type = std.meta.intToEnum(DataType, byte) catch return error.Invalid;

    switch (data_type) {
        .simple_string => {
            const slice = try reader.readUntilDelimiterAlloc(allocator, '\r', max_size);
            try reader.skipBytes(1, .{});
            return RESPType{ .simple_string = slice };
        },
        .simple_error => {
            const slice = try reader.readUntilDelimiterAlloc(allocator, '\r', max_size);
            try reader.skipBytes(1, .{});
            return RESPType{ .simple_error = slice };
        },
        .integer => {
            var buf: [100]u8 = undefined;
            const slice = try reader.readUntilDelimiter(&buf, '\r');
            const int = try std.fmt.parseInt(i64, slice, 10);
            try reader.skipBytes(1, .{});
            return RESPType{ .integer = int };
        },
        .bulk_string => {
            const length = try decodeElementCount(reader, i64);
            // this is stupid
            if (length == -1) {
                return RESPType{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const string = try allocator.alloc(u8, @intCast(length));
            try reader.readNoEof(string);
            try reader.skipBytes(2, .{});
            return RESPType{ .bulk_string = string };
        },
        .array => {
            const length = try decodeElementCount(reader, i64);
            if (length == -1) {
                return RESPType{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const array = try allocator.alloc(RESPType, @intCast(length));
            for (array) |*element| {
                element.* = try decodeRecursive(allocator, reader, max_size);
            }
            return RESPType{ .array = array };
        },
        .null => {
            try reader.skipBytes(2, .{});
            return RESPType{ .null = {} };
        },
        .bool => {
            const value: bool = switch (try reader.readByte()) {
                't' => true,
                'f' => false,
                else => return error.Invalid,
            };
            try reader.skipBytes(2, .{});
            return RESPType{ .bool = value };
        },
        .double => {
            var buf: [100]u8 = undefined;
            const slice = try reader.readUntilDelimiter(&buf, '\r');
            const double = try std.fmt.parseFloat(f64, slice);
            try reader.skipBytes(1, .{});
            return RESPType{ .double = double };
        },
        .big_number => {
            const slice = try reader.readUntilDelimiterAlloc(allocator, '\r', max_size);
            try reader.skipBytes(1, .{});
            return RESPType{ .big_number = slice };
        },
        .bulk_error => {
            const length = try decodeElementCount(reader, i64);
            // this is stupid
            if (length == -1) {
                return RESPType{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const string = try allocator.alloc(u8, @intCast(length));
            try reader.readNoEof(string);
            try reader.skipBytes(2, .{});
            return RESPType{ .bulk_error = string };
        },
        .verbatim_string => {
            const length = try decodeElementCount(reader, i64);
            // this is stupid
            if (length == -1) {
                return RESPType{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const string = try allocator.alloc(u8, @intCast(length));
            try reader.readNoEof(string);
            try reader.skipBytes(2, .{});
            if (length < 4) {
                return RESPType{ .bulk_string = string };
            } else {
                var encoding: [3]u8 = undefined;
                @memcpy(&encoding, string[0..3]);
                return RESPType{ .verbatim_string = .{ .data = string[4..], .encoding = encoding } };
            }
        },
        .map => {
            const length = try decodeElementCount(reader, u64);
            if (length > max_size) return error.StreamTooLong;
            comptime assert(@TypeOf(max_size) == usize);
            assert(length <= std.math.maxInt(usize));
            const map = try allocator.alloc(RESPType.MapItem, @intCast(length));
            for (map) |*kv| {
                kv.key = try decodeRecursive(allocator, reader, max_size);
                kv.value = try decodeRecursive(allocator, reader, max_size);
            }
            return RESPType{ .map = map };
        },
        .set => {
            const length = try decodeElementCount(reader, i64);
            if (length == -1) {
                return RESPType{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const set = try allocator.alloc(RESPType, @intCast(length));
            for (set) |*element| {
                element.* = try decodeRecursive(allocator, reader, max_size);
            }
            return RESPType{ .set = set };
        },
        .push => {
            const length = try decodeElementCount(reader, i64);
            if (length == -1) {
                return RESPType{ .null = {} };
            } else if (length < -1) return error.Invalid;

            if (length > max_size) return error.StreamTooLong;
            assert(length <= std.math.maxInt(usize));
            const push = try allocator.alloc(RESPType, @intCast(length));
            for (push) |*element| {
                element.* = try decodeRecursive(allocator, reader, max_size);
            }
            return RESPType{ .push = push };
        },
    }
}

fn decodeElementCount(reader: anytype, int_type: type) !int_type {
    var buf: [100]u8 = undefined;
    const slice = try reader.readUntilDelimiter(&buf, '\r');
    const int = try std.fmt.parseInt(int_type, slice, 10);
    try reader.skipBytes(1, .{});
    return int;
}

test "decode push" {
    const data = ">2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .push = &.{ RESPType{ .bulk_string = "hello" }, RESPType{ .bulk_string = "world" } } };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode set" {
    const data = "~2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .set = &.{ RESPType{ .bulk_string = "hello" }, RESPType{ .bulk_string = "world" } } };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode map" {
    const data = "%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .map = &.{
        .{ .key = RESPType{ .simple_string = "first" }, .value = RESPType{ .integer = 1 } },
        .{ .key = RESPType{ .simple_string = "second" }, .value = RESPType{ .integer = 2 } },
    } };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode invalid verbatim string as bulk string" {
    const data = "=3\r\ntxt\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .bulk_string = "txt" };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode empty verbatim string" {
    const data = "=4\r\ntxt:\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .verbatim_string = .{ .data = "", .encoding = .{ 't', 'x', 't' } } };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode verbatim string" {
    const data = "=15\r\ntxt:Some string\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .verbatim_string = .{ .data = "Some string", .encoding = .{ 't', 'x', 't' } } };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode bulk error" {
    const data = "!21\r\nSYNTAX invalid syntax\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .bulk_error = "SYNTAX invalid syntax" };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode bug number" {
    const data = "(3492890328409238509324850943850943825024385\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .big_number = "3492890328409238509324850943850943825024385" };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode nan" {
    const data = ",nan\r\n";
    var stream = std.io.fixedBufferStream(data);
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expect(std.math.isNan(decoded.value.double));
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode -inf" {
    const data = ",-inf\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .double = -std.math.inf(f64) };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode inf" {
    const data = ",inf\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .double = std.math.inf(f64) };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode double" {
    const data = ",1.23\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .double = 1.23 };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode true" {
    const data = "#t\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .bool = true };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode false" {
    const data = "#f\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .bool = false };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode null" {
    const data = "_\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .null = {} };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode array" {
    const data = "*2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .array = &.{ RESPType{ .bulk_string = "hello" }, RESPType{ .bulk_string = "world" } } };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode empty array" {
    const data = "*0\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .array = &.{} };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode null array" {
    const data = "*-1\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .null = {} };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode empty string" {
    const data = "$0\r\n\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .bulk_string = "" };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode null bulk string" {
    const data = "$-1\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .null = {} };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode bulk string" {
    const data = "$5\r\nhello\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .bulk_string = "hello" };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode simple error" {
    const data = "-error message\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .simple_error = "error message" };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode simple string" {
    const data = "+OK\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .simple_string = "OK" };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode integer" {
    const data = ":-123\r\n";
    var stream = std.io.fixedBufferStream(data);
    const expected: RESPType = .{ .integer = -123 };
    const decoded = try decodeAlloc(std.testing.allocator, stream.reader(), 512);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(expected, decoded.value);
    try std.testing.expect(stream.pos == try stream.getEndPos());
}

test "decode invalid integer" {
    const data = ":-12333333333333333333333333333333333333333333333333333333333333\r\n";
    var stream = std.io.fixedBufferStream(data);
    const decoded_res = decodeAlloc(std.testing.allocator, stream.reader(), 512);
    try std.testing.expectError(error.Invalid, decoded_res);
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
    const expected = "=15\r\ntxt:Some string\r\n";
    const resp: RESPType = .{ .verbatim_string = .{ .data = "Some string", .encoding = .{ 't', 'x', 't' } } };
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
