const std = @import("std");
const testing = std.testing;
const btree = @import("BTreeMap.zig");

const BTreeMap = btree.BTreeMap;
const Options = btree.Options;
const AutoContext = btree.AutoContext;

fn benchmark(
    allocator: std.mem.Allocator,
    random: std.Random,
    comptime K: type,
    comptime options: Options,
) !void {
    const Map = BTreeMap(K, void, AutoContext(K), options);

    var map: Map = .empty;
    defer map.deinit(allocator);

    for (0..1000) |_| {
        _ = try map.getOrPut(allocator, random.int(u32));
    }
}

pub fn main(init: std.process.Init) !void {
    const seed_str = init.environ_map.get("BTREE_SEED") orelse "0";
    var random: std.Random = undefined;

    if (seed_str.len == 0 or std.mem.eql(u8, seed_str, "0")) {
        var io = init.io;

        random = .init(&io, struct {
            fn f(io_ptr: *std.Io, buf: []u8) void {
                io_ptr.random(buf);
            }
        }.f);
    } else {
        var seed = try std.fmt.parseUnsigned(u64, seed_str, 0);

        random = .init(&seed, struct {
            fn f(seed_ptr: *u64, random_buf: []u8) void {
                const seed_bytes: []const u8 = @ptrCast(seed_ptr);
                var buf = random_buf;

                while (buf.len > seed_bytes.len) {
                    @memcpy(buf[0..8], seed_bytes);
                    buf = buf[8..];
                }

                @memcpy(buf, seed_bytes[0..buf.len]);
            }
        }.f);
    }

    try benchmark(init.gpa, random, u32, .{});
}
