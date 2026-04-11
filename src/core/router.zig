const std = @import("std");
const common = @import("common");

/// Model tier for routing decisions
pub const ModelTier = enum {
    fast, // Haiku - simple queries, greetings, short answers
    default, // Sonnet - general purpose, most tasks
    smart, // Opus - complex analysis, architecture, multi-step reasoning

    pub fn label(self: ModelTier) []const u8 {
        return switch (self) {
            .fast => "fast",
            .default => "default",
            .smart => "smart",
        };
    }
};

/// Result of routing a message
pub const RouteResult = struct {
    tier: ModelTier,
    model: []const u8,
    reason: []const u8,
};

/// Smart model router that picks the cheapest adequate model for a given message.
pub const Router = struct {
    config: *const common.RoutingConfig,

    pub fn init(config: *const common.RoutingConfig) Router {
        return .{ .config = config };
    }

    /// Classify a message and return the appropriate model + reason.
    pub fn route(self: *const Router, message: []const u8, message_count: usize) RouteResult {
        // Check for smart tier triggers first (most specific)
        if (self.needsSmartModel(message, message_count)) {
            return .{
                .tier = .smart,
                .model = self.config.smart_model,
                .reason = "complex query detected",
            };
        }

        // Check if fast tier is sufficient (cheapest)
        if (self.canUseFastModel(message, message_count)) {
            return .{
                .tier = .fast,
                .model = self.config.fast_model,
                .reason = "simple query",
            };
        }

        // Default tier for everything else
        return .{
            .tier = .default,
            .model = self.config.default_model,
            .reason = "standard query",
        };
    }

    /// Check if the message warrants the smart (opus) model.
    /// Opus is reserved for high-level reasoning: architecture, planning, comparing
    /// approaches, multi-system design. NOT for coding tasks — Sonnet handles those.
    fn needsSmartModel(self: *const Router, message: []const u8, message_count: usize) bool {
        _ = self;
        _ = message_count;
        const lower_buf = lowerBuf(message);
        const lower = lower_buf.slice;

        // Opus triggers: high-level reasoning, architecture, strategic decisions
        const smart_triggers = [_][]const u8{
            "architect",
            "architecture",
            "compare approaches",
            "design the system",
            "evaluate trade-off",
            "evaluate tradeoff",
            "high level design",
            "high-level design",
            "multi-agent",
            "plan the migration",
            "system design",
            "trade-off analysis",
            "tradeoff analysis",
            "what are the implications",
            "what approach should",
            "which approach",
            "pros and cons",
        };

        for (smart_triggers) |trigger| {
            if (containsWord(lower, trigger)) return true;
        }

        return false;
    }

    /// Check if the fast (haiku) model is sufficient.
    fn canUseFastModel(self: *const Router, message: []const u8, message_count: usize) bool {
        _ = self;
        _ = message_count;
        const lower_buf = lowerBuf(message);
        const lower = lower_buf.slice;

        // Very short messages are usually simple
        if (message.len < 80) {
            // Greetings and simple exchanges
            const simple_patterns = [_][]const u8{
                "hello",
                "hi",
                "hey",
                "thanks",
                "thank you",
                "yes",
                "no",
                "ok",
                "okay",
                "sure",
                "got it",
                "sounds good",
                "what is",
                "what's",
                "who is",
                "who's",
                "when",
                "where",
                "how much",
                "how many",
                "list",
                "name",
                "define",
                "what does",
                "translate",
                "summarize this:",
                "tldr",
                "tl;dr",
            };

            for (simple_patterns) |pattern| {
                if (startsWith(lower, pattern) or std.mem.eql(u8, lower, pattern)) return true;
            }

            // Single-word or very short queries
            if (message.len < 20 and !std.mem.containsAtLeast(u8, message, 1, "?")) return true;
        }

        return false;
    }
};

// -- Helpers --

const LowerResult = struct {
    buf: [512]u8,
    slice: []const u8,

    fn init(input: []const u8) LowerResult {
        var result: LowerResult = undefined;
        const len = @min(input.len, 512);
        for (input[0..len], 0..) |c, i| {
            result.buf[i] = std.ascii.toLower(c);
        }
        result.slice = result.buf[0..len];
        return result;
    }
};

fn lowerBuf(input: []const u8) LowerResult {
    return LowerResult.init(input);
}

/// Check if haystack contains needle as a word (not substring of a larger word).
fn containsWord(haystack: []const u8, needle: []const u8) bool {
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        if (std.mem.indexOf(u8, haystack[pos..], needle)) |idx| {
            const abs = pos + idx;
            const before_ok = abs == 0 or !std.ascii.isAlphanumeric(haystack[abs - 1]);
            const after_pos = abs + needle.len;
            const after_ok = after_pos >= haystack.len or !std.ascii.isAlphanumeric(haystack[after_pos]);
            if (before_ok and after_ok) return true;
            pos = abs + 1;
        } else {
            break;
        }
    }
    return false;
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

// -- Tests --

test "route simple greeting to fast" {
    const cfg = common.RoutingConfig{};
    const router = Router.init(&cfg);
    const result = router.route("hello", 0);
    try std.testing.expectEqual(ModelTier.fast, result.tier);
}

test "route architecture question to smart" {
    const cfg = common.RoutingConfig{};
    const router = Router.init(&cfg);
    const result = router.route("what approach should we take for the system design", 0);
    try std.testing.expectEqual(ModelTier.smart, result.tier);
}

test "route normal question to default" {
    const cfg = common.RoutingConfig{};
    const router = Router.init(&cfg);
    const result = router.route("How do I configure nginx for reverse proxy?", 0);
    try std.testing.expectEqual(ModelTier.default, result.tier);
}

test "route short factual to fast" {
    const cfg = common.RoutingConfig{};
    const router = Router.init(&cfg);
    const result = router.route("thanks", 0);
    try std.testing.expectEqual(ModelTier.fast, result.tier);
}

test "containsWord matches whole words" {
    try std.testing.expect(containsWord("please analyze this", "analyze"));
    try std.testing.expect(!containsWord("analyzed this", "analyze"));
    try std.testing.expect(containsWord("analyze", "analyze"));
}
