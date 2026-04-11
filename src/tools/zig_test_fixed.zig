const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "zig_test",
    .description = "Test Zig files for compilation errors before rebuilding ClawForge. Prevents daemon suicide from syntax errors.",
    .input_schema_json = 
        \\{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"},"description":"Zig files to test (if empty, tests all tools and adapters)"},"mode":{"type":"string","enum":["syntax","build"],"default":"syntax","description":"Test mode: syntax (ast-check) or build (full compilation)"}},"additionalProperties":false}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

const TestResult = union(enum) {
    success: void,
    err: []const u8,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    // Get files to test
    const files_to_test = blk: {
        if (input == .object) {
            if (input.object.get("files")) |f| {
                if (f == .array) {
                    var files = std.ArrayList([]const u8).init(allocator);
                    for (f.array.items) |item| {
                        if (item == .string) {
                            files.append(item.string) catch continue;
                        }
                    }
                    break :blk files.toOwnedSlice() catch &[_][]const u8{};
                }
            }
        }
        // Default: find all tool and adapter zig files
        break :blk findZigFiles(allocator) catch &[_][]const u8{};
    };
    
    const mode = blk: {
        if (input == .object) {
            if (input.object.get("mode")) |m| {
                if (m == .string) {
                    if (std.mem.eql(u8, m.string, "build")) {
                        break :blk "build";
                    }
                }
            }
        }
        break :blk "syntax";
    };
    
    var output = std.ArrayList(u8).init(allocator);
    var has_errors = false;
    
    output.appendSlice("🧪 **Zig Compilation Test Results**\n\n") catch {};
    
    for (files_to_test) |file_path| {
        output.appendSlice("**Testing: ") catch {};
        output.appendSlice(file_path) catch {};
        output.appendSlice("**\n") catch {};
        
        // Test the file
        const result = if (std.mem.eql(u8, mode, "syntax"))
            testFileSyntax(allocator, file_path)
        else
            testFileBuild(allocator, file_path);
            
        switch (result) {
            .success => {
                output.appendSlice("✅ PASS\n\n") catch {};
            },
            .err => |err_msg| {
                has_errors = true;
                output.appendSlice("❌ **FAIL**\n```\n") catch {};
                output.appendSlice(err_msg) catch {};
                output.appendSlice("\n```\n\n") catch {};
            },
        }
    }
    
    if (has_errors) {
        output.appendSlice("🚨 **ERRORS FOUND** - Do NOT rebuild until fixed!\n") catch {};
        return .{ .content = output.toOwnedSlice() catch "Test failed", .is_error = true };
    } else {
        output.appendSlice("🎉 **ALL TESTS PASSED** - Safe to rebuild!\n") catch {};
        return .{ .content = output.toOwnedSlice() catch "Test passed", .is_error = false };
    }
}

fn testFileSyntax(allocator: std.mem.Allocator, file_path: []const u8) TestResult {
    // Run: zig ast-check <file>
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "ast-check", file_path },
        .max_output_bytes = 1024 * 16,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Failed to run zig: {s}", .{@errorName(err)}) catch "Process error";
        return TestResult{ .err = msg };
    };
    
    if (result.term.Exited == 0) {
        return TestResult.success;
    } else {
        return TestResult{ .err = result.stderr };
    }
}

fn testFileBuild(allocator: std.mem.Allocator, file_path: []const u8) TestResult {
    // Run: zig build-obj <file>
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build-obj", file_path },
        .max_output_bytes = 1024 * 16,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Failed to run zig: {s}", .{@errorName(err)}) catch "Process error";
        return TestResult{ .err = msg };
    };
    
    if (result.term.Exited == 0) {
        return TestResult.success;
    } else {
        return TestResult{ .err = result.stderr };
    }
}

fn findZigFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var files = std.ArrayList([]const u8).init(allocator);
    
    // Add known tool files
    const tool_files = [_][]const u8{
        "/home/garward/Scripts/Tools/ClawForge/src/tools/file_write.zig",
        "/home/garward/Scripts/Tools/ClawForge/src/tools/file_diff_fixed.zig", 
        "/home/garward/Scripts/Tools/ClawForge/src/tools/meme_tool.zig",
        "/home/garward/Scripts/Tools/ClawForge/src/tools/amazon_search.zig",
        "/home/garward/Scripts/Tools/ClawForge/src/tools/calc.zig",
        "/home/garward/Scripts/Tools/ClawForge/src/tools/introspect.zig",
        "/home/garward/Scripts/Tools/ClawForge/src/tools/rebuild.zig",
        "/home/garward/Scripts/Tools/ClawForge/src/tools/research_tool.zig",
        "/home/garward/Scripts/Tools/ClawForge/src/tools/registry.zig",
    };
    
    for (tool_files) |file| {
        // Check if file exists
        const file_handle = std.fs.openFileAbsolute(file, .{}) catch continue;
        file_handle.close();
        files.append(try allocator.dupe(u8, file)) catch continue;
    }
    
    return files.toOwnedSlice();
}