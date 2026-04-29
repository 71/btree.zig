const std = @import("std");
const testing = std.testing;
const btree = @import("../BTreeMap.zig");

const BTreeMap = btree.BTreeMap;
const AutoContext = btree.AutoContext;
const sampleDataFor = btree.sampleDataFor;

/// Expects that `map`'s keys are `expected` in the same order.
fn expectOrder(map: anytype, expected: []const @TypeOf(map.*).Key) !void {
    try testing.expectEqual(expected.len, map.count());

    var it = map.constIterator();
    for (expected) |e| {
        const kv = it.next() orelse return error.TestExpectedEqual;
        try testing.expectEqual(e, kv.key);
    }
    try testing.expectEqual(null, it.next());
}

// -------------------------------------------------------------------------------------------------
// MARK: remove

test "remove: everything" {
    const Map = BTreeMap(usize, usize, AutoContext(usize), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    const N: usize = 40;

    for (0..N) |i| _ = try map.put(testing.allocator, i, i);
    try testing.expectEqual(N, map.count());

    // Remove all keys.
    for (0..N) |i| {
        const kv = map.remove(testing.allocator, i);

        try testing.expect(kv != null);
        try testing.expectEqual(i, kv.?.key);
        try testing.expectEqual(N - i - 1, map.count());

        for (i + 1..N) |j| {
            try testing.expectEqual(j, map.get(j));
        }
    }

    try testing.expectEqual(0, map.count());
}

test "remove: even keys" {
    const Map = BTreeMap(usize, usize, AutoContext(usize), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    const N: usize = 40;

    for (0..N) |i| _ = try map.put(testing.allocator, i, i);
    try testing.expectEqual(N, map.count());

    // Remove even keys.
    for (0..N) |i| {
        if (i % 2 == 1) continue;

        const kv = map.remove(testing.allocator, i);

        try testing.expect(kv != null);
        try testing.expectEqual(i, kv.?.key);
    }

    try testing.expectEqual(N / 2, map.count());
}

// -------------------------------------------------------------------------------------------------
// MARK: retain

test "retain: f() is called exactly len times" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{});
    const ks, const vs, const ctx = sampleDataFor(Map) catch unreachable;

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for (ks, vs) |k, v| _ = try map.putContext(testing.allocator, k, v, ctx);

    var call_count: usize = 0;
    const Counter = struct {
        count: *usize,
        fn f(self: @This(), _: u32, _: *u32) bool {
            self.count.* += 1;
            return true;
        }
    };
    map.retain(testing.allocator, Counter{ .count = &call_count }, Counter.f);
    try testing.expectEqual(map.count(), call_count);
}

test "retain: retain everything" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{});
    const ks, const vs, const ctx = sampleDataFor(Map) catch unreachable;

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for (ks, vs) |k, v| _ = try map.putContext(testing.allocator, k, v, ctx);
    const original_count = map.count();

    map.retain(testing.allocator, {}, struct {
        fn f(_: void, _: u32, _: *u32) bool {
            return true;
        }
    }.f);

    try testing.expectEqual(original_count, map.count());
    for (ks) |k| try testing.expect(map.containsContext(k, ctx));
}

test "retain: remove everything" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{});
    const ks, const vs, const ctx = sampleDataFor(Map) catch unreachable;

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for (ks, vs) |k, v| _ = try map.putContext(testing.allocator, k, v, ctx);

    map.retain(testing.allocator, {}, struct {
        fn f(_: void, _: u32, _: *u32) bool {
            return false;
        }
    }.f);

    try testing.expectEqual(0, map.count());
}

test "retain: remove even keys" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{});
    const ks, const vs, const ctx = sampleDataFor(Map) catch unreachable;

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for (ks, vs) |k, v| _ = try map.putContext(testing.allocator, k, v, ctx);

    map.retain(testing.allocator, {}, struct {
        fn f(_: void, k: u32, _: *u32) bool {
            return k % 2 != 0;
        }
    }.f);

    try testing.expectEqual(ks.len / 2, map.count());

    for (ks) |k| {
        if (k % 2 == 0) {
            try testing.expect(!map.containsContext(k, ctx));
        } else {
            try testing.expect(map.containsContext(k, ctx));
        }
    }
}

// -------------------------------------------------------------------------------------------------
// MARK: Iterator invalidation

