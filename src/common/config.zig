const std = @import("std");
const fs = std.fs;
const json = std.json;

pub const ApiConfig = struct {
    token_file: []const u8 = "data/anthropic-token.txt",
    base_url: []const u8 = "https://api.anthropic.com",
    default_model: []const u8 = "claude-sonnet-4-20250514",
    max_tokens: u32 = 8192,
    timeout_ms: u32 = 120000,
};

pub const DaemonConfig = struct {
    socket_path: []const u8 = "data/clawforge.sock",
    data_dir: []const u8 = "data",
    log_level: []const u8 = "info",
    max_clients: u8 = 5,
};

pub const ToolsConfig = struct {
    enabled: []const []const u8 = &.{ "bash", "file_find", "file_read", "file_write", "amazon_search", "playwright_mcp", "vision_read" },
    bash_require_confirmation: bool = true,
    bash_timeout_ms: u32 = 30000,
    file_write_require_confirmation: bool = true,
};

pub const DisplayConfig = struct {
    stream_output: bool = true,
    show_tool_calls: bool = true,
    show_token_usage: bool = true,
    color_output: bool = true,
};

pub const AuthConfig = struct {
    profiles_path: []const u8 = "data/auth-profiles.json",
    cooldown_enabled: bool = true,
};

pub const WebConfig = struct {
    enabled: bool = true,
    port: u16 = 8081,
    host: []const u8 = "127.0.0.1",
    compact_tool_schemas: bool = false,
    plans_required: bool = true,
};

pub const RoutingConfig = struct {
    enabled: bool = true,
    fast_model: []const u8 = "claude-haiku-4-5-20251001",
    default_model: []const u8 = "claude-sonnet-4-20250514",
    smart_model: []const u8 = "claude-opus-4-20250514",
    /// Provider name for each tier. Maps to registered providers.
    /// "anthropic", "ollama", "openai", "openrouter" — or any registered provider name.
    fast_provider: []const u8 = "anthropic",
    default_provider: []const u8 = "anthropic",
    smart_provider: []const u8 = "anthropic",
};

pub const OllamaModelContext = struct {
    model: []const u8,
    num_ctx: u32,
};

pub const OllamaConfig = struct {
    enabled: bool = false,
    base_url: []const u8 = "http://127.0.0.1:11434",
    default_model: []const u8 = "qwen2.5-coder:14b",
    /// Maximum context window size the Ollama provider is allowed to use
    /// per-request as `options.num_ctx`. This is a VRAM ceiling — the
    /// provider will automatically scale the actual context DOWN to fit
    /// each request's prompt + output budget, so short chats use less and
    /// long agent sessions use more, up to this cap.
    ///
    /// Ollama defaults to a tiny 2K–8K window regardless of what the model
    /// file supports, silently truncating longer inputs. This setting
    /// overrides that per request.
    ///
    /// This is the fallback cap. Prefer `model_contexts` for models with
    /// different VRAM behavior; a 4B long-context model and a 14B coder
    /// model should not be forced through the same ceiling.
    ///
    /// Practical local caps on a 20 GB RX 7900-class card:
    ///   - 32768:  stable target for 14B Q4 coder models
    ///   - 49152:  useful ceiling for small long-context models
    ///   - 65536+: use only after benchmarking the exact model
    ///
    /// Raise this for long agent sessions; lower it for small-model chat.
    num_ctx: u32 = 49152,
    /// Optional per-model context ceilings. Entries may use either bare
    /// Ollama names such as "qwen2.5-coder:14b" or provider-prefixed names
    /// such as "ollama:qwen2.5-coder:14b".
    model_contexts: []const OllamaModelContext = &.{},
};

pub const ContextConfig = struct {
    /// Max content chars before compaction kicks in (~50K tokens)
    compact_threshold: u32 = 200000,
    /// Recent messages to keep verbatim when compacting
    recent_window: u32 = 20,
    /// Max chars for conversation messages (~25k tokens at 4 chars/token)
    max_context_chars: u32 = 100000,
};

pub const OpenAIConfig = struct {
    enabled: bool = false,
    base_url: []const u8 = "https://api.openai.com",
    api_key_file: []const u8 = "",
    default_model: []const u8 = "gpt-4o-mini",
};

pub const OpenRouterConfig = struct {
    enabled: bool = false,
    base_url: []const u8 = "https://openrouter.ai/api/v1",
    /// Env var name in .env file (e.g. "OPENROUTER_API_KEY")
    api_key_env: []const u8 = "OPENROUTER_API_KEY",
    default_model: []const u8 = "x-ai/grok-4.1-fast",
};

