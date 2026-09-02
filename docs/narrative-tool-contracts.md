# Narrative Model Tool Contracts

[Narrative Studio Design Index](narrative-design-index.md)

## 1. Purpose

This document defines the tools exposed to narrative model roles. These are
domain tools, not HTTP endpoints and not generic ClawForge shell/file tools.

Tool availability is part of authorization. A tool not needed by the active
role is omitted from the model schema entirely.

## 2. Tool Design Rules

1. All tools require explicit story, branch, job, and position scope where
   applicable.
2. Read tools return typed records with stable IDs and provenance.
3. Position-sensitive reads default to the current cursor and reject future or
   sibling-branch leakage.
4. Model tools never accept SQL, filesystem paths, or arbitrary query
   expressions.
5. Mutations require expected versions and idempotency keys.
6. Prose mutations require stable block anchors and content hashes.
7. Planning, prose, documentation, and audit mutations are separate
   authorities.
8. Large results are paginated or expanded through a second bounded read.
9. Every tool result enters the context manifest.
10. Terminal tools end the model invocation after success.
11. Validation errors use stable machine-readable codes.
12. Tools return concise projections rather than human-rendered documents.

## 3. Common Scope

All story-aware tool inputs embed:

```json
{
  "scope": {
    "story_id": "uuid",
    "branch_id": "uuid",
    "story_version": 42,
    "job_id": "uuid",
    "position_node_id": "uuid"
  }
}
```

The runtime supplies and locks this scope. The model normally does not generate
the IDs itself.

Mutating tools also require:

```json
{
  "expected_revision_id": "uuid",
  "idempotency_key": "job-uuid/pass-0007"
}
```

## 4. Common Result and Errors

Successful result:

```json
{
  "ok": true,
  "data": {},
  "manifest_item_ids": ["uuid"],
  "truncated": false,
  "next_cursor": null
}
```

Failure:

```json
{
  "ok": false,
  "error": {
    "code": "STALE_REVISION",
    "message": "The manuscript changed after this pass was prepared.",
    "retryable": true,
    "current_revision_id": "uuid",
    "details": {}
  }
}
```

Required error codes:

- `INVALID_SCOPE`
- `ROLE_FORBIDDEN`
- `STAGE_FORBIDDEN`
- `NOT_FOUND`
- `FUTURE_LEAKAGE_BLOCKED`
- `BRANCH_LEAKAGE_BLOCKED`
- `STALE_STORY_VERSION`
- `STALE_REVISION`
- `STALE_ANCHOR`
- `PATCH_TOO_LARGE`
- `INVALID_PATCH`
- `CONSTRAINT_VIOLATION`
- `PROTECTED_MOMENT_VIOLATION`
- `CONTEXT_BUDGET_EXCEEDED`
- `RESULT_TRUNCATED`
- `IDEMPOTENCY_CONFLICT`
- `LEASE_CONFLICT`
- `JOB_PAUSED`
- `JOB_CANCELLED`

## 5. Exposure Matrix

Legend: `R` read, `M` mutate, `T` terminal, `—` unavailable.

| Tool family | Author | Director | Writer | Extractor | Auditor | Repair | Suggestion | Importer |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Position and beat runway | R | R | R | R | R | R | R | R |
| Structured story queries | R | R | R | R | R | R | R | R |
| Manuscript search/excerpts | R | R | R | R | R | R | R | R |
| Context manifest | R | R | R | R | R | R | R | — |
| Decision/record proposal | M | — | — | — | — | — | — | M |
| Plan patch | M | M | — | — | — | — | — | M |
| Writer pass | — | — | T | — | — | — | — | — |
| Extraction change set | — | — | — | T | — | — | — | M |
| Audit findings | — | — | — | — | T | — | — | — |
| Repair pass | — | — | — | — | — | T | — | — |
| Suggestions | — | — | — | — | — | — | T | — |
| Import candidates | — | — | — | — | — | — | — | T |

The discovery interviewer has separate intent-question and intent-proposal
tools and no manuscript mutation tools.

## 6. Exposure by Runtime Stage

