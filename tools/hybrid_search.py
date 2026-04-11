#!/home/garward/Scripts/Tools/.venv/bin/python3
"""
Hybrid search tool for ClawForge.
Combines FTS5 keyword search with vector cosine similarity via RRF merging.
Queries Ollama for embedding generation, SQLite for FTS + stored vectors.

Usage:
    python3 hybrid_search.py "what did we discuss about food budgeting"
    python3 hybrid_search.py '{"query": "protein powder", "limit": 5}'
    python3 hybrid_search.py '{"query": "meal planning", "source_type": "message"}'
"""

import json
import math
import sqlite3
import struct
import sys
import urllib.request

DB_PATH = "/home/garward/Scripts/Tools/ClawForge/data/workspace.db"
OLLAMA_URL = "http://127.0.0.1:11434/api/embeddings"
EMBED_MODEL = "nomic-embed-text"
RRF_K = 60.0  # Standard RRF constant


def get_embedding(text: str) -> list[float] | None:
    """Get embedding vector from Ollama."""
    try:
        payload = json.dumps({"model": EMBED_MODEL, "prompt": text}).encode()
        req = urllib.request.Request(
            OLLAMA_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            return data.get("embedding")
    except Exception as e:
        return None


def cosine_similarity(a: list[float], b_bytes: bytes) -> float:
    """Cosine similarity between a Python list and a SQLite BLOB of float32s."""
    n = len(a)
    # Unpack the BLOB as float32 array
    b = struct.unpack(f"{n}f", b_bytes[:n * 4])

    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


def fts_search(conn: sqlite3.Connection, query: str, source_type: str | None, limit: int) -> list[dict]:
    """Run FTS5 search across messages, summaries, and knowledge."""
    results = []

    # Escape FTS query (simple: wrap terms in double quotes for phrase-safe matching)
    safe_query = query.replace('"', '""')

    if source_type is None or source_type == "message":
        try:
            rows = conn.execute(
                "SELECT m.id, 'message' as source_type, m.id as source_id, "
                "SUBSTR(m.content, 1, 400) as chunk_text, m.role, m.session_id "
                "FROM messages_fts fts JOIN messages m ON m.rowid = fts.rowid "
                "WHERE messages_fts MATCH ? ORDER BY rank LIMIT ?",
                (safe_query, limit),
            ).fetchall()
            for r in rows:
                results.append({
                    "source_type": r[1], "source_id": r[2],
                    "text": r[3], "role": r[4], "session_id": r[5],
                })
        except Exception:
            pass

    if source_type is None or source_type == "summary":
        try:
            rows = conn.execute(
                "SELECT s.id, 'summary' as source_type, s.id as source_id, "
                "SUBSTR(s.summary, 1, 400) as chunk_text, s.scope, s.session_id "
                "FROM summaries_fts fts JOIN summaries s ON s.rowid = fts.rowid "
                "WHERE summaries_fts MATCH ? ORDER BY rank LIMIT ?",
                (safe_query, limit),
            ).fetchall()
            for r in rows:
                results.append({
                    "source_type": r[1], "source_id": r[2],
                    "text": r[3], "scope": r[4], "session_id": r[5],
                })
        except Exception:
            pass

    if source_type is None or source_type == "knowledge":
        try:
            rows = conn.execute(
                "SELECT k.id, 'knowledge' as source_type, k.id as source_id, "
                "k.title || ': ' || SUBSTR(k.content, 1, 350) as chunk_text, "
                "k.category, k.confidence "
                "FROM knowledge_fts fts JOIN knowledge k ON k.rowid = fts.rowid "
                "WHERE knowledge_fts MATCH ? ORDER BY rank LIMIT ?",
                (safe_query, limit),
            ).fetchall()
            for r in rows:
                results.append({
                    "source_type": r[1], "source_id": r[2],
                    "text": r[3], "category": r[4], "confidence": r[5],
                })
        except Exception:
            pass

    return results


def vector_search(
    conn: sqlite3.Connection,
    query_vec: list[float],
    source_type: str | None,
    broad_limit: int = 100,
    final_limit: int = 20,
) -> list[dict]:
    """Two-pass vector search: binary hamming broad pass + FP32 cosine rescore."""
    # Get all embeddings (or filtered by source_type)
    if source_type:
        rows = conn.execute(
            "SELECT id, source_type, source_id, chunk_text, vector_fp32 "
            "FROM embeddings WHERE source_type = ? AND vector_fp32 IS NOT NULL",
            (source_type,),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT id, source_type, source_id, chunk_text, vector_fp32 "
            "FROM embeddings WHERE vector_fp32 IS NOT NULL",
        ).fetchall()

    if not rows:
        return []

    # Score all by cosine similarity (dataset is small enough for brute force)
    scored = []
    for r in rows:
        vec_blob = r[4]
        if vec_blob and len(vec_blob) >= len(query_vec) * 4:
            score = cosine_similarity(query_vec, vec_blob)
            scored.append({
                "source_type": r[1],
                "source_id": r[2],
                "text": r[3][:400] if r[3] else "",
                "cosine_score": round(score, 4),
            })

    # Sort by cosine similarity descending
    scored.sort(key=lambda x: x["cosine_score"], reverse=True)
    return scored[:final_limit]


def rrf_merge(fts_results: list[dict], vec_results: list[dict], limit: int) -> list[dict]:
    """Reciprocal Rank Fusion: merge FTS and vector ranked lists."""
    scores: dict[str, dict] = {}  # key: "source_type:source_id"

    # Add FTS results
    for rank, item in enumerate(fts_results):
        key = f"{item['source_type']}:{item['source_id']}"
        if key not in scores:
            scores[key] = {**item, "fts_rank": rank + 1, "vec_rank": None, "rrf_score": 0.0}
        scores[key]["rrf_score"] += 1.0 / (RRF_K + rank + 1)
        scores[key]["fts_rank"] = rank + 1

    # Add vector results
    for rank, item in enumerate(vec_results):
        key = f"{item['source_type']}:{item['source_id']}"
        if key not in scores:
            scores[key] = {**item, "fts_rank": None, "vec_rank": rank + 1, "rrf_score": 0.0}
        scores[key]["rrf_score"] += 1.0 / (RRF_K + rank + 1)
        scores[key]["vec_rank"] = rank + 1
        if "cosine_score" in item:
            scores[key]["cosine_score"] = item["cosine_score"]

    # Sort by RRF score descending
    merged = sorted(scores.values(), key=lambda x: x["rrf_score"], reverse=True)

    # Clean up and round
    for item in merged:
        item["rrf_score"] = round(item["rrf_score"], 6)

    return merged[:limit]


def hybrid_search(query: str, source_type: str | None = None, limit: int = 20) -> dict:
    """Full hybrid search: FTS + vector + RRF merge."""
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)

    # FTS search
    fts_results = fts_search(conn, query, source_type, limit * 2)

    # Vector search (get embedding from Ollama)
    query_vec = get_embedding(query)
    vec_results = []
    if query_vec:
        vec_results = vector_search(conn, query_vec, source_type, broad_limit=100, final_limit=limit * 2)

    conn.close()

    # If we have both, merge with RRF
    if fts_results and vec_results:
        merged = rrf_merge(fts_results, vec_results, limit)
        return {
            "method": "hybrid_rrf",
            "fts_count": len(fts_results),
            "vector_count": len(vec_results),
            "results": merged,
        }
    elif fts_results:
        # FTS only (no embeddings available)
        for i, r in enumerate(fts_results):
            r["rrf_score"] = round(1.0 / (RRF_K + i + 1), 6)
            r["fts_rank"] = i + 1
            r["vec_rank"] = None
        return {
            "method": "fts_only",
            "fts_count": len(fts_results),
            "vector_count": 0,
            "note": "No embeddings found, using keyword search only",
            "results": fts_results[:limit],
        }
    elif vec_results:
        # Vector only (FTS didn't match)
        for i, r in enumerate(vec_results):
            r["rrf_score"] = round(1.0 / (RRF_K + i + 1), 6)
            r["fts_rank"] = None
            r["vec_rank"] = i + 1
        return {
            "method": "vector_only",
            "fts_count": 0,
            "vector_count": len(vec_results),
            "results": vec_results[:limit],
        }
    else:
        return {
            "method": "none",
            "fts_count": 0,
            "vector_count": 0,
            "results": [],
            "note": "No results found in any search method",
        }


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Provide a search query"}))
        sys.exit(1)

    raw = " ".join(sys.argv[1:]).strip()

    # Try JSON input
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            query = data.get("query", "")
            source_type = data.get("source_type")
            limit = data.get("limit", 20)
        else:
            query = raw
            source_type = None
            limit = 20
    except json.JSONDecodeError:
        query = raw
        source_type = None
        limit = 20

    if not query:
        print(json.dumps({"error": "Empty query"}))
        sys.exit(1)

    result = hybrid_search(query, source_type, limit)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
