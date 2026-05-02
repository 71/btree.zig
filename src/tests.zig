const testing = @import("std").testing;

test {
    testing.refAllDecls(@import("tests/fuzz.zig"));
    testing.refAllDecls(@import("tests/non_zero_sized_context.zig"));
    testing.refAllDecls(@import("tests/suite.zig"));
}
