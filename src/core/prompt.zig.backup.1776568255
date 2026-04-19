const std = @import("std");
const storage = @import("storage");

/// The 6 layers of a system prompt, assembled in order.
/// Each layer is optional — null layers are skipped.
/// Any adapter or automation can build these layers and call assemble().
pub const PromptLayers = struct {
    /// Layer 1: Base persona + source hierarchy rules.
    /// Loaded from config/personas/ or per-user override.
    /// Contains the anti-hallucination rules that are NON-NEGOTIABLE.
    persona: ?[]const u8 = null,

    /// Layer 2: User context from knowledge table.
    /// Preferences, expertise, communication style.
    /// Tagged: [from knowledge]
    user_context: ?[]const u8 = null,

    /// Layer 3: Project context — rolling_summary + rolling_state.
    /// Only present when session is attached to a project.
    /// Tagged: [from project state]
    project: ?ProjectLayer = null,

    /// Layer 3.5: Active execution plan — persisted per-session.
    /// Injected after project context so the model always sees its current
    /// plan state. When null, a mandatory planning instruction is injected
    /// instead to force plan creation on multi-step work.
    active_plan: ?[]const u8 = null,

    /// Layer 3.6: Active skills — matched instruction templates.
    /// Injected after plan, before retrieved search results.
    skills: ?[]const []const u8 = null,

    /// Layer 4: Retrieved context from search (summaries, knowledge, artifacts).
    /// Each entry tagged with provenance for citation.
    /// Tagged: [from summary], [from knowledge], [from artifact], etc.
    retrieved: ?[]const RetrievedEntry = null,

    /// Layer 5: Adapter-specific context (cwd, channel, guild, etc.).
    adapter_context: ?[]const u8 = null,

    /// Layer 6: Session-level system prompt override.
    /// User's explicit `system` command — goes last, highest priority.
    session_override: ?[]const u8 = null,
};

pub const ProjectLayer = struct {
    name: []const u8,
    summary: ?[]const u8,
    state: ?[]const u8,
    /// Constraints extracted from rolling_state. Injected as explicit rules.
    /// e.g., "budget must not exceed $5000", "do not suggest builds exceeding PP"
    constraints: ?[]const []const u8 = null,
    /// Response template from rolling_state. Formatting guide for this project.
    response_template: ?[]const u8 = null,
};

pub const RetrievedEntry = struct {
    /// Source tag for citation: "knowledge", "summary", "artifact", "message"
    source_type: []const u8,
    /// Human-readable label: "session summary 2026-04-08", "knowledge: gaming preferences"
    source_label: []const u8,
    /// The actual content
    content: []const u8,
};

/// Default persona — embedded at compile time from config/personas/default.txt.
pub const DEFAULT_PERSONA = @embedFile("default_persona.txt");

const common = @import("common");

/// Load a persona file from config/personas/{name}.txt at runtime.
/// Returns null if file not found. Caller owns the returned memory.
pub fn loadPersona(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    // Reject path traversal
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "/") != null) return null;

    const rel_path = std.fmt.allocPrint(allocator, "config/personas/{s}.txt", .{name}) catch return null;
    defer allocator.free(rel_path);

    const abs_path = common.config.resolveProjectPath(allocator, rel_path) catch return null;
    defer allocator.free(abs_path);

    const file = std.fs.openFileAbsolute(abs_path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024) catch null;
}

/// List available persona names from config/personas/*.txt.
/// Returns a slice of name strings (without .txt extension). Caller owns memory.
pub fn listPersonas(allocator: std.mem.Allocator) ![]const []const u8 {
    const dir_path = common.config.resolveProjectPath(allocator, "config/personas") catch return &.{};
    defer allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close();

    var names: std.ArrayList([]const u8) = .{};
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const fname = entry.name;
        if (!std.mem.endsWith(u8, fname, ".txt")) continue;
        const name = fname[0 .. fname.len - 4]; // strip .txt
        try names.append(allocator, try allocator.dupe(u8, name));
    }
    return try names.toOwnedSlice(allocator);
}

/// Save a persona file to config/personas/{name}.txt.
pub fn savePersona(allocator: std.mem.Allocator, name: []const u8, content: []const u8) !void {
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "/") != null) return error.InvalidName;
    if (name.len == 0) return error.InvalidName;

    const rel_path = try std.fmt.allocPrint(allocator, "config/personas/{s}.txt", .{name});
    defer allocator.free(rel_path);

    const abs_path = try common.config.resolveProjectPath(allocator, rel_path);
    defer allocator.free(abs_path);

    const file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

