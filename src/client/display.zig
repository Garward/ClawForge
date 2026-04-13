const std = @import("std");
const common = @import("common");
const posix = std.posix;

pub const Display = struct {
    stdout_fd: posix.fd_t,
    is_tty: bool,
    color_enabled: bool,
    show_tool_calls: bool,
    show_token_usage: bool,

    const RESET = "\x1b[0m";
    const BOLD = "\x1b[1m";
    const DIM = "\x1b[2m";
    const RED = "\x1b[31m";
    const GREEN = "\x1b[32m";
    const YELLOW = "\x1b[33m";
    const BLUE = "\x1b[34m";
    const CYAN = "\x1b[36m";

    pub fn init(config: *const common.Config) Display {
        const stdout_fd = posix.STDOUT_FILENO;
        const stdout_file = std.fs.File{ .handle = stdout_fd };
        const is_tty = stdout_file.isTty();

        return .{
            .stdout_fd = stdout_fd,
            .is_tty = is_tty,
            .color_enabled = is_tty and config.display.color_output,
            .show_tool_calls = config.display.show_tool_calls,
            .show_token_usage = config.display.show_token_usage,
        };
    }

    pub fn write(self: *Display, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += posix.write(self.stdout_fd, data[written..]) catch |err| {
                return err;
            };
        }
    }

    fn print(self: *Display, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => {
                try self.write(buf[0..]);
                return;
            },
        };
        try self.write(result);
    }

    pub fn handleResponse(self: *Display, response: common.Response) !void {
        switch (response) {
            .stream_start => |start| {
                if (self.show_tool_calls) {
                    try self.printDim("[{s}]\n", .{start.model});
                }
            },
            .stream_text => |text| {
                try self.write(text);
            },
            .stream_tool_use => |tool| {
                if (self.show_tool_calls) {
                    try self.printColored(YELLOW, "\n[Tool: {s}]\n", .{tool.tool_name});
                    try self.printDim("{s}\n", .{tool.input});
                }
            },
            .stream_tool_result => |result| {
                if (self.show_tool_calls) {
                    if (result.is_error) {
                        try self.printColored(RED, "[Result] ", .{});
                    } else {
                        try self.printColored(GREEN, "[Result] ", .{});
                    }
                    try self.print("{s}\n", .{result.result});
                }
            },
            .stream_end => |end| {
                try self.write("\n");
                if (self.show_token_usage) {
                    try self.printDim("\n[", .{});
                    if (end.model) |m| {
                        try self.printDim("{s}, ", .{m});
                    }
                    try self.printDim("{d} in / {d} out tokens", .{ end.input_tokens, end.output_tokens });
                    if (end.stop_reason) |reason| {
                        try self.printDim(", stop: {s}", .{reason});
                    }
                    try self.printDim("]\n", .{});
                }
            },
            .tool_confirm_request => |confirm| {
                try self.printColored(YELLOW, "\nTool requires confirmation: {s}\n", .{confirm.tool_name});
                try self.printDim("Input: {s}\n", .{confirm.input_preview});
                try self.write("Allow? [y/N]: ");
            },
            .session_list => |sessions| {
                try self.printColored(BOLD, "Sessions:\n", .{});
                for (sessions) |sess| {
                    const name = sess.name orelse "(unnamed)";
                    try self.print("  {s}  {s}  ({d} messages)\n", .{ sess.id, name, sess.message_count });
                }
            },
            .session_created => |created| {
                try self.printColored(GREEN, "Created session: {s}\n", .{created.id});
            },
            .model_list => |models| {
                try self.printColored(BOLD, "Available models:\n", .{});
                for (models) |model| {
                    try self.print("  {s}\n", .{model});
                }
            },
            .status => |status| {
                try self.printColored(BOLD, "ClawForge Daemon Status\n", .{});
                try self.print("  Version: {s}\n", .{status.version});
                try self.print("  Uptime: {d}s\n", .{status.uptime_seconds});
                try self.print("  Active sessions: {d}\n", .{status.active_sessions});
                if (status.current_session) |sess| {
                    try self.print("  Current session: {s}\n", .{sess});
                }
            },
            .error_resp => |err| {
                try self.printColored(RED, "Error [{s}]: {s}\n", .{ err.code, err.message });
            },
            .ok => {
                try self.printColored(GREEN, "OK\n", .{});
            },
            .auth_list => |profiles| {
                try self.printColored(BOLD, "Auth Profiles:\n", .{});
                if (profiles.len == 0) {
                    try self.printDim("  (no profiles configured)\n", .{});
                } else {
                    for (profiles) |profile| {
                        const active_marker: []const u8 = if (profile.is_active) "*" else " ";
                        try self.print(" {s} {s}  [{s}] {s}", .{
                            active_marker,
                            profile.id,
                            profile.profile_type,
                            profile.provider,
                        });
                        if (!std.mem.eql(u8, profile.status, "ok")) {
                            try self.printColored(YELLOW, " ({s})", .{profile.status});
                        }
                        try self.write("\n");
                    }
                }
            },
            .project_list => |projects| {
                try self.printColored(BOLD, "Projects:\n", .{});
                if (projects.len == 0) {
                    try self.printDim("  (no projects)\n", .{});
                } else {
                    for (projects) |proj| {
                        var num_buf: [32]u8 = undefined;
                        const id_str = std.fmt.bufPrint(&num_buf, "{d}", .{proj.id}) catch "?";
                        try self.print("  [{s}] {s}  ({s})\n", .{ id_str, proj.name, proj.status });
                    }
                }
            },
            .project_info => |info| {
                try self.printColored(BOLD, "Project: {s}\n", .{info.name});
                try self.print("  Status: {s}\n", .{info.status});
                if (info.description) |d| {
                    try self.print("  Description: {s}\n", .{d});
                }
                if (info.rolling_summary) |s| {
                    try self.printColored(BOLD, "\nRolling Summary:\n", .{});
                    try self.print("{s}\n", .{s});
                } else {
                    try self.printDim("\n  (no rolling summary yet)\n", .{});
                }
            },
            .auth_status => |status| {
                try self.printColored(BOLD, "Auth Status\n", .{});
                try self.print("  Profile count: {d}\n", .{status.profile_count});
                if (status.active_profile) |profile| {
                    try self.print("  Active profile: {s}\n", .{profile});
                } else {
                    try self.printDim("  Active profile: (none)\n", .{});
                }
                if (status.active_provider) |provider| {
                    try self.print("  Provider: {s}\n", .{provider});
                }
                try self.print("  Cooldown enabled: {s}\n", .{if (status.cooldown_enabled) "yes" else "no"});
            },
            .background_queued => |bg| {
                try self.printColored(GREEN, "Background job queued: {s}\n", .{bg.job_id});
                try self.print("  Session: {s}\n", .{bg.session_id});
            },
            .background_result => |bg| {
                try self.printColored(BOLD, "Background job {s}: {s}\n", .{ bg.job_id, bg.status });
                if (bg.text) |t| {
                    try self.print("{s}\n", .{t});
                }
            },
        }
    }

    fn printColored(self: *Display, comptime color: []const u8, comptime fmt: []const u8, args: anytype) !void {
        if (self.color_enabled) {
            try self.write(color);
            try self.print(fmt, args);
            try self.write(RESET);
        } else {
            try self.print(fmt, args);
        }
    }

    fn printDim(self: *Display, comptime fmt: []const u8, args: anytype) !void {
        if (self.color_enabled) {
            try self.write(DIM);
            try self.print(fmt, args);
            try self.write(RESET);
        } else {
            try self.print(fmt, args);
        }
    }

    pub fn printError(self: *Display, comptime fmt: []const u8, args: anytype) !void {
        try self.printColored(RED, "Error: " ++ fmt ++ "\n", args);
    }

    pub fn printHelp(self: *Display) !void {
        const help =
            \\ClawForge - Local AI Client
            \\
            \\Usage:
            \\  clawforge [command] [options] [arguments]
            \\
            \\Commands:
            \\  <message>              Send a message (default)
            \\  session list           List all sessions
            \\  session new [name]     Create new session
            \\  session switch <id>    Switch to session
            \\  session delete <id>    Delete a session
            \\  model list             List available models
            \\  model set <model>      Set model for current session
            \\  model auto             Enable smart routing (haiku/sonnet/opus)
            \\  system <prompt>        Set system prompt
            \\  auth list              List auth profiles
            \\  auth add <id> <token>  Add auth profile
            \\  auth remove <id>       Remove auth profile
            \\  auth switch <id>       Switch active profile
            \\  auth status            Show auth status
            \\  status                 Show daemon status
            \\  stop                   Stop the daemon
            \\
            \\Options:
            \\  -h, --help             Show this help
            \\  -v, --version          Show version
            \\
        ;
        try self.write(help);
    }
};