test "iterator: removeAndMoveNext() on first entry" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k);

    var it = map.iterator();

    try testing.expectEqual(1, it.peek().?[0].*);

    // Remove first entry.
    const removed = it.removeAndMoveNext(testing.allocator);
    try testing.expectEqual(1, removed.key);

    try testing.expectEqual(2, it.peek().?[0].*);

    try expectOrder(&map, &.{ 2, 3, 4, 5, 6, 7 });
}

test "iterator: removeAndMoveNext() on last entry" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k);

    // Advance to the last entry.
    var it = map.iterator();
    for (0..6) |_| _ = it.next();

    try testing.expectEqual(7, it.peek().?[0].*);

    const removed = it.removeAndMoveNext(testing.allocator);
    try testing.expectEqual(7, removed.key);

    // Cursor must now be exhausted.
    try testing.expectEqual(null, it.peek());

    try expectOrder(&map, &.{ 1, 2, 3, 4, 5, 6 });
}

test "iterator: removeAndMoveNext() on only entry" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{});

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    _ = try map.put(testing.allocator, 42, 42);

    var it = map.iterator();
    const removed = it.removeAndMoveNext(testing.allocator);

    try testing.expectEqual(42, removed.key);
    try testing.expectEqual(null, it.peek());
    try testing.expectEqual(0, map.count());
    try testing.expectEqual(null, map.first());
}

test "iterator: removeAndMoveNext() repeatedly" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k);

    var it = map.iterator();

    try testing.expectEqual(1, it.next().?[0].*);
    try testing.expectEqual(2, it.next().?[0].*);
    try testing.expectEqual(3, it.removeAndMoveNext(testing.allocator).value);
    try testing.expectEqual(4, it.removeAndMoveNext(testing.allocator).value);
    try testing.expectEqual(5, it.next().?[0].*);
    try testing.expectEqual(6, it.removeAndMoveNext(testing.allocator).value);
    try testing.expectEqual(7, it.next().?[0].*);
    try testing.expectEqual(null, it.next());
}

test "iterator: removeAndMovePrevious() on last entry" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k);

    var it = map.iteratorFromEnd();

    try testing.expectEqual(7, it.peek().?[0].*);

    const removed = it.removeAndMovePrevious(testing.allocator);
    try testing.expectEqual(7, removed.key);

    try testing.expectEqual(6, it.peek().?[0].*);

    try expectOrder(&map, &.{ 1, 2, 3, 4, 5, 6 });
}

test "iterator: removeAndMovePrevious() on first entry" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k);

    var it = map.iteratorFromEnd();
    for (0..6) |_| _ = it.previous();

    try testing.expectEqual(1, it.peek().?[0].*);

    const removed = it.removeAndMovePrevious(testing.allocator);
    try testing.expectEqual(1, removed.key);

    try testing.expectEqual(null, it.peek());

    try expectOrder(&map, &.{ 2, 3, 4, 5, 6, 7 });
}

test "iterator: removeAndMovePrevious() on only entry" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{});

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    _ = try map.put(testing.allocator, 42, 42);

    var it = map.iteratorFromEnd();
    const removed = it.removeAndMovePrevious(testing.allocator);

    try testing.expectEqual(42, removed.key);
    try testing.expectEqual(null, it.peek());
    try testing.expectEqual(0, map.count());
    try testing.expectEqual(null, map.last());
}

test "iterator: removeAndMovePrevious() repeatedly" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k);

    var it = map.iteratorFromEnd();

    try testing.expectEqual(7, it.previous().?[0].*);
    try testing.expectEqual(6, it.previous().?[0].*);
    try testing.expectEqual(5, it.removeAndMovePrevious(testing.allocator).value);
    try testing.expectEqual(4, it.removeAndMovePrevious(testing.allocator).value);
    try testing.expectEqual(3, it.previous().?[0].*);
    try testing.expectEqual(2, it.removeAndMovePrevious(testing.allocator).value);
    try testing.expectEqual(1, it.previous().?[0].*);
    try testing.expectEqual(null, it.previous());
}