pub const CodexConfig = struct {
    /// Codex (ChatGPT subscription) provider via OAuth from `~/.codex/auth.json`.
    /// Authenticate with the Codex CLI (`codex login`) before enabling.
    enabled: bool = false,
    /// Path to the auth.json produced by Codex CLI. Tilde-expanded at load.
    auth_path: []const u8 = "~/.codex/auth.json",
    base_url: []const u8 = "https://chatgpt.com/backend-api",
    default_model: []const u8 = "gpt-5",
};

pub const DiscordConfig = struct {
    enabled: bool = false,
    token_file: []const u8 = "",
    guild_id: []const u8 = "",
    channel_id: []const u8 = "",
    compact_tool_schemas: bool = false,
    plans_required: bool = true,
    attachment_spool: []const u8 = "data/discord_attachments",
    max_attachment_bytes: u32 = 25 * 1024 * 1024,
    max_attachment_count: u8 = 10,
    attachment_retention_seconds: u32 = 86400,
};

pub const VisionConfig = struct {
    /// Enable image analysis for attachments. If false, attachments are
    /// stored but no vision call is made.
    enabled: bool = true,
    /// Model used for the vision call. Provider-prefixed models such as
    /// "ollama:qwen2.5vl:7b" run locally and are unloaded after each call.
    /// Runtime overridable via /api/vision.
    model: []const u8 = "ollama:qwen2.5vl:7b",
    /// Cap per-image bytes to bound vision input cost. Images larger
    /// than this are skipped with an explanatory description.
    max_image_bytes: u32 = 10 * 1024 * 1024, // 10 MB
    /// Max images analyzed per message turn (GarGPT pattern).
    max_images_per_turn: u8 = 2,
    /// Max output tokens for the vision description.
    max_output_tokens: u32 = 512,
    /// Prompt used for the vision call. Kept short — the description is
    /// injected as plain text into the main model's system prompt, so this
    /// controls what detail the user gets to reference.
    prompt: []const u8 =
        "Describe this image in detail. Extract any visible text verbatim " ++
        "(OCR). If it shows an error, UI, diagram, or code, extract the " ++
        "relevant structure. Be concise and factual — no speculation.",
};

/// Inner config data that can be JSON parsed
const ConfigData = struct {
    api: ApiConfig = .{},
    daemon: DaemonConfig = .{},
    tools: ToolsConfig = .{},
    display: DisplayConfig = .{},
    auth: AuthConfig = .{},
    web: WebConfig = .{},
    routing: RoutingConfig = .{},
    ollama: OllamaConfig = .{},
    openai: OpenAIConfig = .{},
    openrouter: OpenRouterConfig = .{},
    codex: CodexConfig = .{},
    discord: DiscordConfig = .{},
    context: ContextConfig = .{},
    vision: VisionConfig = .{},
};

/// Config wrapper that manages the parsed JSON lifetime
pub const Config = struct {
    api: ApiConfig,
    daemon: DaemonConfig,
    tools: ToolsConfig,
    display: DisplayConfig,
    auth: AuthConfig,
    web: WebConfig,
    routing: RoutingConfig,
    ollama: OllamaConfig,
    openai: OpenAIConfig,
    openrouter: OpenRouterConfig,
    codex: CodexConfig,
    discord: DiscordConfig,
    context: ContextConfig,
    vision: VisionConfig,
    _parsed: ?json.Parsed(ConfigData),

    pub fn defaults() Config {
        return .{
            .api = .{},
            .daemon = .{},
            .tools = .{},
            .display = .{},
            .auth = .{},
            .web = .{},
            .routing = .{},
            .ollama = .{},
            .openai = .{},
            .openrouter = .{},
            .codex = .{},
            .discord = .{},
            .context = .{},
            .vision = .{},
            ._parsed = null,
        };
    }

    pub fn deinit(self: *Config) void {
        if (self._parsed) |*parsed| {
            parsed.deinit();
        }
    }

    pub fn load(allocator: std.mem.Allocator, config_path: ?[]const u8) !Config {
        // Resolve config path relative to exe directory (project root)
        const resolved_path = try resolveProjectPath(allocator, config_path orelse "config/config.json");
        defer allocator.free(resolved_path);

        const io = process_io orelse return error.ProcessRuntimeNotInitialized;
        var file = std.Io.Dir.openFileAbsolute(io, resolved_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("Config file not found at {s}, using defaults", .{resolved_path});
                return Config.defaults();
            }
            return err;
        };
        defer file.close(io);
        var file_reader = file.reader(io, &.{});

        const content = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        const parsed = try json.parseFromSlice(ConfigData, allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });

        return .{
            .api = parsed.value.api,
            .daemon = parsed.value.daemon,
            .tools = parsed.value.tools,
            .display = parsed.value.display,
            .auth = parsed.value.auth,
            .web = parsed.value.web,
            .routing = parsed.value.routing,
            .ollama = parsed.value.ollama,
            .openai = parsed.value.openai,
            .openrouter = parsed.value.openrouter,
            .codex = parsed.value.codex,
            .discord = parsed.value.discord,
            .context = parsed.value.context,
            .vision = parsed.value.vision,
            ._parsed = parsed,
        };
    }
};