| Runtime stage | Exposed tools |
|---|---|
| `author_room` | position, structured records, manuscript reads, context manifest, propose decision/record/plan patch |
| `directing` | position, plans, state, obligations, manuscript search, propose plan patch, finish director decision |
| `preparing_pass` | no model tools; application-only context compilation |
| `invoking_writer` | position, beat runway, state queries, bounded manuscript reads, context manifest, finish writer pass |
| `extracting_changes` | accepted patch read, prior state reads, submit change set |
| `checking_local` | normally deterministic; optional scoped checker output tool |
| `closing_scene` / `auditing_chapter` | audit reads and submit findings |
| `repairing` | exact finding/range reads, state queries, finish repair pass |
| `suggesting` | accepted state/plans reads and submit suggestions |
| `importing` | registered source reads and submit import candidates |

Tool schemas are assembled once at invocation creation. Changing job stage
requires a new model invocation and a new registry.

## 7. Read Tools

### 7.1 `get_authoring_position`

Purpose: return the authoritative current cursor.

Input:

```json
{"scope": {}}
```

Result data:

```json
{
  "chapter": {"id": "uuid", "title": "...", "ordinal": 12},
  "scene": {"id": "uuid", "title": "...", "ordinal": 3},
  "beat": {"id": "uuid", "title": "...", "status": "active"},
  "revision_id": "uuid",
  "cursor": {
    "block_id": "uuid",
    "side": "after",
    "content_hash": "sha256"
  },
  "working_story_version": 42
}
```

### 7.2 `get_active_beat_runway`

Purpose: expose bounded trajectory.

Input:

```json
{
  "scope": {},
  "lookbehind_beats": 2,
  "lookahead_beats": 3,
  "include_protected_moments": true
}
```

Limits: lookbehind `0..3`, lookahead `0..5`.

Result includes:

- scene purpose and exit condition
- completed beat summaries with evidence
- active beat obligation and completion test
- future beat summaries
- remaining-space estimate
- pending protected moment payloads and fidelity

### 7.3 `inspect_prose_window`

Purpose: retrieve exact local manuscript blocks.

Input:

```json
{
  "scope": {},
  "revision_id": "uuid",
  "anchor_block_id": "uuid",
  "blocks_before": 4,
  "blocks_after": 2,
  "maximum_tokens": 2400
}
```

Limits: at most 12 blocks and 4K tokens. Result includes stable block IDs,
hashes, types, ordinal positions, and exact text.

### 7.4 `query_story_records`

Purpose: retrieve compact typed documentation records.

Input:

```json
{
  "scope": {},
  "record_types": ["world_rule", "character_fact"],
  "entity_ids": ["uuid"],
  "predicates": ["regeneration.limit"],
  "status": ["accepted", "provisional"],
  "maximum_items": 20,
  "reason": "Need the known limits of venom adaptation."
}
```

No arbitrary SQL-like filter language is allowed. Results include record ID,
concise value, validity range, truth class, confidence, and provenance pointer.

### 7.5 `get_entity_state`

Input:

```json
{
  "scope": {},
  "entity_id": "uuid",
  "field_groups": ["physical", "emotional", "inventory", "knowledge"],
  "at_node_id": "uuid"
}
```

Future positions are rejected during prose writing.

### 7.6 `get_relationship_state`

Input:

```json
{
  "scope": {},
  "relationship_id": "uuid",
  "include_recent_deltas": 3,
  "include_planned_milestones": false
}
```

The result separates public, private, participant-believed, and objective
state where modeled.

### 7.7 `get_information_state`

Purpose: prevent knowledge and revelation leakage.

Input:

```json
{
  "scope": {},
  "information_item_ids": ["uuid"],
  "character_ids": ["uuid"],
  "include_reader_state": true,
  "include_revelation_plan": true
}
```

Result distinguishes world truth, each character's knowledge/belief, reader
knowledge/suspicion, and protected future instructions.

### 7.8 `get_open_obligations`

Input:

```json
{
  "scope": {},
  "kinds": ["thread", "promise", "milestone", "clue", "protected_moment"],
  "relevance": "current_scene",
  "maximum_items": 20
}
```

Result is ranked by hard requirement, placement urgency, and relevance.

### 7.9 `search_manuscript`

Input:

```json
{
  "scope": {},
  "query": "Lyra manual venom safety",
  "search_mode": "hybrid",
  "allowed_position": "not_after_current",
  "maximum_results": 8
}
```

Result returns summaries and short snippets. It does not return entire
chapters.

### 7.10 `read_manuscript_excerpt`

Input:

```json
{
  "scope": {},
  "source_revision_id": "uuid",
  "start_block_id": "uuid",
  "end_block_id": "uuid",
  "maximum_tokens": 3000,
  "reason": "Exact callback wording."
}
```

The requested range must be bounded, branch-visible, and valid for the role.

### 7.11 `get_context_manifest`

Input:

```json
{
  "scope": {},
  "manifest_id": "uuid",
  "group": "all"
}
```

Result reports included, summarized, excluded, and user-attached items with
token counts and reasons. It does not reveal private provider reasoning.

## 8. Author Room and Planning Tools

### 8.1 `propose_record_patch`

Creates a candidate documentation mutation. It never applies the mutation.

Input:

```json
{
  "scope": {},
  "record_id": "uuid-or-null",
  "record_type": "volume_contract",
  "expected_record_revision": 4,
  "operation": "update",
  "fields": {
    "target_emotional_effect": "Uneasy victory rather than triumph."
  },
  "reason": "The author decided the cost of victory should dominate the ending.",
  "conversation_message_ids": ["uuid"],
  "story_evidence_ids": ["uuid"]
}
```

Record type and editable fields must be allowlisted. Established-fact changes
that would require a retcon are labeled accordingly rather than presented as
ordinary edits.

### 8.2 `propose_story_decision`

Creates an approval card that may group record and plan proposals.

```json
{
  "scope": {},
  "title": "Volume One ends in an uneasy victory",
  "decision": "Rorann wins the confrontation but loses political autonomy.",
  "decision_scope": {"kind": "volume", "id": "uuid"},
  "proposal_ids": ["uuid"],
  "consequences": [
    "Moves the political-weaponization thread into Volume Two.",
    "Requires the final celebration scene to become restrained."
  ],
  "conflicts": [],
  "alternatives_rejected": ["Unqualified public triumph"]
}
```

The tool is non-terminal so the collaborator can still explain the proposal.

### 8.3 `finish_author_room_turn`

Terminal for an Author Room invocation:

```json
{
  "scope": {},
  "response_markdown": "That ending fits the existing political pressure...",
  "proposal_ids": ["uuid"],
  "unresolved_questions": [],
  "conversation_summary_delta": "Discussed the emotional shape of Volume One's ending."
}
```

An empty `proposal_ids` array is normal for brainstorming or factual answers.

### 8.4 `propose_beat_plan_patch`

Non-terminal. It creates a candidate plan mutation; application policy decides
whether it may auto-accept.

Input:

```json
{
  "scope": {},
  "expected_plan_revision": 7,
  "operations": [
    {
      "operation": "insert_after",
      "anchor_beat_id": "uuid",
      "beat": {
        "title": "Lyra recognizes the experiment",
        "requirement": "required",
        "purpose": "Convert observation into interpersonal conflict.",
        "entry_assumptions": ["Rorann holds the smaller sac."],
        "exit_change": "Lyra understands his immediate intent.",
        "completion_test": "Her concern becomes explicit.",
        "pacing_weight": 1,
        "information": {
          "deliver": [],
          "withhold": ["broodmother location"]
        },
        "participants": ["Lyra", "Rorann"],
        "interaction_contracts": [
          {
            "speaker": "Lyra",
            "listener": "Rorann",
            "relationship_state_at_entry": "wary field partners",
            "speaker_goal": "stop the experiment and force an explanation",
            "emotional_posture": "alarmed, then angry",
            "openness": "direct",
            "speech_mode": "urgent interruption",
            "may_express": ["fear for his safety", "anger at his methods"],
            "must_withhold": [],
            "prohibited_moves": ["detached clinical phrasing", "romantic confession"],
            "expected_shift": "Lyra treats his self-experimentation as a shared problem",
            "certainty": "strongly_implied",
            "evidence": ["character:lyra.voice", "relationship:lyra-rorann"]
          }
        ]
      }
    }
  ],
  "rationale": "The existing runway jumps from discovery to intervention."
}
```

Supported operations: insert, update, reorder within parent, mark conditional,
supersede. Removing required beats requires explicit user authority.

### 8.5 `propose_protected_moment`

Input:

```json
{
  "scope": {},
  "beat_id": "uuid",
  "kind": "exact_quote",
  "fidelity": "verbatim",
  "payload": "TRAINING IS CANCELED!",
  "speaker_entity_id": "uuid",
  "placement": {"earliest_beat_id": "uuid", "latest_beat_id": "uuid"},
  "prerequisites": ["Lyra physically stops the second attempt."],
  "adapt_surrounding_text": true
}
```

