const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A simple ordered map backed by an `ArrayList`, used as the model when fuzzing `BTreeMap`.
pub fn OrderedMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { key: K, value: V };

        pub const Key = K;

        /// The ordered entries.
        entries: std.ArrayList(Entry),

        pub const empty: Self = .{ .entries = .empty };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.entries.deinit(allocator);
        }

        pub fn clear(self: *Self) void {
            self.entries.clearRetainingCapacity();
        }

        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }

        pub fn contains(self: *const Self, key: K, ctx: Context) bool {
            return self.get(key, ctx) != null;
        }

        pub fn get(self: *const Self, key: K, ctx: Context) ?V {
            const r = self.search(key, ctx);
            return if (r.found) self.entries.items[r.index].value else null;
        }

        pub fn put(self: *Self, allocator: Allocator, key: K, value: V, ctx: Context) !?V {
            const r = self.search(key, ctx);
            if (r.found) {
                const old = self.entries.items[r.index].value;
                self.entries.items[r.index].value = value;
                return old;
            }
            try self.entries.insert(allocator, r.index, .{ .key = key, .value = value });
            return null;
        }

        pub fn remove(self: *Self, key: K, ctx: Context) ?struct { K, V } {
            const r = self.search(key, ctx);
            if (!r.found) return null;
            const e = self.entries.orderedRemove(r.index);
            return .{ e.key, e.value };
        }

        /// Asserts that `map` (a `BTreeMap`) and `self` have equivalent state.
        pub fn expectEqualToMap(self: *const Self, map: anytype, ctx: Context) !void {
            try testing.expectEqual(self.count(), map.count());

            var it = map.iterator();
            for (self.entries.items) |e| {
                const key_ptr, const value_ptr = it.next() orelse {
                    std.debug.print(
                        "model has more entries than map; next model key: {any}\n",
                        .{e.key},
                    );
                    return error.TestExpectedEqual;
                };
                try testing.expectEqual(.eq, ctx.order(e.key, key_ptr.*));
                try testing.expectEqual(e.value, value_ptr.*);
            }

            if (it.next()) |kv| {
                const key_ptr, _ = kv;

                std.debug.print(
                    "map has more entries than model; extra key: {any}\n",
                    .{key_ptr.*},
                );
                return error.TestExpectedEqual;
            }
        }

        fn search(self: *const Self, key: K, ctx: Context) struct { found: bool, index: usize } {
            var lo: usize = 0;
            var hi: usize = self.entries.items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;

                switch (ctx.order(self.entries.items[mid].key, key)) {
                    .lt => lo = mid + 1,
                    .eq => return .{ .found = true, .index = mid },
                    .gt => hi = mid,
                }
            }
            return .{ .found = false, .index = lo };
        }
    };
}
