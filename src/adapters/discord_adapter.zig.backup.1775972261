const std = @import("std");
const common = @import("common");
const core = @import("core");
const adapter_mod = @import("adapter.zig");

pub const DiscordAdapter = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    engine: *core.Engine,
    token: ?[]const u8,
    running: bool,
    client: ?std.http.Client,
    gateway_url: ?[]const u8,
    session_id: ?[]const u8,
    last_sequence: ?u32,
    heartbeat_interval: ?u32,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: *const common.Config, engine: *core.Engine) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .engine = engine,
            .token = null,
            .running = false,
            .client = null,
            .gateway_url = null,
            .session_id = null,
            .last_sequence = null,
            .heartbeat_interval = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        if (self.gateway_url) |url| {
            self.allocator.free(url);
        }
        if (self.session_id) |id| {
            self.allocator.free(id);
        }
        if (self.token) |token| {
            self.allocator.free(token);
        }
        if (self.client) |*client| {
            client.deinit();
        }
    }
    
    pub fn adapter(self: *Self) adapter_mod.Adapter {
        return adapter_mod.Adapter{
            .ptr = self,
            .vtable = &.{
                .start = startImpl,
                .stop = stopImpl,
                .run = runImpl,
                .send_message = sendMessageImpl,
                .deinit = deinitImpl,
            },
        };
    }
    
    fn startImpl(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.start();
    }
    
    fn stopImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.stop();
    }
    
    fn runImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.run();
    }
    
    fn sendMessageImpl(ptr: *anyopaque, message: []const u8, context: anytype) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.sendMessage(message, context);
    }
    
    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
    
    pub fn start(self: *Self) !void {
        if (self.running) return;
        
        std.log.info("Starting Discord adapter...", .{});
        
        // Check if Discord is configured
        if (self.config.discord.token_file.len == 0) {
            std.log.err("Discord token file not configured", .{});
            return error.MissingTokenFile;
        }
        
        // Load Discord token from file
        const token_data = std.fs.cwd().readFileAlloc(self.allocator, self.config.discord.token_file, 1024) catch |err| {
            std.log.err("Failed to read Discord token file: {}", .{err});
            return err;
        };
        
        // Trim whitespace from token
        self.token = try self.allocator.dupe(u8, std.mem.trim(u8, token_data, " \n\r\t"));
        self.allocator.free(token_data);
        
        // Initialize HTTP client
        self.client = std.http.Client{ .allocator = self.allocator };
        
        // Get gateway URL
        try self.getGatewayUrl();
        
        self.running = true;
        std.log.info("Discord adapter started", .{});
    }
    
    pub fn stop(self: *Self) void {
        if (!self.running) return;
        
        std.log.info("Stopping Discord adapter...", .{});
        self.running = false;
        std.log.info("Discord adapter stopped", .{});
    }
    
    pub fn run(self: *Self) void {
        std.log.info("Discord adapter running...", .{});
        
        while (self.running) {
            // In a full implementation, this would:
            // 1. Connect to Discord gateway WebSocket
            // 2. Send identify payload
            // 3. Handle heartbeat
            // 4. Process incoming events
            // 5. Reconnect on disconnection
            
            // For now, just sleep and check running status
            std.time.sleep(1000 * 1000 * 1000); // 1 second
        }
        
        std.log.info("Discord adapter run loop exiting", .{});
    }
    
    pub fn sendMessage(self: *Self, message: []const u8, context: anytype) !void {
        // Extract channel_id from context
        const channel_id = context.get("channel_id") orelse return error.MissingChannelId;
        
        // Send message to Discord channel
        try self.sendDiscordMessage(channel_id, message);
    }
    
    // Discord API Methods
    
    fn getGatewayUrl(self: *Self) !void {
        if (self.client == null) return error.ClientNotInitialized;
        var client = &self.client.?;
        
        // Discord API endpoint for gateway
        const url = "https://discord.com/api/v10/gateway/bot";
        
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        
        // Add authorization header
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bot {s}", .{self.token.?});
        defer self.allocator.free(auth_header);
        try headers.append("Authorization", auth_header);
        try headers.append("Content-Type", "application/json");
        
        var request = try client.request(.GET, try std.Uri.parse(url), headers, .{});
        defer request.deinit();
        
        try request.start();
        try request.wait();
        
        if (request.response.status != .ok) {
            std.log.err("Failed to get gateway URL: {}", .{request.response.status});
            return error.GatewayRequestFailed;
        }
        
        // Read response body
        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();
        
        const max_size = 1024 * 1024; // 1MB max
        try request.reader().readAllArrayList(&response_body, max_size);
        
        // Parse JSON response
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body.items, .{});
        defer parsed.deinit();
        
        const gateway_obj = parsed.value.object.get("url").?.string;
        self.gateway_url = try self.allocator.dupe(u8, gateway_obj);
        
        std.log.info("Got Discord gateway URL: {s}", .{self.gateway_url.?});
    }
    
    fn sendDiscordMessage(self: *Self, channel_id: []const u8, content: []const u8) !void {
        if (self.client == null) return error.ClientNotInitialized;
        var client = &self.client.?;
        
        // Build Discord API URL
        const url = try std.fmt.allocPrint(self.allocator, "https://discord.com/api/v10/channels/{s}/messages", .{channel_id});
        defer self.allocator.free(url);
        
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        
        // Add authorization header
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bot {s}", .{self.token.?});
        defer self.allocator.free(auth_header);
        try headers.append("Authorization", auth_header);
        try headers.append("Content-Type", "application/json");
        
        // Build JSON payload - escape content properly
        var escaped_content = std.ArrayList(u8).init(self.allocator);
        defer escaped_content.deinit();
        
        for (content) |char| {
            switch (char) {
                '"' => try escaped_content.appendSlice("\\\""),
                '\\' => try escaped_content.appendSlice("\\\\"),
                '\n' => try escaped_content.appendSlice("\\n"),
                '\r' => try escaped_content.appendSlice("\\r"),
                '\t' => try escaped_content.appendSlice("\\t"),
                else => try escaped_content.append(char),
            }
        }
        
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"content\": \"{s}\"}}", .{escaped_content.items});
        defer self.allocator.free(payload);
        
        var request = try client.request(.POST, try std.Uri.parse(url), headers, .{});
        defer request.deinit();
        
        request.transfer_encoding = .{ .content_length = payload.len };
        try request.start();
        
        // Send payload
        try request.writeAll(payload);
        try request.finish();
        try request.wait();
        
        if (request.response.status != .ok and request.response.status != .created) {
            std.log.err("Failed to send Discord message: {}", .{request.response.status});
        } else {
            std.log.info("Sent Discord message to channel {s}", .{channel_id});
        }
    }
};