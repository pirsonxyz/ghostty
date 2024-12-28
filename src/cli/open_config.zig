const std = @import("std");
const Action = @import("action.zig").Action;
const open = @import("../config/edit.zig").open;
const Allocator = std.mem.Allocator;
pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Open the configuration file in default editor
pub fn run(alloc: Allocator) !u8 {
    try open(alloc);
    return 0;
}
