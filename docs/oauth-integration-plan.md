# ClawForge OAuth Token Integration Plan

## Overview

Integrate Claude Code OAuth token (`sk-ant-oat01-*`) support into ClawForge, enabling subscription-based authentication instead of API keys.

## Key Findings from OpenClaw Analysis

### 1. OAuth Token Authentication Requirements

**Detection:**
```javascript
function isOAuthToken(apiKey) {
    return apiKey.includes("sk-ant-oat");
}
```

**Required Headers for OAuth:**
```
Authorization: Bearer <oauth-token>
anthropic-version: 2023-06-01
anthropic-beta: claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14
user-agent: claude-cli/<version>
x-app: cli
content-type: application/json
```

**Required System Prompt (MANDATORY for OAuth):**
```json
{
  "system": [
    {
      "type": "text",
      "text": "You are Claude Code, Anthropic's official CLI for Claude."
    },
    {
      "type": "text",
      "text": "<user's system prompt if any>"
    }
  ]
}
```

### 2. API Key Authentication (existing)
```
x-api-key: <api-key>
anthropic-version: 2023-06-01
anthropic-beta: fine-grained-tool-streaming-2025-05-14
content-type: application/json
```

## Implementation Plan

### Phase 1: Core OAuth Authentication

**File: `src/api/anthropic.zig`**

1. Add OAuth token detection:
```zig
fn isOAuthToken(token: []const u8) bool {
    return std.mem.indexOf(u8, token, "sk-ant-oat") != null;
}
```

2. Modify `createMessage` to use different headers based on token type:
   - OAuth: `Authorization: Bearer` + Claude Code beta headers
   - API Key: `x-api-key` header

3. Add required Claude Code identity headers for OAuth:
   - `anthropic-beta: claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14`
   - `user-agent: clawforge/0.1.0`
   - `x-app: cli`

**File: `src/api/messages.zig`**

4. Modify `MessageRequest.toJson` to prepend Claude Code identity system prompt for OAuth:
```zig
pub fn toJson(self: *const MessageRequest, allocator: std.mem.Allocator, is_oauth: bool) ![]u8 {
    // If OAuth, prepend "You are Claude Code..." to system prompt
}
```

### Phase 2: Auth Profile Management

**New File: `src/common/auth_profiles.zig`**

Storage format (JSON):
```json
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "token",
      "provider": "anthropic",
      "token": "sk-ant-oat01-...",
      "expires": 1774234612000
    },
    "anthropic:api": {
      "type": "api_key",
      "provider": "anthropic",
      "key": "sk-ant-api03-..."
    }
  },
  "active": "anthropic:default",
  "usageStats": {
    "anthropic:default": {
      "lastUsed": 1775495557923,
      "errorCount": 0
    }
  }
}
```

Functions:
- `loadProfiles(allocator, path)` - Load auth profiles from JSON
- `saveProfiles(profiles, path)` - Save profiles to JSON
- `getActiveCredential(profiles)` - Get current active credential
- `markProfileUsed(profiles, id)` - Update usage stats
- `markProfileFailed(profiles, id)` - Increment error count

### Phase 3: Token Lifecycle

**File: `src/common/auth_profiles.zig`**

1. **Expiry Checking:**
```zig
fn isExpired(profile: AuthProfile) bool {
    if (profile.expires) |exp| {
        return std.time.milliTimestamp() > exp;
    }
    return false; // No expiry = never expires
}
```

2. **Profile Eligibility:**
```zig
const ProfileStatus = enum {
    ok,
    missing_credential,
    invalid_expires,
    expired,
    cooldown,
};

fn checkEligibility(profile: AuthProfile) ProfileStatus {
    // Check token/key presence
    // Check expiry validity
    // Check cooldown status
}
```

3. **Cooldown Management:**
   - Track consecutive failures
   - Implement exponential backoff: 1min → 5min → 25min → 1hr
   - Auto-reset after 24 hours of no failures

### Phase 4: Session Integration

**File: `src/daemon/session.zig`**

1. Pin auth profile per session (cache-friendly)
2. Allow manual override via command
3. Reset profile pin on session reset

**File: `src/daemon/handler.zig`**

1. Resolve credential before API call
2. Pass `is_oauth` flag to API client
3. Update usage stats after successful call
4. Handle auth failures with profile rotation

### Phase 5: CLI Commands

**New commands:**
```
clawforge auth list              # List auth profiles
clawforge auth add <token>       # Add new credential
clawforge auth remove <id>       # Remove profile
clawforge auth switch <id>       # Set active profile
clawforge auth status            # Show current auth status
```

## File Changes Summary

| File | Changes |
|------|---------|
| `src/api/anthropic.zig` | OAuth header logic, token detection |
| `src/api/messages.zig` | OAuth system prompt injection |
| `src/common/auth_profiles.zig` | NEW - Profile management |
| `src/common/config.zig` | Add auth_profiles_path config |
| `src/daemon/handler.zig` | Credential resolution, usage tracking |
| `src/daemon/session.zig` | Profile pinning per session |
| `src/cli.zig` | Auth management commands |
| `config/config.json` | Add auth settings |

## Testing Plan

1. **OAuth Authentication:**
   - Test with valid OAuth token
   - Verify Claude Code identity headers sent
   - Verify system prompt injection

2. **API Key Authentication:**
   - Ensure existing flow still works
   - No Claude Code headers for API keys

3. **Profile Management:**
   - Add/remove profiles
   - Switch between profiles
   - Expiry handling

4. **Error Handling:**
   - Auth failure cooldown
   - Profile rotation on failure
   - Graceful degradation

## Configuration

**config/config.json additions:**
```json
{
  "auth": {
    "profiles_path": "data/auth-profiles.json",
    "default_profile": "anthropic:default",
    "cooldown_enabled": true,
    "cooldown_stages_ms": [60000, 300000, 1500000, 3600000]
  }
}
```

## Notes

- OAuth tokens use subscription quota, not API billing
- Some features unavailable with OAuth: 1M context window, certain betas
- OpenClaw automatically skips incompatible features for OAuth
- Token expiry is optional but recommended for lifecycle tracking
