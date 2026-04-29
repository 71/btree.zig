const std = @import("std");
const testing = std.testing;
const btree = @import("../BTreeMap.zig");

const BTreeMap = btree.BTreeMap;
const Options = btree.Options;
const AutoContext = btree.AutoContext;

const OrderedMap = @import("OrderedMap.zig").OrderedMap;

/// Range of distinct keys/values used for the fuzzed operations. Kept small to drive frequent
/// collisions, splits, and merges.
const max_key = 50;

// -------------------------------------------------------------------------------------------------
// MARK: Op

/// One operation the fuzzer may perform, together with the operands needed to perform it.
const Op = union(enum) {
    get: struct { index: u16 },
    get_ptr: struct { index: u16 },
    contains: struct { index: u16 },

    first,
    last,

    iterate,

    clear,

    put: struct { index: u16 },
    put_get_or_put: struct { index: u16 },
    put_get_or_put_value: struct { index: u16 },

    put_entry: struct { index: u16 },
    put_entry_vacant_discard: struct { index: u16 },
    replace_via_occupied_entry: struct { index: u16, new_index: u16 },

    mutate_via_get_ptr: struct { index: u16, new_index: u16 },

    remove: struct { index: u16 },
    remove_occupied_entry: struct { index: u16 },

    /// Remove the smallest entry with `firstEntry().remove()`.
    remove_first_entry,
    /// Remove the largest entry with `lastEntry().remove()`.
    remove_last_entry,

    remove_and_move_next: struct { skip: u16, remove: u16, batch: bool },
    remove_and_move_previous: struct { skip: u16, remove: u16 },

    /// Keep entries whose key is below `ks[threshold]`.
    retain: struct { threshold: u16 },

    fn fromSmith(smith: *testing.Smith) Op {
        const tag = smith.value(std.meta.Tag(Op));

        return switch (tag) {
            inline else => |t| blk: {
                const Payload = @FieldType(Op, @tagName(t));

                if (Payload == void)
                    break :blk @unionInit(Op, @tagName(t), {});

                var payload: Payload = undefined;
                inline for (@typeInfo(Payload).@"struct".fields) |f| {
                    @field(payload, f.name) =
                        if (f.type == bool)
                            smith.value(bool)
                        else
                            smith.valueRangeLessThan(f.type, 0, max_key);
                }
                break :blk @unionInit(Op, @tagName(t), payload);
            },
        };
    }
};

// -------------------------------------------------------------------------------------------------
// MARK: perform()

