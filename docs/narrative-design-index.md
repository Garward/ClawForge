# Narrative Studio Design Index

## 0. Implementation Status

The first executable vertical slice landed on 2026-07-23:

- same-origin `/narrative` studio and `Chat | Narrative Studio` switcher
- independent `src/narrative/` application, domain, storage, and runtime boundary
- shared `src/inference/` provider gateway; Narrative does not call `Engine.process()`
- independently versioned SQLite narrative schema
- story workspaces, main branches, story versions, and per-story model profiles
- deterministic 19-record story documentation package with editable projections
- volume/arc/chapter/scene storyboard nodes
- reader/editor manuscript surface with immutable, block-scoped prose revisions
- persistent Author Room with bounded typed-document context
- guided discovery interview with adaptive questions and approval-gated document proposals
- durable passage-writer jobs using the required `finish_writer_pass` terminal tool
- eight-block prose runway plus explicit cross-pass continuation capsules
- automatic `PassChangeSet` and `ContinuationCapsule` records after writer passes
- protocol/storage tests using an in-memory database and fake inference gateway

The design remains authoritative for subsequent slices. Not yet implemented:

- blueprint readiness gates
- manuscript/document import and approval reconciliation
- post-passage semantic extraction into entity/relationship/world state
- director, audit, repair, suggestion, and chapter/scene-close roles
- retrieval embeddings and full context-manifest accounting
- server-owned background job execution, streaming, pause/cancel, and leases
- branch creation/merge UI, exports, and richer document projections

## 1. Start Here

Narrative Studio design is split into five documents:

| Document | Authority |
|---|---|
| [System Design](narrative-system-design.md) | Product architecture, narrative principles, data concepts, delivery phases |
| [Runtime Protocol](narrative-runtime-protocol.md) | Normative agent-loop lifecycle, context assembly, transactions, recovery |
| [Tool Contracts](narrative-tool-contracts.md) | Normative model tools, schemas, role exposure, authorization |
| [Document Model](narrative-document-model.md) | Normative canonical record catalog and human/model projections |
| [UI and Web Architecture](narrative-ui-design.md) | Product interaction, workspaces, web transport, frontend behavior |

If documents conflict:

1. Runtime behavior follows the Runtime Protocol.
2. Model authority and tool schemas follow Tool Contracts.
3. Record/document identity follows the Document Model.
4. Architectural intent follows System Design.
5. Presentation and transport behavior follow UI and Web Architecture.

Contradictions should still be corrected in all affected documents rather than
left to precedence indefinitely.

## 2. Implementation Reading Paths

### 2.1 Runtime foundation

