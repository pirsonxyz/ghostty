const std = @import("std");
const Action = @import("action.zig").Action;
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

/// Open the configuration file in $EDITOR
pub fn run(_: Allocator) !u8 {
    return 0;
}