var process_environ: ?*const std.process.Environ.Map = null;
var process_io: ?std.Io = null;

pub fn setProcessRuntime(environ: *const std.process.Environ.Map, io: std.Io) void {
    process_environ = environ;
    process_io = io;
}

/// Process-wide Io used by long-lived synchronization and filesystem helpers.
/// Tests receive Zig's test Io automatically.
pub fn runtimeIo() std.Io {
    if (process_io) |io| return io;
    if (@import("builtin").is_test) return std.testing.io;
    @panic("ClawForge process runtime was not initialized");
}

pub fn getEnvVar(key: []const u8) ?[]const u8 {
    const environ = process_environ orelse return null;
    return environ.get(key);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const environ = process_environ orelse return error.EnvironmentVariableNotFound;
    const value = environ.get(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}

/// Get the project root directory.
/// Priority: CLAWFORGE_ROOT env var, else derived from exe path (exe_dir/../..).
/// Caller owns returned memory.
pub fn getProjectRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (getEnvVarOwned(allocator, "CLAWFORGE_ROOT")) |v| {
        return v;
    } else |_| {}

    const io = process_io orelse return error.ProcessRuntimeNotInitialized;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &exe_buf);
    const exe_dir = std.fs.path.dirname(exe_buf[0..exe_len]) orelse return error.InvalidExecutablePath;
    const parent1 = std.fs.path.dirname(exe_dir) orelse exe_dir;
    const root = std.fs.path.dirname(parent1) orelse parent1;
    return try allocator.dupe(u8, root);
}

/// Resolve a path relative to the project root.
pub fn resolveProjectPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    }
    const root = try getProjectRoot(allocator);
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &.{ root, path });
}

/// Path to the SQLite workspace DB.
pub fn getDbPath(allocator: std.mem.Allocator) ![]const u8 {
    if (getEnvVarOwned(allocator, "CLAWFORGE_DB")) |v| return v else |_| {}
    return resolveProjectPath(allocator, "data/workspace.db");
}

/// Path to python interpreter used for tool scripts.
/// Priority: CLAWFORGE_PYTHON env, then .env CLAWFORGE_PYTHON, then "python3" on PATH.
pub fn getPython(allocator: std.mem.Allocator) ![]const u8 {
    if (getEnvVarOwned(allocator, "CLAWFORGE_PYTHON")) |v| return v else |_| {}
    if (loadEnvKey(allocator, "CLAWFORGE_PYTHON")) |v| return v else |_| {}
    return try allocator.dupe(u8, "python3");
}

/// Path to a tool script under tools/.
pub fn getToolScript(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const rel = try std.fmt.allocPrint(allocator, "tools/{s}", .{name});
    defer allocator.free(rel);
    return resolveProjectPath(allocator, rel);
}

pub fn loadApiKey(allocator: std.mem.Allocator, token_path: []const u8) ![]const u8 {
    const resolved = try resolveProjectPath(allocator, token_path);
    defer allocator.free(resolved);
    const io = runtimeIo();
    var file = try std.Io.Dir.openFileAbsolute(io, resolved, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});

    const content = try file_reader.interface.allocRemaining(allocator, .limited(1024));
    // Trim whitespace and newlines
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);

    // Create a new allocation with just the trimmed content
    const result = try allocator.alloc(u8, trimmed.len);
    @memcpy(result, trimmed);
    allocator.free(content);

    return result;
}

/// Load an API key from the project .env file by variable name.
/// Parses lines of the form `KEY=value` (strips optional quotes and whitespace).
pub fn loadEnvKey(allocator: std.mem.Allocator, env_var: []const u8) ![]const u8 {
    const env_path = try resolveProjectPath(allocator, ".env");
    defer allocator.free(env_path);

    const io = runtimeIo();
    var file = try std.Io.Dir.openFileAbsolute(io, env_path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});

    const content = try file_reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
            if (!std.mem.eql(u8, key, env_var)) continue;

            var val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);
            // Strip surrounding quotes if present
            if (val.len >= 2) {
                if ((val[0] == '"' and val[val.len - 1] == '"') or
                    (val[0] == '\'' and val[val.len - 1] == '\''))
                {
                    val = val[1 .. val.len - 1];
                }
            }
            if (val.len == 0) return error.EmptyValue;
            return try allocator.dupe(u8, val);
        }
    }
    return error.KeyNotFound;
}

pub fn getSocketPath(allocator: std.mem.Allocator, config: *const Config) ![]const u8 {
    return resolveProjectPath(allocator, config.daemon.socket_path);
}

test "loadApiKey trims whitespace" {
    // This would need a test file
}

test "defaults returns valid config" {
    const cfg = Config.defaults();
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", cfg.api.default_model);
}
