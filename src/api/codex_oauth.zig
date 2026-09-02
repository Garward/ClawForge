const std = @import("std");
const json = std.json;
const http = std.http;
const common = @import("common");

/// Codex (ChatGPT subscription) OAuth — read/refresh tokens stored at
/// `~/.codex/auth.json` by the Codex CLI. The refresh endpoint is the
/// public OpenAI auth host; the resulting access_token is then used as
/// a Bearer token against `chatgpt.com/backend-api/codex/responses`.
///
/// The access_token is a JWT carrying both:
///   - exp  (unix seconds, used to detect expiry)
///   - https://api.openai.com/auth.chatgpt_account_id (used as the
///     `chatgpt-account-id` header on every request)
///
/// We do NOT implement the interactive OAuth login flow. Users authenticate
/// with the Codex CLI (`codex login`) and ClawForge consumes whatever
/// auth.json that flow produces.
pub const TOKEN_URL = "https://auth.openai.com/oauth/token";
pub const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const JWT_CLAIM = "https://api.openai.com/auth";

pub const Tokens = struct {
    access_token: []const u8, // owned
    refresh_token: []const u8, // owned
    id_token: []const u8, // owned (preserved on writeback; may be empty)
    account_id: []const u8, // owned (extracted from JWT claim)
    /// Unix seconds.
    expires_at: i64,

    pub fn deinit(self: *Tokens, a: std.mem.Allocator) void {
        a.free(self.access_token);
        a.free(self.refresh_token);
        a.free(self.id_token);
        a.free(self.account_id);
    }
};

/// Thread-safe token store. Reads `~/.codex/auth.json` on init; refreshes
/// transparently when `getCredentials()` is called within 60s of expiry,
/// and persists the rotated tokens back to disk so the Codex CLI and
/// ClawForge stay in sync.
pub const Store = struct {
    allocator: std.mem.Allocator,
    auth_path: []const u8, // owned
    tokens: Tokens,
    mutex: common.sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, auth_path: []const u8) !Store {
        const path_dup = try allocator.dupe(u8, auth_path);
        errdefer allocator.free(path_dup);
        var tokens = try readAuthFile(allocator, path_dup);
        errdefer tokens.deinit(allocator);
        return .{
            .allocator = allocator,
            .auth_path = path_dup,
            .tokens = tokens,
        };
    }

    pub fn deinit(self: *Store) void {
        self.tokens.deinit(self.allocator);
        self.allocator.free(self.auth_path);
    }

    /// Returns borrowed slices valid until the next call to a mutating
    /// method on this Store (refresh / forceRefresh). Refreshes if the
    /// access_token expires within 60s.
    pub fn getCredentials(self: *Store) !struct {
        access_token: []const u8,
        account_id: []const u8,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = common.sync.timestamp();
        if (self.tokens.expires_at - now < 60) {
            try self.refreshLocked();
        }
        return .{
            .access_token = self.tokens.access_token,
            .account_id = self.tokens.account_id,
        };
    }

    /// Force a refresh regardless of expiry — call this on a 401 response
    /// before retrying the request once.
    pub fn forceRefresh(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.refreshLocked();
    }

    fn refreshLocked(self: *Store) !void {
        var new_tokens = try refreshTokens(self.allocator, self.tokens.refresh_token);
        errdefer new_tokens.deinit(self.allocator);

        // Preserve id_token from previous file if the refresh response
        // didn't return one (some servers omit it on refresh).
        if (new_tokens.id_token.len == 0 and self.tokens.id_token.len > 0) {
            self.allocator.free(new_tokens.id_token);
            new_tokens.id_token = try self.allocator.dupe(u8, self.tokens.id_token);
        }

        // Replace.
        self.tokens.deinit(self.allocator);
        self.tokens = new_tokens;

        writeAuthFile(self.allocator, self.auth_path, &self.tokens) catch |err| {
            std.log.warn("codex: failed to persist refreshed tokens to {s}: {}", .{ self.auth_path, err });
        };
        std.log.info("codex: tokens refreshed (expires_at={d}, account={s})", .{
            self.tokens.expires_at,
            self.tokens.account_id,
        });
    }
};

// =============================================================================
// auth.json IO
// =============================================================================

