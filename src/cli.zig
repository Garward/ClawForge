const std = @import("std");
const common = @import("common");
const client = @import("client");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var config = try common.Config.load(allocator, null);
    defer config.deinit();

    // Initialize display
    var display = client.Display.init(&config);

    // Parse arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try display.printHelp();
        return;
    }

    // Check for help/version flags
    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        try display.printHelp();
        return;
    }

    if (std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "--version")) {
        try display.write("ClawForge v0.1.0\n");
        return;
    }

    // Get socket path
    const socket_path = try common.config.getSocketPath(allocator, &config);
    defer allocator.free(socket_path);

    // Connect to daemon
    var conn = client.Connection.connect(allocator, socket_path) catch |err| {
        try display.printError("Could not connect to daemon at {s}: {s}", .{ socket_path, @errorName(err) });
        try display.printError("Is the daemon running? Start it with: clawforged", .{});
        return;
    };
    defer conn.deinit();

    // Parse and execute command
    const parse_result = try parseCommand(allocator, args[1..], &display);
    if (parse_result.request) |req| {
        defer if (parse_result.allocated_string) |s| allocator.free(s);
        try conn.send(req);
        try conn.receiveStreaming(&display);
    }
}

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    // Calculate total length
    var total_len: usize = 0;
    for (args, 0..) |arg, i| {
        total_len += arg.len;
        if (i > 0) total_len += 1; // space
    }

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            result[pos] = ' ';
            pos += 1;
        }
        @memcpy(result[pos..][0..arg.len], arg);
        pos += arg.len;
    }
    return result;
}

const ParseResult = struct {
    request: ?common.Request,
    allocated_string: ?[]const u8,
};

fn parseCommand(allocator: std.mem.Allocator, args: []const []const u8, display: *client.Display) !ParseResult {
    if (args.len == 0) {
        try display.printHelp();
        return .{ .request = null, .allocated_string = null };
    }

    const cmd = args[0];

    const no_alloc = ParseResult{ .request = null, .allocated_string = null };

    // Session commands
    if (std.mem.eql(u8, cmd, "session")) {
        if (args.len < 2) {
            try display.printError("Usage: clawforge session <list|new|switch|delete>", .{});
            return no_alloc;
        }

        const subcmd = args[1];

        if (std.mem.eql(u8, subcmd, "list")) {
            return .{ .request = .{ .session_list = {} }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "new")) {
            const name = if (args.len > 2) args[2] else null;
            return .{ .request = .{ .session_create = .{ .name = name } }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "switch")) {
            if (args.len < 3) {
                try display.printError("Usage: clawforge session switch <id>", .{});
                return no_alloc;
            }
            return .{ .request = .{ .session_switch = args[2] }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "delete")) {
            if (args.len < 3) {
                try display.printError("Usage: clawforge session delete <id>", .{});
                return no_alloc;
            }
            return .{ .request = .{ .session_delete = args[2] }, .allocated_string = null };
        } else {
            try display.printError("Unknown session command: {s}", .{subcmd});
            return no_alloc;
        }
    }

    // Model commands
    if (std.mem.eql(u8, cmd, "model")) {
        if (args.len < 2) {
            try display.printError("Usage: clawforge model <list|set>", .{});
            return no_alloc;
        }

        const subcmd = args[1];

        if (std.mem.eql(u8, subcmd, "list")) {
            return .{ .request = .{ .model_list = {} }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "auto")) {
            return .{ .request = .{ .model_set = "auto" }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "set")) {
            if (args.len < 3) {
                try display.printError("Usage: clawforge model set <model>", .{});
                return no_alloc;
            }
            return .{ .request = .{ .model_set = args[2] }, .allocated_string = null };
        } else {
            try display.printError("Unknown model command: {s}", .{subcmd});
            return no_alloc;
        }
    }

    // Auth commands
    if (std.mem.eql(u8, cmd, "auth")) {
        if (args.len < 2) {
            try display.printError("Usage: clawforge auth <list|add|remove|switch|status>", .{});
            return no_alloc;
        }

        const subcmd = args[1];

        if (std.mem.eql(u8, subcmd, "list")) {
            return .{ .request = .{ .auth_list = {} }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "add")) {
            if (args.len < 4) {
                try display.printError("Usage: clawforge auth add <id> <token>", .{});
                return no_alloc;
            }
            return .{ .request = .{ .auth_add = .{
                .id = args[2],
                .credential = args[3],
                .provider = if (args.len > 4) args[4] else "anthropic",
            } }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "remove")) {
            if (args.len < 3) {
                try display.printError("Usage: clawforge auth remove <id>", .{});
                return no_alloc;
            }
            return .{ .request = .{ .auth_remove = args[2] }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "switch")) {
            if (args.len < 3) {
                try display.printError("Usage: clawforge auth switch <id>", .{});
                return no_alloc;
            }
            return .{ .request = .{ .auth_switch = args[2] }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "status")) {
            return .{ .request = .{ .auth_status = {} }, .allocated_string = null };
        } else {
            try display.printError("Unknown auth command: {s}", .{subcmd});
            return no_alloc;
        }
    }

    // Project commands
    if (std.mem.eql(u8, cmd, "project")) {
        if (args.len < 2) {
            try display.printError("Usage: clawforge project <list|create|info|attach|detach>", .{});
            return no_alloc;
        }

        const subcmd = args[1];

        if (std.mem.eql(u8, subcmd, "list")) {
            return .{ .request = .{ .project_list = {} }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "create")) {
            if (args.len < 3) {
                try display.printError("Usage: clawforge project create <name> [description]", .{});
                return no_alloc;
            }
            const desc = if (args.len > 3) try joinArgs(allocator, args[3..]) else null;
            return .{ .request = .{ .project_create = .{
                .name = args[2],
                .description = desc,
            } }, .allocated_string = desc };
        } else if (std.mem.eql(u8, subcmd, "info")) {
            if (args.len < 3) {
                try display.printError("Usage: clawforge project info <name>", .{});
                return no_alloc;
            }
            return .{ .request = .{ .project_info = args[2] }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "attach")) {
            if (args.len < 3) {
                try display.printError("Usage: clawforge project attach <name>", .{});
                return no_alloc;
            }
            return .{ .request = .{ .project_attach = args[2] }, .allocated_string = null };
        } else if (std.mem.eql(u8, subcmd, "detach")) {
            return .{ .request = .{ .project_detach = {} }, .allocated_string = null };
        } else {
            try display.printError("Unknown project command: {s}", .{subcmd});
            return no_alloc;
        }
    }

    // System prompt
    if (std.mem.eql(u8, cmd, "system")) {
        if (args.len < 2) {
            return .{ .request = .{ .system_set = null }, .allocated_string = null };
        }
        const prompt = try joinArgs(allocator, args[1..]);
        return .{ .request = .{ .system_set = prompt }, .allocated_string = prompt };
    }

    // Status
    if (std.mem.eql(u8, cmd, "status")) {
        return .{ .request = .{ .status = {} }, .allocated_string = null };
    }

    // Stop daemon
    if (std.mem.eql(u8, cmd, "stop")) {
        return .{ .request = .{ .stop = {} }, .allocated_string = null };
    }

    // Default: treat as chat message
    const message = try joinArgs(allocator, args);
    return .{ .request = .{ .chat = .{ .message = message } }, .allocated_string = message };
}