test "iterator: generation bumps on every mutating API" {
    // We cannot patch panics (short of replacing them in the whole process:
    // https://github.com/ziglang/zig/issues/1356), so instead we manually check the generation
    // before/after mutations below.
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{});

    const GenerationChecker = struct {
        map: *const Map,
        gen: u32,

        pub fn init(map: *const Map) @This() {
            return .{ .map = map, .gen = map.generation };
        }

        pub fn expectStale(self: *@This()) !void {
            try testing.expect(self.gen != self.map.generation);

            self.gen = self.map.generation;
        }

        pub fn expectUnchanged(self: *@This()) !void {
            try testing.expectEqual(self.gen, self.map.generation);
        }
    };

    // `put()` on an empty map.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);

        var checker: GenerationChecker = .init(&map);
        _ = try map.put(testing.allocator, 1, 1);
        try checker.expectStale();
    }

    // `put()` overwriting an existing key. Bumps conservatively.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);
        _ = try map.put(testing.allocator, 1, 1);

        var checker: GenerationChecker = .init(&map);
        _ = try map.put(testing.allocator, 1, 2);
        try checker.expectStale();
    }

    // `remove()`.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);
        _ = try map.put(testing.allocator, 1, 1);

        var checker: GenerationChecker = .init(&map);
        _ = map.remove(testing.allocator, 1);
        try checker.expectStale();
    }

    // `clear()` on a non-empty map.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);
        _ = try map.put(testing.allocator, 1, 1);

        var checker: GenerationChecker = .init(&map);
        map.clear(testing.allocator);
        try checker.expectStale();
    }

    // `clear()` on an empty map still bumps, for consistency.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);

        var checker: GenerationChecker = .init(&map);
        map.clear(testing.allocator);
        try checker.expectStale();
    }

    // `entry()` returning `Occupied` still bumps, because pre-emptive splits may have moved keys.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);
        _ = try map.put(testing.allocator, 1, 1);

        var checker: GenerationChecker = .init(&map);
        switch (try map.entry(testing.allocator, 1)) {
            .occupied => {},
            .vacant => unreachable,
        }
        try checker.expectStale();
    }

    // `OccupiedEntry.replace()` does not bump on its own, but the preceding `map.entry()` call
    // does. The combined effect is a single bump.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);
        _ = try map.put(testing.allocator, 1, 1);

        var checker: GenerationChecker = .init(&map);
        switch (try map.entry(testing.allocator, 1)) {
            .occupied => |e| _ = {
                try checker.expectStale();
                _ = e.replace(99);
                try checker.expectUnchanged();
            },
            .vacant => unreachable,
        }
    }

    // `retain()` that removes nothing is a pure read and does not bump.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);
        _ = try map.put(testing.allocator, 1, 1);
        _ = try map.put(testing.allocator, 2, 2);

        var checker: GenerationChecker = .init(&map);
        map.retain(testing.allocator, {}, struct {
            fn keep(_: void, _: u32, _: *u32) bool {
                return true;
            }
        }.keep);
        try checker.expectUnchanged();
    }

    // `removeAndMoveNext()` refreshes the iterator's own generation so the same iterator stays
    // usable.
    {
        var map: Map = .empty;
        defer map.deinit(testing.allocator);
        for ([_]u32{ 1, 2, 3 }) |k| _ = try map.put(testing.allocator, k, k);

        var it = map.iterator();
        const before = it.gen;
        _ = it.removeAndMoveNext(testing.allocator);

        try testing.expect(it.gen != before); // Generation changed.
        try testing.expectEqual(map.generation, it.gen); // Iterator is updated.

        // The iterator must still be usable on the surviving entries.
        const peeked = it.peek() orelse return error.TestExpectedEqual;
        try testing.expectEqual(@as(u32, 2), peeked[0].*);
    }
}

test "Iterator.removeAndMoveNext() across leaf merge" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5 }) |k| _ = try map.put(testing.allocator, k, k);

    // Walk the first few entries with `removeAndMoveNext()`; at least one removal is guaranteed to
    // trigger a merge given the minimum-sized leaves. The cursor fix-up must keep the iterator in
    // the correct in-order position.
    var it = map.iterator();

    try testing.expectEqual(1, it.removeAndMoveNext(testing.allocator).key);
    try testing.expectEqual(2, it.removeAndMoveNext(testing.allocator).key);
    try testing.expectEqual(3, it.removeAndMoveNext(testing.allocator).key);

    // Whatever remains in the iterator must match the remaining entries in order.
    try expectOrder(&map, &.{ 4, 5 });
}