/// Delete a persona file. Cannot delete "default".
pub fn deletePersona(allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, name, "default")) return error.CannotDeleteDefault;
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "/") != null) return error.InvalidName;

    const rel_path = try std.fmt.allocPrint(allocator, "config/personas/{s}.txt", .{name});
    defer allocator.free(rel_path);

    const abs_path = try common.config.resolveProjectPath(allocator, rel_path);
    defer allocator.free(abs_path);

    try std.fs.deleteFileAbsolute(abs_path);
}

/// Assemble a system prompt from layers. Returns allocated string.
/// Layers are concatenated in order with section headers.
/// If total exceeds max_tokens (estimated), trims retrieved context first.
pub fn assemble(allocator: std.mem.Allocator, layers: PromptLayers, max_chars: usize) ![]const u8 {
    var buf = try allocator.alloc(u8, max_chars);
    var pos: usize = 0;

    const write = struct {
        fn f(b: []u8, p: *usize, data: []const u8) void {
            const len = @min(data.len, b.len -| p.*);
            @memcpy(b[p.*..][0..len], data[0..len]);
            p.* += len;
        }
    }.f;

    // Layer 1: Persona (base rules + anti-hallucination)
    if (layers.persona) |persona| {
        write(buf, &pos, persona);
    } else {
        write(buf, &pos, DEFAULT_PERSONA);
    }

    // Layer 2: User context
    if (layers.user_context) |user_ctx| {
        write(buf, &pos, "\n\n--- User Context [from knowledge] ---\n");
        write(buf, &pos, user_ctx);
    }

    // Layer 3: Project context
    if (layers.project) |project| {
        write(buf, &pos, "\n\n--- Project: ");
        write(buf, &pos, project.name);
        write(buf, &pos, " [from project state] ---\n");

        if (project.summary) |summary| {
            write(buf, &pos, "\nCurrent state:\n");
            write(buf, &pos, summary);
        }

        if (project.state) |state| {
            if (state.len > 2) {
                write(buf, &pos, "\n\nStructured state:\n");
                write(buf, &pos, state);
            }
        }

        // Inject constraints as explicit rules
        if (project.constraints) |constraints| {
            if (constraints.len > 0) {
                write(buf, &pos, "\n\nACTIVE CONSTRAINTS (enforce these):\n");
                for (constraints) |c| {
                    write(buf, &pos, "- CONSTRAINT: ");
                    write(buf, &pos, c);
                    write(buf, &pos, "\n");
                }
            }
        }

        // Inject response template
        if (project.response_template) |template| {
            write(buf, &pos, "\n\nRESPONSE FORMAT (follow this structure):\n");
            write(buf, &pos, template);
        }
    }

    // Layer 3.5: Active plan (persisted task tracking)
    if (layers.active_plan) |plan| {
        write(buf, &pos, "\n\n--- Active Execution Plan (delegate work via summon_subagent — do NOT hallucinate results) ---\n");
        write(buf, &pos, plan);
        write(buf, &pos, "\n--- End Plan ---");
    } else {
        // No plan exists — inject planning instruction with lightweight exception
        write(buf, &pos, "\n\n--- Execution Plan: None Active ---\n");
        write(buf, &pos,
            \\DEFAULT: Handle it yourself. You have direct access to file_read,
            \\introspect, calc, research, meme_tool, amazon_search, and safe bash
            \\commands (ls, tree, pwd, git log/status/diff, head, tail, cat, find).
            \\Use them for quick lookups, listing files, checking facts. No plan
            \\needed. Just call the tool and answer the user.
            \\
            \\ONLY escalate to plan + subagent when the task genuinely requires
            \\multiple heavy steps (destructive shell commands, file edits, builds):
            \\1. Call `plan` with operation "create" (this unblocks heavy tools)
            \\2. Use summon_subagent for steps that need file_write/file_diff/builds
            \\3. Subagents update the plan as they complete steps
            \\
            \\Examples of what NOT to plan/delegate:
            \\- "What's in main.zig?" → file_read, answer. Done.
            \\- "List the src directory" → bash ls src/, answer. Done.
            \\- "Show recent commits" → bash git log --oneline -10, answer. Done.
            \\- "How many sessions exist?" → introspect, answer. Done.
            \\- "Where is the config file?" → introspect project_tree with query, answer. Done.
            \\
            \\Heavy tools (mutating bash, file_write, file_diff, summon_subagent)
            \\are BLOCKED until you create a plan. Read-only tools are available now.
        );
        write(buf, &pos, "\n--- End Plan ---");
    }

    // Layer 3.6: Skills (matched instruction templates)
    if (layers.skills) |skill_instructions| {
        if (skill_instructions.len > 0) {
            write(buf, &pos, "\n\n--- Active Skills ---\n");
            for (skill_instructions) |instruction| {
                write(buf, &pos, "- ");
                write(buf, &pos, instruction);
                write(buf, &pos, "\n");
            }
            write(buf, &pos, "--- End Skills ---");
        }
    }

    // Layer 4: Retrieved context (most trimmable — added last before adapter)
    if (layers.retrieved) |entries| {
        if (entries.len > 0) {
            write(buf, &pos, "\n\n--- Retrieved Context ---\n");
            for (entries) |entry| {
                // Check budget: stop adding if we're within 500 chars of limit
                if (pos + entry.content.len + 100 > max_chars -| 500) {
                    write(buf, &pos, "\n[Additional context trimmed for token budget]\n");
                    break;
                }
                write(buf, &pos, "\n[from ");
                write(buf, &pos, entry.source_type);
                write(buf, &pos, ": ");
                write(buf, &pos, entry.source_label);
                write(buf, &pos, "]\n");
                write(buf, &pos, entry.content);
                write(buf, &pos, "\n");
            }
            write(buf, &pos, "--- End Retrieved Context ---");
        }
    }

    // Layer 5: Adapter context
    if (layers.adapter_context) |adapter_ctx| {
        write(buf, &pos, "\n\n--- Interface Context ---\n");
        write(buf, &pos, adapter_ctx);
    }

    // Layer 6: Session override (user's explicit system prompt)
    if (layers.session_override) |override| {
        write(buf, &pos, "\n\n--- Custom Instructions ---\n");
        write(buf, &pos, override);
    }

    return allocator.realloc(buf, pos) catch buf[0..pos];
}

