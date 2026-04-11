/**
 * ClawForge Virtual Message Renderer
 * Implements Discord-style lazy loading for unlimited conversation history
 * 
 * Replaces the DOM-exploding loadSessionMessages() function with virtual scrolling
 */

class MessageVirtualizer {
    constructor(container, options = {}) {
        this.container = container;
        this.sessionId = null;
        this.totalCount = 0;
        this.messageCache = new Map(); // index -> message object
        this.renderedWindow = { start: 0, end: 0 };
        
        // Configuration
        this.messageHeight = options.messageHeight || 120; // estimated px per message
        this.windowSize = options.windowSize || 50;        // DOM nodes to keep rendered  
        this.bufferSize = options.bufferSize || 10;        // extra messages above/below viewport
        this.loadBatchSize = options.loadBatchSize || 100; // messages to load per batch
        
        // State
        this.isLoadingHistory = false;
        this.isScrollingToBottom = false;
        this.lastScrollTop = 0;
        
        this.setupVirtualContainer();
        this.setupScrollHandler();
        
        console.log('[MessageVirtualizer] Initialized with container:', container);
    }
    
    setupVirtualContainer() {
        this.container.innerHTML = `
            <div id="spacer-top" style="height: 0px; background: transparent;"></div>
            <div id="message-window"></div>
            <div id="spacer-bottom" style="height: 0px; background: transparent;"></div>
            <div id="load-indicator" style="display: none; padding: 12px; text-align: center; color: var(--text-muted); font-size: 13px;">
                <div class="spinner" style="display: inline-block; margin-right: 8px;"></div>
                Loading messages...
            </div>
        `;
        
        this.topSpacer = this.container.querySelector('#spacer-top');
        this.messageWindow = this.container.querySelector('#message-window');
        this.bottomSpacer = this.container.querySelector('#spacer-bottom');
        this.loadIndicator = this.container.querySelector('#load-indicator');
        
        console.log('[MessageVirtualizer] Virtual container setup complete');
    }
    
    setupScrollHandler() {
        // Throttled scroll handler for smooth performance
        let scrollTimeout;
        this.container.addEventListener('scroll', () => {
            if (scrollTimeout) clearTimeout(scrollTimeout);
            scrollTimeout = setTimeout(() => this.onScroll(), 16); // ~60fps
        });
        
        // Passive scroll monitoring for loading triggers
        this.container.addEventListener('scroll', () => {
            this.checkLoadTriggers();
        }, { passive: true });
        
        console.log('[MessageVirtualizer] Scroll handlers attached');
    }
    
    async loadSession(sessionId) {
        console.log('[MessageVirtualizer] Loading session:', sessionId);
        
        this.sessionId = sessionId;
        this.messageCache.clear();
        this.totalCount = 0;
        
        if (!sessionId) {
            this.showEmptyState();
            return;
        }
        
        this.showLoadIndicator(true);
        
        try {
            // Load recent messages (bottom of conversation)
            const response = await this.fetchMessages({
                limit: this.windowSize,
                order: 'desc' // Get most recent first
            });
            
            if (!response.messages || response.messages.length === 0) {
                this.showEmptyState();
                return;
            }
            
            this.totalCount = response.pagination.total_count;
            
            // Cache recent messages in chronological order
            const recentMessages = response.messages.reverse(); // Now oldest->newest
            const startIndex = Math.max(0, this.totalCount - recentMessages.length);
            
            recentMessages.forEach((msg, i) => {
                this.messageCache.set(startIndex + i, msg);
            });
            
            console.log('[MessageVirtualizer] Cached', recentMessages.length, 'recent messages');
            console.log('[MessageVirtualizer] Total messages in conversation:', this.totalCount);
            
            // Render window at the bottom and scroll to bottom
            await this.renderWindow(startIndex, this.totalCount);
            this.scrollToBottom();
            
        } catch (error) {
            console.error('[MessageVirtualizer] Failed to load session:', error);
            this.showErrorState('Failed to load conversation: ' + error.message);
        } finally {
            this.showLoadIndicator(false);
        }
    }
    
