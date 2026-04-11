// Streaming-aware compaction system for ClawForge
// This implements the blocking + post-compaction prompt system

const std = @import("std");

// Add to Engine struct (around line 12):
//     streaming_active: bool = false,
//     pending_compaction: bool = false,

// Enhanced maybeSummarizeSession that respects streaming state
pub fn maybeSummarizeSessionWithStreaming(self: *Engine, session_id: []const u8) void {
    if (self.summarizer) |s| {
        // Check if streaming is active
        if (self.streaming_active) {
            // Defer compaction until streaming ends
            self.pending_compaction = true;
            std.log.info("Compaction deferred - streaming active for session {s}", .{session_id[0..8]});
            return;
        }
        
        // Normal compaction path
        const old_token_count = self.getSessionTokenCount(session_id) catch 0;
        s.maybeSummarizeSession(session_id);
        
        // Check if compaction actually happened
        const new_token_count = self.getSessionTokenCount(session_id) catch 0;
        if (new_token_count < old_token_count) {
            // Compaction occurred - inject context restoration prompt
            self.injectPostCompactionPrompt(session_id, old_token_count, new_token_count) catch |err| {
                std.log.warn("Failed to inject post-compaction prompt: {}", .{err});
            };
        }
    }
}

// Track streaming state 
pub fn setStreamingActive(self: *Engine, active: bool) void {
    const was_streaming = self.streaming_active;
    self.streaming_active = active;
    
    // If streaming just ended and we have pending compaction, do it now
    if (was_streaming and !active and self.pending_compaction) {
        self.pending_compaction = false;
        std.log.info("Processing deferred compaction...");
        
        // Get active session for deferred compaction
        if (self.session_store.getActiveSession()) |sess| {
            const old_token_count = self.getSessionTokenCount(&sess.id) catch 0;
            if (self.summarizer) |s| {
                s.maybeSummarizeSession(&sess.id);
                
                // Check if compaction happened and inject prompt
                const new_token_count = self.getSessionTokenCount(&sess.id) catch 0;
                if (new_token_count < old_token_count) {
                    self.injectPostCompactionPrompt(&sess.id, old_token_count, new_token_count) catch |err| {
                        std.log.warn("Failed to inject deferred compaction prompt: {}", .{err});
                    };
                }
            }
            self.session_store.freeSessionInfo(&sess);
        }
    }
}

// Inject context restoration prompt after compaction
fn injectPostCompactionPrompt(self: *Engine, session_id: []const u8, old_tokens: usize, new_tokens: usize) !void {
    // Get the last user message for context extraction
    const recent_messages = try self.message_store.getRecentMessages(session_id, 3);
    defer self.allocator.free(recent_messages);
    
    var last_topic: []const u8 = "continuing previous work";
    if (recent_messages.len > 0) {
        const last_msg = recent_messages[recent_messages.len - 1];
        if (last_msg.content.len > 20) {
            // Extract first line or first 50 chars as topic hint
            const topic_end = @min(last_msg.content.len, 50);
            var line_end = topic_end;
            for (last_msg.content[0..topic_end], 0..) |char, i| {
                if (char == '\n' or char == '.') {
                    line_end = i;
                    break;
                }
            }
            last_topic = try self.allocator.dupe(u8, last_msg.content[0..line_end]);
        }
    }
    
    // Build post-compaction system message
    var prompt_buffer: [1024]u8 = undefined;
    const prompt = try std.fmt.bufPrint(&prompt_buffer, 
        \\[COMPACTION COMPLETED - {d} → {d} tokens]
        \\
        \\Your conversation history was just compacted to manage tokens. The most recent messages are preserved above.
        \\
        \\IMPORTANT: Check the last user message carefully for context. You were working on: {s}
        \\
        \\Continue from where you left off.
    , .{ old_tokens, new_tokens, last_topic });
    
    // Add system message to conversation
    _ = try self.message_store.addSystemMessage(session_id, try self.allocator.dupe(u8, prompt));
    
    std.log.info("Injected post-compaction prompt for session {s}", .{session_id[0..8]});
}

// Helper to estimate token count for a session
fn getSessionTokenCount(self: *Engine, session_id: []const u8) !usize {
    const messages = try self.message_store.getRecentMessages(session_id, 200);
    defer self.allocator.free(messages);
    
    var total_chars: usize = 0;
    for (messages) |msg| {
        total_chars += msg.content.len;
    }
    
    // Rough estimate: 4 chars per token
    return total_chars / 4;
}

// Modified processChat function additions:
// 
// At the start (line ~522):
//     self.setStreamingActive(emitter != null);
//
// At the end (line ~874, after postResponseHooks):
//     self.setStreamingActive(false);
//
// Replace line 926 call:
//     self.maybeSummarizeSessionWithStreaming(session_id);

// Worker pool integration - modify enqueueMaybeSummarize to check streaming:
//
// In workers/pool.zig, modify the maybe_summarize handler:
// if (!engine.streaming_active) {
//     s.maybeSummarizeSession(&job.session_id);
// } else {
//     engine.pending_compaction = true;
// }