/// Build PromptLayers from the current engine state.
/// This is the standard path — adapters can also build layers manually.
pub fn buildFromState(
    allocator: std.mem.Allocator,
    project_store: *storage.ProjectStore,
    session_id: []const u8,
    session_system_prompt: ?[]const u8,
    adapter_context: ?[]const u8,
) !PromptLayers {
    var layers = PromptLayers{};

    // Layer 1: Persona — load by name from config/personas/ or fall back to compiled default.
    // session_system_prompt stores the persona NAME (e.g. "Vera"), not the full text.
    if (session_system_prompt) |persona_name| {
        if (persona_name.len > 0) {
            layers.persona = loadPersona(allocator, persona_name);
            std.log.info("Persona load: name='{s}' result={s}", .{
                persona_name,
                if (layers.persona != null) "loaded" else "FALLBACK_TO_DEFAULT",
            });
        }
    } else {
        std.log.info("Persona load: no system_prompt on session, using DEFAULT", .{});
    }
    if (layers.persona == null) {
        layers.persona = DEFAULT_PERSONA;
    }

    // Layer 3: Project context if attached
    if (try project_store.getSessionProject(session_id)) |project_id| {
        const project = project_store.getProject(project_id) catch null;
        const rolling = project_store.getRollingContext(project_id) catch storage.RollingContext{ .summary = null, .state = null };

        if (project) |p| {
            // Extract constraints from rolling_state JSON if present
            var constraints_buf: [16][]const u8 = undefined;
            var constraint_count: usize = 0;
            if (rolling.state) |state_json| {
                if (state_json.len > 2) {
                    const parsed = std.json.parseFromSlice(std.json.Value, allocator, state_json, .{}) catch null;
                    if (parsed) |pv| {
                        if (pv.value == .object) {
                            if (pv.value.object.get("constraints")) |cv| {
                                if (cv == .array) {
                                    for (cv.array.items) |item| {
                                        if (item == .string and constraint_count < constraints_buf.len) {
                                            constraints_buf[constraint_count] = item.string;
                                            constraint_count += 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Extract response_template from rolling_state
            var response_template: ?[]const u8 = null;
            if (rolling.state) |state_json| {
                if (state_json.len > 2) {
                    const parsed = std.json.parseFromSlice(std.json.Value, allocator, state_json, .{}) catch null;
                    if (parsed) |pv| {
                        if (pv.value == .object) {
                            if (pv.value.object.get("response_template")) |rt| {
                                if (rt == .string) response_template = rt.string;
                            }
                        }
                    }
                }
            }

            const constraints = if (constraint_count > 0) blk: {
                const heap = allocator.alloc([]const u8, constraint_count) catch break :blk null;
                @memcpy(heap, constraints_buf[0..constraint_count]);
                break :blk @as(?[]const []const u8, heap);
            } else null;

            layers.project = .{
                .name = p.name,
                .summary = rolling.summary,
                .state = rolling.state,
                .constraints = constraints,
                .response_template = response_template,
            };
        }
    }

    // Layer 5: Adapter context
    layers.adapter_context = adapter_context;

    // Layer 6: Session override — no longer used for persona (now Layer 1).
    // Reserved for future per-session instruction overrides.

    return layers;
}
