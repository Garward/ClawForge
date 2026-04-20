#!/usr/bin/env python3
"""
Smart Context Pruner - Intelligently optimize conversation context to reduce token usage
while preserving relevance and workflow state.

Strategy:
1. Identify conversation segments and workflow states
2. Score segments by relevance to current task
3. Preserve high-value content, summarize/remove low-value
4. Maintain workflow continuity and context coherence
"""

import os
import sys
import json
import sqlite3
import re
from pathlib import Path
from typing import Dict, List, Tuple, Set
from datetime import datetime, timedelta

def get_project_root() -> Path:
    env = os.environ.get("CLAWFORGE_ROOT")
    if env:
        return Path(env)
    # This script lives at <root>/tools/smart_context_pruner.py
    return Path(__file__).resolve().parent.parent

def get_db_path():
    env = os.environ.get("CLAWFORGE_DB")
    if env:
        return env
    return str(get_project_root() / "data" / "workspace.db")

def estimate_tokens(text: str) -> int:
    """Rough token estimation: ~4 chars per token"""
    return len(text) // 4

def analyze_message_content(message: str) -> Dict[str, float]:
    """Analyze message content and assign relevance scores"""
    scores = {
        'code_content': 0.0,
        'tool_calls': 0.0,
        'error_handling': 0.0,
        'workflow_state': 0.0,
        'meta_discussion': 0.0,
        'project_context': 0.0
    }
    
    # Code content patterns
    code_patterns = [
        r'```\w+\n.*?\n```',  # Code blocks
        r'file_write|file_read|zig_test',  # File operations
        r'impl|struct|fn|let|const',  # Language keywords
        r'\.zig|\.py|\.js|\.rs|\.go',  # File extensions
    ]
    
    for pattern in code_patterns:
        if re.search(pattern, message, re.DOTALL | re.IGNORECASE):
            scores['code_content'] += 0.2
    
    # Tool call patterns
    if '<function_calls>' in message:
        scores['tool_calls'] = 0.9
        
    if '<invoke' in message:
        scores['tool_calls'] = 0.9
        
    # Error handling patterns
    error_patterns = [
        r'error|failed|exception|crash',
        r'fix|debug|troubleshoot|resolve',
        r'try again|retry|attempt',
    ]
    
    for pattern in error_patterns:
        if re.search(pattern, message, re.IGNORECASE):
            scores['error_handling'] += 0.15
            
    # Workflow state patterns
    workflow_patterns = [
        r'next|continue|then|after',
        r'implement|create|build|design',
        r'status|progress|complete',
        r'ready|finished|done',
    ]
    
    for pattern in workflow_patterns:
        if re.search(pattern, message, re.IGNORECASE):
            scores['workflow_state'] += 0.1
            
    # Project context patterns
    project_patterns = [
        r'ClawForge|project|system|architecture',
        r'requirements|goals|objectives',
        r'strategy|approach|plan',
    ]
    
    for pattern in project_patterns:
        if re.search(pattern, message, re.IGNORECASE):
            scores['project_context'] += 0.15
            
    # Meta discussion (lower value)
    meta_patterns = [
        r'great|awesome|perfect|excellent',
        r'thanks|appreciate|helpful',
        r'interesting|cool|nice',
    ]
    
    for pattern in meta_patterns:
        if re.search(pattern, message, re.IGNORECASE):
            scores['meta_discussion'] += 0.05
            
    return scores

