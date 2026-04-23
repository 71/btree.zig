# btree.zig

A [Zig](https://ziglang.org/) [B-Tree](https://en.wikipedia.org/wiki/B-tree)
implementation.

- Standard APIs to query, update, and remove entries:

  ```zig
  var map: BTreeMap(u32, u32, AutoContext(u32), .{}) = .empty;
  defer map.deinit(allocator);

  _ = try map.put(allocator, 1, 100);
  _ = try map.put(allocator, 2, 200);

  try std.testing.expectEqual(100, map.get(1));
  try std.testing.expect(map.contains(2));

  const removed = map.remove(allocator, 1).?;
  try std.testing.expectEqual(100, removed.value);
  ```

- Allocating entry API:

  ```zig
  switch (try map.entry(allocator, 42)) {
      .occupied => |e| _ = e.replace(11),  // Or `e.remove(allocator)`.
      .vacant => |e| _ = e.insert(42),     // Yields `OccupiedEntry`.
  }
  ```

- Non-allocating entry API:

  ```zig
  if (map.occupiedEntry(42)) |e| {
      _ = e.remove(allocator);
  }
  ```

- Iteration, including `next()` and `removeAndAdvance()`:

  ```zig
  var it = map.iterator();

  while (it.peek()) |kv| {
      const key_ptr, _ = kv;

      if (key_ptr.* % 2 == 0) {
          _ = it.removeAndAdvance(allocator);
      } else {
          it.advance();
      }
  }
  ```

- Allocating operations take a `std.mem.Allocator` as argument.

- Customizable: custom capacity, search strategy, and contexts can be given. All
  operations also support "adapted" variants that can compare keys of different
  types (e.g. `std.ArrayList(u8)` and `[]const u8`, see
  [`src/tests/suite.zig`](src/tests/suite.zig)).

- Tested, documented, and fuzzed.

## Installation

Using `zig fetch`:

```sh
zig fetch --save https://github.com/71/btree.zig/archive/<git-ref>.tar.gz
```

## Disclaimer

The "core" of the logic was initially written by an LLM (with the overall
design, API, feature set, testing, fuzzing, and documentation coming from me). I
then reviewed it and improved on it, fixing bugs with the help of that same LLM.

Most of the final code is mine, tests pass, and the fuzzer didn't find anything
after 40M runs, but the fixes _were_ made by an LLM.
