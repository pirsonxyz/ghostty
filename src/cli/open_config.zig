const std = @import("std");
const Action = @import("action.zig").Action;
const open_config = @import("../config/edit.zig").open;
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

/// Open the configuration file in default editor.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    try open_config(alloc);
    return 0;
}
