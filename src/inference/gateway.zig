//! Small provider-neutral inference boundary for non-chat runtimes.

const std = @import("std");
const api = @import("api");

pub const ToolDefinition = api.messages.ToolDefinition;

pub const Request = struct {
    model: []const u8,
    system: []const u8,
    prompt: []const u8,
    max_tokens: u32,
    tools: ?[]const ToolDefinition = null,
};

pub const Response = struct {
    text: []u8,
    model: []u8,
    input_tokens: u32,
    output_tokens: u32,
    tool_name: ?[]u8 = null,
    tool_input_json: ?[]u8 = null,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.model);
        if (self.tool_name) |value| allocator.free(value);
        if (self.tool_input_json) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Gateway = struct {
    ptr: *anyopaque,
    invoke_fn: *const fn (*anyopaque, Request) anyerror!Response,

    pub fn invoke(self: Gateway, request: Request) !Response {
        return self.invoke_fn(self.ptr, request);
    }
};

pub const RegistryGateway = struct {
    allocator: std.mem.Allocator,
    registry: *api.ProviderRegistry,
    fallback_provider: api.Provider,

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *api.ProviderRegistry,
        fallback_provider: api.Provider,
    ) RegistryGateway {
        return .{
            .allocator = allocator,
            .registry = registry,
            .fallback_provider = fallback_provider,
        };
    }

    pub fn gateway(self: *RegistryGateway) Gateway {
        return .{ .ptr = self, .invoke_fn = invokeOpaque };
    }

    fn invokeOpaque(ptr: *anyopaque, request: Request) !Response {
        const self: *RegistryGateway = @ptrCast(@alignCast(ptr));
        const resolved = self.resolve(request.model);
        const blocks = [_]api.messages.ContentBlock{
            .{ .text = .{ .text = request.prompt } },
        };
        const messages = [_]api.messages.Message{
            .{ .role = .user, .content = &blocks },
        };
        var provider_response = try resolved.provider.createMessage(&.{
            .model = resolved.model,
            .max_tokens = request.max_tokens,
            .messages = &messages,
            .system = request.system,
            .tools = request.tools,
            .stream = false,
        });
        defer provider_response.deinit(self.allocator);
        var tool_name: ?[]u8 = null;
        var tool_input_json: ?[]u8 = null;
        errdefer {
            if (tool_name) |value| self.allocator.free(value);
            if (tool_input_json) |value| self.allocator.free(value);
        }
        if (provider_response.tool_use.len > 0) {
            const tool = provider_response.tool_use[0];
            tool_name = try self.allocator.dupe(u8, tool.name);
            tool_input_json = try std.json.Stringify.valueAlloc(self.allocator, tool.input, .{});
        }
        return .{
            .text = try self.allocator.dupe(u8, provider_response.text_content),
            .model = try self.allocator.dupe(u8, request.model),
            .input_tokens = provider_response.usage.input_tokens,
            .output_tokens = provider_response.usage.output_tokens,
            .tool_name = tool_name,
            .tool_input_json = tool_input_json,
        };
    }

    fn resolve(self: *RegistryGateway, model: []const u8) struct {
        provider: api.Provider,
        model: []const u8,
    } {
        if (std.mem.indexOfScalar(u8, model, ':')) |separator| {
            const prefix = model[0..separator];
            if (prefix.len > 0 and prefix.len <= 16) {
                if (self.registry.get(prefix)) |provider| {
                    return .{ .provider = provider, .model = model[separator + 1 ..] };
                }
            }
        }
        return .{ .provider = self.fallback_provider, .model = model };
    }
};