    async fetchMessages(options = {}) {
        const params = new URLSearchParams({
            session_id: this.sessionId,
            limit: options.limit || 50,
            offset: options.offset || 0,
            order: options.order || 'asc'
        });
        
        const url = `/api/messages?${params}`;
        console.log('[MessageVirtualizer] Fetching:', url);
        
        const response = await fetch(url);
        if (!response.ok) {
            throw new Error(`API request failed: ${response.status}`);
        }
        
        const data = await response.json();
        console.log('[MessageVirtualizer] Fetched', data.messages?.length || 0, 'messages');
        
        return data;
    }
    
    async renderWindow(start, end) {
        console.log('[MessageVirtualizer] Rendering window:', start, 'to', end);
        
        // Clamp to valid bounds
        start = Math.max(0, start);
        end = Math.min(this.totalCount, end);
        
        if (start >= end) return;
        
        // Load any missing messages in this range
        await this.ensureMessagesLoaded(start, end);
        
        // Clear current window
        this.messageWindow.innerHTML = '';
        
        // Render cached messages
        let renderedCount = 0;
        for (let i = start; i < end; i++) {
            const msg = this.messageCache.get(i);
            if (msg) {
                const msgEl = this.createMessageElement(msg);
                this.messageWindow.appendChild(msgEl);
                renderedCount++;
            }
        }
        
        // Update spacers to maintain scroll position
        this.updateSpacers(start, end);
        
        // Update window tracking
        this.renderedWindow = { start, end };
        
        console.log('[MessageVirtualizer] Rendered', renderedCount, 'messages in DOM');
    }
    
    updateSpacers(start, end) {
        const topHeight = start * this.messageHeight;
        const bottomHeight = (this.totalCount - end) * this.messageHeight;
        
        this.topSpacer.style.height = topHeight + 'px';
        this.bottomSpacer.style.height = bottomHeight + 'px';
        
        console.log('[MessageVirtualizer] Spacers: top=' + topHeight + 'px, bottom=' + bottomHeight + 'px');
    }
    
    async ensureMessagesLoaded(start, end) {
        const toLoad = [];
        
        // Find missing messages in the range
        for (let i = start; i < end; i++) {
            if (!this.messageCache.has(i)) {
                toLoad.push(i);
            }
        }
        
        if (toLoad.length === 0) return;
        
        console.log('[MessageVirtualizer] Need to load', toLoad.length, 'missing messages');
        
        // Group consecutive missing indices into batch ranges
        const ranges = this.groupConsecutive(toLoad);
        
        for (const range of ranges) {
            await this.loadMessageRange(range.start, range.end);
        }
    }
    
    groupConsecutive(indices) {
        if (indices.length === 0) return [];
        
        indices.sort((a, b) => a - b);
        const ranges = [];
        let start = indices[0];
        let end = indices[0];
        
        for (let i = 1; i < indices.length; i++) {
            if (indices[i] === end + 1) {
                end = indices[i];
            } else {
                ranges.push({ start, end: end + 1 });
                start = indices[i];
                end = indices[i];
            }
        }
        ranges.push({ start, end: end + 1 });
        
        return ranges;
    }
    
    async loadMessageRange(start, end) {
        const count = end - start;
        
        this.showLoadIndicator(true);
        
        try {
            const response = await this.fetchMessages({
                offset: start,
                limit: count,
                order: 'asc'
            });
            
            // Cache loaded messages
            response.messages.forEach((msg, i) => {
                this.messageCache.set(start + i, msg);
            });
            
            console.log('[MessageVirtualizer] Loaded range', start, 'to', end, '- cached', response.messages.length, 'messages');
            
        } catch (error) {
            console.error('[MessageVirtualizer] Failed to load range:', error);
        } finally {
            this.showLoadIndicator(false);
        }
    }
    
