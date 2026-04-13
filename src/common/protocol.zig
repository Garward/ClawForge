const std = @import("std");
const json = std.json;

/// IPC Request types from CLI to daemon
pub const Request = union(enum) {
    chat: ChatRequest,
    session_list: void,
    session_create: SessionCreateRequest,
    session_switch: []const u8,
    session_delete: []const u8,
    model_list: void,
    model_set: []const u8,
    system_set: ?[]const u8,
    tool_confirm: ToolConfirmResponse,
    status: void,
    stop: void,
    // Auth profile management
    auth_list: void,
    auth_add: AuthAddRequest,
    auth_remove: []const u8,
    auth_switch: []const u8,
    auth_status: void,
    // Project management
    project_list: void,
    project_create: ProjectCreateRequest,
    project_info: []const u8,
    project_attach: []const u8,
    project_detach: void,

    pub const ProjectCreateRequest = struct {
        name: []const u8,
        description: ?[]const u8 = null,
    };

    pub const ChatRequest = struct {
        message: []const u8,
        session_id: ?[]const u8 = null,
        model_override: ?[]const u8 = null,
        stream: bool = true,
        no_tools: bool = false,
        background: bool = false,
        callback_channel: ?[]const u8 = null,
        /// Comma-separated tool names to allow. If set, only these tools are
        /// offered to the model. Null means all tools are available.
        allowed_tools: ?[]const u8 = null,
        /// Adapter-specific context injected into the system prompt.
        adapter_context: ?[]const u8 = null,
    };

    pub const SessionCreateRequest = struct {
        name: ?[]const u8 = null,
    };

    pub const ToolConfirmResponse = struct {
        tool_id: []const u8,
        approved: bool,
        always_allow: bool = false,
    };

    pub const AuthAddRequest = struct {
        id: []const u8,
        credential: []const u8,
        provider: []const u8 = "anthropic",
        expires: ?i64 = null,
    };

    pub fn serialize(self: Request, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 16 * 1024);
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                @memcpy(b[p.*..][0..data.len], data);
                p.* += data.len;
            }
        }.f;

        const writeEscaped = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                for (data) |c| {
                    if (c == '"') {
                        b[p.*] = '\\';
                        p.* += 1;
                        b[p.*] = '"';
                        p.* += 1;
                    } else if (c == '\\') {
                        b[p.*] = '\\';
                        p.* += 1;
                        b[p.*] = '\\';
                        p.* += 1;
                    } else if (c == '\n') {
                        b[p.*] = '\\';
                        p.* += 1;
                        b[p.*] = 'n';
                        p.* += 1;
                    } else if (c == '\r') {
                        b[p.*] = '\\';
                        p.* += 1;
                        b[p.*] = 'r';
                        p.* += 1;
                    } else {
                        b[p.*] = c;
                        p.* += 1;
                    }
                }
            }
        }.f;

        switch (self) {
            .chat => |req| {
                write(buf, &pos, "{\"chat\":{\"message\":\"");
                writeEscaped(buf, &pos, req.message);
                write(buf, &pos, "\",\"stream\":");
                write(buf, &pos, if (req.stream) "true" else "false");
                if (req.no_tools) {
                    write(buf, &pos, ",\"no_tools\":true");
                }
                if (req.background) {
                    write(buf, &pos, ",\"background\":true");
                }
                if (req.session_id) |sid| {
                    write(buf, &pos, ",\"session_id\":\"");
                    write(buf, &pos, sid);
                    write(buf, &pos, "\"");
                }
                if (req.model_override) |mo| {
                    write(buf, &pos, ",\"model_override\":\"");
                    write(buf, &pos, mo);
                    write(buf, &pos, "\"");
                }
                if (req.callback_channel) |cc| {
                    write(buf, &pos, ",\"callback_channel\":\"");
                    writeEscaped(buf, &pos, cc);
                    write(buf, &pos, "\"");
                }
                write(buf, &pos, "}}");
            },
            .session_list => {
                write(buf, &pos, "{\"session_list\":{}}");
            },
            .session_create => |req| {
                write(buf, &pos, "{\"session_create\":{\"name\":");
                if (req.name) |n| {
                    write(buf, &pos, "\"");
                    writeEscaped(buf, &pos, n);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, "}}");
            },
            .session_switch => |id| {
                write(buf, &pos, "{\"session_switch\":\"");
                write(buf, &pos, id);
                write(buf, &pos, "\"}");
            },
            .session_delete => |id| {
                write(buf, &pos, "{\"session_delete\":\"");
                write(buf, &pos, id);
                write(buf, &pos, "\"}");
            },
            .model_list => {
                write(buf, &pos, "{\"model_list\":{}}");
            },
            .model_set => |model| {
                write(buf, &pos, "{\"model_set\":\"");
                write(buf, &pos, model);
                write(buf, &pos, "\"}");
            },
            .system_set => |system| {
                write(buf, &pos, "{\"system_set\":");
                if (system) |s| {
                    write(buf, &pos, "\"");
                    writeEscaped(buf, &pos, s);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, "}");
            },
            .status => {
                write(buf, &pos, "{\"status\":{}}");
            },
            .stop => {
                write(buf, &pos, "{\"stop\":{}}");
            },
            .tool_confirm => |confirm| {
                write(buf, &pos, "{\"tool_confirm\":{\"tool_id\":\"");
                write(buf, &pos, confirm.tool_id);
                write(buf, &pos, "\",\"approved\":");
                write(buf, &pos, if (confirm.approved) "true" else "false");
                write(buf, &pos, "}}");
            },
            .auth_list => {
                write(buf, &pos, "{\"auth_list\":{}}");
            },
            .auth_add => |req| {
                write(buf, &pos, "{\"auth_add\":{\"id\":\"");
                write(buf, &pos, req.id);
                write(buf, &pos, "\",\"credential\":\"");
                writeEscaped(buf, &pos, req.credential);
                write(buf, &pos, "\",\"provider\":\"");
                write(buf, &pos, req.provider);
                write(buf, &pos, "\"}}");
            },
            .auth_remove => |id| {
                write(buf, &pos, "{\"auth_remove\":\"");
                write(buf, &pos, id);
                write(buf, &pos, "\"}");
            },
            .auth_switch => |id| {
                write(buf, &pos, "{\"auth_switch\":\"");
                write(buf, &pos, id);
                write(buf, &pos, "\"}");
            },
            .auth_status => {
                write(buf, &pos, "{\"auth_status\":{}}");
            },
            .project_list => {
                write(buf, &pos, "{\"project_list\":{}}");
            },
            .project_create => |req| {
                write(buf, &pos, "{\"project_create\":{\"name\":\"");
                writeEscaped(buf, &pos, req.name);
                write(buf, &pos, "\"");
                if (req.description) |d| {
                    write(buf, &pos, ",\"description\":\"");
                    writeEscaped(buf, &pos, d);
                    write(buf, &pos, "\"");
                }
                write(buf, &pos, "}}");
            },
            .project_info => |name| {
                write(buf, &pos, "{\"project_info\":\"");
                writeEscaped(buf, &pos, name);
                write(buf, &pos, "\"}");
            },
            .project_attach => |name| {
                write(buf, &pos, "{\"project_attach\":\"");
                writeEscaped(buf, &pos, name);
                write(buf, &pos, "\"}");
            },
            .project_detach => {
                write(buf, &pos, "{\"project_detach\":{}}");
            },
        }

        return allocator.realloc(buf, pos) catch buf[0..pos];
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !Request {
        const parsed = try json.parseFromSlice(Request, allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        return parsed.value;
    }
};