### 8.6 `finish_director_decision`

Terminal for a director invocation.

Input:

```json
{
  "scope": {},
  "decision": "write",
  "active_beat_id": "uuid",
  "passage_obligation": "...",
  "completion_test": "...",
  "activated_tracks": ["relationship", "comedy"],
  "risk_flags": ["complex_blocking"],
  "recommended_patch_scale": "small"
}
```

Allowed decisions: `write`, `retrieve_then_write`, `repair`, `close_scene`,
`pause_for_conflict`, `complete_chapter`.

## 9. Writer Mutation

### 9.1 `finish_writer_pass`

Terminal and atomic.

Input:

```json
{
  "scope": {},
  "expected_revision_id": "uuid",
  "idempotency_key": "job/pass-0007",
  "patch": {
    "operation": "insert_after",
    "start_anchor": {
      "block_id": "uuid",
      "content_hash": "sha256"
    },
    "end_anchor": null,
    "blocks": [
      {"type": "paragraph", "text": "..."},
      {"type": "paragraph", "text": "..."}
    ],
    "addressed_beat_ids": ["uuid"],
    "claimed_moment_anchor_ids": ["uuid"],
    "intent": "Lyra realizes and interrupts the experiment."
  },
  "continue_context": {
    "handoff": "Lyra is holding the larger sac against Rorann's chest.",
    "items": [
      {
        "kind": "unfinished_action",
        "value": "Rorann has not responded to being restrained.",
        "priority": "required",
        "ttl_passes": 1,
        "source_block_refs": [{"new_block_index": 1}]
      }
    ]
  }
}
```

Allowed patch operations:

- `insert_before`
- `insert_after`
- `replace_range`
- `delete_range`
- `move_range`

Writer mode normally permits insert and tightly scoped replacement. Delete and
move require revision/repair mode.

Success returns resulting revision, assigned block IDs, accepted local window,
new cursor, and saved capsule ID. The application then runs extraction and
checks outside this invocation.

The current bounded writer surface represents `blocks` as a required
`paragraphs` array plus explicit quality-check flags. Paragraph items are
independently addressable manuscript blocks, are capped at 130 words, and may
contain dialogue from at most one speaking character. Revision mode applies
the same terminal contract to a four-source-block `replace_range`.

## 10. Extraction Mutation

### 10.1 `submit_narrative_changeset`

Terminal for extractor role.

Input:

```json
{
  "scope": {},
  "source_revision_id": "uuid",
  "source_patch_id": "uuid",
  "idempotency_key": "patch/extraction-v1",
  "operations": [
    {
      "kind": "state_delta",
      "subject_id": "uuid",
      "predicate": "physical.position",
      "old_value": "beside corpse",
      "new_value": "restraining venom sac against Rorann",
      "confidence": 0.98,
      "evidence_block_ids": ["uuid"]
    },
    {
      "kind": "beat_evidence",
      "beat_id": "uuid",
      "result": "satisfied",
      "evidence_block_ids": ["uuid"]
    }
  ],
  "continuation_additions": [],
  "uncertainties": []
}
```

Allowed operation kinds are registry-defined. Unknown predicates and
unsupported evidence are rejected individually. The extractor cannot make
records accepted canon; it proposes updates to the job-local working state.

## 11. Audit Mutation

### 11.1 `submit_audit_findings`

Terminal for auditor role.

Input:

```json
{
  "scope": {},
  "audit_scope": {"kind": "scene", "id": "uuid"},
  "quality_gate_version": "1",
  "result": "revise",
  "findings": [
    {
      "code": "voice.narrator_character_bleed",
      "priority": 2,
      "severity": "blocking",
      "block_ids": ["uuid"],
      "evidence": "Narration adopts Lyra's dialogue register.",
      "repair_constraint": "Preserve Rorann's spoken deadpan."
    }
  ],
  "passing_constraints": [
    "The scene remains entertaining.",
    "The venom rule is demonstrated through action."
  ]
}
```

Auditors submit evidence and constraints, never rewritten prose.

## 12. Repair Mutation

### 12.1 `finish_repair_pass`

Terminal for revision coordinator.

It uses the same anchored patch structure as `finish_writer_pass` and adds:

