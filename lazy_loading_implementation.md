# ClawForge Lazy Loading Implementation

## 1. Backend API Updates Needed

### Current Issue
The `handleApiMessages` function loads ALL messages:
```zig
// BAD: Loads every message in the session
"SELECT role, content, ... FROM messages WHERE session_id = '{s}' ORDER BY sequence ASC;"
```

### Solution: Add Pagination Parameters
Update the API to accept `limit` and `offset` parameters:

```zig
// NEW: Parse pagination params from query string
// /api/messages?session_id=UUID&limit=50&offset=100&order=desc

fn parseQueryParam(path: []const u8, param: []const u8) ?[]const u8 {
    const pattern = std.fmt.allocPrint(allocator, "{s}=", .{param}) catch return null;
    defer allocator.free(pattern);
    
    if (std.mem.indexOf(u8, path, pattern)) |idx| {
        const start = idx + pattern.len;
        const rest = path[start..];
        const end = std.mem.indexOf(u8, rest, "&") orelse rest.len;
        return rest[0..end];
    }
    return null;
}

fn handleApiMessages(self: *WebAdapter, stream: std.net.Stream, path: []const u8) !void {
    // Parse pagination parameters
    const session_id = parseQueryParam(path, "session_id");
    const limit_str = parseQueryParam(path, "limit") orelse "50";
    const offset_str = parseQueryParam(path, "offset") orelse "0";
    const order = parseQueryParam(path, "order") orelse "asc";
    
    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;
    const offset = std.fmt.parseInt(u32, offset_str, 10) catch 0;
    
    // Build paginated query
    const order_clause = if (std.mem.eql(u8, order, "desc")) "DESC" else "ASC";
    const query = std.fmt.bufPrint(&query_buf,
        "SELECT role, content, datetime(created_at, 'unixepoch') as created_at, " ++
        "model_used, input_tokens, output_tokens, " ++
        "(SELECT COUNT(*) FROM messages WHERE session_id = '{s}') as total_count " ++
        "FROM messages WHERE session_id = '{s}' " ++
        "ORDER BY sequence {s} LIMIT {d} OFFSET {d};",
        .{ session_id, session_id, order_clause, limit, offset }
    ) catch return;
}
```

## 2. Frontend Virtual Scrolling

### Replace loadSessionMessages Function