def identify_conversation_segments(messages: List[Dict]) -> List[Dict]:
    """Identify conversation segments based on topic shifts and workflow boundaries"""
    segments = []
    current_segment = {
        'start_idx': 0,
        'end_idx': 0,
        'topic': 'general',
        'messages': [],
        'total_tokens': 0,
        'relevance_score': 0.0,
        'contains_tools': False,
        'contains_errors': False,
        'workflow_state': 'unknown'
    }
    
    topic_keywords = {
        'file_ops': ['file_write', 'file_read', 'file_diff', 'edit'],
        'build_system': ['zig_test', 'rebuild', 'compilation', 'build'],
        'token_optimization': ['token', 'compaction', 'summarization', 'optimization'],
        'tool_development': ['tool', 'register', 'implement', 'create'],
        'debugging': ['error', 'fix', 'debug', 'troubleshoot', 'crash'],
        'planning': ['design', 'strategy', 'approach', 'requirements', 'plan']
    }
    
    for i, msg in enumerate(messages):
        content = msg.get('content', '')
        scores = analyze_message_content(content)
        
        # Detect topic changes
        current_topics = set()
        for topic, keywords in topic_keywords.items():
            if any(keyword.lower() in content.lower() for keyword in keywords):
                current_topics.add(topic)
                
        # If significant topic change, start new segment
        if current_topics and current_segment['topic'] != 'general':
            prev_topics = {current_segment['topic']}
            if not current_topics.intersection(prev_topics) and len(current_segment['messages']) > 0:
                # Finalize current segment
                current_segment['end_idx'] = i - 1
                current_segment['relevance_score'] = sum(
                    sum(analyze_message_content(m.get('content', '')).values())
                    for m in current_segment['messages']
                ) / len(current_segment['messages'])
                segments.append(current_segment)
                
                # Start new segment
                current_segment = {
                    'start_idx': i,
                    'end_idx': i,
                    'topic': list(current_topics)[0] if current_topics else 'general',
                    'messages': [],
                    'total_tokens': 0,
                    'relevance_score': 0.0,
                    'contains_tools': False,
                    'contains_errors': False,
                    'workflow_state': 'unknown'
                }
        elif current_topics:
            current_segment['topic'] = list(current_topics)[0]
            
        # Add message to current segment
        current_segment['messages'].append(msg)
        current_segment['total_tokens'] += estimate_tokens(content)
        current_segment['contains_tools'] = current_segment['contains_tools'] or '<function_calls>' in content
        current_segment['contains_errors'] = current_segment['contains_errors'] or any(
            word in content.lower() for word in ['error', 'failed', 'exception', 'crash']
        )
        
    # Finalize last segment
    if current_segment['messages']:
        current_segment['end_idx'] = len(messages) - 1
        current_segment['relevance_score'] = sum(
            sum(analyze_message_content(m.get('content', '')).values())
            for m in current_segment['messages']
        ) / len(current_segment['messages'])
        segments.append(current_segment)
        
    return segments

def prioritize_segments(segments: List[Dict], current_context: str) -> List[Dict]:
    """Score and prioritize segments based on relevance to current context"""
    current_topics = set()
    if current_context:
        content_scores = analyze_message_content(current_context)
        # Extract primary topic from current context
        topic_weights = {
            'code_content': ['file_ops', 'build_system'],
            'tool_calls': ['tool_development'],
            'error_handling': ['debugging'],
            'workflow_state': ['planning'],
            'project_context': ['token_optimization']
        }
        
        for score_type, weight in content_scores.items():
            if weight > 0.3:  # Significant presence
                if score_type in topic_weights:
                    current_topics.update(topic_weights[score_type])
    
    for segment in segments:
        base_score = segment['relevance_score']
        
        # Boost segments matching current context
        if current_topics and segment['topic'] in current_topics:
            base_score *= 1.5
            
        # Boost segments with tools (high value)
        if segment['contains_tools']:
            base_score *= 1.3
            
        # Boost error resolution segments
        if segment['contains_errors']:
            base_score *= 1.2
            
        # Recent segments get higher priority
        segment_age = len(segments) - segments.index(segment)
        recency_boost = min(1.2, 1.0 + (10 - segment_age) * 0.02)
        base_score *= recency_boost
        
        # Penalize very long segments (might be verbose)
        if segment['total_tokens'] > 5000:
            base_score *= 0.8
            
        segment['final_score'] = base_score
        
    # Sort by final score descending
    segments.sort(key=lambda s: s['final_score'], reverse=True)
    return segments