test "Iterator.removeAndMovePrevious() across leaf merge" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5 }) |k| _ = try map.put(testing.allocator, k, k);

    // Walk the last few entries with `removeAndMovePrevious()`; at least one removal is guaranteed
    // to trigger a merge given the minimum-sized leaves. The cursor fix-up must keep the iterator
    // in the correct in-order position.
    var it = map.iteratorFromEnd();

    try testing.expectEqual(5, it.removeAndMovePrevious(testing.allocator).key);
    try testing.expectEqual(4, it.removeAndMovePrevious(testing.allocator).key);
    try testing.expectEqual(3, it.removeAndMovePrevious(testing.allocator).key);

    try expectOrder(&map, &.{ 1, 2 });
}

// -------------------------------------------------------------------------------------------------
// MARK: Iterator.removeUntil()

test "Iterator.removeUntilAndMoveNext() self == end is a no-op" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5 }) |k| _ = try map.put(testing.allocator, k, k);

    var begin = map.iterator();
    const end = begin;

    const removed = begin.removeUntilAndMoveNext(testing.allocator, end);

    try testing.expectEqual(0, removed);
    try testing.expectEqual(1, begin.peek().?[0].*);

    try expectOrder(&map, &.{ 1, 2, 3, 4, 5 });
}

test "Iterator.removeUntilAndMoveNext() with exhausted end removes to end of map" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k);

    var begin = map.iterator();
    for (0..2) |_| begin.moveNext();

    var end = map.iterator();
    for (0..7) |_| end.moveNext();
    try testing.expectEqual(null, end.peek());

    const removed = begin.removeUntilAndMoveNext(testing.allocator, end);

    try testing.expectEqual(5, removed);
    try testing.expectEqual(null, begin.peek());

    try expectOrder(&map, &.{ 1, 2 });
}

test "Iterator.removeUntilAndMoveNext() removes the entire map" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k);

    var begin = map.iterator();
    var end = map.iterator();
    for (0..7) |_| end.moveNext();

    const removed = begin.removeUntilAndMoveNext(testing.allocator, end);

    try testing.expectEqual(7, removed);
    try testing.expectEqual(0, map.count());
    try testing.expectEqual(null, begin.peek());
    try testing.expectEqual(null, map.first());
}

test "Iterator.removeUntilAndMoveNext() from middle to middle" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for (1..16) |k| _ = try map.put(testing.allocator, @intCast(k), @intCast(k));

    var begin = map.iterator();
    for (0..3) |_| begin.moveNext();
    try testing.expectEqual(4, begin.peek().?[0].*);

    var end = map.iterator();
    for (0..11) |_| end.moveNext();
    try testing.expectEqual(12, end.peek().?[0].*);

    const removed = begin.removeUntilAndMoveNext(testing.allocator, end);

    try testing.expectEqual(8, removed);
    try testing.expectEqual(12, begin.peek().?[0].*);
}

test "Iterator.removeUpToAndMoveNext() delete all except first two" {
    const Map = BTreeMap(usize, usize, AutoContext(usize), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for (0..10) |i| _ = try map.put(testing.allocator, i, i);

    var begin = map.iterator();
    begin.moveNext();
    begin.moveNext();

    try testing.expectEqual(8, begin.removeUpToAndMoveNext(testing.allocator, 1000));
}

test "Iterator.removeUntilAndMovePrevious() removes the entire map" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5 }) |k| _ = try map.put(testing.allocator, k, k);

    var begin = map.iterator();
    var end = map.iterator();
    for (0..5) |_| end.moveNext();

    const removed = begin.removeUntilAndMovePrevious(testing.allocator, end);

    try testing.expectEqual(5, removed);
    try testing.expectEqual(null, begin.peek());
    try testing.expectEqual(0, map.count());
}

// -------------------------------------------------------------------------------------------------
// MARK: Ordering

test "ascending, descending, and zig-zag produce the same map" {
    const Map = BTreeMap(usize, usize, AutoContext(usize), .{});

    const N: usize = 64;

    var ascending: Map = .empty;
    defer ascending.deinit(testing.allocator);
    var i: usize = 1;
    while (i <= N) : (i += 1) _ = try ascending.put(testing.allocator, i, i);

    var descending: Map = .empty;
    defer descending.deinit(testing.allocator);
    i = N;
    while (i >= 1) : (i -= 1) _ = try descending.put(testing.allocator, i, i);

    var zigzag: Map = .empty;
    defer zigzag.deinit(testing.allocator);
    var lo: usize = 1;
    var hi: usize = N;
    while (lo <= hi) {
        _ = try zigzag.put(testing.allocator, lo, lo);
        if (lo == hi) break;
        _ = try zigzag.put(testing.allocator, hi, hi);
        lo += 1;
        hi -= 1;
    }

    // All maps should be equivalent.
    try testing.expectEqual(ascending.count(), descending.count());
    try testing.expectEqual(ascending.count(), zigzag.count());

    var ait = ascending.constIterator();
    var dit = descending.constIterator();
    var zit = zigzag.constIterator();

    while (ait.next()) |a| {
        const d = dit.next() orelse return error.TestExpectedEqual;
        const z = zit.next() orelse return error.TestExpectedEqual;
        try testing.expectEqual(a.key, d.key);
        try testing.expectEqual(a.key, z.key);
    }

    try testing.expectEqual(null, dit.next());
    try testing.expectEqual(null, zit.next());
}

