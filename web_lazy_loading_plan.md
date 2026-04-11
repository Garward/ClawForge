# ClawForge Web UI - Lazy Loading Implementation Plan

## 🎯 **Goal: Discord-Style Lazy Loading**
Transform from "load all messages" to "load visible + buffer" architecture.

## 📊 **Current Problem**
```javascript
// BAD: loadSessionMessages() loads EVERYTHING
const messages = await apiGet('/api/messages?session_id=' + sessionId);
messages.forEach(msg => appendMessage(...));  // 1000+ DOM nodes!
```

## ✅ **Solution: Virtual Message Rendering**

### 1. **Message Window Architecture**
```javascript
const WINDOW_SIZE = 50;        // Messages to keep in DOM
const BUFFER_SIZE = 10;        // Extra messages above/below viewport
const MESSAGE_HEIGHT_EST = 120; // Pixels per message (estimated)

class MessageWindow {
    constructor(container) {
        this.container = container;
        this.totalMessages = 0;
        this.startIndex = 0;
        this.endIndex = 0;
        this.messages = [];        // Full message cache
        this.renderedNodes = [];   // DOM nodes currently in viewport
        this.scrollTop = 0;
    }
}
```

### 2. **API Changes Needed**
Add pagination to `/api/messages`:
```javascript
// NEW API: Paginated message loading
GET /api/messages?session_id={id}&limit=50&offset=100&order=desc

// Response:
{
    "messages": [...],
    "total_count": 1247,
    "has_more": true
}
```

### 3. **Virtual Scroll Container**
Replace `#messages` div with virtual scroll structure:
```html
<div id="messages-viewport" style="height: 100%; overflow-y: auto;">
    <!-- Spacer for messages before viewport -->
    <div id="spacer-top" style="height: 0px;"></div>
    
    <!-- Actual rendered messages (50 max) -->
    <div id="messages-window"></div>
    
    <!-- Spacer for messages after viewport -->
    <div id="spacer-bottom" style="height: 0px;"></div>
    
    <!-- Loading indicator -->
    <div id="load-more-indicator" style="display: none;">Loading...</div>
</div>
```

### 4. **Scroll Event Handler**
```javascript
function onScroll(e) {
    const viewport = e.target;
    const scrollTop = viewport.scrollTop;
    const viewHeight = viewport.clientHeight;
    
    // Calculate which messages should be visible
    const startIdx = Math.floor(scrollTop / MESSAGE_HEIGHT_EST) - BUFFER_SIZE;
    const endIdx = Math.ceil((scrollTop + viewHeight) / MESSAGE_HEIGHT_EST) + BUFFER_SIZE;
    
    // Only re-render if window changed significantly
    if (Math.abs(startIdx - window.startIndex) > 10) {
        renderMessageWindow(Math.max(0, startIdx), Math.min(totalMessages, endIdx));
    }
    
    // Load more if scrolling near top (for history)
    if (scrollTop < 200 && !isLoadingHistory) {
        loadMoreHistory();
    }
}
```

### 5. **Message Loading Strategy**
```javascript
async function loadSessionMessages(sessionId) {
    // 1. Get total count + recent messages
    const recent = await apiGet(`/api/messages?session_id=${sessionId}&limit=50&order=desc`);
    
    // 2. Setup virtual scroll
    totalMessages = recent.total_count;
    messages = recent.messages.reverse(); // [oldest...newest]
    
    // 3. Render bottom window (most recent)
    const startIdx = Math.max(0, totalMessages - WINDOW_SIZE);
    renderMessageWindow(startIdx, totalMessages);
    
    // 4. Scroll to bottom
    scrollToBottom();
}

async function loadMoreHistory() {
    if (messages.length >= totalMessages) return; // All loaded
    
    isLoadingHistory = true;
    const needed = Math.min(100, totalMessages - messages.length);
    const offset = totalMessages - messages.length - needed;
    
    const older = await apiGet(`/api/messages?session_id=${sessionId}&limit=${needed}&offset=${offset}`);
    
    // Prepend to cache
    messages = [...older.messages, ...messages];
    
    // Adjust scroll position to maintain user's view
    const addedHeight = older.messages.length * MESSAGE_HEIGHT_EST;
    viewport.scrollTop += addedHeight;
    
    isLoadingHistory = false;
}
```

### 6. **Optimized Rendering**
```javascript
function renderMessageWindow(start, end) {
    const window = document.getElementById('messages-window');
    const topSpacer = document.getElementById('spacer-top');
    const bottomSpacer = document.getElementById('spacer-bottom');
    
    // Clear current window
    window.innerHTML = '';
    
    // Render only visible messages
    for (let i = start; i < end; i++) {
        if (messages[i]) {
            const msgEl = createMessageElement(messages[i]);
            window.appendChild(msgEl);
        }
    }
    
    // Update spacers to maintain scroll position
    topSpacer.style.height = (start * MESSAGE_HEIGHT_EST) + 'px';
    bottomSpacer.style.height = ((totalMessages - end) * MESSAGE_HEIGHT_EST) + 'px';
    
    // Update window bounds
    startIndex = start;
    endIndex = end;
}
```

## 🎯 **Implementation Steps**

### Phase 1: Backend API Updates
1. ✅ Add pagination to `/api/messages` endpoint
2. ✅ Add message count to session metadata
3. ✅ Ensure consistent ordering (by timestamp)

### Phase 2: Frontend Virtual Scrolling
1. ✅ Replace `loadSessionMessages()` with windowed loading
2. ✅ Implement virtual scroll container
3. ✅ Add scroll event handling for window management
4. ✅ Implement history loading on scroll-to-top

### Phase 3: Performance Optimizations  
1. ✅ Message height estimation/measurement
2. ✅ Throttled scroll handlers (60fps max)
3. ✅ DOM node recycling for repeated message types
4. ✅ Image lazy loading within messages

### Phase 4: Polish
1. ✅ Smooth scroll transitions
2. ✅ Loading states and indicators
3. ✅ Keyboard navigation (Page Up/Down)
4. ✅ Search highlighting within viewport

## 📈 **Expected Performance Gains**

### Before (Current):
- **1000 messages** = 1000 DOM nodes = 💀 Browser death
- **Initial load**: 5-10 seconds for large conversations
- **Mobile**: Crashes on 200+ messages

### After (Lazy Loading):
- **1000 messages** = 50 DOM nodes = ⚡ Smooth as Discord
- **Initial load**: <500ms regardless of history length  
- **Mobile**: Handles unlimited history gracefully

## 🧪 **Testing Strategy**
1. Create test session with 1000+ messages
2. Measure DOM node count (should stay ~50-70)
3. Test scroll performance on mobile device
4. Verify no message loss during window transitions
5. Test history loading at conversation start

## 🎯 **Success Metrics**
- ✅ **DOM nodes**: Always <100 regardless of conversation length
- ✅ **Initial load**: <1 second for any conversation size
- ✅ **Scroll performance**: Smooth 60fps on mid-range mobile
- ✅ **Memory usage**: Constant regardless of history length
- ✅ **UX**: Feels like Discord/WhatsApp/Slack

This will transform ClawForge from "amateur hour" to "production ready" UI! 🚀