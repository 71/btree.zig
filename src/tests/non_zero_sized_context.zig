const std = @import("std");
const testing = std.testing;

const BTreeMap = @import("../BTreeMap.zig").BTreeMap;

/// A non-zero-sized context; `u8` keys map to `u64` values (too large to fit in `u8`).
const IndirectContext = struct {
    values: *const [256]u64 = blk: {
        var values: [256]u64 = undefined;

        for (0.., &values) |i, *v| v.* = i * 1000;

        const arr = values;

        break :blk &arr;
    },

    pub const empty: IndirectContext = .{};

    pub fn order(self: @This(), a: u8, b: u8) std.math.Order {
        return std.math.order(self.values[a], self.values[b]);
    }
};

test "non-zero-sized Context" {
    const Map = BTreeMap(u8, u32, IndirectContext, .{});

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    const ctx: IndirectContext = .empty;

    // Insert keys in an order that is _not_ the same as their `u64` order.
    var k: u8 = 1;
    while (true) : (k += 2) {
        try testing.expectEqual(null, try map.putContext(testing.allocator, k, k, ctx));
        if (k == 255) break;
    }
    k = 0;
    while (true) : (k += 2) {
        try testing.expectEqual(null, try map.putContext(testing.allocator, k, k, ctx));
        if (k == 254) break;
    }

    try testing.expectEqual(256, map.count());

    // Every key must be found.
    for (0..255) |i_usize| {
        const i: u8 = @intCast(i_usize);

        try testing.expectEqual(i, map.getContext(i, ctx));
    }
}