```json
{
  "finding_ids": ["uuid"],
  "preserve_constraints": ["uuid-or-literal"],
  "maximum_scope": {
    "start_block_id": "uuid",
    "end_block_id": "uuid"
  }
}
```

The validator rejects changes outside maximum scope or removal of protected
passing spans.

## 13. Suggestion Mutation

### 13.1 `submit_story_suggestions`

Terminal for suggestion role.

Each suggestion includes:

- kind and title
- concise proposal
- evidence record/block IDs
- affected tracks
- predicted consequences
- risks
- urgency and confidence

Suggestions are versioned and non-canonical.

## 14. Import Mutation

### 14.1 `read_import_source_chunk`

Importer-only bounded read:

```json
{
  "import_job_id": "uuid",
  "source_id": "uuid",
  "chunk_id": "uuid",
  "include_previous_summary": true,
  "maximum_tokens": 6000
}
```

The result includes exact source block IDs, detected chapter/scene position,
neighbor summaries, and already recognized entity aliases. The importer cannot
read arbitrary filesystem paths.

### 14.2 `submit_import_structure_candidates`

Proposes volume, chapter, scene, POV, and ordering records with exact source
spans and confidence. These must be reviewed or deterministically verified
before later extraction treats positions as stable.

### 14.3 `submit_import_candidates`

Terminal for import reconciler.

Each candidate requires:

- proposed record type
- normalized fields
- source document and exact source span
- confidence
- possible duplicate IDs
- possible conflict IDs
- recommended action

Nothing is accepted automatically merely because extraction succeeded.

### 14.4 `finish_import_batch`

Terminal result includes:

- processed source/chunk IDs
- candidate IDs grouped by document family
- unresolved identity matches
- conflicts
- extraction coverage
- recommended next batch

Import candidates remain isolated from canonical retrieval until a user
approval command promotes them into the baseline version.

## 15. Discovery Tools

### 15.1 `record_discovery_answer`

Stores the user's answer as interview evidence, not canon.

### 15.2 `propose_intent_profile_patch`

Proposes structured intent fields and cites discovery-answer IDs.

### 15.3 `finish_discovery_turn`

Returns the next prioritized questions, resolved topics, contradictions, and
readiness estimate.

Discovery tools are unavailable after active writing unless the user
explicitly reopens design discovery.

## 16. Application Commands Are Not Model Tools

The following remain service commands used by UI/controller code:

- create/open/delete story
- start prose-only or documentation import
- approve/reject/edit import candidates by item or reviewed batch
- commit approved import as baseline story version
- start/pause/resume/cancel/steer job
- accept/reject plan proposal
- edit documentation record
- pin/attach/exclude context item
- waive or move protected moment
- accept/reject candidate direction
- undo story version
- compile/export
- manage branches

Models cannot call user-authority commands through their tool registry.

## 17. Result Budgeting

Default maximum tool-result sizes:

| Result | Maximum |
|---|---:|
| Position/cursor | 500 tokens |
| Beat runway | 2,000 tokens |
| Local prose window | 4,000 tokens |
| Structured record query | 2,500 tokens |
| Entity/relationship state | 1,500 tokens |
| Open obligations | 1,500 tokens |
| Search results | 1,500 tokens |
| Expanded excerpt | 3,000 tokens |
| Context manifest | 2,000 tokens |

The context compiler may set smaller limits. Tool results that would exceed
the remaining operation budget return summaries and continuation cursors
rather than overflowing context.

## 18. Schema Versioning

Every mutating tool has a semantic schema version. Stored invocations retain:

- tool name
- schema version
- canonicalized arguments hash
- result hash
- model/provider
- context manifest

Breaking schema changes require a new major tool version or migration adapter.
Prompts refer to capability semantics, not hard-coded JSON examples alone.

## 19. Tool Contract Tests

- every role exposes only its matrix-approved tools
- Author Room can propose but cannot accept record or plan changes
- conversation responses remain separate from story truth
- future and sibling-branch reads are blocked
- result budgets paginate correctly
- stale prose anchors fail without mutation
- duplicate idempotency key returns original patch
- writer cannot update plans or documentation
- extractor cannot submit unsupported claims without evidence
- auditor cannot mutate prose
- repair cannot exceed approved range
- direct application commands are absent from model registries
- import candidates remain outside canonical retrieval until baseline commit
- terminal tool success prevents further model tool calls
- tool schema version is persisted with every mutation