    onScroll() {
        const scrollTop = this.container.scrollTop;
        const viewHeight = this.container.clientHeight;
        
        // Calculate which message indices should be visible
        const visibleStart = Math.floor(scrollTop / this.messageHeight);
        const visibleEnd = Math.ceil((scrollTop + viewHeight) / this.messageHeight);
        
        // Add buffer around visible area
        const windowStart = Math.max(0, visibleStart - this.bufferSize);
        const windowEnd = Math.min(this.totalCount, visibleEnd + this.bufferSize);
        
        // Check if we need to re-render
        const { start: currentStart, end: currentEnd } = this.renderedWindow;
        const startDelta = Math.abs(windowStart - currentStart);
        const endDelta = Math.abs(windowEnd - currentEnd);
        
        // Re-render if window moved significantly
        if (startDelta > this.windowSize / 4 || endDelta > this.windowSize / 4) {
            console.log('[MessageVirtualizer] Window moved significantly, re-rendering');
            this.renderWindow(windowStart, windowEnd);
        }
        
        this.lastScrollTop = scrollTop;
    }
    
    checkLoadTriggers() {
        const scrollTop = this.container.scrollTop;
        
        // Load more history if scrolled near top
        if (scrollTop < 200 && !this.isLoadingHistory && this.messageCache.size < this.totalCount) {
            this.loadMoreHistory();
        }
    }
    
    async loadMoreHistory() {
        if (this.isLoadingHistory) return;
        
        console.log('[MessageVirtualizer] Loading more history...');
        this.isLoadingHistory = true;
        
        try {
            const cachedIndices = Array.from(this.messageCache.keys()).sort((a, b) => a - b);
            const oldestCached = cachedIndices[0] || this.totalCount;
            const toLoad = Math.min(this.loadBatchSize, oldestCached);
            
            if (toLoad <= 0) {
                console.log('[MessageVirtualizer] No more history to load');
                return;
            }
            
            const loadStart = oldestCached - toLoad;
            await this.loadMessageRange(loadStart, oldestCached);
            
            // Adjust scroll position to maintain user's view
            const addedHeight = toLoad * this.messageHeight;
            this.container.scrollTop += addedHeight;
            
            console.log('[MessageVirtualizer] Loaded', toLoad, 'historical messages, adjusted scroll by', addedHeight);
            
        } catch (error) {
            console.error('[MessageVirtualizer] Failed to load history:', error);
        } finally {
            this.isLoadingHistory = false;
        }
    }
    
    createMessageElement(msg) {
        // Use the existing appendMessage logic but return element instead of appending
        const el = document.createElement('div');
        el.className = `msg msg-${msg.role}`;
        
        const roleLabel = document.createElement('div');
        roleLabel.className = 'msg-role';
        roleLabel.textContent = msg.role === 'user' ? 'You' : 'ClawForge';
        el.appendChild(roleLabel);
        
        const contentEl = document.createElement('div');
        contentEl.className = 'msg-content';
        
        if (msg.role === 'assistant') {
            // Parse tool calls if present (using existing parseToolCallsFromContent logic)
            const parsed = this.parseToolCallsFromContent(msg.content || '');
            
            // Render tool indicators
            parsed.tools.forEach(tool => {
                const tc = this.createToolCallElement(tool);
                contentEl.appendChild(tc);
            });
            
            if (parsed.cleanContent) {
                const textEl = document.createElement('div');
                textEl.innerHTML = this.renderMarkdown(parsed.cleanContent);
                contentEl.appendChild(textEl);
            }
        } else {
            contentEl.innerHTML = this.escapeHtml(msg.content).replace(/\n/g, '<br>');
        }
        
        el.appendChild(contentEl);
        
        // Add token info if available
        if (msg.input_tokens || msg.output_tokens) {
            const footer = document.createElement('div');
            footer.className = 'msg-tokens';
            footer.innerHTML = 
                `<span>${this.formatTokens(msg.input_tokens || 0)} in</span>` +
                `<span>${this.formatTokens(msg.output_tokens || 0)} out</span>`;
            if (msg.model_used) {
                footer.innerHTML += `<span class="msg-model">${this.escapeHtml(msg.model_used)}</span>`;
            }
            el.appendChild(footer);
        }
        
        return el;
    }
    
