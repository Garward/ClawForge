const std = @import("std");
const json = std.json;
const fs = std.fs;

/// Type of authentication credential
pub const CredentialType = enum {
    api_key,
    token, // OAuth token
};

/// A single authentication profile
pub const AuthProfile = struct {
    id: []const u8,
    profile_type: CredentialType,
    provider: []const u8,
    credential: []const u8, // The actual key or token
    expires: ?i64 = null, // Milliseconds since epoch, null = never expires
};

/// Usage statistics for a profile
pub const UsageStats = struct {
    last_used: i64 = 0,
    error_count: u32 = 0,
    last_failure_at: i64 = 0,
    cooldown_until: i64 = 0,
    disabled_until: i64 = 0,
    disabled_reason: ?[]const u8 = null,
};

/// Profile eligibility status
pub const ProfileStatus = enum {
    ok,
    missing_credential,
    invalid_expires,
    expired,
    cooldown,
    disabled,
};

/// Auth profiles store
pub const AuthProfileStore = struct {
    allocator: std.mem.Allocator,
    profiles: std.StringHashMap(AuthProfile),
    usage_stats: std.StringHashMap(UsageStats),
    active_profile: ?[]const u8,
    last_good: std.StringHashMap([]const u8), // provider -> profile_id

    // Cooldown stages in milliseconds: 1min, 5min, 25min, 1hr
    const COOLDOWN_STAGES = [_]i64{ 60_000, 300_000, 1_500_000, 3_600_000 };

    pub fn init(allocator: std.mem.Allocator) AuthProfileStore {
        return .{
            .allocator = allocator,
            .profiles = std.StringHashMap(AuthProfile).init(allocator),
            .usage_stats = std.StringHashMap(UsageStats).init(allocator),
            .active_profile = null,
            .last_good = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *AuthProfileStore) void {
        self.profiles.deinit();
        self.usage_stats.deinit();
        self.last_good.deinit();
    }

    /// Load profiles from JSON file
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !AuthProfileStore {
        var store = AuthProfileStore.init(allocator);
        errdefer store.deinit();

        const file = fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("Auth profiles not found at {s}, starting fresh", .{path});
                return store;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const parsed = json.parseFromSlice(json.Value, allocator, content, .{
            .allocate = .alloc_always,
        }) catch {
            std.log.warn("Failed to parse auth profiles, starting fresh", .{});
            return store;
        };

        const obj = parsed.value.object;

        // Parse profiles
        if (obj.get("profiles")) |profiles_val| {
            var it = profiles_val.object.iterator();
            while (it.next()) |entry| {
                const profile_id = entry.key_ptr.*;
                const profile_obj = entry.value_ptr.*.object;

                const profile_type_str = if (profile_obj.get("type")) |t| t.string else "api_key";
                const profile_type: CredentialType = if (std.mem.eql(u8, profile_type_str, "token"))
                    .token
                else
                    .api_key;

                const credential = blk: {
                    if (profile_obj.get("token")) |t| break :blk t.string;
                    if (profile_obj.get("key")) |k| break :blk k.string;
                    break :blk "";
                };

                const expires: ?i64 = if (profile_obj.get("expires")) |e|
                    (if (e == .integer) e.integer else null)
                else
                    null;

                const provider = if (profile_obj.get("provider")) |p| p.string else "anthropic";

                try store.profiles.put(profile_id, .{
                    .id = profile_id,
                    .profile_type = profile_type,
                    .provider = provider,
                    .credential = credential,
                    .expires = expires,
                });
            }
        }

        // Parse active profile
        if (obj.get("active")) |active| {
            if (active != .null) {
                store.active_profile = active.string;
            }
        }

        // Parse usage stats
        if (obj.get("usageStats")) |stats_val| {
            var it = stats_val.object.iterator();
            while (it.next()) |entry| {
                const profile_id = entry.key_ptr.*;
                const stats_obj = entry.value_ptr.*.object;

                try store.usage_stats.put(profile_id, .{
                    .last_used = if (stats_obj.get("lastUsed")) |lu| lu.integer else 0,
                    .error_count = if (stats_obj.get("errorCount")) |ec| @intCast(ec.integer) else 0,
                    .last_failure_at = if (stats_obj.get("lastFailureAt")) |lf| lf.integer else 0,
                    .cooldown_until = if (stats_obj.get("cooldownUntil")) |cu| cu.integer else 0,
                    .disabled_until = if (stats_obj.get("disabledUntil")) |du| du.integer else 0,
                });
            }
        }

        // Parse lastGood
        if (obj.get("lastGood")) |last_good_val| {
            var it = last_good_val.object.iterator();
            while (it.next()) |entry| {
                try store.last_good.put(entry.key_ptr.*, entry.value_ptr.*.string);
            }
        }

        std.log.info("Loaded {d} auth profiles", .{store.profiles.count()});
        return store;
    }

    /// Save profiles to JSON file
    pub fn save(self: *AuthProfileStore, path: []const u8) !void {
        var buf = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(buf);
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
                    } else {
                        b[p.*] = c;
                        p.* += 1;
                    }
                }
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

        write(buf, &pos, "{\"version\":1");

        // Profiles
        write(buf, &pos, ",\"profiles\":{");
        var first = true;
        var profile_it = self.profiles.iterator();
        while (profile_it.next()) |entry| {
            if (!first) write(buf, &pos, ",");
            first = false;

            write(buf, &pos, "\"");
            write(buf, &pos, entry.key_ptr.*);
            write(buf, &pos, "\":{\"type\":\"");
            write(buf, &pos, if (entry.value_ptr.profile_type == .token) "token" else "api_key");
            write(buf, &pos, "\",\"provider\":\"");
            write(buf, &pos, entry.value_ptr.provider);
            write(buf, &pos, "\"");

            if (entry.value_ptr.profile_type == .token) {
                write(buf, &pos, ",\"token\":\"");
            } else {
                write(buf, &pos, ",\"key\":\"");
            }
            writeEscaped(buf, &pos, entry.value_ptr.credential);
            write(buf, &pos, "\"");

            if (entry.value_ptr.expires) |exp| {
                write(buf, &pos, ",\"expires\":");
                writeNum(buf, &pos, exp);
            }
            write(buf, &pos, "}");
        }
        write(buf, &pos, "}");

        // Active profile
        write(buf, &pos, ",\"active\":");
        if (self.active_profile) |active| {
            write(buf, &pos, "\"");
            write(buf, &pos, active);
            write(buf, &pos, "\"");
        } else {
            write(buf, &pos, "null");
        }

        // Usage stats
        write(buf, &pos, ",\"usageStats\":{");
        first = true;
        var stats_it = self.usage_stats.iterator();
        while (stats_it.next()) |entry| {
            if (!first) write(buf, &pos, ",");
            first = false;

            write(buf, &pos, "\"");
            write(buf, &pos, entry.key_ptr.*);
            write(buf, &pos, "\":{\"lastUsed\":");
            writeNum(buf, &pos, entry.value_ptr.last_used);
            write(buf, &pos, ",\"errorCount\":");
            writeNum(buf, &pos, entry.value_ptr.error_count);
            write(buf, &pos, ",\"lastFailureAt\":");
            writeNum(buf, &pos, entry.value_ptr.last_failure_at);
            write(buf, &pos, ",\"cooldownUntil\":");
            writeNum(buf, &pos, entry.value_ptr.cooldown_until);
            write(buf, &pos, ",\"disabledUntil\":");
            writeNum(buf, &pos, entry.value_ptr.disabled_until);
            write(buf, &pos, "}");
        }
        write(buf, &pos, "}");

        // Last good
        write(buf, &pos, ",\"lastGood\":{");
        first = true;
        var lg_it = self.last_good.iterator();
        while (lg_it.next()) |entry| {
            if (!first) write(buf, &pos, ",");
            first = false;

            write(buf, &pos, "\"");
            write(buf, &pos, entry.key_ptr.*);
            write(buf, &pos, "\":\"");
            write(buf, &pos, entry.value_ptr.*);
            write(buf, &pos, "\"");
        }
        write(buf, &pos, "}}");

        // Ensure directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        // Write file
        const file = try fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(buf[0..pos]);

        std.log.debug("Saved {d} auth profiles to {s}", .{ self.profiles.count(), path });
    }

    /// Check profile eligibility
    pub fn checkEligibility(self: *AuthProfileStore, profile_id: []const u8) ProfileStatus {
        const profile = self.profiles.get(profile_id) orelse return .missing_credential;

        // Check credential
        if (profile.credential.len == 0) {
            return .missing_credential;
        }

        // Check expiry
        if (profile.expires) |exp| {
            if (exp <= 0) return .invalid_expires;
            const now = std.time.milliTimestamp();
            if (now > exp) return .expired;
        }

        // Check cooldown/disabled
        if (self.usage_stats.get(profile_id)) |stats| {
            const now = std.time.milliTimestamp();
            if (stats.disabled_until > now) return .disabled;
            if (stats.cooldown_until > now) return .cooldown;
        }

        return .ok;
    }

    /// Get active credential for a provider
    pub fn getActiveCredential(self: *AuthProfileStore, provider: []const u8) ?AuthProfile {
        // First try explicit active profile
        if (self.active_profile) |active_id| {
            if (self.profiles.get(active_id)) |profile| {
                if (std.mem.eql(u8, profile.provider, provider)) {
                    if (self.checkEligibility(active_id) == .ok) {
                        return profile;
                    }
                }
            }
        }

        // Try last good
        if (self.last_good.get(provider)) |last_good_id| {
            if (self.profiles.get(last_good_id)) |profile| {
                if (self.checkEligibility(last_good_id) == .ok) {
                    return profile;
                }
            }
        }

        // Find any eligible profile for this provider
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.provider, provider)) {
                if (self.checkEligibility(entry.key_ptr.*) == .ok) {
                    return entry.value_ptr.*;
                }
            }
        }

        return null;
    }

    /// Mark profile as successfully used
    pub fn markUsed(self: *AuthProfileStore, profile_id: []const u8) void {
        const now = std.time.milliTimestamp();

        if (self.usage_stats.getPtr(profile_id)) |stats| {
            stats.last_used = now;
            stats.error_count = 0; // Reset on success
        } else {
            self.usage_stats.put(profile_id, .{
                .last_used = now,
                .error_count = 0,
            }) catch {};
        }

        // Update last good for the provider
        if (self.profiles.get(profile_id)) |profile| {
            self.last_good.put(profile.provider, profile_id) catch {};
        }
    }

    /// Mark profile as failed
    pub fn markFailed(self: *AuthProfileStore, profile_id: []const u8) void {
        const now = std.time.milliTimestamp();

        if (self.usage_stats.getPtr(profile_id)) |stats| {
            stats.error_count += 1;
            stats.last_failure_at = now;

            // Calculate cooldown based on error count
            const stage = @min(stats.error_count, COOLDOWN_STAGES.len) - 1;
            stats.cooldown_until = now + COOLDOWN_STAGES[stage];
        } else {
            self.usage_stats.put(profile_id, .{
                .error_count = 1,
                .last_failure_at = now,
                .cooldown_until = now + COOLDOWN_STAGES[0],
            }) catch {};
        }
    }

    /// Add a new profile
    pub fn addProfile(
        self: *AuthProfileStore,
        id: []const u8,
        profile_type: CredentialType,
        provider: []const u8,
        credential: []const u8,
        expires: ?i64,
    ) !void {
        try self.profiles.put(id, .{
            .id = id,
            .profile_type = profile_type,
            .provider = provider,
            .credential = credential,
            .expires = expires,
        });

        // Set as active if it's the first profile
        if (self.active_profile == null) {
            self.active_profile = id;
        }
    }

    /// Remove a profile
    pub fn removeProfile(self: *AuthProfileStore, id: []const u8) bool {
        if (self.profiles.remove(id)) {
            _ = self.usage_stats.remove(id);

            // Clear active if it was this profile
            if (self.active_profile) |active| {
                if (std.mem.eql(u8, active, id)) {
                    self.active_profile = null;
                }
            }
            return true;
        }
        return false;
    }

    /// Set active profile
    pub fn setActive(self: *AuthProfileStore, id: []const u8) bool {
        if (self.profiles.contains(id)) {
            self.active_profile = id;
            return true;
        }
        return false;
    }

    /// List all profiles
    pub fn listProfiles(self: *AuthProfileStore) []const AuthProfile {
        var list = self.allocator.alloc(AuthProfile, self.profiles.count()) catch return &.{};
        var i: usize = 0;
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            list[i] = entry.value_ptr.*;
            i += 1;
        }
        return list[0..i];
    }
};

/// Check if a token is an OAuth token
pub fn isOAuthToken(token: []const u8) bool {
    return std.mem.indexOf(u8, token, "sk-ant-oat") != null;
}

/// Detect credential type from token format
pub fn detectCredentialType(credential: []const u8) CredentialType {
    if (isOAuthToken(credential)) {
        return .token;
    }
    return .api_key;
}
