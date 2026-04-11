#!/usr/bin/env python3
"""
Web Research Tool for ClawForge
Provides comprehensive web search capabilities including:
- DuckDuckGo search (privacy-focused, no API key needed)
- Wikipedia lookups  
- News aggregation
- Academic paper search
- Documentation finder
"""

import json
import sys
import requests
import time
from urllib.parse import quote, urljoin
from typing import Dict, List, Optional, Any
from dataclasses import dataclass
import re
from bs4 import BeautifulSoup

@dataclass
class SearchResult:
    title: str
    url: str
    snippet: str
    source: str = "web"
    date: Optional[str] = None
    relevance_score: float = 0.0

class WebResearcher:
    def __init__(self):
        self.session = requests.Session()
        self.session.headers.update({
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        })
        
    def search_duckduckgo(self, query: str, max_results: int = 10) -> List[SearchResult]:
        """Search using DuckDuckGo instant answer API and web results"""
        results = []
        
        try:
            # DuckDuckGo instant answers
            instant_url = f"https://api.duckduckgo.com/?q={quote(query)}&format=json&no_html=1"
            response = self.session.get(instant_url, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                
                # Abstract answer
                if data.get('Abstract'):
                    results.append(SearchResult(
                        title=data.get('Heading', 'DuckDuckGo Answer'),
                        url=data.get('AbstractURL', ''),
                        snippet=data['Abstract'][:300],
                        source='instant_answer',
                        relevance_score=0.9
                    ))
                
                # Related topics
                for topic in data.get('RelatedTopics', [])[:3]:
                    if isinstance(topic, dict) and topic.get('Text'):
                        results.append(SearchResult(
                            title=topic.get('FirstURL', '').split('/')[-1].replace('_', ' '),
                            url=topic.get('FirstURL', ''),
                            snippet=topic['Text'][:200],
                            source='related_topic',
                            relevance_score=0.7
                        ))
            
            # If we need more results, try web search
            if len(results) < max_results:
                web_results = self._search_duckduckgo_web(query, max_results - len(results))
                results.extend(web_results)
                
        except Exception as e:
            print(f"DuckDuckGo search error: {e}", file=sys.stderr)
            
        return results[:max_results]
    
    def _search_duckduckgo_web(self, query: str, max_results: int) -> List[SearchResult]:
        """Search DuckDuckGo web results (HTML scraping)"""
        results = []
        
        try:
            search_url = f"https://html.duckduckgo.com/html/?q={quote(query)}"
            response = self.session.get(search_url, timeout=15)
            
            if response.status_code == 200:
                soup = BeautifulSoup(response.content, 'html.parser')
                
                # Find search results
                for result_div in soup.find_all('div', class_='result')[:max_results]:
                    title_elem = result_div.find('a', class_='result__a')
                    snippet_elem = result_div.find('a', class_='result__snippet')
                    
                    if title_elem:
                        title = title_elem.get_text(strip=True)
                        url = title_elem.get('href', '')
                        snippet = snippet_elem.get_text(strip=True) if snippet_elem else ""
                        
                        results.append(SearchResult(
                            title=title,
                            url=url,
                            snippet=snippet[:300],
                            source='web_search',
                            relevance_score=0.8
                        ))
                        
        except Exception as e:
            print(f"Web search error: {e}", file=sys.stderr)
            
        return results
    
    def search_wikipedia(self, query: str, max_results: int = 5) -> List[SearchResult]:
        """Search Wikipedia articles"""
        results = []
        
        try:
            # Search API
            search_url = "https://en.wikipedia.org/api/rest_v1/page/summary/" + quote(query.replace(' ', '_'))
            response = self.session.get(search_url, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                if data.get('extract'):
                    results.append(SearchResult(
                        title=data.get('title', 'Wikipedia Article'),
                        url=data.get('content_urls', {}).get('desktop', {}).get('page', ''),
                        snippet=data['extract'][:400],
                        source='wikipedia',
                        relevance_score=0.85
                    ))
            
            # If no direct match, try search API
            if not results:
                search_api = f"https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch={quote(query)}&format=json&srlimit={max_results}"
                response = self.session.get(search_api, timeout=10)
                
                if response.status_code == 200:
                    data = response.json()
                    for page in data.get('query', {}).get('search', []):
                        title = page.get('title', '')
                        snippet = page.get('snippet', '').replace('<span class="searchmatch">', '').replace('</span>', '')
                        url = f"https://en.wikipedia.org/wiki/{quote(title.replace(' ', '_'))}"
                        
                        results.append(SearchResult(
                            title=title,
                            url=url,
                            snippet=snippet[:300],
                            source='wikipedia',
                            relevance_score=0.75
                        ))
                        
        except Exception as e:
            print(f"Wikipedia search error: {e}", file=sys.stderr)
            
        return results[:max_results]
    
    def search_news(self, query: str, max_results: int = 5) -> List[SearchResult]:
        """Search for news articles using DuckDuckGo news"""
        results = []
        
        try:
            # Use DuckDuckGo with news focus
            news_query = f"news {query}"
            search_url = f"https://html.duckduckgo.com/html/?q={quote(news_query)}&iar=news"
            response = self.session.get(search_url, timeout=15)
            
            if response.status_code == 200:
                soup = BeautifulSoup(response.content, 'html.parser')
                
                for result_div in soup.find_all('div', class_='result')[:max_results]:
                    title_elem = result_div.find('a', class_='result__a')
                    snippet_elem = result_div.find('a', class_='result__snippet')
                    
                    if title_elem:
                        title = title_elem.get_text(strip=True)
                        url = title_elem.get('href', '')
                        snippet = snippet_elem.get_text(strip=True) if snippet_elem else ""
                        
                        results.append(SearchResult(
                            title=title,
                            url=url,
                            snippet=snippet[:300],
                            source='news',
                            relevance_score=0.8
                        ))
                        
        except Exception as e:
            print(f"News search error: {e}", file=sys.stderr)
            
        return results[:max_results]
    
    def search_academic(self, query: str, max_results: int = 5) -> List[SearchResult]:
        """Search for academic papers and documentation"""
        results = []
        
        try:
            # Search for academic content
            academic_query = f"academic paper research {query}"
            search_url = f"https://html.duckduckgo.com/html/?q={quote(academic_query)}"
            response = self.session.get(search_url, timeout=15)
            
            if response.status_code == 200:
                soup = BeautifulSoup(response.content, 'html.parser')
                
                for result_div in soup.find_all('div', class_='result')[:max_results]:
                    title_elem = result_div.find('a', class_='result__a')
                    snippet_elem = result_div.find('a', class_='result__snippet')
                    
                    if title_elem:
                        title = title_elem.get_text(strip=True)
                        url = title_elem.get('href', '')
                        snippet = snippet_elem.get_text(strip=True) if snippet_elem else ""
                        
                        # Boost relevance for academic domains
                        relevance = 0.7
                        if any(domain in url for domain in ['arxiv.org', 'scholar.google', 'pubmed', 'ieee.org', 'acm.org']):
                            relevance = 0.9
                            
                        results.append(SearchResult(
                            title=title,
                            url=url,
                            snippet=snippet[:300],
                            source='academic',
                            relevance_score=relevance
                        ))
                        
        except Exception as e:
            print(f"Academic search error: {e}", file=sys.stderr)
            
        return results[:max_results]

def research(query: str, 
             search_type: str = "general",
             max_results: int = 10,
             include_wikipedia: bool = True,
             include_news: bool = False) -> Dict[str, Any]:
    """
    Comprehensive web research function
    
    Args:
        query: Search term or question
        search_type: "general", "news", "academic", "wikipedia"  
        max_results: Maximum number of results to return
        include_wikipedia: Include Wikipedia results in general searches
        include_news: Include news results in general searches
        
    Returns:
        Dict with results, search metadata, and summary
    """
    researcher = WebResearcher()
    all_results = []
    
    try:
        if search_type == "general":
            # Multi-source search
            web_results = researcher.search_duckduckgo(query, max_results//2)
            all_results.extend(web_results)
            
            if include_wikipedia:
                wiki_results = researcher.search_wikipedia(query, 2)
                all_results.extend(wiki_results)
                
            if include_news:
                news_results = researcher.search_news(query, 2)
                all_results.extend(news_results)
                
        elif search_type == "wikipedia":
            all_results = researcher.search_wikipedia(query, max_results)
            
        elif search_type == "news":
            all_results = researcher.search_news(query, max_results)
            
        elif search_type == "academic":
            all_results = researcher.search_academic(query, max_results)
            
        else:
            # Default to general web search
            all_results = researcher.search_duckduckgo(query, max_results)
        
        # Sort by relevance
        all_results.sort(key=lambda x: x.relevance_score, reverse=True)
        all_results = all_results[:max_results]
        
        # Format results
        formatted_results = []
        for result in all_results:
            formatted_results.append({
                "title": result.title,
                "url": result.url,
                "snippet": result.snippet,
                "source": result.source,
                "relevance": result.relevance_score
            })
        
        return {
            "success": True,
            "query": query,
            "search_type": search_type,
            "total_results": len(formatted_results),
            "results": formatted_results,
            "summary": f"Found {len(formatted_results)} results for '{query}'" + 
                      (f" (search type: {search_type})" if search_type != "general" else "")
        }
        
    except Exception as e:
        return {
            "success": False,
            "error": f"Research error: {str(e)}",
            "query": query,
            "results": []
        }

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python research_tool.py '{\"query\":\"AI safety\",\"search_type\":\"general\"}'")
        sys.exit(1)
    
    try:
        params = json.loads(sys.argv[1])
        query = params.get("query", "")
        
        if not query:
            print("Error: query parameter is required")
            sys.exit(1)
            
        result = research(
            query=query,
            search_type=params.get("search_type", "general"),
            max_results=params.get("max_results", 10),
            include_wikipedia=params.get("include_wikipedia", True),
            include_news=params.get("include_news", False)
        )
        
        print(json.dumps(result, indent=2))
        
    except json.JSONDecodeError:
        print("Error: Invalid JSON input")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {str(e)}")
        sys.exit(1)