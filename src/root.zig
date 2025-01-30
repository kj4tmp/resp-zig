const std = @import("std");

pub const spec = @import("spec.zig");

test {
    std.testing.refAllDecls(@This());
}