pub fn readAuthFile(allocator: std.mem.Allocator, path: []const u8) !Tokens {
    const io = common.config.runtimeIo();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    const content = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(content);

    var parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthFile;
    const root = parsed.value.object;

    const tokens_val = root.get("tokens") orelse return error.MissingTokens;
    if (tokens_val != .object) return error.InvalidAuthFile;
    const tok = tokens_val.object;

    const access = (tok.get("access_token") orelse return error.MissingAccessToken);
    const refresh = (tok.get("refresh_token") orelse return error.MissingRefreshToken);
    if (access != .string or refresh != .string) return error.InvalidAuthFile;

    const id_str = blk: {
        if (tok.get("id_token")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "";
    };

    // Prefer JWT-derived account_id; fall back to the file's `account_id` field.
    const claim = decodeJwtClaim(allocator, access.string) catch |err| {
        std.log.warn("codex: JWT decode failed ({}); falling back to file account_id", .{err});
        // No exp from JWT; use a far-past timestamp so first call refreshes.
        const fallback_account = blk: {
            if (tok.get("account_id")) |v| {
                if (v == .string) break :blk v.string;
            }
            return error.NoAccountId;
        };
        return .{
            .access_token = try allocator.dupe(u8, access.string),
            .refresh_token = try allocator.dupe(u8, refresh.string),
            .id_token = try allocator.dupe(u8, id_str),
            .account_id = try allocator.dupe(u8, fallback_account),
            .expires_at = 0,
        };
    };
    defer allocator.free(claim.account_id);

    return .{
        .access_token = try allocator.dupe(u8, access.string),
        .refresh_token = try allocator.dupe(u8, refresh.string),
        .id_token = try allocator.dupe(u8, id_str),
        .account_id = try allocator.dupe(u8, claim.account_id),
        .expires_at = claim.exp,
    };
}

/// Persist tokens back to `auth.json` using the Codex CLI's schema. Done
/// atomically (write to .tmp, rename) so a crash mid-write never leaves a
/// truncated file that locks the user out of their session.
pub fn writeAuthFile(allocator: std.mem.Allocator, path: []const u8, tokens: *const Tokens) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n  \"OPENAI_API_KEY\": null,\n  \"tokens\": {\n    \"id_token\": ");
    try appendJsonString(&out, allocator, tokens.id_token);
    try out.appendSlice(allocator, ",\n    \"access_token\": ");
    try appendJsonString(&out, allocator, tokens.access_token);
    try out.appendSlice(allocator, ",\n    \"refresh_token\": ");
    try appendJsonString(&out, allocator, tokens.refresh_token);
    try out.appendSlice(allocator, ",\n    \"account_id\": ");
    try appendJsonString(&out, allocator, tokens.account_id);
    try out.appendSlice(allocator, "\n  },\n  \"last_refresh\": ");

    // ISO-8601 UTC timestamp.
    var ts_buf: [40]u8 = undefined;
    const ts = formatIso8601(&ts_buf, common.sync.timestamp());
    try appendJsonString(&out, allocator, ts);
    try out.appendSlice(allocator, "\n}\n");

    // Atomic write via tmp+rename.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        const io = common.config.runtimeIo();
        const tmp_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = .fromMode(0o600) });
        defer tmp_file.close(io);
        var file_writer = tmp_file.writer(io, &.{});
        try file_writer.interface.writeAll(out.items);
    }
    const io = common.config.runtimeIo();
    try std.Io.Dir.cwd().rename(tmp_path, .cwd(), path, io);
}

fn appendJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [8]u8 = undefined;
                    const e = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    try out.appendSlice(a, e);
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
    try out.append(a, '"');
}

fn formatIso8601(buf: []u8, unix_seconds: i64) []const u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

// =============================================================================
// JWT decode
// =============================================================================

