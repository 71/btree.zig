const root_mod = @import("root"); // "root_mod" to allow naming variables "root".
const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const assert = std.debug.assert;
const testing = std.testing;

// -------------------------------------------------------------------------------------------------
// MARK: Options

/// Options given to `BTreeMap()`.
pub const Options = struct {
    /// Capacity of each leaf. Must be in 4..<255.
    B: usize = 16,

    /// Type of search to use to find nodes. If `null`, picks the one that seems the most
    /// appropriate for `K`.
    search: ?enum { binary, linear } = null,

    /// Whether the map should call `checkInvariants()` after each mutation. This should typically
    /// be left as `false`.
    ///
    /// If `true`, adapted contexts must also support comparisons between key types `K`.
    check_invariants: bool = global_options.check_invariants,

    /// Whether the map should maintain a "generation counter" to detect when an entry or iterator
    /// is used after a mutation.
    track_generations: bool = global_options.track_generations,
};

/// Global options set in the root module with `pub const btree_options: GlobalOptions = .{}`.
pub const GlobalOptions = struct {
    /// Default value for `Options.check_invariants`.
    check_invariants: bool = false,

    /// Default value for `Options.track_generations`.
    track_generations: bool = true,
};

const global_options: GlobalOptions = if (@hasDecl(root_mod, "btree_options"))
    root_mod.btree_options
else if (std.mem.eql(u8, @typeName(root_mod), "test_runner"))
    // When running tests the root module is `test_runner`, not our `root.zig`.
    .{ .check_invariants = true, .track_generations = true }
else
    .{};

// -------------------------------------------------------------------------------------------------
// MARK: BTreeMap

