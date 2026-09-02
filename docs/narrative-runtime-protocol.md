# Narrative Runtime and Agent-Loop Protocol

[Narrative Studio Design Index](narrative-design-index.md)

## 1. Purpose and Status

This document is the normative execution contract for Narrative Studio. It
defines what happens from an authoring command through durable commit.

The broader system and UI documents explain product intent. This protocol
defines implementation behavior. Terms `MUST`, `MUST NOT`, `SHOULD`, and `MAY`
are normative.

## 2. Runtime Invariants

1. `Write chapter` is a durable job goal, never a chapter-sized model output.
2. Each writer pass is a fresh bounded model invocation.
3. A writer pass produces one coherent passage of one to six structured
   paragraph blocks. Each block contains at most one speaking character.
4. Writer prose enters the manuscript only through an anchored,
   revision-checked patch.
5. A successful writer pass ends with exactly one terminal
   `finish_writer_pass` tool call.
6. Chat history is not the writer's memory. The runtime owns position, state,
   context manifests, beat progress, and handoffs.
7. Planned material, provisional state, and accepted canon remain distinct.
8. A model never mutates story tables directly.
9. Every model role receives only the tools allowed for that role and stage.
10. Every accepted mutation is attributable, versioned, inspectable, and
    reversible.
11. A job can resume from the last durable boundary without reconstructing its
    state from model conversation.
12. Context sufficiency is checked before prose is requested.
13. Context pressure removes optional material before trajectory, local
    continuity, protected moments, or hard constraints.
14. Narrative code does not import or invoke the chat-oriented `Engine`.

## 3. Runtime Components

```text
NarrativeService
    |
    +-- CommandHandler
    +-- QueryHandler
    +-- NarrativeJobRuntime
            |
            +-- ChapterDirector
            +-- ContextCompiler
            +-- InferenceGateway
            +-- PatchValidator
            +-- ChangeExtractor
            +-- LocalChecker
            +-- BoundaryAuditor
            +-- RevisionCoordinator
            +-- NarrativeStores
            +-- EventBus
```

`NarrativeService` accepts typed commands and queries. Long-running commands
enqueue jobs and return job IDs. HTTP is not part of this layer.

`NarrativeJobRuntime` owns workers, cancellation, steering, checkpoints, and
per-worker database connections.

`InferenceGateway` maps a narrative role request onto the shared generic
inference runtime. It does not use chat sessions or chat prompt assembly.

### 3.1 Model resolution

Before compiling context, each invocation resolves:

```json
{
  "role": "passage_writer",
  "model_id": "anthropic:claude-sonnet-4-6",
  "source": "story_role_override",
  "context_window": 200000,
  "input_budget": 12000,
  "output_budget": 1800,
  "timeout_ms": 120000,
  "capabilities": {
    "tools": true,
    "structured_output": true,
    "streaming": true
  }
}
```

Resolution follows the inheritance chain defined in System Design §23.7.

Job-start preflight resolves and snapshots every role the job may use. It
fails before writing when the selected writer cannot support the terminal tool
contract or when required context cannot fit its known context window.

Each context manifest and stored invocation records the resolved model, source
of selection, budgets, and catalog capability version.

Changing story model settings does not affect an active job. An explicit
`change_job_role_model` command schedules a validated switch at the next safe
boundary and invalidates prepared context for that role.

## 4. Model Roles

One provider model may serve several roles, but each invocation has exactly
one role and role-specific contracts.

| Role | Owns | Must not do |
|---|---|---|
| Author collaborator | Tool-enabled discussion and decision proposals | Treat conversation as truth or self-approve changes |
| Discovery interviewer | Clarify author intent | Draft canonical prose |
| Structure director | Plans, beat runway, completion decisions | Write manuscript prose |
| Passage writer | One bounded prose patch and handoff | Update canon or rewrite plans |
| Change extractor | Proposed typed effects of accepted prose | Add prose or invent unsupported facts |
| Local checker | Cheap scoped findings | Rewrite prose |
| Boundary auditor | Scene/chapter quality findings | Mutate manuscript |
| Revision coordinator | One coherent scoped repair | Change unrelated passing material |
| Suggestion generator | Non-canonical next-direction advice | Change plan or canon |
| Import reconciler | Candidate records with provenance | Silently accept source claims |