    // Helper functions (assuming these exist in the global scope, otherwise implement)
    parseToolCallsFromContent(content) {
        // Use existing implementation from main app
        if (typeof window.parseToolCallsFromContent === 'function') {
            return window.parseToolCallsFromContent(content);
        }
        // Fallback
        return { cleanContent: content, tools: [] };
    }
    
    renderMarkdown(text) {
        if (typeof window.renderMarkdown === 'function') {
            return window.renderMarkdown(text);
        }
        // Fallback
        return this.escapeHtml(text).replace(/\n/g, '<br>');
    }
    
    createToolCallElement(tool) {
        const tc = document.createElement('div');
        tc.className = 'tool-call';
        // Simplified tool call rendering
        tc.innerHTML = `
            <div class="tool-call-header">
                <span class="tool-icon">🔧</span>
                <span class="tool-name">${this.escapeHtml(tool.name)}</span>
                <span class="tool-status ${tool.error ? 'error' : 'done'}">
                    ${tool.error ? 'failed' : 'done'}
                </span>
            </div>
        `;
        return tc;
    }
    
    escapeHtml(str) {
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }
    
    formatTokens(n) {
        if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
        if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
        return String(n || 0);
    }
    
    scrollToBottom() {
        this.isScrollingToBottom = true;
        this.container.scrollTop = this.container.scrollHeight;
        setTimeout(() => { this.isScrollingToBottom = false; }, 100);
    }
    
    showLoadIndicator(show) {
        this.loadIndicator.style.display = show ? 'block' : 'none';
    }
    
    showEmptyState() {
        this.container.innerHTML = `
            <div id="empty-state" style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; color: var(--text-dim); gap: 12px;">
                <div class="forge-icon" style="font-size: 48px; opacity: 0.3;">⚒</div>
                <p style="font-size: 14px; max-width: 300px; text-align: center; line-height: 1.6;">
                    No messages yet. Type below to begin forging.
                </p>
            </div>
        `;
    }
    
    showErrorState(message) {
        this.container.innerHTML = `
            <div style="padding: 24px; text-align: center; color: var(--error);">
                <h3>Failed to Load Conversation</h3>
                <p style="margin-top: 8px; color: var(--text-muted);">${this.escapeHtml(message)}</p>
                <button onclick="location.reload()" style="margin-top: 16px; padding: 8px 16px; background: var(--accent-primary); color: white; border: none; border-radius: 4px; cursor: pointer;">
                    Reload Page
                </button>
            </div>
        `;
    }
    
    // Public API for adding new messages (for live chat)
    appendNewMessage(message) {
        // Add to cache at end
        this.messageCache.set(this.totalCount, message);
        this.totalCount++;
        
        // If we're at the bottom, extend the rendered window
        if (this.renderedWindow.end === this.totalCount - 1) {
            this.renderWindow(this.renderedWindow.start, this.totalCount);
            this.scrollToBottom();
        }
    }
    
    // Public API for getting current state
    getState() {
        return {
            sessionId: this.sessionId,
            totalCount: this.totalCount,
            cachedCount: this.messageCache.size,
            renderedWindow: this.renderedWindow,
            isLoading: this.isLoadingHistory
        };
    }
}

// Usage example:
//
// // Initialize 
// const messageVirtualizer = new MessageVirtualizer(document.getElementById('messages'));
//
// // Replace existing loadSessionMessages function
// async function loadSessionMessages(sessionId) {
//     await messageVirtualizer.loadSession(sessionId);
// }
//
// // Add new message from chat
// function addNewMessage(message) {
//     messageVirtualizer.appendNewMessage(message);
// }