/// IPC Response types from daemon to CLI
pub const Response = union(enum) {
    stream_start: StreamStart,
    stream_text: []const u8,
    stream_tool_use: StreamToolUse,
    stream_tool_result: StreamToolResult,
    stream_end: StreamEnd,
    tool_confirm_request: ToolConfirmRequest,
    session_list: []const SessionSummary,
    session_created: SessionCreated,
    model_list: []const []const u8,
    status: StatusInfo,
    error_resp: ErrorInfo,
    ok: void,
    // Auth responses
    auth_list: []const AuthProfileSummary,
    auth_status: AuthStatusInfo,
    // Project responses
    project_list: []const ProjectSummary,
    project_info: ProjectInfoResp,
    // Background job responses
    background_queued: BackgroundQueued,
    background_result: BackgroundResultResp,

    pub const StreamStart = struct {
        message_id: []const u8,
        model: []const u8,
    };

    pub const StreamToolUse = struct {
        tool_id: []const u8,
        tool_name: []const u8,
        input: []const u8,
    };

    pub const StreamToolResult = struct {
        tool_id: []const u8,
        result: []const u8,
        is_error: bool,
    };

    pub const StreamEnd = struct {
        stop_reason: ?[]const u8,
        model: ?[]const u8 = null,
        input_tokens: u32,
        output_tokens: u32,
    };

    pub const ToolConfirmRequest = struct {
        tool_id: []const u8,
        tool_name: []const u8,
        input_preview: []const u8,
    };

    pub const SessionSummary = struct {
        id: []const u8,
        name: ?[]const u8,
        message_count: u32,
        updated_at: i64,
    };

    pub const SessionCreated = struct {
        id: []const u8,
        name: ?[]const u8,
    };

    pub const StatusInfo = struct {
        version: []const u8,
        uptime_seconds: u64,
        active_sessions: u32,
        current_session: ?[]const u8,
    };

    pub const ErrorInfo = struct {
        code: []const u8,
        message: []const u8,
    };

    pub const AuthProfileSummary = struct {
        id: []const u8,
        provider: []const u8,
        profile_type: []const u8, // "api_key" or "token"
        is_active: bool,
        status: []const u8, // "ok", "expired", "cooldown", "disabled"
        last_used: ?i64,
        cooldown_until: ?i64,
    };

    pub const AuthStatusInfo = struct {
        active_profile: ?[]const u8,
        active_provider: ?[]const u8,
        profile_count: u32,
        cooldown_enabled: bool,
    };

    pub const ProjectSummary = struct {
        id: i64 = 0,
        name: []const u8 = "",
        status: []const u8 = "active",
        updated_at: i64 = 0,
    };

    pub const ProjectInfoResp = struct {
        id: i64 = 0,
        name: []const u8 = "",
        description: ?[]const u8 = null,
        status: []const u8 = "active",
        rolling_summary: ?[]const u8 = null,
        rolling_state: ?[]const u8 = null,
    };

    pub const BackgroundQueued = struct {
        job_id: []const u8,
        session_id: []const u8,
    };

    pub const BackgroundResultResp = struct {
        job_id: []const u8,
        status: []const u8,
        text: ?[]const u8 = null,
        model: ?[]const u8 = null,
        input_tokens: u32 = 0,
        output_tokens: u32 = 0,
        callback_channel: ?[]const u8 = null,
    };

    pub fn serialize(self: Response, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 64 * 1024);
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                @memcpy(b[p.*..][0..data.len], data);
                p.* += data.len;
            }
        }.f;

        const writeNum = struct {
            fn f(b: []u8, p: *usize, n: anytype) void {
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch "0";
                @memcpy(b[p.*..][0..s.len], s);
                p.* += s.len;
            }
        }.f;

        const writeEscaped = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                for (data) |c| {
                    if (c == '"') {
                        b[p.*] = '\\';
                        p.* += 1;
                        b[p.*] = '"';
                        p.* += 1;
                    } else if (c == '\\') {
                        b[p.*] = '\\';
                        p.* += 1;
                        b[p.*] = '\\';
                        p.* += 1;
                    } else if (c == '\n') {
                        b[p.*] = '\\';
                        p.* += 1;
                        b[p.*] = 'n';
                        p.* += 1;
                    } else {
                        b[p.*] = c;
                        p.* += 1;
                    }
                }
            }
        }.f;

        switch (self) {
            .stream_end => |end| {
                write(buf, &pos, "{\"stream_end\":{\"stop_reason\":");
                if (end.stop_reason) |reason| {
                    write(buf, &pos, "\"");
                    write(buf, &pos, reason);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, ",\"model\":");
                if (end.model) |m| {
                    write(buf, &pos, "\"");
                    write(buf, &pos, m);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, ",\"input_tokens\":");
                writeNum(buf, &pos, end.input_tokens);
                write(buf, &pos, ",\"output_tokens\":");
                writeNum(buf, &pos, end.output_tokens);
                write(buf, &pos, "}}");
            },
            .stream_text => |text| {
                write(buf, &pos, "{\"stream_text\":\"");
                writeEscaped(buf, &pos, text);
                write(buf, &pos, "\"}");
            },
            .error_resp => |err| {
                write(buf, &pos, "{\"error_resp\":{\"code\":\"");
                write(buf, &pos, err.code);
                write(buf, &pos, "\",\"message\":\"");
                writeEscaped(buf, &pos, err.message);
                write(buf, &pos, "\"}}");
            },
            .ok => {
                write(buf, &pos, "{\"ok\":{}}");
            },
            .status => |status| {
                write(buf, &pos, "{\"status\":{\"version\":\"");
                write(buf, &pos, status.version);
                write(buf, &pos, "\",\"uptime_seconds\":");
                writeNum(buf, &pos, status.uptime_seconds);
                write(buf, &pos, ",\"active_sessions\":");
                writeNum(buf, &pos, status.active_sessions);
                write(buf, &pos, ",\"current_session\":");
                if (status.current_session) |sess| {
                    write(buf, &pos, "\"");
                    write(buf, &pos, sess);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, "}}");
            },
            .session_list => |sessions| {
                write(buf, &pos, "{\"session_list\":[");
                for (sessions, 0..) |sess, i| {
                    if (i > 0) write(buf, &pos, ",");
                    write(buf, &pos, "{\"id\":\"");
                    write(buf, &pos, sess.id);
                    write(buf, &pos, "\",\"name\":");
                    if (sess.name) |n| {
                        write(buf, &pos, "\"");
                        write(buf, &pos, n);
                        write(buf, &pos, "\"");
                    } else {
                        write(buf, &pos, "null");
                    }
                    write(buf, &pos, ",\"message_count\":");
                    writeNum(buf, &pos, sess.message_count);
                    write(buf, &pos, ",\"updated_at\":");
                    writeNum(buf, &pos, sess.updated_at);
                    write(buf, &pos, "}");
                }
                write(buf, &pos, "]}");
            },
            .session_created => |created| {
                write(buf, &pos, "{\"session_created\":{\"id\":\"");
                write(buf, &pos, created.id);
                write(buf, &pos, "\",\"name\":");
                if (created.name) |n| {
                    write(buf, &pos, "\"");
                    write(buf, &pos, n);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, "}}");
            },
            .model_list => |models| {
                write(buf, &pos, "{\"model_list\":[");
                for (models, 0..) |model, i| {
                    if (i > 0) write(buf, &pos, ",");
                    write(buf, &pos, "\"");
                    write(buf, &pos, model);
                    write(buf, &pos, "\"");
                }
                write(buf, &pos, "]}");
            },
            .stream_start => |start| {
                write(buf, &pos, "{\"stream_start\":{\"message_id\":\"");
                write(buf, &pos, start.message_id);
                write(buf, &pos, "\",\"model\":\"");
                write(buf, &pos, start.model);
                write(buf, &pos, "\"}}");
            },
            .stream_tool_use => |tool| {
                write(buf, &pos, "{\"stream_tool_use\":{\"tool_id\":\"");
                write(buf, &pos, tool.tool_id);
                write(buf, &pos, "\",\"tool_name\":\"");
                write(buf, &pos, tool.tool_name);
                write(buf, &pos, "\",\"input\":\"");
                writeEscaped(buf, &pos, tool.input);
                write(buf, &pos, "\"}}");
            },
            .stream_tool_result => |result| {
                write(buf, &pos, "{\"stream_tool_result\":{\"tool_id\":\"");
                write(buf, &pos, result.tool_id);
                write(buf, &pos, "\",\"result\":\"");
                writeEscaped(buf, &pos, result.result);
                write(buf, &pos, "\",\"is_error\":");
                write(buf, &pos, if (result.is_error) "true" else "false");
                write(buf, &pos, "}}");
            },
            .tool_confirm_request => |confirm| {
                write(buf, &pos, "{\"tool_confirm_request\":{\"tool_id\":\"");
                write(buf, &pos, confirm.tool_id);
                write(buf, &pos, "\",\"tool_name\":\"");
                write(buf, &pos, confirm.tool_name);
                write(buf, &pos, "\",\"input_preview\":\"");
                writeEscaped(buf, &pos, confirm.input_preview);
                write(buf, &pos, "\"}}");
            },
            .auth_list => |profiles| {
                write(buf, &pos, "{\"auth_list\":[");
                for (profiles, 0..) |profile, i| {
                    if (i > 0) write(buf, &pos, ",");
                    write(buf, &pos, "{\"id\":\"");
                    write(buf, &pos, profile.id);
                    write(buf, &pos, "\",\"provider\":\"");
                    write(buf, &pos, profile.provider);
                    write(buf, &pos, "\",\"profile_type\":\"");
                    write(buf, &pos, profile.profile_type);
                    write(buf, &pos, "\",\"is_active\":");
                    write(buf, &pos, if (profile.is_active) "true" else "false");
                    write(buf, &pos, ",\"status\":\"");
                    write(buf, &pos, profile.status);
                    write(buf, &pos, "\",\"last_used\":");
                    if (profile.last_used) |lu| {
                        writeNum(buf, &pos, lu);
                    } else {
                        write(buf, &pos, "null");
                    }
                    write(buf, &pos, ",\"cooldown_until\":");
                    if (profile.cooldown_until) |cu| {
                        writeNum(buf, &pos, cu);
                    } else {
                        write(buf, &pos, "null");
                    }
                    write(buf, &pos, "}");
                }
                write(buf, &pos, "]}");
            },
            .auth_status => |status| {
                write(buf, &pos, "{\"auth_status\":{\"active_profile\":");
                if (status.active_profile) |ap| {
                    write(buf, &pos, "\"");
                    write(buf, &pos, ap);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, ",\"active_provider\":");
                if (status.active_provider) |provider| {
                    write(buf, &pos, "\"");
                    write(buf, &pos, provider);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, ",\"profile_count\":");
                writeNum(buf, &pos, status.profile_count);
                write(buf, &pos, ",\"cooldown_enabled\":");
                write(buf, &pos, if (status.cooldown_enabled) "true" else "false");
                write(buf, &pos, "}}");
            },
            .project_list => |projects| {
                write(buf, &pos, "{\"project_list\":[");
                for (projects, 0..) |proj, i| {
                    if (i > 0) write(buf, &pos, ",");
                    write(buf, &pos, "{\"id\":");
                    writeNum(buf, &pos, proj.id);
                    write(buf, &pos, ",\"name\":\"");
                    writeEscaped(buf, &pos, proj.name);
                    write(buf, &pos, "\",\"status\":\"");
                    write(buf, &pos, proj.status);
                    write(buf, &pos, "\",\"updated_at\":");
                    writeNum(buf, &pos, proj.updated_at);
                    write(buf, &pos, "}");
                }
                write(buf, &pos, "]}");
            },
            .background_queued => |bg| {
                write(buf, &pos, "{\"background_queued\":{\"job_id\":\"");
                write(buf, &pos, bg.job_id);
                write(buf, &pos, "\",\"session_id\":\"");
                write(buf, &pos, bg.session_id);
                write(buf, &pos, "\"}}");
            },
            .background_result => |bg| {
                write(buf, &pos, "{\"background_result\":{\"job_id\":\"");
                write(buf, &pos, bg.job_id);
                write(buf, &pos, "\",\"status\":\"");
                write(buf, &pos, bg.status);
                write(buf, &pos, "\",\"text\":");
                if (bg.text) |t| {
                    write(buf, &pos, "\"");
                    writeEscaped(buf, &pos, t);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, ",\"model\":");
                if (bg.model) |m| {
                    write(buf, &pos, "\"");
                    write(buf, &pos, m);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, ",\"input_tokens\":");
                writeNum(buf, &pos, bg.input_tokens);
                write(buf, &pos, ",\"output_tokens\":");
                writeNum(buf, &pos, bg.output_tokens);
                write(buf, &pos, "}}");
            },
            .project_info => |info| {
                write(buf, &pos, "{\"project_info\":{\"id\":");
                writeNum(buf, &pos, info.id);
                write(buf, &pos, ",\"name\":\"");
                writeEscaped(buf, &pos, info.name);
                write(buf, &pos, "\",\"description\":");
                if (info.description) |d| {
                    write(buf, &pos, "\"");
                    writeEscaped(buf, &pos, d);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, ",\"status\":\"");
                write(buf, &pos, info.status);
                write(buf, &pos, "\",\"rolling_summary\":");
                if (info.rolling_summary) |s| {
                    write(buf, &pos, "\"");
                    writeEscaped(buf, &pos, s);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, ",\"rolling_state\":");
                if (info.rolling_state) |s| {
                    write(buf, &pos, "\"");
                    writeEscaped(buf, &pos, s);
                    write(buf, &pos, "\"");
                } else {
                    write(buf, &pos, "null");
                }
                write(buf, &pos, "}}");
            },
        }

        return allocator.realloc(buf, pos) catch buf[0..pos];
    }

    pub const ParsedResponse = json.Parsed(Response);

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !ParsedResponse {
        return try json.parseFromSlice(Response, allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

/// Message framing: 4-byte big-endian length prefix + payload
pub const Framing = struct {
    pub fn writeFrame(writer: anytype, data: []const u8) !void {
        const len: u32 = @intCast(data.len);
        try writer.writeInt(u32, len, .big);
        try writer.writeAll(data);
    }

    pub fn readFrame(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
        const len = try reader.readInt(u32, .big);
        if (len > 10 * 1024 * 1024) {
            return error.MessageTooLarge;
        }
        const buf = try allocator.alloc(u8, len);
        errdefer allocator.free(buf);
        const read = try reader.readAll(buf);
        if (read != len) {
            return error.UnexpectedEof;
        }
        return buf;
    }
};