Role separation is enforced by prompt contract, tool registry, output schema,
and application-layer authorization.

### 4.1 Author Room turn

An Author Room turn is a bounded conversational invocation:

1. Persist the user's message in the selected story conversation thread.
2. Resolve selected story/branch/position and explicit attachments.
3. Compile relevant records and bounded conversation summary.
4. Expose collaborator read tools and proposal tools.
5. Let the collaborator answer normally and optionally emit one or more
   structured decision proposals.
6. Persist the conversational response separately from story truth.
7. Display proposals for user approval.
8. On approval, validate and commit proposed record patches as a story version.
9. Replace durable decisions in future context with their structured records;
   retain conversation only as provenance.

The collaborator may say that no durable decision was reached. Ordinary
brainstorming does not create empty or speculative record updates.

## 5. Authoring Job State

Every job persists a `NarrativeAuthoringJobState`:

```json
{
  "job_id": "uuid",
  "story_id": "uuid",
  "branch_id": "uuid",
  "base_story_version": 42,
  "mode": "write_chapter",
  "status": "preflight",
  "chapter_id": "uuid",
  "scene_id": "uuid",
  "beat_id": "uuid",
  "cursor_block_id": "uuid",
  "working_revision_id": "uuid",
  "working_snapshot_id": "uuid",
  "pass_number": 0,
  "patch_count": 0,
  "repair_count": 0,
  "word_count": 0,
  "context_manifest_id": null,
  "continuation_capsule_id": null,
  "pending_steering_id": null,
  "limits": {
    "maximum_passes": 40,
    "maximum_repairs": 4,
    "maximum_words": 7000,
    "deadline_unix_ms": null
  }
}
```

Limits are configurable operation safeguards, not chapter targets. Reaching a
limit checkpoints and pauses; it does not cause compressed or rushed prose.

## 6. Job State Machine

```text
queued
  → preflight
  → directing
  → preparing_pass
  → invoking_writer
  → validating_patch
  → saving_patch
  → extracting_changes
  → checking_local
  → deciding
       ├── preparing_pass
       ├── repairing
       ├── closing_scene
       ├── paused
       └── failed
  → closing_scene
       ├── directing next scene
       ├── auditing_chapter
       └── repairing
  → auditing_chapter
       ├── repairing
       └── committing
  → committing
  → completed
```

`cancelled`, `failed`, and `paused` may be entered only at safe boundaries.
An in-flight provider request may be cancelled, but no partial tool arguments
are committed.

Every transition is validated against the persisted state. Illegal transitions
are rejected rather than coerced.

## 7. Start-Job Sequence

`start_chapter_authoring_job` performs:

1. Validate story, branch, chapter, expected story version, and permissions.
2. Acquire a branch/chapter authoring lease.
3. Create a job against an immutable base story version.
4. Load the accepted volume, arc, and chapter contracts.
5. Verify blueprint readiness.
6. Verify a chapter scene sequence exists.
7. Verify the first authorable scene has a usable beat plan.
8. Verify required protected moments have valid placement windows.
9. Materialize the entering branch snapshot.
10. Establish the working manuscript revision and initial cursor.
11. Run context and pacing preflight.
12. Persist the first checkpoint.
13. Emit `job_started`.
14. Enter the director stage.

Missing structure does not get silently invented by the writer. The director
may propose missing structure, and configured autonomous mode may accept
low-risk refinements, but every such decision is stored as a plan change.

## 8. Director Stage

The director receives structural state, not a large prose prompt.

It determines:

- current scene and active beat
- whether the beat plan needs refinement
- required and optional narrative tracks
- immediate passage obligation
- protected moments entering their placement window
- pacing weight and approximate remaining space
- whether the next action is write, retrieve, repair, close scene, or stop

Director output is schema-validated:

```json
{
  "decision": "write",
  "scene_id": "uuid",
  "beat_id": "uuid",
  "passage_obligation": "Lyra notices the smaller venom sac and realizes Rorann's intent.",
  "completion_test": "Her concern becomes explicit before he pours it.",
  "preserve_for_next": ["Rorann has not explained his reasoning yet."],
  "activated_tracks": ["world_rule", "relationship", "comedy"],
  "risk_flags": ["complex_blocking"],
  "recommended_patch_scale": "small"
}
```

The director cannot declare a required beat complete without evidence spans or
an explicit plan revision.

## 9. Context Compilation

### 9.1 Context layers and order

Each fresh invocation is compiled in this order:

1. Role contract and output/tool contract
2. Story, branch, base version, job, and selected position
3. Current user instruction and unconsumed steering
4. Exact writer cursor and accepted local prose boundary
5. Active continuation capsule
6. Current beat obligation and completion test
7. Immediate beat lookbehind and bounded lookahead
8. Pending protected moments in or approaching their window
9. Narrator, POV, speaking-character voice, and hard style constraints
10. Current relevant character, relationship, object, location, and timeline
    state
11. Applicable world rules and knowledge boundaries
12. Active promises, threads, revelations, and information-delivery rules
13. Routed craft guidance
14. Retrieved summaries, callbacks, exemplars, and exact excerpts
15. Explicit user attachments

Ordering is stable for provider prompt caching. Dynamic content is placed
after stable contracts where the provider supports prefix caching.

### 9.2 Always-required writer material

The writer MUST receive:

- exact story position and branch
- expected manuscript revision and cursor anchors
- local prose boundary
- active continuation capsule
- current beat and completion test
- immediate lookbehind and lookahead
- scene exit condition and remaining-space estimate
- applicable hard canon and world rules
- POV knowledge boundary
- narrator and involved-character voice constraints
- pending verbatim anchors in their placement window
- prohibited reveals and protected tone
- patch size and terminal-tool contract

### 9.3 Conditional material

Conditional material is routed by explicit scene/beat signals:

- detailed comedy guidance
- romance or intimacy guidance
- action choreography
- mystery and clue logic
- horror or suspense
- exposition technique
- specialized setting rules
- old callbacks and stylistic exemplars

Activation and omission are recorded in the context manifest.

### 9.4 Context sufficiency preflight

Before writer invocation the compiler must answer:

1. What just happened?
2. What is physically and emotionally true at the cursor?
3. What must the next passage accomplish?
4. What must remain unresolved or hidden?
5. What must be possible after the passage?
6. Whose knowledge and perception constrain the prose?
7. What exact moments must survive compression?
8. How much scene and chapter space remains?

Failure blocks writing and routes to planning, retrieval, or conflict
resolution.

### 9.5 Compression policy

Drop or compress in this order:

1. Optional exemplars
2. Old authoring conversation
3. Distant raw prose
4. Unrelated entity fields
5. Verbose long-range plans
6. Low-priority semantic retrieval

Never drop:

- cursor and local boundary
- continuation capsule
- current beat and completion test
- immediate lookbehind/lookahead
- hard constraints
- protected reveal rules
- pending verbatim anchors in scope

### 9.6 Role injection profiles

Each role receives a separately compiled packet:

| Role | Required injection | Deliberately omitted |
|---|---|---|
| Author collaborator | current user turn, bounded thread summary, selected story position, explicit attachments, relevant records and prose excerpts, unresolved proposals | unrelated conversations, whole manuscript, authority to treat its own discussion as accepted |
| Discovery interviewer | current intent profile, answered questions, missing high-value decisions, contradictions, discovery provenance | manuscript prose and detailed canon not referenced by the user |
| Structure director | story/volume/arc/chapter contracts, entering state, beat progress, open obligations, summaries, completion conditions, bounded prose boundary | full manuscript, prose style exemplars unless evaluating a specific planned moment |
| Passage writer | §9.2 writer material plus routed craft and bounded retrieval | unrelated dossiers, full human docs, generic chat history, distant full chapters |
| Change extractor | accepted patch, small before/after window, prior working snapshot, active beat/anchors, allowed change schemas | future beat details not needed to classify the patch, style exemplars, author conversation |
| Local checker | patch, local boundary, hard rules, knowledge boundary, voice fingerprints, active beat | broad arc plans and unrelated world records |
| Boundary auditor | complete scene or chapter prose, entry/exit state, contracts, beat plans, obligations, voice/quality rubric, relevant long-range summaries | author chat, unrelated documents, unused skill manuals |
| Revision coordinator | exact failing spans plus bounded surroundings, findings, preserve constraints, relevant canon/voice/beat obligations | unaffected full manuscript and low-priority suggestions |
| Suggestion generator | accepted current state, open arcs/threads/promises, upcoming plan horizon, recent summaries, author preferences | provisional rejected drafts and protected future details outside its authorized planning scope |
| Import reconciler | one source section, source metadata/span, candidate schema, existing likely matches/conflicts | unrelated source corpus and accepted status authority |

Default target/hard input ceilings:

| Role invocation | Target | Hard ceiling |
|---|---:|---:|
| Author Room turn | 6–14K | 20K |
| Discovery turn | 6–12K | 16K |
| Director decision | 8–14K | 20K |
| Writer passage | 6–12K | 16K |
| Semantic extraction | 4–8K | 12K |
| Optional local model check | 4–8K | 10K |
| Scene audit | 12–20K | 28K |
| Chapter audit | 16–28K | 36K |
| Scoped repair | 6–14K | 18K |
| Suggestions | 6–12K | 16K |
| Import reconciliation chunk | 8–16K | 20K |

These are ceilings for compiled inputs, not targets to fill. Unused budget
remains unused.

## 10. Writer Pass

The writer may:

1. Inspect its cursor and context manifest.
2. Request narrowly scoped story records or prose excerpts.
3. Compose one coherent passage.
4. End with `finish_writer_pass`.

It may not:

- write ordinary assistant prose as the result
- call generic filesystem tools
- change story plans or documentation
- mark its own beat definitively complete
- emit more than one prose mutation
- continue after a successful terminal tool call

`finish_writer_pass` contains:

- expected revision
- anchored patch
- beat IDs addressed
- concise intent
- proposed continuation capsule
- claimed protected anchors used

## 11. Patch Validation and Draft Transaction

Validation order:

1. JSON/schema validity
2. Job, branch, node, and role authorization
3. Expected revision match
4. Anchor existence and content-hash match
5. Operation/range validity
6. Patch size ceiling
7. Paragraph readability ceiling and one-speaker dialogue layout
8. UTF-8 and manuscript block validity
9. Protected content and prohibited-reveal checks
10. Hard deterministic canon checks
11. Continuation-capsule schema and source validation

On failure, no prose or capsule is saved. The tool returns a stable error code,
the current revision, and the smallest useful diff/context for retry.

On success, one draft transaction saves:

- immutable prose patch
- resulting working revision
- model invocation metadata
- context manifest
- proposed continuation capsule
- updated writer cursor
- job checkpoint
- patch-accepted event

The transaction does not yet promote provisional facts to accepted canon.

### 11.1 Bounded chapter revision

`Revise chapter` is also a durable multi-pass job. Each pass receives a target
range of at most four existing paragraph blocks, up to two adjacent blocks on
either side as read-only context, the applicable contracts, and the user's
revision direction. It returns replacement paragraph blocks only.

Revision passes MUST preserve events, facts, viewpoint, chronology, and
unresolved implications unless the user explicitly asks to change them. They
MUST NOT advance the story. Each accepted range creates an immutable
`replace_range` prose revision; rejected output changes nothing and may be
retried automatically within a bounded retry allowance.

## 12. Post-Patch Extraction

Extraction receives only:

- accepted patch
- small before/after prose boundary
- prior working snapshot
- current beat and protected anchors
- schemas for allowed change types

It proposes a `NarrativeChangeSet`:

- mentioned entities and aliases
- new or changed facts
- physical and inventory changes
- character and relationship deltas
- timeline events
- knowledge transfers
- reader-understanding changes
- thread, promise, clue, and revelation movement
- beat satisfaction evidence
- protected-moment placement evidence
- continuation items omitted by the writer