// -------------------------------------------------------------------------------------------------
// MARK: Entry API

test "discarding a VacantEntry leaves the map valid" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5 }) |k| _ = try map.put(testing.allocator, k, k);
    const before = map.count();

    // Take a vacant entry but never call `insert()`. The map may have allocated on the way down,
    // but from the outside it hasn't changed.
    switch (try map.entry(testing.allocator, 999)) {
        .vacant => {},
        .occupied => return error.TestExpectedEqual,
    }

    try testing.expectEqual(before, map.count());
    try testing.expect(!map.contains(999));

    try expectOrder(&map, &.{ 1, 2, 3, 4, 5 });
}

test "OccupiedEntry.replace() preserves structure and key identity" {
    const Map = BTreeMap(u32, u32, AutoContext(u32), .{ .B = 4 });

    var map: Map = .empty;
    defer map.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7 }) |k| _ = try map.put(testing.allocator, k, k * 10);
    const before = map.count();

    const entry: Map.OccupiedEntry = map.occupiedEntry(4).?;
    const key_ptr_before = entry.key_ptr;
    const old = entry.replace(999);

    try testing.expectEqual(40, old);
    try testing.expectEqual(before, map.count());
    try testing.expectEqual(999, map.get(4).?);

    // Replacing the value must not shift the key's address within the node.
    try testing.expectEqual(key_ptr_before, map.occupiedEntry(4).?.key_ptr);
}

// -------------------------------------------------------------------------------------------------
// MARK: Adapted lookup

test "Adapted: store std.ArrayList(u8), lookup with []const u8" {
    const Str = std.ArrayList(u8);

    // We need a context, even if all lookups go through the `Adapter`.
    const Ctx = struct {
        pub fn order(_: @This(), a: Str, b: Str) std.math.Order {
            return std.mem.order(u8, a.items, b.items);
        }
    };
    const Map = BTreeMap(Str, u32, Ctx, .{});

    const Adapter = struct {
        pub fn order(_: @This(), a: Str, b: anytype) std.math.Order {
            // We must support `Str` and `[]const u8`; the former for `checkInvariants()`, and the
            // latter to compare with unowned strings.
            if (@TypeOf(b) == Str) return std.mem.order(u8, a.items, b.items);
            return std.mem.order(u8, a.items, @as([]const u8, b));
        }

        pub fn toKey(
            _: @This(),
            allocator: std.mem.Allocator,
            key: []const u8,
        ) error{OutOfMemory}!Str {
            var result: Str = try .initCapacity(allocator, key.len);
            result.appendSliceAssumeCapacity(key);
            return result;
        }
    };
    const adapter: Adapter = .{};

    var map: Map = .empty;
    defer {
        var it = map.iterator();
        while (it.next()) |kv| kv[0].deinit(testing.allocator);
        map.deinit(testing.allocator);
    }

    // Insert entries: "N" -> N.
    inline for (0..8) |k| {
        var str: Str = .empty;
        try str.print(testing.allocator, "{}", .{k});

        // Insert using `[]const u8`.
        _ = try map.putAdapted(testing.allocator, str, @intCast(k), adapter);
    }

    // If the entry already exists, we shouldn't create a new key.
    _ = try map.getOrPutAdapted(testing.failing_allocator, "1", adapter);

    // Lookup using `[]const u8`.
    try testing.expectEqual(1, map.getAdapted("1", adapter));
    try testing.expectEqual(5, map.getAdapted("5", adapter));
    try testing.expectEqual(null, map.getAdapted("10", adapter));

    try testing.expect(map.containsAdapted("2", adapter));
    try testing.expect(!map.containsAdapted("20", adapter));
}