/// Decode the middle segment of a JWT, extract `exp` (unix seconds) and
/// the account_id from the OpenAI claim path. Caller owns `account_id`.
pub fn decodeJwtClaim(allocator: std.mem.Allocator, jwt: []const u8) !struct {
    exp: i64,
    account_id: []u8,
} {
    var it = std.mem.splitScalar(u8, jwt, '.');
    _ = it.next() orelse return error.InvalidJwt;
    const payload_b64 = it.next() orelse return error.InvalidJwt;

    // base64url, padding optional. Pad it ourselves to keep the decoder happy.
    const padded = try padBase64Url(allocator, payload_b64);
    defer allocator.free(padded);

    const decoded_len = try std.base64.url_safe.Decoder.calcSizeForSlice(padded);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe.Decoder.decode(decoded, padded);

    var parsed = try json.parseFromSlice(json.Value, allocator, decoded, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJwt;
    const obj = parsed.value.object;

    const exp_val = obj.get("exp") orelse return error.NoExp;
    const exp: i64 = switch (exp_val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return error.NoExp,
    };

    const claim_obj = obj.get(JWT_CLAIM) orelse return error.NoClaim;
    if (claim_obj != .object) return error.NoClaim;
    const aid = claim_obj.object.get("chatgpt_account_id") orelse return error.NoAccountId;
    if (aid != .string) return error.NoAccountId;

    return .{
        .exp = exp,
        .account_id = try allocator.dupe(u8, aid.string),
    };
}

fn padBase64Url(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const rem = s.len % 4;
    const pad: usize = if (rem == 0) 0 else 4 - rem;
    const out = try allocator.alloc(u8, s.len + pad);
    @memcpy(out[0..s.len], s);
    var i: usize = 0;
    while (i < pad) : (i += 1) out[s.len + i] = '=';
    return out;
}

// =============================================================================
// Refresh
// =============================================================================

pub fn refreshTokens(allocator: std.mem.Allocator, refresh_token: []const u8) !Tokens {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // URL-encode the refresh_token value.
    const enc_refresh = try urlEncode(arena, refresh_token);
    const body = try std.fmt.allocPrint(
        arena,
        "grant_type=refresh_token&refresh_token={s}&client_id={s}",
        .{ enc_refresh, CLIENT_ID },
    );

    var client = http.Client{ .allocator = arena, .io = common.config.runtimeIo() };
    var response_writer = std.Io.Writer.Allocating.init(arena);
    var redirect_buf: [8 * 1024]u8 = undefined;

    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "accept", .value = "application/json" },
    };

    const result = client.fetch(.{
        .location = .{ .url = TOKEN_URL },
        .method = .POST,
        .redirect_buffer = &redirect_buf,
        .response_writer = &response_writer.writer,
        .extra_headers = &headers,
        .payload = body,
    }) catch |err| {
        std.log.err("codex: token refresh network error: {}", .{err});
        return error.NetworkError;
    };

    const data = response_writer.written();
    if (result.status != .ok) {
        std.log.err("codex: refresh failed {d}: {s}", .{
            @intFromEnum(result.status),
            data[0..@min(data.len, 500)],
        });
        return error.RefreshFailed;
    }

    const parsed = try json.parseFromSlice(json.Value, arena, data, .{});
    if (parsed.value != .object) return error.InvalidRefreshResponse;
    const obj = parsed.value.object;

    const access_v = obj.get("access_token") orelse return error.InvalidRefreshResponse;
    const refresh_v = obj.get("refresh_token") orelse return error.InvalidRefreshResponse;
    if (access_v != .string or refresh_v != .string) return error.InvalidRefreshResponse;

    const id_str = blk: {
        if (obj.get("id_token")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "";
    };

    // Prefer JWT exp; else fall back to expires_in + now.
    const access_str = access_v.string;
    var exp_seconds: i64 = 0;
    var account_id_owned: ?[]u8 = null;
    errdefer if (account_id_owned) |a| allocator.free(a);

    if (decodeJwtClaim(allocator, access_str)) |claim| {
        exp_seconds = claim.exp;
        account_id_owned = claim.account_id;
    } else |err| {
        std.log.warn("codex: refresh response JWT decode failed: {}", .{err});
        if (obj.get("expires_in")) |ev| {
            const ein: i64 = switch (ev) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => 3600,
            };
            exp_seconds = common.sync.timestamp() + ein;
        } else {
            exp_seconds = common.sync.timestamp() + 3600;
        }
        // Without a JWT we can't extract account_id; bail. The caller
        // should treat this as "manually re-authenticate via codex CLI".
        return error.NoAccountIdInResponse;
    }

    return .{
        .access_token = try allocator.dupe(u8, access_str),
        .refresh_token = try allocator.dupe(u8, refresh_v.string),
        .id_token = try allocator.dupe(u8, id_str),
        .account_id = account_id_owned.?,
        .expires_at = exp_seconds,
    };
}

fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, s.len + 16);
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try out.append(arena, c);
        } else {
            var buf: [4]u8 = undefined;
            const e = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch continue;
            try out.appendSlice(arena, e);
        }
    }
    return out.toOwnedSlice(arena);
}