/// An ordered map backed by a B-Tree.
///
/// Iterators are invalidated on mutation.
///
/// ## Contexts
///
/// Most functions in this struct have three variants based on the _context_ type used for
/// comparisons; using `occupiedEntry()` as example:
///
/// - `occupiedEntry(Self, K)` requires `C` to be zero-sized, and will call
///   `occupiedEntryContext(Self, K, undefined)`.
///
/// - `occupiedEntryContext(Self, K, C)` requires `C` to define `fn order(C, K, K) std.math.Order`,
///   and will call `occupiedEntryAdapted(Self, K, C)`.
///
/// - `occupiedEntryAdapted(Self, key: anytype, context: anytype)` requires `@TypeOf(context)` to
///   define `fn order(@TypeOf(context), K, @TypeOf(key)) std.math.Order`.
///
/// Furthermore, some functions (e.g. `entryAdapted()`, `putAdapted()`) require converting the
/// `anytype` key to `K` for insertion into the map. When calling these functions, the `anytype`
/// context must also define `fn toKey(@TypeOf(context), std.mem.Allocator, @TypeOf(key)) !K`.
pub fn BTreeMap(
    comptime K: type,
    comptime V: type,
    comptime C: type,
    comptime options: Options,
) type {
    // Only accept `B >= 4` to match Abseil:
    // https://github.com/abseil/abseil-cpp/blob/4ab53949759ddf3f26336eae7130ac6445376b53/absl/container/internal/btree.h#L611-L616.
    comptime if (options.B <= 3) @compileError("B must be >= 4");

    // We store `B + 1` and compute lengths as `u8`, so `B` must be `< 255`.
    comptime if (options.B >= 255) @compileError("B must be < 255");

    const linear_search = if (options.search) |search|
        search == .linear
    else if (@hasDecl(C, "prefer_linear_search"))
        C.prefer_linear_search
    else
        false;

    // We support tracking iterator generations.
    const track_generation = options.track_generations;
    const Generation = if (track_generation) u32 else u0;

    // Minimum number of keys in a non-root node.
    //
    // Splitting a full node at `mid = B/2` produces a left half of `B/2` keys, one promoted
    // median, and a right half of `B - B/2 - 1` keys. For both halves to respect `min_keys`
    // post-split, `min_keys` must be at most the smaller half, i.e. `B - B/2 - 1`, which is
    // `(B - 1) / 2`.
    const min_keys: usize = (options.B - 1) / 2;

    return struct {
        pub const B = options.B;
        pub const Key = K;
        pub const Value = V;
        pub const Context = C;

        pub fn KeyConversionError(comptime AdaptedKey: type, comptime AdaptedContext: type) type {
            if (AdaptedKey == Key or AdaptedContext == Context) return error{OutOfMemory};

            const return_type = switch (@typeInfo(@TypeOf(AdaptedContext.toKey))) {
                .@"fn" => |f| f.return_type orelse @compileError(""),
                else => @compileError(""),
            };
            const error_type = switch (@typeInfo(return_type)) {
                .error_union => |e| e.error_set,
                else => error{},
            };

            return error{OutOfMemory} || error_type;
        }

        pub const KV = struct {
            key: K,
            value: V,
        };

        /// A pointer to the root, null when empty. Do not access.
        root: NodePtr = .nil,

        /// Number of entries in the map. Use `count()` instead.
        len: usize = 0,

        /// The current generation of the map, used to track iterator invalidation. Bumped by
        /// every mutating public API. Compiles away when `options.check_invariants` is false. Do
        /// not access.
        generation: Generation = 0,

        // -----------------------------------------------------------------------------------------
        // MARK: empty, deinit, misc

        /// An empty map.
        pub const empty: Self = .{};

        test empty {
            var map: Self = .empty;

            try testing.expect(map.root.isNil());
            try testing.expectEqual(0, map.count());
            try testing.expectEqual(map.first(), null);
            try testing.expectEqual(map.last(), null);
            try testing.expectEqual(map.firstEntry(), null);
            try testing.expectEqual(map.lastEntry(), null);

            var it = map.iterator();
            try testing.expectEqual(it.next(), null);
        }

        /// Frees the map and its resources. If keys and/or values own memory, they should be
        /// separately deinitialized before calling this function.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.clear(allocator);
            self.* = undefined;
        }

        /// Frees the map and its resources, and resets it to being empty. If keys and/or values own
        /// memory, they should be separately deinitialized before calling this function.
        pub fn clear(self: *Self, allocator: Allocator) void {
            // Bump generation even if nothing changes, as it is still an error to mutate the map
            // during iteration.
            self.bumpGeneration();

            var current = (self.root.orNull() orelse return).leftmostLeafNode();

            const gen = self.generation;
            defer self.* = .{ .generation = gen };

            while (true) {
                const parent = current.parent();
                const parent_idx = current.parentIdx();

                if (current.asLeaf()) |leaf| {
                    allocator.destroy(leaf);
                } else {
                    allocator.destroy(current.assertInternal());
                }

                const p = parent orelse return; // Just freed the root.

                if (parent_idx + 1 <= p.len) {
                    // There is a right sibling subtree; descend into it.
                    current = p.children[parent_idx + 1].leftmostLeafNode();
                } else {
                    // Go up to the parent.
                    current = .internal(p);
                }
            }
        }

        test clear {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            for (ks, vs) |k, v| _ = try map.putContext(testing.allocator, k, v, ctx);
            try testing.expectEqual(ks.len, map.count());

            map.clear(testing.allocator);

            try testing.expectEqual(0, map.count());
            for (ks) |k| try testing.expect(!map.containsContext(k, ctx));

            // Reusable after clear.
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            try testing.expectEqual(vs[0], map.getContext(ks[0], ctx));
        }

        /// Returns the number of entries in the map.
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        test count {
            const ks, const vs, const ctx = try testData();

            var map: BTreeMap(K, V, C, options) = .empty;
            defer map.deinit(testing.allocator);

            try testing.expectEqual(0, map.count());
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            try testing.expectEqual(1, map.count());
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);
            try testing.expectEqual(2, map.count());

            // Overwrite does not change count.
            _ = try map.putContext(testing.allocator, ks[0], vs[1], ctx);
            try testing.expectEqual(2, map.count());

            // Deletion decrements count.
            _ = map.removeContext(testing.allocator, ks[0], ctx);
            try testing.expectEqual(1, map.count());

            // Deleting absent key does not change count.
            _ = map.removeContext(testing.allocator, ks[0], ctx);
            try testing.expectEqual(1, map.count());
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Read-only

        /// Returns a pointer to the value corresponding to `key`, or `null` if not found.
        pub inline fn get(self: *const Self, key: K) ?V {
            return self.getContext(key, implicitContext("get"));
        }
        pub inline fn getContext(self: *const Self, key: K, context: Context) ?V {
            return self.getAdapted(key, context);
        }
        pub fn getAdapted(self: *const Self, key: anytype, context: anytype) ?V {
            return (@constCast(self).getPtrAdapted(key, context) orelse return null).*;
        }

        /// Returns a pointer to the value corresponding to `key`, or `null` if not found.
        pub inline fn getPtr(self: *Self, key: K) ?*V {
            return self.getPtrContext(key, implicitContext("getPtr"));
        }
        pub inline fn getPtrContext(self: *Self, key: K, context: Context) ?*V {
            return self.getPtrAdapted(key, context);
        }
        pub fn getPtrAdapted(self: *Self, key: anytype, context: anytype) ?*V {
            var current = self.root.orNull() orelse return null;

            while (current.asInternal()) |node| {
                const index, const found = search(context, node.keys[0..node.len], key);
                if (found) return &node.values[index];
                current = node.children[index];
            }

            const leaf = current.assertLeaf();
            const index =
                searchIndex(context, leaf.keys[0..leaf.len], key) orelse return null;
            return &leaf.values[index];
        }

        /// Return `true` iff `key` is present in the map.
        pub inline fn contains(self: *const Self, key: K) bool {
            return self.containsContext(key, implicitContext("contains"));
        }
        pub inline fn containsContext(self: *const Self, key: K, context: Context) bool {
            return self.containsAdapted(key, context);
        }
        pub fn containsAdapted(self: *const Self, key: anytype, context: anytype) bool {
            return self.getAdapted(key, context) != null;
        }

        test contains {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);

            try testing.expect(map.containsContext(ks[0], ctx));
            try testing.expect(!map.containsContext(ks[1], ctx));
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Entry API

        /// A reference to an entry in the map. Invalidated on mutation.
        pub const Entry = union(enum) {
            occupied: OccupiedEntry,
            vacant: VacantEntry,
        };

        /// A reference to an existing entry in the map. Invalidated on mutation.
        pub const OccupiedEntry = struct {
            /// A pointer to the key. Although it can be modified, the key should keep its ordering.
            key_ptr: *K,
            /// A pointer to the value.
            value_ptr: *V,

            /// Do not access the fields below.
            map: *Self,
            node: NodePtr,
            idx: u8,
            gen: Generation,

            /// Replaces the value, returning the old one.
            pub fn replace(self: OccupiedEntry, value: V) V {
                assert(self.gen == self.map.generation);

                const old = self.value_ptr.*;
                self.value_ptr.* = value;
                return old;
            }

            /// Removes the entry.
            pub fn remove(self: OccupiedEntry, allocator: Allocator) KV {
                assert(self.gen == self.map.generation);

                return self.map.removeAt(allocator, self.node, self.idx);
            }
        };

        /// A reference to a vacant slot. Invalidated on mutation.
        pub const VacantEntry = struct {
            /// The key that was searched for. May be modified by the caller before calling
            /// `insert()`, provided its ordering stays the same.
            key: K,

            /// Do not access the fields below.
            map: *Self,
            leaf: *LeafNode,
            leaf_idx: u8,
            gen: Generation,

            /// Inserts `value` in this slot.
            pub fn insert(self: VacantEntry, value: V) OccupiedEntry {
                assert(self.gen == self.map.generation);

                const key_ptr, const value_ptr = self.leaf.insert(self.leaf_idx, self.key, value);

                self.map.len += 1;

                return .{
                    .key_ptr = key_ptr,
                    .value_ptr = value_ptr,
                    .map = self.map,
                    .node = .leaf(self.leaf),
                    .idx = self.leaf_idx,
                    .gen = self.map.generation,
                };
            }
        };

        /// Returns the `OccupiedEntry` for `key`, or `null` if it doesn't exist.
        pub inline fn occupiedEntry(self: *Self, key: K) ?OccupiedEntry {
            return self.occupiedEntryContext(key, implicitContext("entry"));
        }
        pub inline fn occupiedEntryContext(self: *Self, key: K, context: Context) ?OccupiedEntry {
            return self.occupiedEntryAdapted(key, context);
        }
        pub fn occupiedEntryAdapted(self: *Self, key: anytype, context: anytype) ?OccupiedEntry {
            var current = self.root.orNull() orelse return null;

            while (current.asInternal()) |node| {
                const index, const found = search(context, node.keys[0..node.len], key);
                if (found) return .{
                    .key_ptr = &node.keys[index],
                    .value_ptr = &node.values[index],
                    .map = self,
                    .node = current,
                    .idx = index,
                    .gen = self.generation,
                };
                current = node.children[index];
            }

            const leaf = current.assertLeaf();
            const index = searchIndex(context, leaf.keys[0..leaf.len], key) orelse return null;

            return .{
                .key_ptr = &leaf.keys[index],
                .value_ptr = &leaf.values[index],
                .map = self,
                .node = current,
                .idx = index,
                .gen = self.generation,
            };
        }

        test occupiedEntry {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            try testing.expectEqual(null, map.occupiedEntryContext(ks[0], ctx));

            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);

            const e: OccupiedEntry = map.occupiedEntryContext(ks[0], ctx).?;

            try testing.expectEqual(ks[0], e.key_ptr.*);
            try testing.expectEqual(vs[0], e.value_ptr.*);

            try testing.expectEqual(vs[0], e.replace(vs[1]));

            try testing.expectEqual(vs[1], e.remove(testing.allocator).value);

            try testing.expectEqual(null, map.occupiedEntryContext(ks[0], ctx));
        }

        /// Returns the `Entry` for `key`.
        ///
        /// If the result is a `VacantEntry`, it may be discarded without calling `insert()`, which
        /// will leave the map in a valid state. However, some allocations may still have occurred.
        /// If you always discard the `VacantEntry`, prefer using `occupiedEntry()` instead, which
        /// will not allocate.
        pub fn entry(self: *Self, allocator: Allocator, key: K) error{OutOfMemory}!Entry {
            return try self.entryContext(allocator, key, implicitContext("entry"));
        }
        pub fn entryContext(
            self: *Self,
            allocator: Allocator,
            key: K,
            context: Context,
        ) error{OutOfMemory}!Entry {
            return try self.entryAdapted(allocator, key, context);
        }
        pub fn entryAdapted(
            self: *Self,
            allocator: Allocator,
            key: anytype,
            context: anytype,
        ) KeyConversionError(@TypeOf(key), @TypeOf(context))!Entry {
            defer self.maybeCheckInvariants(context);

            // Bump unconditionally: even when this call returns an OccupiedEntry without
            // structural changes, the pre-emptive splits below may have moved keys.
            self.bumpGeneration();

            // Ensure a root exists.
            if (self.root.isNil()) {
                const leaf = try allocator.create(LeafNode);
                leaf.* = .{};
                self.root = .leaf(leaf);
            }

            // Pre-split the root if full.
            if (self.root.len() == B) try self.splitFullRoot(allocator);

            var current = self.root;

            while (current.asInternal()) |node| {
                var index, var found = search(context, node.keys[0..node.len], key);
                if (found) return .{
                    .occupied = .{
                        .key_ptr = &node.keys[index],
                        .value_ptr = &node.values[index],
                        .map = self,
                        .node = current,
                        .idx = index,
                        .gen = self.generation,
                    },
                };

                // Pre-split the child before descending.
                if (node.children[index].len() == B) try splitFullChild(allocator, node, index);

                // The split may have promoted a key into node at position `index`, so we need to
                // search again.
                index, found = search(context, node.keys[0..node.len], key);
                if (found) return .{
                    .occupied = .{
                        .key_ptr = &node.keys[index],
                        .value_ptr = &node.values[index],
                        .map = self,
                        .node = current,
                        .idx = index,
                        .gen = self.generation,
                    },
                };
                current = node.children[index];
            }

            const leaf = current.assertLeaf();
            const index, const found = search(context, leaf.keys[0..leaf.len], key);
            if (found) return .{
                .occupied = .{
                    .key_ptr = &leaf.keys[index],
                    .value_ptr = &leaf.values[index],
                    .map = self,
                    .node = current,
                    .idx = index,
                    .gen = self.generation,
                },
            };
            return .{
                .vacant = .{
                    .key = try toKey(allocator, key, context),
                    .leaf = leaf,
                    .leaf_idx = index,
                    .map = self,
                    .gen = self.generation,
                },
            };
        }

        test entry {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            // Insert the value: we hit a vacant spot.
            const ve: VacantEntry = switch (try map.entryContext(testing.allocator, ks[0], ctx)) {
                .vacant => |v| v,
                .occupied => unreachable,
            };

            try testing.expectEqual(ks[0], ve.key);

            // The map is still empty.
            try testing.expectEqual(0, map.len);
            try testing.expect(!map.containsContext(ks[0], ctx));

            // Insert a value into the spot.
            const e: OccupiedEntry = ve.insert(vs[0]);

            // The map is no longer empty.
            try testing.expectEqual(1, map.len);
            try testing.expect(map.containsContext(ks[0], ctx));

            try testing.expectEqual(ks[0], e.key_ptr.*);
            try testing.expectEqual(vs[0], e.value_ptr.*);

            // We have an `OccupiedEntry`, so we can still interact with it.
            try testing.expectEqual(vs[0], e.replace(vs[1]));

            try testing.expectEqual(vs[1], e.remove(testing.allocator).value);

            try testing.expectEqual(null, map.occupiedEntryContext(ks[0], ctx));
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Mutations

        /// Inserts `key, value` into the map. If it already exists, replaces the value with `value`
        /// and returns its previous value.
        pub inline fn put(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) error{OutOfMemory}!?V {
            return try self.putContext(allocator, key, value, implicitContext("put"));
        }
        pub fn putContext(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
            context: Context,
        ) error{OutOfMemory}!?V {
            return try self.putAdapted(allocator, key, value, context);
        }
        pub fn putAdapted(
            self: *Self,
            allocator: Allocator,
            key: anytype,
            value: V,
            context: anytype,
        ) KeyConversionError(@TypeOf(key), @TypeOf(context))!?V {
            defer self.maybeCheckInvariants(context);

            switch (try self.entryAdapted(allocator, key, context)) {
                .occupied => |e| return e.replace(value),
                .vacant => |e| {
                    _ = e.insert(value);
                    return null;
                },
            }
        }

        test put {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            try testing.expectEqual(null, try map.putContext(testing.allocator, ks[0], vs[0], ctx));
            try testing.expectEqual(vs[0], map.getContext(ks[0], ctx));

            try testing.expectEqual(vs[0], try map.putContext(testing.allocator, ks[0], vs[1], ctx));
            try testing.expectEqual(vs[1], map.getContext(ks[0], ctx)); // Overwritten.
        }

        /// Result of `getOrPut()` and `getOrPutValue()`.
        pub const GetOrPutResult = struct {
            key_ptr: *K,
            value_ptr: *V,
            found_existing: bool,
        };

        /// Inserts `key, undefined` into the map, then returns its pointers. No-op if `key` already
        /// exists.
        pub inline fn getOrPut(
            self: *Self,
            allocator: Allocator,
            key: K,
        ) error{OutOfMemory}!GetOrPutResult {
            return try self.getOrPutContext(allocator, key, implicitContext("getOrPut"));
        }
        pub inline fn getOrPutContext(
            self: *Self,
            allocator: Allocator,
            key: K,
            context: Context,
        ) error{OutOfMemory}!GetOrPutResult {
            return try self.getOrPutAdapted(allocator, key, context);
        }
        pub fn getOrPutAdapted(
            self: *Self,
            allocator: Allocator,
            key: anytype,
            context: anytype,
        ) KeyConversionError(@TypeOf(key), @TypeOf(context))!GetOrPutResult {
            return try self.getOrPutValueAdapted(allocator, key, undefined, context);
        }

        test getOrPut {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            // Insert new entry.
            var result: GetOrPutResult =
                try map.getOrPutContext(testing.allocator, ks[0], ctx);

            try testing.expect(!result.found_existing);
            try testing.expectEqual(ks[0], result.key_ptr.*);

            result.value_ptr.* = vs[0];

            try testing.expectEqual(vs[0], map.getContext(ks[0], ctx));

            // Get back inserted value.
            result = try map.getOrPutContext(testing.allocator, ks[0], ctx);

            try testing.expect(result.found_existing);
            try testing.expectEqual(ks[0], result.key_ptr.*);
            try testing.expectEqual(vs[0], result.value_ptr.*); // Not overwritten.
        }

        /// Inserts `key, value` into the map, then returns its pointers. No-op if `key` already
        /// exists.
        pub inline fn getOrPutValue(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) error{OutOfMemory}!GetOrPutResult {
            return try self.getOrPutValueContext(allocator, key, value, implicitContext("getOrPutValue"));
        }
        pub inline fn getOrPutValueContext(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
            context: Context,
        ) error{OutOfMemory}!GetOrPutResult {
            return try self.getOrPutValueAdapted(allocator, key, value, context);
        }
        pub fn getOrPutValueAdapted(
            self: *Self,
            allocator: Allocator,
            key: anytype,
            value: V,
            context: anytype,
        ) KeyConversionError(@TypeOf(key), @TypeOf(context))!GetOrPutResult {
            defer self.maybeCheckInvariants(context);

            switch (try self.entryAdapted(allocator, key, context)) {
                .occupied => |e| return .{
                    .key_ptr = e.key_ptr,
                    .value_ptr = e.value_ptr,
                    .found_existing = true,
                },
                .vacant => |e| {
                    const occupied = e.insert(value);
                    return .{
                        .key_ptr = occupied.key_ptr,
                        .value_ptr = occupied.value_ptr,
                        .found_existing = false,
                    };
                },
            }
        }

        test getOrPutValue {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            // Insert new entry.
            var result: GetOrPutResult =
                try map.getOrPutValueContext(testing.allocator, ks[0], vs[0], ctx);

            try testing.expect(!result.found_existing);
            try testing.expectEqual(ks[0], result.key_ptr.*);
            try testing.expectEqual(vs[0], result.value_ptr.*);

            try testing.expectEqual(vs[0], map.getContext(ks[0], ctx));

            // Get back inserted value.
            result = try map.getOrPutValueContext(testing.allocator, ks[0], vs[1], ctx);

            try testing.expect(result.found_existing);
            try testing.expectEqual(ks[0], result.key_ptr.*);
            try testing.expectEqual(vs[0], result.value_ptr.*); // Kept first value.
        }

        /// Removes the entry corresponding to `key` from the map.
        pub inline fn remove(self: *Self, allocator: Allocator, key: K) ?KV {
            return self.removeContext(allocator, key, implicitContext("remove"));
        }
        pub inline fn removeContext(
            self: *Self,
            allocator: Allocator,
            key: K,
            context: Context,
        ) ?KV {
            return self.removeAdapted(allocator, key, context);
        }
        pub fn removeAdapted(
            self: *Self,
            allocator: Allocator,
            key: anytype,
            context: anytype,
        ) ?KV {
            defer self.maybeCheckInvariants(context);

            return (self.occupiedEntryContext(key, context) orelse return null).remove(allocator);
        }

        test remove {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            try testing.expectEqual(null, map.removeContext(testing.allocator, ks[0], ctx));

            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            try testing.expectEqual(1, map.len);

            try testing.expectEqual(vs[0], map.removeContext(testing.allocator, ks[0], ctx).?.value);
            try testing.expectEqual(0, map.len);
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Iterator

        /// Iterator over key-value pairs returned by `iterator()`.
        ///
        /// Yields entries in ascending key order (with `next()`) or descending key order (with
        /// `previous()`). Invalidated by any mutation of the map.
        pub const Iterator = struct {
            node: NodePtr,
            map: *Self,
            idx: u8,
            gen: Generation,

            /// Returns the current key-value pair, or `null` if the end of the map was reached,
            /// then moves the iterator to the next entry.
            pub fn next(self: *Iterator) ?struct { *K, *V } {
                const result = self.peek() orelse return null;
                self.moveNextUnchecked();
                return result;
            }

            /// Returns the current key-value pair, or `null` if the beginning of the map was
            /// reached, then moves the iterator to the previous entry.
            pub fn previous(self: *Iterator) ?struct { *K, *V } {
                const result = self.peek() orelse return null;
                self.movePreviousUnchecked();
                return result;
            }

            /// Returns the current key-value pair, or `null` if the end of the map was reached.
            pub fn peek(self: *const Iterator) ?struct { *K, *V } {
                self.checkGeneration();

                const current = self.node.orNull() orelse return null;

                if (current.asLeaf()) |leaf|
                    return .{ &leaf.keys[self.idx], &leaf.values[self.idx] };

                const node = current.assertInternal();

                return .{ &node.keys[self.idx], &node.values[self.idx] };
            }

            /// Moves the cursor to the next key-value position.
            pub fn moveNext(self: *Iterator) void {
                self.checkGeneration();
                self.moveNextUnchecked();
            }

            /// Moves the cursor to the previous key-value position.
            pub fn movePrevious(self: *Iterator) void {
                self.checkGeneration();
                self.movePreviousUnchecked();
            }

            /// Same as `moveNext()`, but skips the generation check.
            fn moveNextUnchecked(self: *Iterator) void {
                if (self.node.isNil()) return;

                if (self.node.asLeaf()) |leaf| {
                    if (self.idx + 1 < leaf.len) {
                        // More slots in this leaf.
                        self.idx += 1;
                        return;
                    }

                    // Go up the tree.
                    var current = self.node;

                    while (current.parent()) |parent| {
                        if (current.parentIdx() < parent.len) {
                            // Switch to the right sibling. Even if we're the last child, there are
                            // more keys/values on our right, so this is fine.
                            assert(parent.keys.len == parent.children.len - 1);

                            self.node = .internal(parent);
                            self.idx = current.parentIdx();
                            return;
                        }

                        // We were the rightmost child; keep ascending.
                        current = .internal(parent);
                    }

                    // Reached the root coming up; exhausted.
                    self.node = .nil;
                } else {
                    self.node = self.node.assertInternal().children[self.idx + 1].leftmostLeafNode();
                    self.idx = 0;
                }
            }

            /// Same as `movePrevious()`, but skips the generation check.
            fn movePreviousUnchecked(self: *Iterator) void {
                if (self.node.isNil()) return;

                if (self.node.isLeaf()) {
                    if (self.idx > 0) {
                        // More slots in this leaf.
                        self.idx -= 1;
                        return;
                    }

                    // Go up the tree.
                    var current = self.node;

                    while (current.parent()) |parent| {
                        if (current.parentIdx() > 0) {
                            // Switch to the left sibling.
                            self.node = .internal(parent);
                            self.idx = current.parentIdx() - 1;
                            return;
                        }

                        // We were the leftmost child; keep ascending.
                        current = .internal(parent);
                    }

                    // Reached the root coming up; exhausted.
                    self.node = .nil;
                } else {
                    // At an internal node: go to the rightmost leaf of `children[idx]`.
                    const leaf = self.node.assertInternal().children[self.idx].rightmostLeaf();

                    self.node = .leaf(leaf);
                    self.idx = leaf.len - 1;
                }
            }

            /// Removes the current entry from the map and moves to the next position. The removed
            /// key-value pair is returned. May not be called if `peek()` returns `null`.
            pub fn removeAndMoveNext(self: *Iterator, allocator: Allocator) KV {
                defer self.map.maybeCheckInvariantsNoContext();

                const kv, const pos = self.removeBeforeMove(allocator);

                if (pos) |p| {
                    const wasInternal = !self.node.isLeaf();

                    self.node = p.node;
                    self.idx = p.idx;

                    // Step past the predecessor's slot to reach the original successor.
                    if (wasInternal) self.moveNextUnchecked();
                } else {
                    self.node = .nil;
                    self.idx = 0;
                }

                self.gen = self.map.generation;

                return kv;
            }

            /// Removes the current entry from the map and moves to the previous position. The
            /// removed key-value pair is returned. May not be called if `peek()` returns `null`.
            pub fn removeAndMovePrevious(self: *Iterator, allocator: Allocator) KV {
                defer self.map.maybeCheckInvariantsNoContext();

                const kv, const pos = self.removeBeforeMove(allocator);

                if (pos) |p| {
                    const wasLeaf = self.node.isLeaf();

                    self.node = p.node;
                    self.idx = p.idx;

                    // `pos` is the successor; move once to reach the predecessor.
                    if (wasLeaf) self.movePreviousUnchecked();

                    // For internal nodes, `fixAfterRemovalAt()` walks up from the left subtree and
                    // lands on `internal[idx]`, which is where we want to be.
                } else {
                    // No successor: either the map is now empty, or we removed the last entry.
                    if (self.map.len == 0) {
                        self.node = .nil;
                        self.idx = 0;
                    } else {
                        // The predecessor of the removed entry is the new last element.
                        const leaf = self.map.root.orNull().?.rightmostLeaf();

                        self.node = .leaf(leaf);
                        self.idx = leaf.len - 1;
                    }
                }

                self.gen = self.map.generation;

                return kv;
            }

            /// Removes the current entry, leaving it up to the caller to fix the iterator position.
            fn removeBeforeMove(self: *Iterator, allocator: Allocator) struct { KV, ?Removal } {
                assert(!self.node.isNil()); // May not be called on an exhausted iterator.

                self.checkGeneration();
                self.map.bumpGeneration();

                const node = self.node;
                const idx = self.idx;
                assert(idx < node.len());

                self.map.len -= 1;

                var kv: KV = undefined;
                var removal: ?Removal = undefined;

                if (node.asLeaf()) |leaf| {
                    kv.key, kv.value = leaf.remove(idx);
                    removal = self.map.fixAfterRemovalAt(allocator, node, idx);
                } else {
                    const internal = node.assertInternal();
                    kv.key = internal.keys[idx];
                    kv.value = internal.values[idx];

                    const leaf = internal.children[idx].rightmostLeaf();
                    assert(leaf.len >= 1);

                    internal.keys[idx], internal.values[idx] = leaf.removeLast();
                    removal = self.map.fixAfterRemovalAt(allocator, .leaf(leaf), leaf.len);
                }

                return .{ kv, removal };
            }

            fn checkGeneration(self: *const Iterator) void {
                assert(self.gen == self.map.generation);
            }
        };

        /// Returns an iterator positioned at the first entry. Use `next()` to traverse in
        /// ascending order.
        pub fn iterator(self: *Self) Iterator {
            const root = self.root.orNull() orelse
                return .{ .node = .nil, .map = self, .idx = 0, .gen = self.generation };

            const leaf = root.leftmostLeaf();
            if (leaf.len == 0)
                return .{ .node = .nil, .map = self, .idx = 0, .gen = self.generation };

            return .{ .node = .leaf(leaf), .map = self, .idx = 0, .gen = self.generation };
        }

        /// Returns an iterator positioned at the last entry. Use `previous()` to traverse in
        /// descending order.
        pub fn iteratorFromEnd(self: *Self) Iterator {
            const root = self.root.orNull() orelse
                return .{ .node = .nil, .map = self, .idx = 0, .gen = self.generation };

            const leaf = root.rightmostLeaf();
            if (leaf.len == 0)
                return .{ .node = .nil, .map = self, .idx = 0, .gen = self.generation };

            return .{ .node = .leaf(leaf), .map = self, .idx = leaf.len - 1, .gen = self.generation };
        }

        test iterator {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            var iter = map.iterator();

            try testing.expectEqual(null, iter.next());

            // Insert keys in arbitrary order.
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);

            // We need the first and last values below, since we also run this test with reversed
            // iterators.
            const first_key = map.first().?.key;
            const last_key = map.last().?.key;

            // Results are yielded in ascending order.
            iter = map.iterator();

            try testing.expectEqual(first_key, iter.next().?[0].*);
            try testing.expectEqual(ks[1], iter.next().?[0].*);
            try testing.expectEqual(last_key, iter.next().?[0].*);
            try testing.expectEqual(null, iter.next());

            // Values can be removed going forward.
            iter = map.iterator();

            try testing.expectEqual(first_key, iter.next().?[0].*);

            try testing.expectEqual(ks[1], iter.peek().?[0].*);
            try testing.expectEqual(ks[1], iter.removeAndMoveNext(testing.allocator).key);

            try testing.expectEqual(last_key, iter.next().?[0].*);
            try testing.expectEqual(null, iter.next());

            iter = map.iterator();

            try testing.expectEqual(first_key, iter.next().?[0].*);
            try testing.expectEqual(last_key, iter.next().?[0].*);
            try testing.expectEqual(null, iter.next());

            // Values can be removed going backward.
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);

            iter = map.iteratorFromEnd();

            try testing.expectEqual(last_key, iter.peek().?[0].*);
            try testing.expectEqual(last_key, iter.removeAndMovePrevious(testing.allocator).key);

            try testing.expectEqual(ks[1], iter.peek().?[0].*);
            try testing.expectEqual(ks[1], iter.removeAndMovePrevious(testing.allocator).key);

            // After removing `ks[1]`, the iterator should be at `first_key`.
            try testing.expectEqual(first_key, iter.peek().?[0].*);

            // Removing the first entry leaves the iterator exhausted.
            try testing.expectEqual(first_key, iter.removeAndMovePrevious(testing.allocator).key);
            try testing.expectEqual(null, iter.peek());
        }

        test iteratorFromEnd {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            var iter = map.iterator();

            try testing.expectEqual(null, iter.previous());

            // Insert keys in arbitrary order.
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);

            const first_key = map.first().?.key;
            const last_key = map.last().?.key;

            // Results are yielded in descending order.
            iter = map.iteratorFromEnd();

            try testing.expectEqual(last_key, iter.previous().?[0].*);
            try testing.expectEqual(ks[1], iter.previous().?[0].*);
            try testing.expectEqual(first_key, iter.previous().?[0].*);
            try testing.expectEqual(null, iter.previous());
        }

        /// Constant iterator over key-value pairs returned by `constIterator()`.
        ///
        /// Yields entries in ascending key order (with `next()`) or descending key order (with
        /// `previous()`). Invalidated by any mutation of the map.
        pub const ConstIterator = struct {
            iterator: Iterator,

            pub fn next(self: *ConstIterator) ?KV {
                const key_ptr, const value_ptr = self.iterator.next() orelse return null;

                return .{ .key = key_ptr.*, .value = value_ptr.* };
            }

            pub fn previous(self: *ConstIterator) ?KV {
                const key_ptr, const value_ptr = self.iterator.previous() orelse return null;

                return .{ .key = key_ptr.*, .value = value_ptr.* };
            }

            pub fn peek(self: *const ConstIterator) ?KV {
                const key_ptr, const value_ptr = self.iterator.peek() orelse return null;

                return .{ .key = key_ptr.*, .value = value_ptr.* };
            }

            pub fn moveNext(self: *ConstIterator) void {
                self.iterator.moveNext();
            }

            pub fn movePrevious(self: *ConstIterator) void {
                self.iterator.movePrevious();
            }
        };

        /// Returns an iterator over all the entries in the map.
        pub fn constIterator(self: *const Self) ConstIterator {
            return .{ .iterator = @constCast(self).iterator() };
        }

        test constIterator {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            var iter = map.constIterator();

            try testing.expectEqual(null, iter.next());

            // Insert keys in arbitrary order.
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);

            // We need the first and last values below, since we also run this test with reversed
            // iterators.
            const first_key = map.first().?.key;
            const last_key = map.last().?.key;

            // Results are yielded in ascending order.
            iter = map.constIterator();

            try testing.expectEqual(first_key, iter.next().?.key);
            try testing.expectEqual(ks[1], iter.next().?.key);
            try testing.expectEqual(last_key, iter.next().?.key);
            try testing.expectEqual(null, iter.next());
        }

        /// Returns a constant iterator positioned at the last entry. Call `previous()` to traverse
        /// in descending key order.
        pub fn constIteratorFromEnd(self: *const Self) ConstIterator {
            return .{ .iterator = @constCast(self).iteratorFromEnd() };
        }

        test constIteratorFromEnd {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            var iter = map.constIterator();

            try testing.expectEqual(null, iter.previous());

            // Insert keys in arbitrary order.
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);

            // We need the first and last values below, since we also run this test with reversed
            // iterators.
            const first_key = map.first().?.key;
            const last_key = map.last().?.key;

            // Results are yielded in descending order.
            iter = map.constIteratorFromEnd();

            try testing.expectEqual(last_key, iter.previous().?.key);
            try testing.expectEqual(ks[1], iter.previous().?.key);
            try testing.expectEqual(first_key, iter.previous().?.key);
            try testing.expectEqual(null, iter.previous());
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Retain

        /// Calls `f(context, key, value)` on all key-value pairs in the map in order, then removes
        /// all entries for which `f()` returned false.
        ///
        /// `self` should not be mutated or otherwise accessed by `f()`.
        pub fn retain(
            self: *Self,
            allocator: Allocator,
            context: anytype,
            comptime f: fn (@TypeOf(context), K, *V) bool,
        ) void {
            var it = self.iterator();

            while (it.peek()) |kv| {
                const key_ptr, const value_ptr = kv;

                if (f(context, key_ptr.*, value_ptr)) {
                    it.moveNext();
                } else {
                    _ = it.removeAndMoveNext(allocator);
                }
            }
        }

        test retain {
            const ks, const vs, const ctx = try testData();

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            map.retain(testing.allocator, {}, struct {
                fn f(_: void, _: K, _: *V) bool {
                    unreachable;
                }
            }.f);

            // Insert keys in arbitrary order.
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);

            // Function is called over keys in ascending order, and keeps all keys except `ks[1]`.
            const Ctx = struct {
                calls: usize = 0,
                keys: *const @TypeOf(ks),
                values: *const @TypeOf(vs),
                ctx: C,

                fn f(self: *@This(), key: K, value_ptr: *V) bool {
                    const index =
                        if (sampleContextIsReversed(C)) 3 - self.calls - 1 else self.calls;

                    assert(self.ctx.order(key, self.keys[index]) == .eq);
                    assert(value_ptr.* == self.values[index]);

                    self.calls += 1;

                    return self.ctx.order(key, self.keys[1]) != .eq; // Remove `ks[1]`.
                }
            };
            var retain_ctx: Ctx = .{ .keys = &ks, .values = &vs, .ctx = ctx };
            map.retain(testing.allocator, &retain_ctx, Ctx.f);

            try testing.expectEqual(vs[0], map.getContext(ks[0], ctx));
            try testing.expectEqual(null, map.getContext(ks[1], ctx));
            try testing.expectEqual(vs[2], map.getContext(ks[2], ctx));
        }

        // -----------------------------------------------------------------------------------------
        // MARK: first / last

        /// Returns the `OccupiedEntry` for the smallest key, or `null` if empty.
        pub fn firstEntry(self: *Self) ?OccupiedEntry {
            const root = self.root.orNull() orelse return null;
            const leaf = root.leftmostLeaf();
            if (leaf.len == 0) return null;

            return .{
                .key_ptr = &leaf.keys[0],
                .value_ptr = &leaf.values[0],
                .map = self,
                .node = .leaf(leaf),
                .idx = 0,
                .gen = self.generation,
            };
        }
        /// Returns the smallest key-value pair, or `null` if empty.
        pub fn first(self: *const Self) ?KV {
            const e = @constCast(self).firstEntry() orelse return null;

            return .{ .key = e.key_ptr.*, .value = e.value_ptr.* };
        }

        /// Returns the `OccupiedEntry` for the largest key, or `null` if empty.
        pub fn lastEntry(self: *Self) ?OccupiedEntry {
            const root = self.root.orNull() orelse return null;
            const leaf = root.rightmostLeaf();
            if (leaf.len == 0) return null;

            const idx: u8 = leaf.len - 1;
            return .{
                .key_ptr = &leaf.keys[idx],
                .value_ptr = &leaf.values[idx],
                .map = self,
                .node = .leaf(leaf),
                .idx = idx,
                .gen = self.generation,
            };
        }
        /// Returns the largest key-value pair, or `null` if empty.
        pub fn last(self: *const Self) ?KV {
            const e = @constCast(self).lastEntry() orelse return null;

            return .{ .key = e.key_ptr.*, .value = e.value_ptr.* };
        }

        test firstEntry {
            const ks, const vs, const ctx = try testData();
            const reversed = sampleContextIsReversed(C);

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            try testing.expectEqual(null, map.firstEntry());

            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);

            const e: OccupiedEntry = map.firstEntry().?;

            if (reversed) {
                try testing.expectEqual(ks[2], e.key_ptr.*);
                try testing.expectEqual(vs[2], e.value_ptr.*);
            } else {
                try testing.expectEqual(ks[0], e.key_ptr.*);
                try testing.expectEqual(vs[0], e.value_ptr.*);
            }
        }

        test first {
            const ks, const vs, const ctx = try testData();
            const reversed = sampleContextIsReversed(C);

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            try testing.expectEqual(null, map.first());

            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);
            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);

            const kv = map.first().?;

            if (reversed) {
                try testing.expectEqual(ks[2], kv.key);
                try testing.expectEqual(vs[2], kv.value);
            } else {
                try testing.expectEqual(ks[0], kv.key);
                try testing.expectEqual(vs[0], kv.value);
            }
        }

        test lastEntry {
            const ks, const vs, const ctx = try testData();
            const reversed = sampleContextIsReversed(C);

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            try testing.expectEqual(null, map.lastEntry());

            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);
            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);

            const e: OccupiedEntry = map.lastEntry().?;

            if (reversed) {
                try testing.expectEqual(ks[0], e.key_ptr.*);
                try testing.expectEqual(vs[0], e.value_ptr.*);
            } else {
                try testing.expectEqual(ks[2], e.key_ptr.*);
                try testing.expectEqual(vs[2], e.value_ptr.*);
            }
        }

        test last {
            const ks, const vs, const ctx = try testData();
            const reversed = sampleContextIsReversed(C);

            var map: Self = .empty;
            defer map.deinit(testing.allocator);

            try testing.expectEqual(null, map.last());

            _ = try map.putContext(testing.allocator, ks[1], vs[1], ctx);
            _ = try map.putContext(testing.allocator, ks[2], vs[2], ctx);
            _ = try map.putContext(testing.allocator, ks[0], vs[0], ctx);

            const kv = map.last().?;

            if (reversed) {
                try testing.expectEqual(ks[0], kv.key);
                try testing.expectEqual(vs[0], kv.value);
            } else {
                try testing.expectEqual(ks[2], kv.key);
                try testing.expectEqual(vs[2], kv.value);
            }
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Nodes

        const LeafNode = struct {
            parent: ?*InternalNode = null,
            parent_idx: u8 = 0,
            len: u8 = 0,
            keys: [B]K = undefined,
            values: [B]V = undefined,

            /// Inserts a new key-value pair at `idx`.
            fn insert(self: *LeafNode, idx: u8, key: K, value: V) struct { *K, *V } {
                assert(self.len < B);
                assert(idx <= self.len);

                const len = self.len;
                @memmove(self.keys[idx + 1 .. len + 1], self.keys[idx..len]);
                @memmove(self.values[idx + 1 .. len + 1], self.values[idx..len]);
                self.keys[idx] = key;
                self.values[idx] = value;
                self.len += 1;
                return .{ &self.keys[idx], &self.values[idx] };
            }

            /// Removes the key-value pair at `idx`.
            fn remove(self: *LeafNode, idx: u8) struct { K, V } {
                assert(idx < self.len);

                const key = self.keys[idx];
                const value = self.values[idx];

                const len = self.len;
                @memmove(self.keys[idx .. len - 1], self.keys[idx + 1 .. len]);
                @memmove(self.values[idx .. len - 1], self.values[idx + 1 .. len]);
                self.len -= 1;

                self.keys[self.len] = undefined;
                self.values[self.len] = undefined;

                return .{ key, value };
            }

            /// Removes the key-value pair at `self.len - 1`. Equivalent to, but more efficient
            /// than `self.remove(self.len - 1)`,
            fn removeLast(self: *LeafNode) struct { K, V } {
                assert(self.len > 0);

                self.len -= 1;

                defer self.keys[self.len] = undefined;
                defer self.values[self.len] = undefined;

                return .{ self.keys[self.len], self.values[self.len] };
            }
        };

        const InternalNode = struct {
            parent: ?*InternalNode = null,
            parent_idx: u8 = 0,
            len: u8 = 0,
            keys: [B]K = undefined,
            values: [B]V = undefined,
            children: [B + 1]NodePtr = undefined,

            /// Inserts a new key-value pair (followed by the next sibling) at `idx`.
            fn insert(self: *InternalNode, idx: u8, key: K, value: V, right_child: NodePtr) void {
                assert(self.len < B);
                assert(idx <= self.len);

                const len = self.len;
                @memmove(self.keys[idx + 1 .. len + 1], self.keys[idx..len]);
                @memmove(self.values[idx + 1 .. len + 1], self.values[idx..len]);
                @memmove(self.children[idx + 2 .. len + 2], self.children[idx + 1 .. len + 1]);
                self.keys[idx] = key;
                self.values[idx] = value;
                self.children[idx + 1] = right_child;
                self.len += 1;
            }

            /// Fixes the pointers and indices stored in each child from `from_idx` to `self.len`.
            fn fixChildrenFrom(self: *InternalNode, from_idx: u8) void {
                for (self.children[from_idx .. self.len + 1], from_idx..) |child, i| {
                    child.setParent(self, @intCast(i));
                }
            }

            /// Merges the child at `sep + 1` into the one at `sep`, then removes it.
            fn mergeNextInto(self: *InternalNode, allocator: Allocator, sep: u8) void {
                assert(sep < self.len);

                const left = self.children[sep];
                const right = self.children[sep + 1];

                // Leaves should be at the same depth.
                assert(left.isLeaf() == right.isLeaf());
                // Merge produces a single survivor holding both sides and the separator.
                assert(left.len() + right.len() + 1 <= B);

                if (left.asLeaf()) |l| {
                    const r = right.assertLeaf();

                    l.keys[l.len] = self.keys[sep];
                    l.values[l.len] = self.values[sep];
                    @memcpy(l.keys[l.len + 1 ..][0..r.len], r.keys[0..r.len]);
                    @memcpy(l.values[l.len + 1 ..][0..r.len], r.values[0..r.len]);
                    l.len += 1 + r.len;

                    allocator.destroy(r);
                } else {
                    const l = left.assertInternal();
                    const r = right.assertInternal();

                    l.keys[l.len] = self.keys[sep];
                    l.values[l.len] = self.values[sep];
                    @memcpy(l.keys[l.len + 1 ..][0..r.len], r.keys[0..r.len]);
                    @memcpy(l.values[l.len + 1 ..][0..r.len], r.values[0..r.len]);
                    @memcpy(l.children[l.len + 1 ..][0 .. r.len + 1], r.children[0 .. r.len + 1]);
                    const old_l_len = l.len;
                    l.len += 1 + r.len;
                    l.fixChildrenFrom(old_l_len + 1);

                    allocator.destroy(r);
                }

                // Drop the separator from `parent` and shift the right half of its keys/children
                // down by one.
                const len = self.len;
                @memmove(self.keys[sep .. len - 1], self.keys[sep + 1 .. len]);
                @memmove(self.values[sep .. len - 1], self.values[sep + 1 .. len]);
                @memmove(self.children[sep + 1 .. len], self.children[sep + 2 .. len + 1]);
                self.len -= 1;
                self.fixChildrenFrom(sep + 1);
            }

            /// Rotates `self.children[sep]` to the end of `left`, then replaces it with
            /// `right.remove(0)`.
            fn rotateLeafLeft(
                self: *InternalNode,
                left: *LeafNode,
                sep: u8,
                right: *LeafNode,
            ) void {
                assert(right.len > min_keys);
                assert(left.len < B);
                assert(sep < self.len);
                assert(self.children[sep].assertLeaf() == left);
                assert(self.children[sep + 1].assertLeaf() == right);

                left.keys[left.len] = self.keys[sep];
                left.values[left.len] = self.values[sep];
                left.len += 1;

                self.keys[sep], self.values[sep] = right.remove(0);
            }

            /// Rotates `self.children[sep]` to the start of `right`, then replaces it with
            /// `left.remove(left.len - 1)`.
            fn rotateLeafRight(
                self: *InternalNode,
                left: *LeafNode,
                sep: u8,
                right: *LeafNode,
            ) void {
                assert(left.len > min_keys);
                assert(right.len < B);
                assert(sep < self.len);
                assert(self.children[sep].assertLeaf() == left);
                assert(self.children[sep + 1].assertLeaf() == right);

                const rlen = right.len;
                @memmove(right.keys[1 .. rlen + 1], right.keys[0..rlen]);
                @memmove(right.values[1 .. rlen + 1], right.values[0..rlen]);

                right.keys[0] = self.keys[sep];
                right.values[0] = self.values[sep];
                right.len += 1;

                self.keys[sep], self.values[sep] = left.removeLast();
            }

            /// Rotates `self.children[sep]` to the end of `left`, then replaces it with
            /// `right.remove(0)`.
            fn rotateInternalLeft(
                self: *InternalNode,
                left: *InternalNode,
                sep: u8,
                right: *InternalNode,
            ) void {
                assert(right.len > min_keys);
                assert(left.len < B);
                assert(self.children[sep].assertInternal() == left);
                assert(self.children[sep + 1].assertInternal() == right);

                // Move `self[sep]` to `left[left.len]`.
                left.keys[left.len] = self.keys[sep];
                left.values[left.len] = self.values[sep];

                // Move `right.children[0]` to `left.children[left.len + 1]`.
                left.children[left.len + 1] = right.children[0];
                right.children[0].setParent(left, left.len + 1);
                left.len += 1;

                // Move `right[0]` to `self[sep]`.
                self.keys[sep] = right.keys[0];
                self.values[sep] = right.values[0];

                // Shift `right[1..rlen]` to `right[0..rlen-1]` after moving `right[0]`.
                const rlen = right.len;
                @memmove(right.keys[0 .. rlen - 1], right.keys[1..rlen]);
                @memmove(right.values[0 .. rlen - 1], right.values[1..rlen]);
                @memmove(right.children[0..rlen], right.children[1 .. rlen + 1]);
                right.len -= 1;
                right.fixChildrenFrom(0);
            }

            /// Rotates `self.children[sep]` to the start of `right`, then replaces it with
            /// `left.remove(left.len - 1)`.
            fn rotateInternalRight(
                self: *InternalNode,
                left: *InternalNode,
                sep: u8,
                right: *InternalNode,
            ) void {
                assert(left.len > min_keys);
                assert(right.len < B);
                assert(self.children[sep].assertInternal() == left);
                assert(self.children[sep + 1].assertInternal() == right);

                // Shift `right[0..rlen]` to `right[1..rlen+1]` to free up `right[0]`.
                const rlen = right.len;
                @memmove(right.keys[1 .. rlen + 1], right.keys[0..rlen]);
                @memmove(right.values[1 .. rlen + 1], right.values[0..rlen]);
                @memmove(right.children[1 .. rlen + 2], right.children[0 .. rlen + 1]);

                // Move `self[sep]` to `right[0]`.
                right.keys[0] = self.keys[sep];
                right.values[0] = self.values[sep];

                // Move `left.children[left.len]` to `right.children[0]`.
                right.children[0] = left.children[left.len];
                right.len += 1;
                right.fixChildrenFrom(1);
                left.children[left.len].setParent(right, 0);

                // Move `left[left.len - 1]` to `self[sep]`.
                self.keys[sep] = left.keys[left.len - 1];
                self.values[sep] = left.values[left.len - 1];
                left.len -= 1;
            }
        };

        /// A tagged pointer to a `LeafNode` or `InternalNode`.
        const NodePtr = struct {
            comptime {
                // Ensure that both nodes are suitably aligned to store the tag.
                assert(@alignOf(LeafNode) > 1);
                assert(@alignOf(InternalNode) > 1);
            }

            const Tag = enum(u1) { leaf, internal };
            const tag_mask: usize = 1;
            const ptr_mask: usize = ~tag_mask;

            bits: usize,

            const nil: NodePtr = .{ .bits = 0 };

            fn orNull(self: NodePtr) ?NodePtr {
                return if (self.isNil()) null else self;
            }

            fn leaf(p: *LeafNode) NodePtr {
                return .{ .bits = @intFromPtr(p) | @intFromEnum(Tag.leaf) };
            }
            fn internal(p: *InternalNode) NodePtr {
                return .{ .bits = @intFromPtr(p) | @intFromEnum(Tag.internal) };
            }

            fn isNil(self: NodePtr) bool {
                return self.bits == 0;
            }
            fn isLeaf(self: NodePtr) bool {
                return (self.bits & tag_mask) == @intFromEnum(Tag.leaf);
            }

            fn asLeaf(self: NodePtr) ?*LeafNode {
                assert(!self.isNil());
                return if (self.isLeaf()) self.assertLeaf() else null;
            }
            fn asInternal(self: NodePtr) ?*InternalNode {
                assert(!self.isNil());
                return if (self.isLeaf()) null else self.assertInternal();
            }

            fn assertLeaf(self: NodePtr) *LeafNode {
                assert(self.isLeaf());
                return @ptrFromInt(self.bits & ptr_mask);
            }
            fn assertInternal(self: NodePtr) *InternalNode {
                assert(!self.isLeaf());
                return @ptrFromInt(self.bits & ptr_mask);
            }

            fn parent(self: NodePtr) ?*InternalNode {
                return if (self.isLeaf())
                    self.assertLeaf().parent
                else
                    self.assertInternal().parent;
            }
            fn setParent(self: NodePtr, new_parent: ?*InternalNode, new_parent_idx: u8) void {
                if (self.asLeaf()) |l| {
                    l.parent = new_parent;
                    l.parent_idx = new_parent_idx;
                } else {
                    self.assertInternal().parent = new_parent;
                    self.assertInternal().parent_idx = new_parent_idx;
                }
            }
            fn parentIdx(self: NodePtr) u8 {
                return if (self.isLeaf())
                    self.assertLeaf().parent_idx
                else
                    self.assertInternal().parent_idx;
            }
            fn len(self: NodePtr) u8 {
                return if (self.isLeaf())
                    self.assertLeaf().len
                else
                    self.assertInternal().len;
            }
            fn keys(self: NodePtr) *[B]K {
                return if (self.asLeaf()) |l| &l.keys else &self.assertInternal().keys;
            }
            fn values(self: NodePtr) *[B]V {
                return if (self.asLeaf()) |l| &l.values else &self.assertInternal().values;
            }

            fn leftmostLeafNode(self: NodePtr) NodePtr {
                var current = self;
                while (current.asInternal()) |n| current = n.children[0];
                return current;
            }
            fn rightmostLeafNode(self: NodePtr) NodePtr {
                var current = self;
                while (current.asInternal()) |n| current = n.children[n.len];
                return current;
            }

            inline fn leftmostLeaf(self: NodePtr) *LeafNode {
                return self.leftmostLeafNode().assertLeaf();
            }
            inline fn rightmostLeaf(self: NodePtr) *LeafNode {
                return self.rightmostLeafNode().assertLeaf();
            }
        };

        // -----------------------------------------------------------------------------------------
        // MARK: Search

        /// Returns the index in `keys` where `key` appears, or directly after that if it cannot be
        /// found.
        ///
        /// The second value is true iff `keys[index] == key`. That is, if false, the returned index
        /// is the insertion point, i.e. the first index whose key is strictly greater than `key`,
        /// which is also the child index to follow in an internal node.
        fn search(context: anytype, keys: []const K, key: anytype) struct { u8, bool } {
            assert(keys.len <= B);

            if (linear_search) {
                for (keys, 0..) |k, i| {
                    switch (context.order(k, key)) {
                        .lt => {},
                        .eq => return .{ @intCast(i), true },
                        .gt => return .{ @intCast(i), false },
                    }
                }
                return .{ @intCast(keys.len), false };
            } else {
                var lo: u16 = 0;
                var hi: u16 = @intCast(keys.len);
                while (lo < hi) {
                    // No need for an overflow trick here, `len` is always low enough.
                    const mid = lo + (hi - lo) / 2;

                    switch (context.order(keys[mid], key)) {
                        .lt => lo = mid + 1,
                        .eq => return .{ @intCast(mid), true },
                        .gt => hi = mid,
                    }
                }
                return .{ @intCast(lo), false };
            }
        }

        /// Returns the index in `keys` where `key` appears, or null if it cannot be found.
        inline fn searchIndex(context: anytype, keys: []const K, key: anytype) ?u8 {
            const index, const found = search(context, keys, key);
            return if (found) index else null;
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Insertion

        /// Assuming `self.root.len() == B`, replaces it with a new internal node and splits it into
        /// its children.
        fn splitFullRoot(self: *Self, allocator: Allocator) error{OutOfMemory}!void {
            const root = self.root;

            assert(!root.isNil());
            assert(root.len() == B);

            const new_root = try allocator.create(InternalNode);
            errdefer allocator.destroy(new_root);

            new_root.* = .{};
            new_root.children[0] = root;

            root.setParent(new_root, 0);

            // The old root is full by definition of this branch; this call must split it.
            try splitFullChild(allocator, new_root, 0);

            assert(new_root.len == 1);

            // Only update `self.root` after succeeding above.
            self.root = .internal(new_root);
        }

        /// Assuming `parent.children[parent_idx_before].len() == B`, splits it and promotes the
        /// median into `parent`.
        fn splitFullChild(
            allocator: Allocator,
            parent: *InternalNode,
            parent_idx_before: u8,
        ) error{OutOfMemory}!void {
            const child = parent.children[parent_idx_before];

            assert(child.len() == B);

            // Layout after split: left keeps `0..mid`, median is at `mid`, right takes `mid+1..B`.
            const mid: u8 = B / 2;
            const rlen: u8 = B - mid - 1;
            const parent_idx: u8 = parent_idx_before + 1;

            // Save median keys/values before the mutation below.
            const mid_key = child.keys()[mid];
            const mid_value = child.values()[mid];

            // Create the right node and update the left node.
            const right: NodePtr = if (child.asLeaf()) |left| blk: {
                const right = try allocator.create(LeafNode);
                right.* = .{ .parent = parent, .parent_idx = parent_idx, .len = rlen };
                @memcpy(right.keys[0..rlen], left.keys[mid + 1 .. B]);
                @memcpy(right.values[0..rlen], left.values[mid + 1 .. B]);

                left.len = mid;

                break :blk .leaf(right);
            } else blk: {
                const left = child.assertInternal();
                const right = try allocator.create(InternalNode);
                right.* = .{ .parent = parent, .parent_idx = parent_idx, .len = rlen };
                @memcpy(right.keys[0..rlen], left.keys[mid + 1 .. B]);
                @memcpy(right.values[0..rlen], left.values[mid + 1 .. B]);
                @memcpy(right.children[0 .. rlen + 1], left.children[mid + 1 .. B + 1]);
                right.fixChildrenFrom(0);

                left.len = mid;

                break :blk .internal(right);
            };

            parent.insert(parent_idx_before, mid_key, mid_value, right);
            parent.fixChildrenFrom(parent_idx_before + 2);
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Removal

        /// Removes the key-value pair at `idx` in `ptr`.
        fn removeAt(self: *Self, allocator: Allocator, ptr: NodePtr, idx: u8) KV {
            assert(idx < ptr.len());

            defer self.maybeCheckInvariantsNoContext();

            self.bumpGeneration();

            if (ptr.asLeaf()) |leaf| {
                const key, const value = leaf.remove(idx);
                self.len -= 1;
                self.fixAfterRemoval(allocator, ptr);
                return .{ .key = key, .value = value };
            }

            const node = ptr.assertInternal();
            const key = node.keys[idx];
            const value = node.values[idx];

            // Replace with leftmost key of the right subtree.
            const succ = node.children[idx + 1].leftmostLeaf();
            assert(succ.len >= 1);
            node.keys[idx], node.values[idx] = succ.remove(0);
            self.len -= 1;
            self.fixAfterRemoval(allocator, .leaf(succ));

            return .{ .key = key, .value = value };
        }

        /// Iterator position returned by `fixAfterRemovalAt()`.
        const Removal = struct { node: NodePtr, idx: u8 };

        /// Same as `fixAfterRemoval()`, but returns the iterator position immediately after the
        /// entry that was removed at `idx` from `ptr`. Returns `null` if the map is empty or the
        /// removed entry was the last.
        fn fixAfterRemovalAt(
            self: *Self,
            allocator: Allocator,
            ptr: NodePtr,
            idx: u8,
        ) ?Removal {
            var removal: RemovalLeaf = .{ .leaf = ptr.assertLeaf(), .idx = idx };
            self.fixAfterRemovalImpl(allocator, ptr, &removal);

            if (self.len == 0) return null;

            // `self.len > 0`, so there must be at least one node remaining, set in `removal.leaf`.
            if (removal.idx < removal.leaf.len) return .{ .node = .leaf(removal.leaf), .idx = removal.idx };

            // At end of leaf; walk up to the first ancestor where `current_idx < parent.len`.
            var current: NodePtr = .leaf(removal.leaf);

            while (current.parent()) |parent| {
                const current_idx = current.parentIdx();
                if (current_idx < parent.len) return .{ .node = .internal(parent), .idx = current_idx };
                current = .internal(parent);
            }

            return null;
        }

        /// Fixes a node after removing a key-value pair from it.
        fn fixAfterRemoval(self: *Self, allocator: Allocator, ptr: NodePtr) void {
            self.fixAfterRemovalImpl(allocator, ptr, null);
        }

        /// Leaf tracked by `fixAfterRemovalImpl()`.
        const RemovalLeaf = struct { leaf: *LeafNode, idx: u8 };

        /// Implementation of `fixAfterRemoval()` and `fixAfterRemovalAt()`.
        fn fixAfterRemovalImpl(
            self: *Self,
            allocator: Allocator,
            ptr: NodePtr,
            info: ?*RemovalLeaf,
        ) void {
            var current = ptr;

            // Whether we entered processed a leaf; we should only process leaves once, so this
            // ensures we don't enter an infinite loop below.
            var processed_leaf = if (options.check_invariants) false else {};

            while (current.parent()) |parent| {
                if (current.len() >= min_keys) return; // No need to fix.

                const current_idx: u8 = current.parentIdx();

                assert(current_idx <= parent.len);
                assert(parent.children[current_idx].bits == current.bits);

                // Try stealing from right sibling.
                if (current_idx < parent.len) {
                    const right = parent.children[current_idx + 1];

                    if (right.len() > min_keys) {
                        // Leaves have the same depth, so if `left` is a leaf, then so is `right`.
                        if (current.asLeaf()) |left| {
                            if (options.check_invariants) assert(!processed_leaf);

                            parent.rotateLeafLeft(left, current_idx, right.assertLeaf());

                            // Rotating left appends to `l` without shifting existing entries, so
                            // `cursor` does not need to be updated.
                        } else {
                            parent.rotateInternalLeft(current.assertInternal(), current_idx, right.assertInternal());
                        }
                        return;
                    }
                }

                // Try stealing from left sibling.
                if (current_idx > 0) {
                    const left = parent.children[current_idx - 1];

                    if (left.len() > min_keys) {
                        if (current.asLeaf()) |r| {
                            if (options.check_invariants) assert(!processed_leaf);

                            parent.rotateLeafRight(left.assertLeaf(), current_idx - 1, r);

                            // Rotating right shifts every entry of `current` right by one.
                            if (info) |i| i.idx += 1;
                        } else {
                            parent.rotateInternalRight(left.assertInternal(), current_idx - 1, current.assertInternal());
                        }
                        return;
                    }
                }

                // Merge with a sibling: right one if `current_idx == 0`, left one otherwise.
                const sep: u8 = if (current_idx == 0) 0 else current_idx - 1;

                if (current.isLeaf()) {
                    if (options.check_invariants) {
                        assert(!processed_leaf);
                        processed_leaf = true;
                    }

                    // Fix up cursor if needed.
                    if (info) |i| if (current_idx == 0) {
                        // Right sibling is destroyed, so the cursor is unchanged.
                    } else {
                        // Merged into the left sibling, which is now the survivor.
                        const left_leaf = parent.children[sep].assertLeaf();

                        i.leaf = left_leaf;
                        i.idx += @intCast(left_leaf.len + 1);
                    };
                }

                parent.mergeNextInto(allocator, sep);

                // Keep fixing up.
                current = .internal(parent);
            }

            // `current` is the root.
            if (current.asLeaf()) |leaf| {
                if (leaf.len == 0) {
                    allocator.destroy(leaf);
                    self.root = .nil;
                }
                return;
            }

            const node = current.assertInternal();
            if (node.len == 0) {
                // Sole child becomes new root.
                const new_root = node.children[0];
                new_root.setParent(null, 0);
                self.root = new_root;
                allocator.destroy(node);
            }
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Invariants

        /// Calls `self.checkInvariantsAdapted(context)` if `options.check_invariants` is true.
        fn maybeCheckInvariants(self: *const Self, context: anytype) void {
            if (options.check_invariants) self.checkInvariantsAdapted(context);
        }

        /// Calls `self.checkInvariants()` if `options.check_invariants` is true and the `Context`
        /// can be synthesized.
        fn maybeCheckInvariantsNoContext(self: *const Self) void {
            if (options.check_invariants and @sizeOf(Context) == 0) self.checkInvariants();
        }

        /// Check all structural invariants of the tree. Panics on violation.
        pub fn checkInvariants(self: *const Self) void {
            self.checkInvariantsContext(implicitContext("checkInvariants"));
        }
        pub fn checkInvariantsContext(self: *const Self, context: Context) void {
            self.checkInvariantsAdapted(context);
        }
        pub fn checkInvariantsAdapted(self: *const Self, context: anytype) void {
            const root = self.root.orNull() orelse {
                assert(self.len == 0);
                return;
            };

            // Verify the root has no parent.
            assert(root.parent() == null);

            // Verify the tree.
            var total_count: usize = 0;
            _ = checkSubtree(root, null, 0, context, &total_count, null, null);
            assert(self.len == total_count);

            // Verify the iterator.
            var prev_key: ?K = null;
            var it = self.constIterator();
            var it_len: usize = 0;
            while (it.next()) |kv| {
                if (prev_key) |key| {
                    assert(context.order(key, kv.key) == .lt);
                }
                prev_key = kv.key;
                it_len += 1;
            }
            assert(self.len == it_len);
        }

        /// Recursively checks a subtree rooted at `ptr`.
        ///
        /// This is intentionally recursive (rather than iterative) as it is a debug tool.
        ///
        /// Returns the depth of leaves in this subtree (to check for equality). `parent` and
        /// `min_key` / `max_key` are used to verify ordering.
        fn checkSubtree(
            ptr: NodePtr,
            parent_node: ?*InternalNode,
            depth: usize,
            context: anytype,
            total_count: *usize,
            min_key: ?K,
            max_key: ?K,
        ) usize {
            // Verify parent link.
            assert(ptr.parent() == parent_node);

            const len = ptr.len();
            total_count.* += len;

            // Non-root nodes must have `>= min_keys` keys.
            if (parent_node != null) assert(len >= min_keys);

            // Nodes must have `<= B` keys.
            assert(len <= B);

            // Keys must be strictly ascending.
            const keys = if (ptr.asLeaf()) |leaf| leaf.keys else ptr.assertInternal().keys;

            for (keys[0..len], 0..) |k, i| {
                if (i > 0) assert(context.order(keys[i - 1], k) == .lt);
                if (min_key) |mk| assert(context.order(mk, k) == .lt);
                if (max_key) |xk| assert(context.order(k, xk) == .lt);
            }

            const node = ptr.asInternal() orelse return depth;
            const child_count = @as(u16, node.len) + 1;

            var common_depth: ?usize = null;

            for (0..child_count) |i| {
                // Verify `parent_idx`.
                const child = node.children[i];
                assert(child.parentIdx() == i);

                // Recurse.
                const child_min = if (i > 0) node.keys[i - 1] else min_key;
                const child_max = if (i < node.len) node.keys[i] else max_key;

                const child_depth = checkSubtree(child, node, depth + 1, context, total_count, child_min, child_max);

                // Verify that all leaves have the same depth.
                if (common_depth) |ld| assert(child_depth == ld) else common_depth = child_depth;
            }

            return common_depth.?;
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Misc

        const Self = @This();

        /// Bumps the current generation; should be called after every mutation.
        inline fn bumpGeneration(self: *Self) void {
            if (track_generation) self.generation +%= 1;
        }

        /// Returns the implicit context used by functions without `Context` or `Adapted` suffixes.
        /// If such a context is unavailable, emits a `@compileError()`.
        inline fn implicitContext(comptime fnName: []const u8) Context {
            if (@sizeOf(Context) != 0)
                @compileError(fnName ++ "() may not be used with a non-zero-sized Context type; use " ++ fnName ++ "Context() instead");

            return undefined;
        }

        /// Transforms a possibly adapted key into `K`.
        inline fn toKey(
            allocator: Allocator,
            key: anytype,
            context: anytype,
        ) KeyConversionError(@TypeOf(key), @TypeOf(context))!K {
            if (@TypeOf(key) == K) return key;
            if (@typeInfo(@TypeOf(context.toKey(allocator, key))) == .error_union) return try context.toKey(allocator, key);
            return context.toKey(allocator, key);
        }

        /// Returns data (keys, values, context) that can be used in tests.
        ///
        /// The tests run on different combinations of `K`, `V`, `B`, and `Context`, so we need this
        /// to make the tests run on different types.
        inline fn testData() error{SkipZigTest}!struct { [B * 10]K, [B * 10]V, Context } {
            return sampleDataFor(Self);
        }

        // -----------------------------------------------------------------------------------------
        // MARK: Managed

        /// A wrapper around a `BTreeMap` with embedded `Allocator` and `Context`.
        pub const Managed = struct {
            pub const Unmanaged = Self;
            pub const Key = Self.Key;
            pub const Value = Self.Value;
            pub const Context = Self.Context;
            pub const KV = Self.KV;
            pub const GetOrPutResult = Self.GetOrPutResult;

            unmanaged: Unmanaged,
            allocator: Allocator,
            context: Self.Context,

            fn fromUnmanaged(unmanaged: *Unmanaged) *Managed {
                return @fieldParentPtr("unmanaged", unmanaged.map);
            }

            pub fn init(allocator: Allocator) Managed {
                return .initContext(allocator, implicitContext("init"));
            }
            pub fn initContext(allocator: Allocator, context: Managed.Context) Managed {
                return .{ .unmanaged = .empty, .allocator = allocator, .context = context };
            }

            pub fn deinit(self: *Managed) void {
                self.unmanaged.deinit(self.allocator);
            }

            pub fn clear(self: *Managed) void {
                self.unmanaged.clear(self.allocator);
            }

            pub fn count(self: *const Managed) usize {
                return self.unmanaged.count();
            }

            pub fn get(self: *const Managed, key: K) ?V {
                return self.unmanaged.getContext(key, self.context);
            }
            pub fn getPtr(self: *Managed, key: K) ?*V {
                return self.unmanaged.getPtrContext(key, self.context);
            }

            pub fn contains(self: *const Managed, key: K) bool {
                return self.unmanaged.containsContext(key, self.context);
            }

            pub const OccupiedEntry = struct {
                unmanaged: Self.OccupiedEntry,

                pub fn replace(self: @This(), value: V) V {
                    return self.unmanaged.replace(value);
                }

                pub fn remove(self: @This()) Managed.KV {
                    const managed: *Managed = .fromUnmanaged(self.unmanaged.map);
                    return self.unmanaged.remove(managed.allocator);
                }
            };

            pub const VacantEntry = struct {
                unmanaged: Self.VacantEntry,

                pub fn insert(self: @This()) Managed.OccupiedEntry {
                    const managed: *Managed = .fromUnmanaged(self.unmanaged.map);
                    return .{ .unmanaged = self.unmanaged.insert(managed.allocator) };
                }
            };

            pub const Entry = union(enum) {
                occupied: Managed.OccupiedEntry,
                vacant: Managed.VacantEntry,
            };

            pub fn occupiedEntry(self: *Managed, key: K) ?Managed.OccupiedEntry {
                const e = self.unmanaged.occupiedEntryContext(key, self.context) orelse return null;
                return .{ .unmanaged = e };
            }
            pub fn entry(self: *Managed, key: K) error{OutOfMemory}!Managed.Entry {
                return switch (try self.unmanaged.entryContext(self.allocator, key, self.context)) {
                    .occupied => |e| .{ .occupied = .{ .unmanaged = e } },
                    .vacant => |e| .{ .vacant = .{ .unmanaged = e } },
                };
            }

            pub fn put(self: *Managed, key: K, value: V) error{OutOfMemory}!?V {
                return self.unmanaged.putContext(self.allocator, key, value, self.context);
            }
            pub fn getOrPut(self: *Managed, key: K) error{OutOfMemory}!Managed.GetOrPutResult {
                return self.unmanaged.getOrPutContext(self.allocator, key, self.context);
            }
            pub fn getOrPutValue(self: *Managed, key: K, value: V) error{OutOfMemory}!Managed.GetOrPutResult {
                return self.unmanaged.getOrPutValueContext(self.allocator, key, value, self.context);
            }

            pub fn remove(self: *Managed, key: K) ?Managed.KV {
                return self.unmanaged.removeContext(self.allocator, key, self.context);
            }

            pub const Iterator = struct {
                unmanaged: Self.Iterator,

                pub fn next(self: *@This()) ?struct { *K, *V } {
                    return self.unmanaged.next();
                }

                pub fn previous(self: *@This()) ?struct { *K, *V } {
                    return self.unmanaged.previous();
                }

                pub fn peek(self: *const @This()) ?struct { *K, *V } {
                    return self.unmanaged.peek();
                }

                pub fn moveNext(self: *@This()) void {
                    self.unmanaged.moveNext();
                }

                pub fn movePrevious(self: *@This()) void {
                    self.unmanaged.movePrevious();
                }

                pub fn removeAndMoveNext(self: *@This()) Managed.KV {
                    const managed: *Managed = .fromUnmanaged(self.unmanaged.map);
                    return self.unmanaged.removeAndMoveNext(managed.allocator);
                }

                pub fn removeAndMovePrevious(self: *@This()) Managed.KV {
                    const managed: *Managed = .fromUnmanaged(self.unmanaged.map);
                    return self.unmanaged.removeAndMovePrevious(managed.allocator);
                }
            };

            pub fn iterator(self: *Managed) Managed.Iterator {
                return .{ .unmanaged = self.unmanaged.iterator() };
            }

            pub const ConstIterator = Self.ConstIterator;

            pub fn constIterator(self: *const Managed) Managed.ConstIterator {
                return self.unmanaged.constIterator();
            }

            pub fn retain(
                self: *Managed,
                context: anytype,
                comptime f: fn (@TypeOf(context), K, *V) bool,
            ) void {
                self.unmanaged.retain(self.allocator, context, f);
            }

            pub fn first(self: *const Managed) ?Managed.KV {
                return self.unmanaged.first();
            }
            pub fn firstEntry(self: *Managed) ?Managed.OccupiedEntry {
                return .{ .unmanaged = self.unmanaged.firstEntry() orelse return null };
            }

            pub fn last(self: *const Managed) ?Managed.KV {
                return self.unmanaged.last();
            }
            pub fn lastEntry(self: *Managed) ?Managed.OccupiedEntry {
                return .{ .unmanaged = self.unmanaged.lastEntry() orelse return null };
            }

            pub fn checkInvariants(self: *const Managed) void {
                self.unmanaged.checkInvariantsContext(self.context);
            }
        };
    };
}

// -------------------------------------------------------------------------------------------------
// MARK: AutoContext

/// Returns a type which can be used as `Context` in `BTreeMap` for trivially comparable types:
///
/// - `bool`, `enum`s, integers, and floats.
/// - Slices and arrays thereof.
pub fn AutoContext(comptime K: type) type {
    const linear_search_max_bytes = 512;

    return switch (@typeInfo(K)) {
        .pointer => |ptr| blk: {
            comptime checkAutoContextScalar(ptr.child);

            break :blk switch (ptr.size) {
                .one => struct {
                    pub const prefer_linear_search: bool = @sizeOf(K) <= linear_search_max_bytes;

                    pub fn order(_: @This(), a: K, b: K) Order {
                        return std.math.order(a.*, b.*);
                    }
                },
                .slice => struct {
                    pub fn order(_: @This(), a: K, b: K) Order {
                        return std.mem.order(ptr.child, a, b);
                    }
                },
                .many => struct {
                    comptime {
                        const sentinel = ptr.sentinel() orelse
                            @compileError("a pointer of an unknown size may not be used with AutoContext");
                        if (sentinel != 0) @compileError("only 0 may be used as a sentinel in AutoContext");
                    }

                    pub fn order(_: @This(), a: K, b: K) Order {
                        return std.mem.orderZ(ptr.child, a, b);
                    }
                },
                .c => @compileError("a C pointer type may not be used with AutoContext"),
            };
        },

        .array => |array| struct {
            comptime {
                checkAutoContextScalar(array.child);
            }

            pub const prefer_linear_search: bool = @sizeOf(K) <= linear_search_max_bytes;

            pub fn order(_: @This(), a: K, b: K) Order {
                return std.mem.order(array.child, a, b);
            }
        },

        else => struct {
            comptime {
                checkAutoContextScalar(K);
            }

            pub const prefer_linear_search: bool = @sizeOf(K) <= linear_search_max_bytes;

            pub fn order(_: @This(), a: K, b: K) Order {
                return std.math.order(a, b);
            }
        },
    };
}

/// Emits a `@compileError()` if `t` may not be used as a scalar in `AutoContext`.
fn checkAutoContextScalar(comptime t: type) void {
    switch (@typeInfo(t)) {
        .bool, .@"enum", .int, .float => {},
        else => @compileError("type " ++ @typeName(t) ++ " cannot be used in AutoContext"),
    }
}

// -------------------------------------------------------------------------------------------------
// MARK: Test helpers

/// Returns `n` keys used for testing, or `SkipZigTest` if the key type `K` is not supported.
pub fn sampleKeys(comptime K: type, comptime n: usize) error{SkipZigTest}![n]K {
    @setEvalBranchQuota(50000);

    var result: [n]K = undefined;

    inline for (0..n) |i| {
        result[i] = switch (@typeInfo(K)) {
            .int => @intCast(i),
            .pointer => std.fmt.comptimePrint("{}", .{i}),
            else => return error.SkipZigTest,
        };
    }

    return result;
}

/// Returns `n` values used for testing, or `SkipZigTest` if the value type `V` is not supported.
pub fn sampleValues(comptime V: type, comptime n: usize) error{SkipZigTest}![n]V {
    if (V == void) return [_]void{{}} ** n;
    return try sampleKeys(V, n);
}

pub fn sampleContext(comptime C: type) C {
    if (@sizeOf(C) == 0) return undefined;
    return .empty;
}

/// Returns sample data used for testing, or `SkipZigTest` if the
pub fn sampleDataFor(
    comptime Map: type,
) error{SkipZigTest}!struct { [Map.B * 10]Map.Key, [Map.B * 10]Map.Value, Map.Context } {
    return .{
        try sampleKeys(Map.Key, Map.B * 10),
        sampleValues(Map.Value, Map.B * 10) catch unreachable, // All values should be supported.
        sampleContext(Map.Context),
    };
}

pub fn sampleContextIsReversed(comptime C: type) bool {
    return @hasField(C, "reversed");
}

// -------------------------------------------------------------------------------------------------
// MARK: Declaration tests

test {
    const U32 = AutoContext(u32);

    testing.refAllDecls(BTreeMap(u32, u32, U32, .{}));

    // Different options.
    testing.refAllDecls(BTreeMap(u32, u32, U32, .{ .B = 4 }));
    testing.refAllDecls(BTreeMap(u32, u32, U32, .{ .B = 7 }));
    testing.refAllDecls(BTreeMap(u32, u32, U32, .{ .B = 32, .search = .binary }));
    testing.refAllDecls(BTreeMap(u32, u32, U32, .{ .B = 32, .search = .linear }));
    testing.refAllDecls(BTreeMap(u32, u32, U32, .{ .B = 254 }));

    // String keys.
    testing.refAllDecls(BTreeMap([]const u8, u32, AutoContext([]const u8), .{}));

    // Void values.
    testing.refAllDecls(BTreeMap(u32, void, U32, .{}));

    // Managed.
    testing.refAllDecls(BTreeMap(u32, void, U32, .{}).Managed);

    // Reversed.
    const ReversedU32 = struct {
        comptime reversed: bool = true,

        pub fn order(_: @This(), a: u32, b: u32) Order {
            return std.math.order(a, b).invert();
        }
    };

    testing.refAllDecls(BTreeMap(u32, u32, ReversedU32, .{}));
}