Every claim requires one or more accepted prose block IDs or an explicit
plan/rule source. Unsupported claims are rejected or stored as low-confidence
inference, never authoritative truth.

Cheap deterministic extraction runs first. A model extractor is invoked only
for semantic ambiguity that affects later writing or documentation.

## 13. Working-State Update

Validated extraction updates the job-local working snapshot.

The runtime then:

1. Merges and validates the continuation capsule.
2. Promotes durable immediate facts out of the capsule.
3. Advances provisional beat progress using evidence.
4. Marks protected moments placed only after fidelity validation.
5. Updates pacing telemetry.
6. Refreshes the current scene summary incrementally.
7. Records conflicts and uncertainties.

Human-readable documentation projections do not need synchronous regeneration.
Their backing records and invalidation keys are updated immediately.

At a chapter boundary, completion is gated on semantic documentation
extraction. The extractor receives the accepted chapter, the accepted beat
plan, and only mutable record families. Every canonical replacement requires
exact prose block evidence. A failure leaves the prose intact and the job
`paused` with `postprocess_pending`; resumption retries extraction without
invoking the passage writer again.

## 14. Local Checks

Run after every patch:

- stale anchor or broken block structure
- accidental repeated phrase or duplicated passage
- speaker and quotation balance
- POV knowledge violation detectable from records
- protected reveal violation
- impossible physical transition
- direct hard-world-rule contradiction
- missing required continuation handoff
- gross voice-contract violation
- patch-scale and beat-stagnation warning

These checks should be deterministic where possible. They do not run the full
scene quality rubric after every passage.

A blocking failure routes to a scoped repair. A warning is recorded and may
continue when the next passage can safely resolve it.

## 15. Loop Decision

After checks, the application layer decides:

```text
if cancellation requested:
    checkpoint and cancel
else if steering pending:
    consume steering and re-run director
else if blocking finding:
    run scoped repair
else if current beat incomplete:
    prepare next writer pass
else if scene exit condition incomplete:
    activate next beat
else:
    close scene
```

The model may recommend a decision, but the application validates the
transition using evidence and job state.

## 16. Scene Close

Scene close performs:

1. Verify all required beats are satisfied, revised, or explicitly waived.
2. Verify protected moments in the scene window are placed, moved, or waived.
3. Consolidate the scene summary and proposed exit state.
4. Run the ordered scene quality gate.
5. Route blocking findings to the revision coordinator.
6. Re-run affected extraction after repair.
7. Validate entering-to-exit state consistency.
8. Create a durable scene checkpoint.
9. Commit scene prose and consolidated documentation changes as one accepted
   story version only when the user requested a scene-sized authoring
   operation.
10. Generate the next scene's entering snapshot.

For a chapter-sized authoring operation, scene checkpoints remain durable
working revisions on the job workspace and are promoted together at chapter
close. They do not appear as accepted main-branch canon.

Commit scope is determined by the user command:

| Command | Accepted-story commit boundary |
|---|---|
| Write/revise passage | After that patch, extraction, and local checks |
| Write/revise scene | After scene gate passes |
| Write/revise chapter | After chapter gate passes |

All smaller internal steps remain resumable draft checkpoints. The runtime
does not change commit scope dynamically during a job.

## 17. Chapter Close

Chapter close performs:

1. Assemble accepted scene revisions.
2. Verify chapter beat and scene sequence completion.
3. Run the chapter quality gate.
4. Run long-range continuity checks relevant to the chapter.
5. Coordinate one coherent repair set.
6. Re-extract changed passages.
7. Produce the chapter summary and exit snapshot.
8. Update chapter/arc/volume progress.
9. Refresh documentation invalidations and retrieval chunks.
10. Commit prose, plan progress, state, and documentation atomically.
11. Release the authoring lease.
12. Refresh non-canonical suggestions asynchronously.
13. Emit `job_completed`.

## 18. Repair Protocol

Repairs use exact findings and anchored ranges.

The revision coordinator receives:

- highest-priority failing findings
- exact affected prose
- passing qualities that must be preserved
- beat and protected-moment obligations
- maximum repair scope

It returns one scoped prose patch through the same validation and extraction
pipeline. It cannot silently regenerate a scene or chapter.

Repeated failure beyond the configured repair count checkpoints and pauses for
user review.

## 19. Steering, Pause, Cancel, and Resume

Steering is stored durably with:

- target job
- author
- creation time
- scope: next patch, current scene, chapter remainder, or persistent plan
- instruction
- consumed status

Next-patch steering is injected once and then expires. Persistent decisions
must be promoted into a plan, contract, rule, or preference record.

Pause occurs after the current safe tool boundary. Resume reloads:

- base and current working versions
- exact cursor
- active beat
- working snapshot
- continuation capsule
- pending findings
- remaining limits

No model transcript is required.

## 20. Optimistic Concurrency and Leases

Every mutation names an expected story or manuscript revision.

Only one automatic writer job may own a chapter/branch authoring lease.
Human edits may:

- be blocked while a patch is validating
- pause the job and create a new working revision
- occur on a separate branch

They must not race silently. A conflicting edit invalidates prepared context
and requires the next writer pass to rebuild from the new revision.

## 21. Event Contract

Minimum ordered events:

- `job_started`
- `job_state_changed`
- `director_decision_ready`
- `context_manifest_ready`
- `writer_pass_started`
- `prose_patch_proposed`
- `prose_patch_accepted`
- `prose_patch_rejected`
- `writer_cursor_changed`
- `continuation_capsule_updated`
- `changeset_proposed`
- `working_state_updated`
- `finding_created`
- `beat_progress_changed`
- `protected_moment_placed`
- `scene_checkpoint_created`
- `story_version_committed`
- `job_paused`
- `job_completed`
- `job_failed`
- `job_cancelled`

Events include job ID, monotonic sequence, story ID, branch ID, relevant
revision/version, timestamp, and typed payload.

## 22. Failure Rules

- Provider timeout: retry according to idempotent invocation policy; never
  duplicate an accepted patch.
- Invalid tool call: bounded schema-repair attempt, then pause/fail.
- Stale revision: rebuild context; do not auto-merge prose.
- Database busy: retry transaction within configured deadline.
- Extraction failure: preserve prose checkpoint, mark documentation pending,
  and block the next pass only when missing state is required for coherence.
- Audit failure: preserve draft, do not promote affected boundary.
- Process crash: resume from last committed checkpoint and event sequence.
- Context overflow: apply deterministic compression; if required context still
  does not fit, fail preflight.

## 23. Idempotency

Commands and terminal model tools carry caller-stable idempotency keys.

The runtime stores:

- command key → job ID
- writer-pass key → accepted patch/resulting revision
- extraction key → change-set ID
- commit key → story version

Retries return the existing result rather than applying work twice.

## 24. Observability

Per writer pass record:

- role and model
- prompt/context manifest hashes
- input, cached-input, output, and tool tokens
- retrieval/tool timings
- provider latency
- patch words and blocks
- validation/extraction/check timings
- findings and repair outcome
- resulting accepted-word retention

Secrets and private provider reasoning are never stored.

## 25. Required Protocol Tests

- Author Room answers with story evidence but creates no mutation
- accepted Author Room decision applies exactly its reviewed record patches
- rejected Author Room proposal never enters drafting context
- prose-only import reconstructs candidates without creating accepted canon
- approved import batch preserves exact manuscript provenance
- clean chapter loop across several scenes
- protected quote survives multiple fresh writer passes
- continuation capsule carries unfinished blocking then expires
- stale patch after manual edit
- pause and process restart mid-scene
- cancellation during provider streaming
- model omits critical handoff but extractor restores it
- extraction invents unsupported fact and is rejected
- future-plan leakage into current prose context
- sibling-branch leakage attempt
- beat falsely claimed complete without evidence
- repair preserves a protected passing passage
- context pressure removes optional material in correct order
- duplicate command and terminal-tool retries remain idempotent
- chapter commit atomically updates prose and documentation