1. [System ownership boundary](narrative-system-design.md#51-ownership-and-dependency-boundary)
2. [Proposed module layout](narrative-system-design.md#52-proposed-module-layout)
3. [Composition root](narrative-system-design.md#53-composition-root)
4. [Runtime components](narrative-runtime-protocol.md#3-runtime-components)
5. [Job state machine](narrative-runtime-protocol.md#6-job-state-machine)
6. [Phase 0 runtime seams](narrative-system-design.md#phase-0-runtime-seams)

### 2.2 Story storage and schema

1. [Authority and lifecycle](narrative-system-design.md#6-authority-and-lifecycle)
2. [Common record envelope](narrative-document-model.md#3-common-record-envelope)
3. [Required record packages](narrative-document-model.md#4-required-record-packages)
4. [Story graph](narrative-system-design.md#7-story-graph)
5. [Canon and state](narrative-system-design.md#8-canon-and-state-model)
6. [Storage groups](narrative-system-design.md#17-proposed-storage-groups)
7. [Record lifecycle](narrative-document-model.md#9-record-creation-lifecycle)

### 2.3 Agent loop

1. [Runtime invariants](narrative-runtime-protocol.md#2-runtime-invariants)
2. [Start-job sequence](narrative-runtime-protocol.md#7-start-job-sequence)
3. [Director stage](narrative-runtime-protocol.md#8-director-stage)
4. [Context compilation](narrative-runtime-protocol.md#9-context-compilation)
5. [Writer pass](narrative-runtime-protocol.md#10-writer-pass)
6. [Patch transaction](narrative-runtime-protocol.md#11-patch-validation-and-draft-transaction)
7. [Extraction and working state](narrative-runtime-protocol.md#12-post-patch-extraction)
8. [Loop decision](narrative-runtime-protocol.md#15-loop-decision)
9. [Scene and chapter close](narrative-runtime-protocol.md#16-scene-close)

### 2.4 Context and RAG

1. [Context construction](narrative-system-design.md#14-context-construction)
2. [Context layers](narrative-runtime-protocol.md#91-context-layers-and-order)
3. [Required writer material](narrative-runtime-protocol.md#92-always-required-writer-material)
4. [Context sufficiency](narrative-runtime-protocol.md#94-context-sufficiency-preflight)
5. [Compression](narrative-runtime-protocol.md#95-compression-policy)
6. [Role injection profiles](narrative-runtime-protocol.md#96-role-injection-profiles)
7. [Model projection catalog](narrative-document-model.md#11-model-projection-catalog)
8. [Projection selection](narrative-document-model.md#13-projection-selection-rules)

### 2.5 Model tools

1. [Tool design rules](narrative-tool-contracts.md#2-tool-design-rules)
2. [Exposure matrix](narrative-tool-contracts.md#5-exposure-matrix)
3. [Exposure by stage](narrative-tool-contracts.md#6-exposure-by-runtime-stage)
4. [Read tools](narrative-tool-contracts.md#7-read-tools)
5. [Author Room and planning tools](narrative-tool-contracts.md#8-author-room-and-planning-tools)
6. [Writer mutation](narrative-tool-contracts.md#9-writer-mutation)
7. [Extraction mutation](narrative-tool-contracts.md#10-extraction-mutation)
8. [Audit and repair](narrative-tool-contracts.md#11-audit-mutation)
9. [Application commands](narrative-tool-contracts.md#16-application-commands-are-not-model-tools)

### 2.6 UI implementation

1. [Product principles](narrative-ui-design.md#3-product-principles)
2. [Global shell](narrative-ui-design.md#4-global-application-shell)
3. [Primary workspaces](narrative-ui-design.md#5-primary-workspaces)
4. [Frontend architecture](narrative-ui-design.md#7-front-end-architecture)
5. [Backend web architecture](narrative-ui-design.md#8-backend-web-architecture)
6. [API shape](narrative-ui-design.md#9-api-shape)
7. [Streaming](narrative-ui-design.md#10-streaming-strategy)
8. [UI delivery phases](narrative-ui-design.md#12-mvp-scope)

## 3. Decision Lookup

| Question | Primary section |
|---|---|
| Where does implementation live? | [Module layout](narrative-system-design.md#52-proposed-module-layout) |
| Does Narrative call `Engine.process()`? | [Ownership boundary](narrative-system-design.md#51-ownership-and-dependency-boundary) |
| Is Narrative a separate HTTP adapter? | [Same-origin controller](narrative-ui-design.md#81-same-origin-controller) |
| What does `Write chapter` mean? | [Whole-chapter operation](narrative-system-design.md#1434-whole-chapter-operation) |
| What happens on every pass? | [Passage loop](narrative-runtime-protocol.md#10-writer-pass) |
| How much can a pass write? | [Scoped prose](narrative-system-design.md#121-prose-is-written-through-scoped-patches) |
| How is immediate coherence carried? | [Continuation capsules](narrative-runtime-protocol.md#13-working-state-update) |
| How is pacing preserved? | [Pacing envelope](narrative-system-design.md#1432-hierarchical-pacing-envelope) |
| How are exact quotes preserved? | [Protected moments](narrative-system-design.md#75-protected-moment-anchors) |
| What context is always injected? | [Required writer material](narrative-runtime-protocol.md#92-always-required-writer-material) |
| What is dropped under pressure? | [Compression policy](narrative-runtime-protocol.md#95-compression-policy) |
| Which tools does each model see? | [Exposure matrix](narrative-tool-contracts.md#5-exposure-matrix) |
| How does prose enter storage? | [Writer mutation](narrative-tool-contracts.md#9-writer-mutation) |
| Who updates documentation? | [Documentation authority](narrative-document-model.md#16-documentation-update-authority) |
| What records does every book require? | [Every volume or book](narrative-document-model.md#42-every-volume-or-book) |
| What records does every chapter require? | [Every chapter](narrative-document-model.md#44-every-chapter) |
| What does the user see versus the model? | [Four representations](narrative-document-model.md#2-the-four-representations) |
| When are records created? | [Creation lifecycle](narrative-document-model.md#9-record-creation-lifecycle) |
| How are conflicts/version races handled? | [Concurrency and leases](narrative-runtime-protocol.md#20-optimistic-concurrency-and-leases) |
| How does crash recovery work? | [Steering/pause/resume](narrative-runtime-protocol.md#19-steering-pause-cancel-and-resume) |
| How is latency controlled? | [Latency and cost](narrative-system-design.md#1510-latency-and-cost-control) |
| Where can the user talk normally with a story-aware model? | [Author Room](narrative-ui-design.md#521-author-room) |
| How does the user enter Narrative Studio? | [Entering Narrative Studio](narrative-ui-design.md#412-entering-narrative-studio) |
| How do conversational decisions become durable? | [Author Room turn](narrative-runtime-protocol.md#41-author-room-turn) |
| Can prose be imported without documentation? | [Prose-only reconstruction](narrative-system-design.md#182-prose-only-reconstruction) |
| How does import approval work? | [Import workspace records](narrative-document-model.md#82-import-workspace-records) |
| How are Narrative models selected? | [Role model configuration](narrative-system-design.md#237-role-model-configuration) |
| What model does an active job use? | [Model resolution](narrative-runtime-protocol.md#31-model-resolution) |

## 4. System Design Contents

### Product and architecture

- [Summary](narrative-system-design.md#1-summary)
- [Source-corpus findings](narrative-system-design.md#2-source-corpus-findings)
- [Goals](narrative-system-design.md#3-goals)
- [Non-goals](narrative-system-design.md#4-non-goals)
- [System boundary](narrative-system-design.md#5-system-boundary)
- [Ownership and dependencies](narrative-system-design.md#51-ownership-and-dependency-boundary)
- [Module layout](narrative-system-design.md#52-proposed-module-layout)
- [Composition](narrative-system-design.md#53-composition-root)

### Discovery and design

- [Authority and lifecycle](narrative-system-design.md#6-authority-and-lifecycle)
- [Authoring modes](narrative-system-design.md#61-authoring-modes)
- [Author Room conversation](narrative-system-design.md#611-author-room-conversation)
- [Discovery interview](narrative-system-design.md#62-guided-discovery-interview)
- [Intent model](narrative-system-design.md#63-intent-model)
- [Blueprint readiness](narrative-system-design.md#64-blueprint-readiness)
- [Volume contract](narrative-system-design.md#65-volume-contract)
- [Backward arc design](narrative-system-design.md#66-backward-arc-design)
- [Narrative tracks](narrative-system-design.md#67-narrative-tracks)
- [Contextual craft guidance](narrative-system-design.md#68-contextual-craft-guidance)

### Relational texture and comedy

- [Relational defaults](narrative-system-design.md#69-relational-humanity-and-romance-aware-defaults)
- [Intimacy profiles](narrative-system-design.md#610-character-intimacy-profile)
- [Daily-life grounding](narrative-system-design.md#611-daily-life-grounding)
- [Romance checks](narrative-system-design.md#612-romance-integration-checks)
- [Comedy contract](narrative-system-design.md#613-comedy-contract)
- [Comedy taxonomy](narrative-system-design.md#614-comedy-taxonomy)
- [Humor profiles](narrative-system-design.md#615-character-humor-profiles)
- [Tonal protection](narrative-system-design.md#616-appropriate-placement-and-tonal-protection)
- [Avoiding forced comedy](narrative-system-design.md#617-avoiding-forced-comedy)
- [Venom-training pattern](narrative-system-design.md#618-worked-pattern-venom-resistance-training-apparently)

### Story data

- [Story graph](narrative-system-design.md#7-story-graph)
- [Nodes](narrative-system-design.md#71-narrative-nodes)
- [Edges](narrative-system-design.md#72-narrative-edges)
- [Branches](narrative-system-design.md#73-branches)
- [Beat plans](narrative-system-design.md#74-hierarchical-beat-plans)
- [Protected moments](narrative-system-design.md#75-protected-moment-anchors)
- [Canon and state](narrative-system-design.md#8-canon-and-state-model)
- [Arcs, threads, milestones](narrative-system-design.md#9-arcs-threads-and-milestones)
- [World rules](narrative-system-design.md#10-world-rules-and-constraints)

### Writing quality

- [Style and voice](narrative-system-design.md#11-style-and-voice)
- [Voice hierarchy](narrative-system-design.md#111-tone-and-voice-hierarchy)
- [Continuous guidelines](narrative-system-design.md#113-continuous-writing-guidelines)
- [Promise ledger](narrative-system-design.md#114-story-promise-ledger)
- [Information delivery](narrative-system-design.md#116-information-delivery-contract)
- [Revelation planning](narrative-system-design.md#117-revelation-planning)
- [Ordered quality gate](narrative-system-design.md#119-ordered-scene-and-chapter-quality-gate)

### Prose, documentation, and context

- [Prose and revisions](narrative-system-design.md#12-prose-revisions-and-retrieval)
- [Scoped patches](narrative-system-design.md#121-prose-is-written-through-scoped-patches)
- [Passage loop](narrative-system-design.md#122-passage-authoring-loop)
- [Continuation capsules](narrative-system-design.md#123-continuation-capsules)
- [Documentation maintenance](narrative-system-design.md#13-automatic-documentation-maintenance)
- [Context construction](narrative-system-design.md#14-context-construction)
- [Context budgets](narrative-system-design.md#143-context-packet-and-budget-policy)
- [Pacing envelope](narrative-system-design.md#1432-hierarchical-pacing-envelope)
- [Operation profiles](narrative-system-design.md#144-selection-scoped-operation-profiles)
- [Narrative tools](narrative-system-design.md#146-narrative-authoring-tools)

### Workflows and delivery

- [Agentic workflows](narrative-system-design.md#15-agentic-workflows)
- [Audit cascade](narrative-system-design.md#156-audit-cascade)
- [Revision coordination](narrative-system-design.md#157-revision-coordination)
- [Suggestions](narrative-system-design.md#158-out-of-character-suggestion-generation)
- [Latency and cost](narrative-system-design.md#1510-latency-and-cost-control)
- [Structured contracts](narrative-system-design.md#16-structured-model-contracts)
- [Storage groups](narrative-system-design.md#17-proposed-storage-groups)
- [Story import](narrative-system-design.md#18-story-import)
- [Prose-only reconstruction](narrative-system-design.md#182-prose-only-reconstruction)
- [Protocol requirements](narrative-system-design.md#19-adapter-and-protocol-requirements)
- [Service commands](narrative-system-design.md#20-initial-service-commands)
- [Delivery phases](narrative-system-design.md#21-delivery-phases)
- [Acceptance criteria](narrative-system-design.md#22-acceptance-criteria-for-the-architecture)
- [Initial implementation decisions](narrative-system-design.md#23-initial-implementation-decisions)

## 5. Runtime Protocol Contents

- [Purpose and invariants](narrative-runtime-protocol.md#1-purpose-and-status)
- [Runtime components](narrative-runtime-protocol.md#3-runtime-components)
- [Model resolution](narrative-runtime-protocol.md#31-model-resolution)
- [Model roles](narrative-runtime-protocol.md#4-model-roles)
- [Author Room turn](narrative-runtime-protocol.md#41-author-room-turn)
- [Persisted job state](narrative-runtime-protocol.md#5-authoring-job-state)
- [State machine](narrative-runtime-protocol.md#6-job-state-machine)
- [Start sequence](narrative-runtime-protocol.md#7-start-job-sequence)
- [Director](narrative-runtime-protocol.md#8-director-stage)
- [Context compilation](narrative-runtime-protocol.md#9-context-compilation)
- [Writer pass](narrative-runtime-protocol.md#10-writer-pass)
- [Patch transaction](narrative-runtime-protocol.md#11-patch-validation-and-draft-transaction)
- [Extraction](narrative-runtime-protocol.md#12-post-patch-extraction)
- [Working state](narrative-runtime-protocol.md#13-working-state-update)
- [Local checks](narrative-runtime-protocol.md#14-local-checks)
- [Loop decision](narrative-runtime-protocol.md#15-loop-decision)
- [Scene close](narrative-runtime-protocol.md#16-scene-close)
- [Chapter close](narrative-runtime-protocol.md#17-chapter-close)
- [Repair](narrative-runtime-protocol.md#18-repair-protocol)
- [Pause/resume/steer](narrative-runtime-protocol.md#19-steering-pause-cancel-and-resume)
- [Concurrency](narrative-runtime-protocol.md#20-optimistic-concurrency-and-leases)
- [Events](narrative-runtime-protocol.md#21-event-contract)
- [Failures](narrative-runtime-protocol.md#22-failure-rules)
- [Idempotency](narrative-runtime-protocol.md#23-idempotency)
- [Observability](narrative-runtime-protocol.md#24-observability)
- [Protocol tests](narrative-runtime-protocol.md#25-required-protocol-tests)

## 6. Tool Contract Contents

- [Common scope](narrative-tool-contracts.md#3-common-scope)
- [Results and errors](narrative-tool-contracts.md#4-common-result-and-errors)
- [Exposure matrix](narrative-tool-contracts.md#5-exposure-matrix)
- [Stage exposure](narrative-tool-contracts.md#6-exposure-by-runtime-stage)
- [Read tools](narrative-tool-contracts.md#7-read-tools)
- [Author Room and planning](narrative-tool-contracts.md#8-author-room-and-planning-tools)
- [Writer mutation](narrative-tool-contracts.md#9-writer-mutation)
- [Extraction](narrative-tool-contracts.md#10-extraction-mutation)
- [Audit](narrative-tool-contracts.md#11-audit-mutation)
- [Repair](narrative-tool-contracts.md#12-repair-mutation)
- [Suggestions](narrative-tool-contracts.md#13-suggestion-mutation)
- [Import](narrative-tool-contracts.md#14-import-mutation)
- [Discovery](narrative-tool-contracts.md#15-discovery-tools)
- [Application commands](narrative-tool-contracts.md#16-application-commands-are-not-model-tools)
- [Result budgets](narrative-tool-contracts.md#17-result-budgeting)
- [Schema versioning](narrative-tool-contracts.md#18-schema-versioning)
- [Contract tests](narrative-tool-contracts.md#19-tool-contract-tests)

## 7. Document Model Contents

- [Four representations](narrative-document-model.md#2-the-four-representations)
- [Common envelope](narrative-document-model.md#3-common-record-envelope)
- [Workspace configuration](narrative-document-model.md#31-workspace-configuration-records)
- [Required packages](narrative-document-model.md#4-required-record-packages)
- [Story package](narrative-document-model.md#41-every-story-or-series)
- [Volume/book package](narrative-document-model.md#42-every-volume-or-book)
- [Arc package](narrative-document-model.md#43-every-arc)
- [Chapter package](narrative-document-model.md#44-every-chapter)
- [Scene package](narrative-document-model.md#45-every-scene)
- [Entity families](narrative-document-model.md#5-entity-record-families)
- [Plot/information families](narrative-document-model.md#6-plot-and-information-families)
- [Guidelines/craft](narrative-document-model.md#7-guidelines-and-craft-records)
- [Plan versus established](narrative-document-model.md#8-planning-versus-established-state)
- [Author conversations and decisions](narrative-document-model.md#81-author-conversation-and-decisions)
- [Import workspace](narrative-document-model.md#82-import-workspace-records)
- [Creation lifecycle](narrative-document-model.md#9-record-creation-lifecycle)
- [Human document catalog](narrative-document-model.md#10-human-document-catalog)
- [Model projections](narrative-document-model.md#11-model-projection-catalog)
- [Projection selection](narrative-document-model.md#13-projection-selection-rules)
- [Editing](narrative-document-model.md#14-editing-rules)
- [Invalidation](narrative-document-model.md#15-projection-invalidation)
- [Update authority](narrative-document-model.md#16-documentation-update-authority)
- [Retention](narrative-document-model.md#17-retention-and-deletion)
- [Tests](narrative-document-model.md#18-document-model-tests)

## 8. UI Design Contents

- [Decision](narrative-ui-design.md#1-decision)
- [Existing patterns](narrative-ui-design.md#2-existing-clawforge-patterns-to-preserve)
- [Reader reference](narrative-ui-design.md#21-reader-reference)
- [Product principles](narrative-ui-design.md#3-product-principles)
- [Application shell](narrative-ui-design.md#4-global-application-shell)
- [Model selection](narrative-ui-design.md#411-model-selection)
- [Entering Narrative Studio](narrative-ui-design.md#412-entering-narrative-studio)
- [Suggestions, Inspector, Context Used](narrative-ui-design.md#43-suggestions-and-inspector-rail)
- [Job drawer](narrative-ui-design.md#44-job-drawer)
- [Story position](narrative-ui-design.md#45-persistent-story-position)
- [Dashboard](narrative-ui-design.md#51-story-dashboard)
- [Discovery](narrative-ui-design.md#52-discovery)
- [Author Room](narrative-ui-design.md#521-author-room)
- [Import and sources](narrative-ui-design.md#522-import--sources)
- [Volume contract](narrative-ui-design.md#53-volume-contract)
- [Blueprint and beat plans](narrative-ui-design.md#54-blueprint)
- [Manuscript](narrative-ui-design.md#55-manuscript)
- [Docs and plans](narrative-ui-design.md#56-docs--plans)
- [Characters](narrative-ui-design.md#57-characters)
- [Relationships](narrative-ui-design.md#58-relationships)
- [World](narrative-ui-design.md#59-world)
- [Timeline and knowledge](narrative-ui-design.md#510-timeline-and-reader-knowledge)
- [Arcs, threads, promises](narrative-ui-design.md#511-arcs-threads--promises)
- [Style, voice, craft](narrative-ui-design.md#512-style-voice--craft)
- [Review and continuity](narrative-ui-design.md#513-review--continuity)
- [Interaction flows](narrative-ui-design.md#6-core-interaction-flows)
- [Frontend architecture](narrative-ui-design.md#7-front-end-architecture)
- [Web architecture](narrative-ui-design.md#8-backend-web-architecture)
- [API](narrative-ui-design.md#9-api-shape)
- [Streaming](narrative-ui-design.md#10-streaming-strategy)
- [Accessibility](narrative-ui-design.md#11-accessibility-and-responsive-behavior)
- [MVP](narrative-ui-design.md#12-mvp-scope)
- [Deferrals](narrative-ui-design.md#13-explicit-deferrals)
- [Validation scenarios](narrative-ui-design.md#14-validation-scenarios)

## 9. Hard-to-Change Decisions Checklist

Before implementation passes Phase 0/1, approve:

- module dependency graph
- runtime/job state machine
- role and tool authority matrix
- terminal writer-pass semantics
- prose block identity and patch operations
- story/branch/version identity
- common record envelope
- lifecycle and truth-class vocabulary
- required story/volume/arc/chapter/scene packages
- context layer order and non-droppable material
- continuation capsule TTL and authority
- protected moment fidelity semantics
- scene versus chapter commit policy
- optimistic concurrency and lease behavior
- event names and sequencing
- idempotency keys
- projection schemas and invalidation
- migration/version strategy
- user authority versus autonomous acceptance policy

## 10. Initial Implementation Decisions

The previously open schema/runtime questions are resolved in
[System Design §23](narrative-system-design.md#23-initial-implementation-decisions):

- dedicated domain tables plus extensible typed facts
- UUID story positions with derived ordinal paths
- evidence/validation gates instead of trusting model confidence
- narrowly scoped automatic hard-rule repair
- declarative rules without arbitrary executable story code
- Narrative Story as a top-level workspace with optional project link
- per-role optional model configuration with explicit inheritance

Future changes to an identifier, transaction boundary, truth-class rule, or
public schema require an explicit migration and design update.
