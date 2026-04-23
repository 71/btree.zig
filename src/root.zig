const btree = @import("BTreeMap.zig");
const std = @import("std");
const testing = std.testing;

pub const BTreeMap = btree.BTreeMap;
pub const Options = btree.Options;
pub const GlobalOptions = btree.GlobalOptions;
pub const AutoContext = btree.AutoContext;

test {
    testing.refAllDecls(@import("tests/fuzz.zig"));
    testing.refAllDecls(@import("tests/non_zero_sized_context.zig"));
    testing.refAllDecls(@import("tests/suite.zig"));
}