/// Performs the operation `op` on `map` and `model`.
fn perform(
    comptime K: type,
    comptime V: type,
    comptime C: type,
    comptime options: Options,
    allocator: std.mem.Allocator,
    map: *BTreeMap(K, V, C, options),
    model: *OrderedMap(K, V, C),
    op: Op,
) !void {
    const ks = btree.sampleKeys(K, max_key) catch unreachable;
    const vs = btree.sampleValues(V, max_key) catch unreachable;
    const ctx = btree.sampleContext(C);

    switch (op) {
        .get => |args| {
            const k = ks[args.index];

            try testing.expectEqual(model.get(k, ctx), map.getContext(k, ctx));
        },
        .get_ptr => |args| {
            const k = ks[args.index];
            const model_v = model.get(k, ctx);

            if (map.getPtrContext(k, ctx)) |ptr| {
                try testing.expect(model_v != null);
                try testing.expectEqual(model_v.?, ptr.*);
            } else {
                try testing.expectEqual(null, model_v);
            }
        },
        .contains => |args| {
            const k = ks[args.index];

            try testing.expectEqual(model.contains(k, ctx), map.containsContext(k, ctx));
        },

        .first => {
            const items = model.entries.items;

            if (items.len == 0) {
                try testing.expectEqual(null, map.first());
                try testing.expectEqual(null, map.firstEntry());
            } else {
                const expected = items[0];
                const got = map.first().?;
                try testing.expectEqual(.eq, ctx.order(expected.key, got.key));
                try testing.expectEqual(expected.value, got.value);
                const e = map.firstEntry().?;
                try testing.expectEqual(.eq, ctx.order(expected.key, e.key_ptr.*));
                try testing.expectEqual(expected.value, e.value_ptr.*);
            }
        },
        .last => {
            const items = model.entries.items;

            if (items.len == 0) {
                try testing.expectEqual(null, map.last());
                try testing.expectEqual(null, map.lastEntry());
            } else {
                const expected = items[items.len - 1];
                const got = map.last().?;
                try testing.expectEqual(.eq, ctx.order(expected.key, got.key));
                try testing.expectEqual(expected.value, got.value);
                const e = map.lastEntry().?;
                try testing.expectEqual(.eq, ctx.order(expected.key, e.key_ptr.*));
                try testing.expectEqual(expected.value, e.value_ptr.*);
            }
        },

        .iterate => {
            var it = map.constIterator();
            for (model.entries.items) |expected| {
                const got = it.next() orelse return error.TestExpectedEqual;
                try testing.expectEqual(.eq, ctx.order(expected.key, got.key));
                try testing.expectEqual(expected.value, got.value);
            }
            try testing.expectEqual(null, it.next());
        },

        .clear => {
            map.clear(allocator);
            model.clear();
        },

        .put => |args| {
            const k = ks[args.index];
            const v = vs[args.index];
            const map_old = try map.putContext(allocator, k, v, ctx);
            const model_old = try model.put(allocator, k, v, ctx);

            try testing.expectEqual(model_old, map_old);
        },
        .put_get_or_put => |args| {
            const k = ks[args.index];
            const v = vs[args.index];
            const r = try map.getOrPutContext(allocator, k, ctx);

            try testing.expectEqual(model.contains(k, ctx), r.found_existing);

            if (!r.found_existing) r.value_ptr.* = v; // Initialize value.

            _ = try model.put(allocator, k, r.value_ptr.*, ctx);
        },
        .put_get_or_put_value => |args| {
            const k = ks[args.index];
            const v = vs[args.index];
            const r = try map.getOrPutValueContext(allocator, k, v, ctx);

            try testing.expectEqual(model.contains(k, ctx), r.found_existing);

            _ = try model.put(allocator, k, r.value_ptr.*, ctx);
        },

        .put_entry => |args| {
            const k = ks[args.index];
            const v = vs[args.index];
            const model_old = try model.put(allocator, k, v, ctx);

            switch (try map.entryContext(allocator, k, ctx)) {
                .occupied => |e| {
                    try testing.expect(model_old != null);
                    try testing.expectEqual(model_old.?, e.replace(v));
                },
                .vacant => |e| {
                    try testing.expectEqual(null, model_old);
                    _ = e.insert(v);
                },
            }
        },
        .put_entry_vacant_discard => |args| {
            // Asks for an entry, then drops it without inserting. The map's logical contents must
            // be unchanged.
            const k = ks[args.index];

            switch (try map.entryContext(allocator, k, ctx)) {
                .occupied => try testing.expect(model.contains(k, ctx)),
                .vacant => try testing.expect(!model.contains(k, ctx)),
            }
        },
        .replace_via_occupied_entry => |args| {
            // Replaces a value via `OccupiedEntry.replace()`. Skipped if the key is absent.
            const k = ks[args.index];
            const new_v = vs[args.new_index];

            if (map.occupiedEntryContext(k, ctx)) |e| {
                const old = e.replace(new_v);
                const model_old = try model.put(allocator, k, new_v, ctx);

                try testing.expectEqual(model_old.?, old);
            } else {
                try testing.expectEqual(null, model.get(k, ctx));
            }
        },

        .mutate_via_get_ptr => |args| {
            // Mutates an existing value through `getPtr()`. Skipped if the key is absent.
            const k = ks[args.index];
            const new_v = vs[args.new_index];

            if (map.getPtrContext(k, ctx)) |ptr| {
                try testing.expect(model.contains(k, ctx));
                ptr.* = new_v;
                _ = try model.put(allocator, k, new_v, ctx);
            } else {
                try testing.expectEqual(null, model.get(k, ctx));
            }
        },

        .remove => |args| {
            const k = ks[args.index];
            const map_kv = map.removeContext(allocator, k, ctx);
            const model_kv = model.remove(k, ctx);

            try testing.expectEqual(model_kv != null, map_kv != null);

            if (map_kv) |kv| {
                try testing.expectEqual(.eq, ctx.order(k, kv.key));
                try testing.expectEqual(model_kv.?[1], kv.value);
            }
        },
        .remove_occupied_entry => |args| {
            const k = ks[args.index];

            if (map.occupiedEntryContext(k, ctx)) |e| {
                const kv = e.remove(allocator);
                _, const model_value = model.remove(k, ctx) orelse return error.TestExpectedEqual;

                try testing.expectEqual(model_value, kv.value);
            } else {
                try testing.expectEqual(null, model.remove(k, ctx));
            }
        },

        .remove_first_entry => {
            const e = map.firstEntry() orelse return;
            const kv = e.remove(allocator);
            const model_first = model.entries.items[0];

            try testing.expectEqual(.eq, ctx.order(model_first.key, kv.key));
            try testing.expectEqual(model_first.value, kv.value);

            _ = model.entries.orderedRemove(0);
        },
        .remove_last_entry => {
            const e = map.lastEntry() orelse return;
            const kv = e.remove(allocator);
            const last_idx = model.entries.items.len - 1;
            const model_last = model.entries.items[last_idx];

            try testing.expectEqual(.eq, ctx.order(model_last.key, kv.key));
            try testing.expectEqual(model_last.value, kv.value);

            _ = model.entries.pop();
        },

        .remove_and_move_next => |args| {
            if (map.count() == 0) return;

            const skip = args.skip % @as(u16, @intCast(map.count()));
            var it = map.iterator();

            for (0..skip) |_| it.moveNext();

            if (args.batch) {
                const remove = @min(args.remove, model.entries.items.len - skip);

                for (0..remove) |_|
                    _ = model.entries.orderedRemove(skip);

                try testing.expectEqual(remove, it.removeUpToAndMoveNext(allocator, args.remove));
            } else for (0..args.remove) |_| {
                if (it.peek() == null) break;

                const expected = model.entries.items[skip];
                const removed = it.removeAndMoveNext(allocator);

                try testing.expectEqual(.eq, ctx.order(expected.key, removed.key));
                try testing.expectEqual(expected.value, removed.value);

                _ = model.remove(expected.key, ctx) orelse unreachable;
            }
        },

        .remove_and_move_previous => |args| {
            if (map.count() == 0) return;

            const skip = args.skip % @as(u16, @intCast(map.count()));
            var it = map.iteratorFromEnd();

            for (0..skip) |_| _ = it.movePrevious();

            var model_idx: usize = model.entries.items.len - 1 - skip;
            for (0..args.remove) |_| {
                if (it.peek() == null) break;

                const expected = model.entries.items[model_idx];
                const removed = it.removeAndMovePrevious(allocator);

                try testing.expectEqual(.eq, ctx.order(expected.key, removed.key));
                try testing.expectEqual(expected.value, removed.value);

                _ = model.remove(expected.key, ctx) orelse unreachable;

                if (model_idx == 0) break;
                model_idx -= 1;
            }
        },

        .retain => |args| {
            const Ctx = struct {
                thr: K,
                ctx: C,

                fn keep(self: *@This(), key: K, _: *V) bool {
                    return self.ctx.order(self.thr, key) != .gt;
                }
            };
            var retain_ctx: Ctx = .{ .thr = ks[args.threshold], .ctx = ctx };

            map.retain(allocator, &retain_ctx, Ctx.keep);

            var i: usize = 0;

            while (i < model.entries.items.len) {
                if (retain_ctx.keep(model.entries.items[i].key, &model.entries.items[i].value)) {
                    i += 1;
                } else {
                    _ = model.entries.orderedRemove(i);
                }
            }
        },
    }
}