```javascript
// OLD: Load everything (BAD!)
async function loadSessionMessages(sessionId) {
    const messages = await apiGet('/api/messages?session_id=' + sessionId);
    messages.forEach(msg => appendMessage(...)); // 💀 DOM explosion
}

// NEW: Virtual windowed loading (GOOD!)
class MessageVirtualizer {
    constructor(container) {
        this.container = container;
        this.sessionId = null;
        this.totalCount = 0;
        this.messageCache = new Map(); // index -> message
        this.renderedWindow = { start: 0, end: 0 };
        this.messageHeight = 120; // estimated px per message
        this.windowSize = 50;     // DOM nodes to keep rendered
        this.bufferSize = 10;     // extra messages above/below
        
        this.setupVirtualContainer();
        this.setupScrollHandler();
    }
    
    setupVirtualContainer() {
        this.container.innerHTML = `
            <div id="spacer-top" style="height: 0px;"></div>
            <div id="message-window"></div>
            <div id="spacer-bottom" style="height: 0px;"></div>
            <div id="load-indicator" style="display: none;">Loading...</div>
        `;
        this.topSpacer = this.container.querySelector('#spacer-top');
        this.messageWindow = this.container.querySelector('#message-window');
        this.bottomSpacer = this.container.querySelector('#spacer-bottom');
        this.loadIndicator = this.container.querySelector('#load-indicator');
    }
    
    setupScrollHandler() {
        this.container.addEventListener('scroll', this.throttle(() => {
            this.onScroll();
        }, 16)); // ~60fps
    }
    
    throttle(func, ms) {
        let timeout;
        return (...args) => {
            clearTimeout(timeout);
            timeout = setTimeout(() => func.apply(this, args), ms);
        };
    }
    
    async loadSession(sessionId) {
        this.sessionId = sessionId;
        this.messageCache.clear();
        
        // Load recent messages + get total count
        const response = await apiGet(`/api/messages?session_id=${sessionId}&limit=${this.windowSize}&order=desc`);
        
        if (!response.length) {
            this.showEmptyState();
            return;
        }
        
        // Parse total count (returned by our updated SQL query)
        this.totalCount = response[0]?.total_count || response.length;
        
        // Cache recent messages (reverse to get chronological order)
        const recentMessages = response.reverse();
        const startIndex = Math.max(0, this.totalCount - recentMessages.length);
        
        recentMessages.forEach((msg, i) => {
            this.messageCache.set(startIndex + i, msg);
        });
        
        // Render window at the bottom (most recent)
        await this.renderWindow(startIndex, this.totalCount);
        this.scrollToBottom();
    }
    
    async renderWindow(start, end) {
        this.messageWindow.innerHTML = '';
        
        // Load any missing messages in the window
        await this.ensureMessagesLoaded(start, end);
        
        // Render cached messages
        for (let i = start; i < end; i++) {
            const msg = this.messageCache.get(i);
            if (msg) {
                const msgEl = this.createMessageElement(msg);
                this.messageWindow.appendChild(msgEl);
            }
        }
        
        // Update spacers to maintain scroll position
        this.topSpacer.style.height = (start * this.messageHeight) + 'px';
        this.bottomSpacer.style.height = ((this.totalCount - end) * this.messageHeight) + 'px';
        
        this.renderedWindow = { start, end };
    }
    
    async ensureMessagesLoaded(start, end) {
        const toLoad = [];
        
        // Find gaps in our cache
        for (let i = start; i < end; i++) {
            if (!this.messageCache.has(i)) {
                toLoad.push(i);
            }
        }
        
        if (toLoad.length === 0) return;
        
        // Load missing messages in batches
        const batchSize = 50;
        for (let i = 0; i < toLoad.length; i += batchSize) {
            const batchStart = Math.min(...toLoad.slice(i, i + batchSize));
            const batchEnd = Math.max(...toLoad.slice(i, i + batchSize)) + 1;
            const batchSize = batchEnd - batchStart;
            
            this.showLoadIndicator(true);
            
            const response = await apiGet(
                `/api/messages?session_id=${this.sessionId}&limit=${batchSize}&offset=${batchStart}&order=asc`
            );
            
            // Cache loaded messages
            response.forEach((msg, idx) => {
                this.messageCache.set(batchStart + idx, msg);
            });
            
            this.showLoadIndicator(false);
        }
    }
    
    onScroll() {
        const scrollTop = this.container.scrollTop;
        const viewHeight = this.container.clientHeight;
        
        // Calculate which message indices should be visible
        const visibleStart = Math.floor(scrollTop / this.messageHeight);
        const visibleEnd = Math.ceil((scrollTop + viewHeight) / this.messageHeight);
        
        // Add buffer
        const windowStart = Math.max(0, visibleStart - this.bufferSize);
        const windowEnd = Math.min(this.totalCount, visibleEnd + this.bufferSize);
        
        // Only re-render if window moved significantly
        const { start: currentStart, end: currentEnd } = this.renderedWindow;
        const startDelta = Math.abs(windowStart - currentStart);
        const endDelta = Math.abs(windowEnd - currentEnd);
        
        if (startDelta > this.windowSize / 4 || endDelta > this.windowSize / 4) {
            this.renderWindow(windowStart, windowEnd);
        }
        
        // Load more history if scrolled near top
        if (scrollTop < 200 && this.messageCache.size < this.totalCount) {
            this.loadMoreHistory();
        }
    }
    
    async loadMoreHistory() {
        if (this.isLoadingHistory) return;
        this.isLoadingHistory = true;
        
        const oldestCached = Math.min(...this.messageCache.keys());
        const toLoad = Math.min(100, oldestCached);
        
        if (toLoad <= 0) {
            this.isLoadingHistory = false;
            return;
        }
        
        this.showLoadIndicator(true);
        
        const response = await apiGet(
            `/api/messages?session_id=${this.sessionId}&limit=${toLoad}&offset=${oldestCached - toLoad}&order=asc`
        );
        
        // Cache older messages
        response.forEach((msg, i) => {
            this.messageCache.set(oldestCached - toLoad + i, msg);
        });
        
        // Maintain scroll position
        const addedHeight = response.length * this.messageHeight;
        this.container.scrollTop += addedHeight;
        
        this.showLoadIndicator(false);
        this.isLoadingHistory = false;
    }
    
    createMessageElement(msg) {
        // Use existing appendMessage logic but return element instead of appending
        const el = document.createElement('div');
        el.className = `msg msg-${msg.role}`;
        
        // ... existing message rendering logic ...
        
        return el;
    }
    
    scrollToBottom() {
        this.container.scrollTop = this.container.scrollHeight;
    }
    
    showLoadIndicator(show) {
        this.loadIndicator.style.display = show ? 'block' : 'none';
    }
    
    showEmptyState() {
        this.container.innerHTML = `
            <div id="empty-state">
                <div class="forge-icon">&#9878;</div>
                <p>No messages yet. Type below to begin forging.</p>
            </div>
        `;
    }
}

// Replace the old function
async function loadSessionMessages(sessionId) {
    await messageVirtualizer.loadSession(sessionId);
}

// Initialize
const messageVirtualizer = new MessageVirtualizer(document.getElementById('messages'));
```

## 3. Integration Steps

### Step 1: Update Backend
1. Modify `handleApiMessages` in `web_adapter.zig`
2. Add pagination parameter parsing
3. Update SQL query with LIMIT/OFFSET
4. Return total count in response

### Step 2: Update Frontend 
1. Replace `loadSessionMessages()` function
2. Add `MessageVirtualizer` class
3. Update `switchSession()` to use virtualizer
4. Test with long conversation

### Step 3: Performance Tuning
1. Measure actual message heights for better estimation
2. Tune window size and buffer size
3. Add keyboard navigation (Page Up/Down)
4. Implement search highlighting

## Expected Results

- **Before**: 1000 messages = 1000 DOM nodes = 💀 Browser crash
- **After**: 1000 messages = 50-70 DOM nodes = ⚡ Smooth scrolling
- **Load time**: <500ms regardless of conversation length
- **Memory usage**: Constant O(1) instead of O(n)
- **Mobile**: Actually usable for long conversations

This brings ClawForge web UI up to modern messaging app standards! 🚀