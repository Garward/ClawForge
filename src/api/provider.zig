const std = @import("std");
const messages = @import("messages.zig");
const sse = @import("sse.zig");

/// Provider interface — any LLM backend (Anthropic, OpenAI, Ollama, llama.cpp)
/// implements this to plug into ClawForge.
///
/// The engine calls Provider methods instead of a specific client directly.
/// The model router can route different tiers to different providers.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send a message and get a complete response (non-streaming).
        createMessage: *const fn (
            ptr: *anyopaque,
            request: *const messages.MessageRequest,
        ) anyerror!messages.MessageResponse,

        /// Send a message with streaming — text deltas delivered via handler.
        createMessageStreaming: *const fn (
            ptr: *anyopaque,
            request: *const messages.MessageRequest,
            handler: StreamHandler,
        ) anyerror!messages.MessageResponse,

        /// Update the credential/API key. Used for auth profile switching.
        setCredential: *const fn (ptr: *anyopaque, credential: []const u8) void,

        /// Get the provider name for logging/display.
        getName: *const fn (ptr: *anyopaque) []const u8,
    };

    pub fn createMessage(self: Provider, request: *const messages.MessageRequest) !messages.MessageResponse {
        return self.vtable.createMessage(self.ptr, request);
    }

    pub fn createMessageStreaming(self: Provider, request: *const messages.MessageRequest, handler: StreamHandler) !messages.MessageResponse {
        return self.vtable.createMessageStreaming(self.ptr, request, handler);
    }

    pub fn setCredential(self: Provider, credential: []const u8) void {
        self.vtable.setCredential(self.ptr, credential);
    }

    pub fn getName(self: Provider) []const u8 {
        return self.vtable.getName(self.ptr);
    }
};

/// Callback for streaming text deltas (same as in anthropic.zig).
pub const StreamHandler = struct {
    ctx: *anyopaque,
    onTextDelta: *const fn (ctx: *anyopaque, text: []const u8) void,

    pub fn emitText(self: StreamHandler, text: []const u8) void {
        self.onTextDelta(self.ctx, text);
    }
};

/// Provider registry — maps provider names to Provider instances.
/// The model router uses this to pick which provider handles each request.
pub const ProviderRegistry = struct {
    allocator: std.mem.Allocator,
    providers: std.StringHashMap(Provider),
    /// Maps model tier names to provider names: "fast" → "ollama", "default" → "anthropic"
    tier_mapping: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ProviderRegistry {
        return .{
            .allocator = allocator,
            .providers = std.StringHashMap(Provider).init(allocator),
            .tier_mapping = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ProviderRegistry) void {
        self.providers.deinit();
        self.tier_mapping.deinit();
    }

    /// Register a provider by name.
    pub fn register(self: *ProviderRegistry, name: []const u8, provider: Provider) !void {
        try self.providers.put(name, provider);
    }

    /// Map a model tier to a provider name.
    /// e.g., mapTier("fast", "ollama") — haiku-tier queries go to local Ollama.
    pub fn mapTier(self: *ProviderRegistry, tier: []const u8, provider_name: []const u8) !void {
        try self.tier_mapping.put(tier, provider_name);
    }

    /// Get the provider for a given tier. Falls back to "default" provider.
    pub fn getForTier(self: *ProviderRegistry, tier: []const u8) ?Provider {
        if (self.tier_mapping.get(tier)) |provider_name| {
            return self.providers.get(provider_name);
        }
        // Fall back to first registered provider
        var it = self.providers.valueIterator();
        if (it.next()) |p| return p.*;
        return null;
    }

    /// Get a provider by name.
    pub fn get(self: *ProviderRegistry, name: []const u8) ?Provider {
        return self.providers.get(name);
    }

    /// List registered provider names.
    pub fn listNames(self: *ProviderRegistry) []const []const u8 {
        const count = self.providers.count();
        if (count == 0) return &.{};
        const result = self.allocator.alloc([]const u8, count) catch return &.{};
        var it = self.providers.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| {
            if (i >= count) break;
            result[i] = key.*;
            i += 1;
        }
        return result[0..i];
    }
};