def generate_pruning_recommendations(segments: List[Dict], target_reduction: float = 0.3) -> Dict:
    """Generate recommendations for context pruning"""
    total_tokens = sum(s['total_tokens'] for s in segments)
    target_tokens = int(total_tokens * (1 - target_reduction))
    
    recommendations = {
        'total_tokens': total_tokens,
        'target_tokens': target_tokens,
        'reduction_target': target_reduction,
        'actions': [],
        'preserved_segments': [],
        'summarized_segments': [],
        'removed_segments': []
    }
    
    current_tokens = 0
    
    for segment in segments:
        if current_tokens + segment['total_tokens'] <= target_tokens:
            # Preserve high-value segments
            recommendations['preserved_segments'].append(segment)
            recommendations['actions'].append({
                'action': 'preserve',
                'segment_topic': segment['topic'],
                'tokens': segment['total_tokens'],
                'reason': f"High relevance (score: {segment['final_score']:.2f})"
            })
            current_tokens += segment['total_tokens']
        elif segment['final_score'] > 0.5:
            # Summarize medium-value segments
            summary_tokens = max(100, segment['total_tokens'] // 4)
            if current_tokens + summary_tokens <= target_tokens:
                recommendations['summarized_segments'].append(segment)
                recommendations['actions'].append({
                    'action': 'summarize',
                    'segment_topic': segment['topic'],
                    'original_tokens': segment['total_tokens'],
                    'summary_tokens': summary_tokens,
                    'reason': f"Medium relevance (score: {segment['final_score']:.2f})"
                })
                current_tokens += summary_tokens
            else:
                recommendations['removed_segments'].append(segment)
                recommendations['actions'].append({
                    'action': 'remove',
                    'segment_topic': segment['topic'],
                    'tokens': segment['total_tokens'],
                    'reason': f"Low relevance + space constraints (score: {segment['final_score']:.2f})"
                })
        else:
            # Remove low-value segments
            recommendations['removed_segments'].append(segment)
            recommendations['actions'].append({
                'action': 'remove',
                'segment_topic': segment['topic'],
                'tokens': segment['total_tokens'],
                'reason': f"Low relevance (score: {segment['final_score']:.2f})"
            })
            
    final_tokens = sum(
        s['total_tokens'] for s in recommendations['preserved_segments']
    ) + sum(
        max(100, s['total_tokens'] // 4) for s in recommendations['summarized_segments']
    )
    
    recommendations['final_tokens'] = final_tokens
    recommendations['actual_reduction'] = (total_tokens - final_tokens) / total_tokens
    
    return recommendations

def analyze_current_session(session_id: str = None, limit: int = 50) -> Dict:
    """Analyze current session context for pruning opportunities"""
    try:
        with sqlite3.connect(get_db_path()) as conn:
            conn.row_factory = sqlite3.Row
            
            # Get recent messages
            if session_id:
                query = """
                SELECT id, role, content, created_at, session_id
                FROM messages 
                WHERE session_id = ?
                ORDER BY created_at DESC 
                LIMIT ?
                """
                cursor = conn.execute(query, (session_id, limit))
            else:
                query = """
                SELECT id, role, content, created_at, session_id
                FROM messages 
                ORDER BY created_at DESC 
                LIMIT ?
                """
                cursor = conn.execute(query, (limit,))
                
            messages = [dict(row) for row in cursor.fetchall()]
            
            if not messages:
                return {'error': 'No messages found'}
                
            # Reverse to chronological order
            messages.reverse()
            
            # Analyze segments
            segments = identify_conversation_segments(messages)
            prioritized_segments = prioritize_segments(segments, messages[-1]['content'] if messages else '')
            
            # Generate pruning recommendations
            recommendations = generate_pruning_recommendations(prioritized_segments)
            
            return {
                'session_analysis': {
                    'total_messages': len(messages),
                    'total_segments': len(segments),
                    'total_tokens': sum(s['total_tokens'] for s in segments),
                    'session_id': session_id or messages[0]['session_id'] if messages else 'unknown'
                },
                'segments': [{
                    'topic': s['topic'],
                    'message_count': len(s['messages']),
                    'tokens': s['total_tokens'],
                    'relevance_score': s['final_score'],
                    'contains_tools': s['contains_tools'],
                    'contains_errors': s['contains_errors']
                } for s in prioritized_segments],
                'recommendations': recommendations
            }
            
    except Exception as e:
        return {'error': f"Database analysis failed: {str(e)}"}

def main():
    if len(sys.argv) < 2:
        print(json.dumps({'error': 'Missing input parameters'}))
        sys.exit(1)
        
    try:
        params = json.loads(sys.argv[1])
        mode = params.get('mode', 'analyze')
        session_id = params.get('session_id')
        limit = params.get('limit', 50)
        target_reduction = params.get('target_reduction', 0.3)
        
        if mode == 'analyze':
            result = analyze_current_session(session_id, limit)
            print(json.dumps(result, indent=2))
            
        elif mode == 'suggest':
            analysis = analyze_current_session(session_id, limit)
            if 'error' not in analysis:
                # Add specific pruning suggestions
                suggestions = {
                    'analysis': analysis,
                    'actionable_steps': [
                        f"Archive {len(analysis['recommendations']['removed_segments'])} low-value segments",
                        f"Summarize {len(analysis['recommendations']['summarized_segments'])} medium-value segments",
                        f"Preserve {len(analysis['recommendations']['preserved_segments'])} high-value segments",
                        f"Expected token reduction: {analysis['recommendations']['actual_reduction']:.1%}"
                    ]
                }
                print(json.dumps(suggestions, indent=2))
            else:
                print(json.dumps(analysis))
                
        else:
            print(json.dumps({'error': f'Unknown mode: {mode}'}))
            
    except json.JSONDecodeError:
        print(json.dumps({'error': 'Invalid JSON input'}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({'error': f'Execution failed: {str(e)}'}))
        sys.exit(1)

if __name__ == '__main__':
    main()