// -------------------------------------------------------------------------------------------------
// MARK: Setup

fn fuzz(
    comptime K: type,
    comptime V: type,
    comptime C: type,
    comptime options: Options,
    smith: *testing.Smith,
) !void {
    const Map = BTreeMap(K, V, C, options);
    const Model = OrderedMap(K, V, C);

    const allocator = testing.allocator;
    const ctx = btree.sampleContext(C);

    var map: Map = .empty;
    defer map.deinit(allocator);

    var model: Model = .empty;
    defer model.deinit(allocator);

    // Print map and model on error.
    errdefer {
        std.debug.print("Map:\n", .{});

        var iter = map.constIterator();
        while (iter.next()) |kv| std.debug.print("- {any}: {any}\n", .{ kv.key, kv.value });

        std.debug.print("\nModel:\n", .{});
        for (model.entries.items) |kv| std.debug.print("- {any}: {any}\n", .{ kv.key, kv.value });
    }

    // Print debug information to a buffer that we only actually print to the console on error.
    var debug_output_buf: std.Io.Writer.Allocating = .init(allocator);
    defer debug_output_buf.deinit();
    var debug_output = &debug_output_buf.writer;

    errdefer std.debug.print("{s}", .{debug_output_buf.written()});

    while (!smith.eos()) {
        const op: Op = .fromSmith(smith);

        try debug_output.print("{}\n", .{op});
        try perform(K, V, C, options, allocator, &map, &model, op);
        try model.expectEqualToMap(&map, ctx);
    }
}

/// Returns a function pointer to `fuzz(K, V, C, options, smith)`.
fn fuzzFn(
    comptime K: type,
    comptime V: type,
    comptime C: type,
    comptime options: Options,
) *const fn (*testing.Smith) anyerror!void {
    return struct {
        fn f(smith: *testing.Smith) anyerror!void {
            try fuzz(K, V, C, options, smith);
        }
    }.f;
}

const fuzz_fns = [_]*const fn (*testing.Smith) anyerror!void{
    fuzzFn(u32, u32, AutoContext(u32), .{}),
    fuzzFn(u32, u32, AutoContext(u32), .{ .B = 4 }),
    fuzzFn(u32, u32, AutoContext(u32), .{ .B = 7 }),
    fuzzFn([]const u8, u32, AutoContext([]const u8), .{}),
};

test "fuzz" {
    try testing.fuzz({}, struct {
        fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
            const fuzz_fn = fuzz_fns[smith.index(fuzz_fns.len)];

            try fuzz_fn(smith);
        }
    }.fuzz_one, .{});
}
