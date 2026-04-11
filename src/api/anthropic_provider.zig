const std = @import("std");
const anthropic = @import("anthropic.zig");
const provider_mod = @import("provider.zig");
const messages = @import("messages.zig");

/// Wraps AnthropicClient as a Provider for the provider registry.
pub fn asProvider(client: *anthropic.AnthropicClient) provider_mod.Provider {
    return .{
        .ptr = @ptrCast(client),
        .vtable = &vtable,
    };
}

const vtable = provider_mod.Provider.VTable{
    .createMessage = createMessage,
    .createMessageStreaming = createMessageStreaming,
    .setCredential = setCredential,
    .getName = getName,
};

fn createMessage(ptr: *anyopaque, request: *const messages.MessageRequest) anyerror!messages.MessageResponse {
    const client: *anthropic.AnthropicClient = @ptrCast(@alignCast(ptr));
    return client.createMessage(request, null);
}

fn createMessageStreaming(ptr: *anyopaque, request: *const messages.MessageRequest, handler: provider_mod.StreamHandler) anyerror!messages.MessageResponse {
    const client: *anthropic.AnthropicClient = @ptrCast(@alignCast(ptr));
    // Convert provider StreamHandler to anthropic StreamHandler
    const anthro_handler = anthropic.StreamHandler{
        .ctx = handler.ctx,
        .onTextDelta = handler.onTextDelta,
    };
    return client.createMessageStreaming(request, anthro_handler);
}

fn setCredential(ptr: *anyopaque, credential: []const u8) void {
    const client: *anthropic.AnthropicClient = @ptrCast(@alignCast(ptr));
    client.setCredential(credential);
}

fn getName(_: *anyopaque) []const u8 {
    return "anthropic";
}
