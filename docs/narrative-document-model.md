# Narrative Canonical Records and Document Projections

[Narrative Studio Design Index](narrative-design-index.md)

## 1. Purpose

This document defines:

- which machine-readable record types exist
- which records every story, volume, chapter, and scene must create
- when records are created and updated
- how users view them
- how models receive compact projections
- which material is canonical, planned, provisional, inferred, or derived

The live source of truth is typed storage. Markdown pages, UI dossiers, model
context packets, and exports are projections.

## 2. The Four Representations

### 2.1 Canonical record

Small typed data with stable identity, scope, lifecycle, validity range, and
provenance.

Example: one fact that Rorann can regenerate tissue at Chapter 1.

### 2.2 Human document projection

A readable assembled view over many records.

Example: the complete character dossier for Rorann at Chapter 12, including
current state, history, relationships, voice, arc, and provenance.

### 2.3 Model context projection

A compact operation-specific serialization containing only relevant fields.

Example: Rorann's current injury state, regeneration constraints, knowledge,
voice traits, and immediate relationship state for one passage.

### 2.4 Export artifact

A portable snapshot such as Markdown, JSON, EPUB, or DOCX. It is not edited as
the authoritative store after export.

## 3. Common Record Envelope

All authoritative narrative records use:

```json
{
  "id": "uuid",
  "record_type": "character_fact",
  "story_id": "uuid",
  "branch_id": "uuid-or-null",
  "parent_id": "uuid-or-null",
  "lifecycle": "accepted",
  "truth_class": "established",
  "valid_from_node_id": "uuid-or-null",
  "valid_to_node_id": "uuid-or-null",
  "revision": 3,
  "confidence": 1.0,
  "provenance": [
    {
      "source_type": "prose_block",
      "source_id": "uuid",
      "span": null
    }
  ],
  "created_at": "timestamp",
  "updated_at": "timestamp"
}
```

Lifecycle:

- `candidate`
- `accepted`
- `rejected`
- `superseded`
- `inferred`
- `conflicted`

Truth class:

- `planned`
- `established`
- `character_belief`
- `reader_belief`
- `authorial_rule`
- `derived`

Lifecycle and truth class are separate. An accepted plan remains planned, not
established.

### 3.1 Workspace configuration records

Operational preferences are versioned separately from story canon:

- `NarrativeModelProfile`
- context/token budget overrides
- autonomy and approval policy
- job limit defaults
- UI preferences

`NarrativeModelProfile` contains:

- optional story narrative-default model ID
- per-role model ID or inherit
- per-role input/output budget overrides
- per-role timeout
- last validated model-catalog capability version
- update author and time

Model settings never become prose facts, story plans, or manuscript
provenance. Authoring jobs snapshot the effective profile for reproducibility.

## 4. Required Record Packages

### 4.1 Every story or series

Created during discovery/design:

| Required record | Purpose |
|---|---|
| `StoryIdentity` | Title, premise, genre, audience, status, and one story-level fiction declaration |
| `StoryIntentProfile` | Desired reader experience and author preferences |
| `StoryContract` | Themes, primary dramatic engine, promises, prohibitions |
| `StoryStructureRoot` | Root node and supported linear/branching mode |
| `NarratorContract` | Narrator identity, distance, tense, permeability |
| `StyleContract` | Global prose rules and negative preferences |
| `InformationDeliveryContract` | How explanations and discovery should occur |
| `ComedyContract` | Allowed modes, protected tones, saturation |
| `RelationalTextureContract` | Relationship/romance defaults and exclusions |
| `QualityGateContract` | Ordered evaluation priorities and thresholds |
| `EntityRegistry` | Stable entity namespace plus significant-character dossiers and voice exemplars |
| `WorldRuleRegistry` | Typed world/system constraints |
| `MasterTimeline` | Story-time coordinate system and known events |
| `InformationRegistry` | Secrets, clues, truths, beliefs, reader knowledge |
| `ArcRegistry` | Character, relationship, plot, mystery, and thematic arcs |
| `PromiseLedger` | Setups, emphasized details, obligations, payoffs |
| `AuthorDecisionRegistry` | Accepted conversational decisions and proposal history |
| `SourceRegistry` | Imported and generated provenance |
| `BranchRegistry` | Main and alternate branch ancestry |

These are logical records or registries, not necessarily one SQL row each.

### 4.2 Every volume or book

Created before its arc blueprint:

| Required record | Purpose |
|---|---|
| `VolumeContract` | Required destination and reader experience |
| `VolumeEntryState` | Starting story, character, relationship, and knowledge state |
| `VolumeExitTargets` | Required/preferred/prohibited end state |
| `VolumeBeatPlan` | Major turning points and flexible placement ranges |
| `VolumeArcSchedule` | Arcs active, introduced, advanced, resolved, deferred |
| `VolumeRevelationPlan` | Information learned and delivery methods |
| `VolumePromisePlan` | Promises introduced, reinforced, paid, deferred |
| `VolumeToneAndPacingPlan` | Escalation shape, relief, climax, denouement |
| `VolumeCastPlan` | Major participants and expected trajectory |
| `VolumeCompletionReport` | Derived at close; target-versus-actual evidence |

`VolumeCompletionReport` does not exist until audit/close. All other records
must be sufficiently ready before active volume drafting.

### 4.3 Every arc

Created before its first chapter is authored:

| Required record | Purpose |
|---|---|
| `ArcContract` | Dramatic engine, purpose, scope, and affected tracks |
| `ArcEntryState` | Preconditions |
| `ArcExitTargets` | Intended changes |
| `ArcBeatPlan` | Escalation steps and turning points |
| `ArcInformationPlan` | Clue/revelation progression |
| `ArcRelationshipPlan` | Relevant interpersonal progression |
| `ArcPacingPlan` | Pressure, variation, climax, recovery |
| `ArcDependencies` | Other arcs, promises, rules, and milestones |
| `ArcCompletionReport` | Derived evidence and unresolved consequences |

### 4.4 Every chapter

Required before `Write chapter`:

| Required record | Purpose |
|---|---|
| `ChapterContract` | Why the chapter exists and what must advance |
| `ChapterEntrySnapshot` | Accepted state entering the chapter |
| `ChapterExitTargets` | Desired exit changes and protected future state |
| `ChapterScenePlan` | Ordered scenes and transitions |
| `ChapterBeatPlan` | Chapter-level beats and pacing weights |
| `ChapterInformationPlan` | Reveals, clues, explanations, withholds |
| `ChapterTrackBudget` | Plot, character, relationship, comedy, action, reflection |
| `ChapterProtectedMoments` | Verbatim/semantic/inspirational anchors |
| `ChapterCompletionConditions` | Evidence required to close |

Created while or after writing:

| Derived record | Timing |
|---|---|
| `ChapterWorkingState` | Updated after each accepted passage |
| `ChapterSummary` | Incremental, finalized at close |
| `ChapterExitSnapshot` | Close |
| `ChapterChangeSet` | Consolidated close |
| `ChapterQualityGateResult` | Close and after repair |
| `ChapterRetrievalChunks` | Background after accepted commit |
| `ChapterCompletionReport` | Final target-versus-actual |

### 4.5 Every scene

Required before its first writer pass:

| Required record | Purpose |
|---|---|
| `SceneCard` | POV, setting, purpose, entering/exit state, tone |
| `SceneBeatPlan` | Ordered immediate obligations |
| `ScenePacingEnvelope` | Movement, runway, remaining space |
| `SceneInformationPlan` | Deliver, imply, withhold, protect |
| `SceneParticipants` | Characters, relationships, relevant entities |
| `SceneApplicableRules` | Hard world and craft constraints |
| `SceneCompletionConditions` | Required evidence for close |

Created during writing:

| Working record | Timing |
|---|---|
| `ProseRevision` | Every accepted patch |
| `ProsePatch` | Every writer/repair mutation |
| `WriterCursor` | Every accepted patch |
| `ContinuationCapsule` | Every accepted writer pass |
| `PassContextManifest` | Every model invocation |
| `PassChangeSet` | Every extracted patch |
| `BeatProgress` | Every relevant patch |
| `LocalFinding` | When checks detect an issue |

Created at close:

| Derived record | Purpose |
|---|---|
| `SceneSummary` | Retrieval and later context |
| `SceneExitSnapshot` | State entering the next scene |
| `SceneQualityGateResult` | Ordered audit result |
| `SceneCompletionReport` | Beat and target evidence |

## 5. Entity Record Families

### 5.1 Character

Stable identity:

- canonical name and aliases
- role and story importance
- immutable origin data

Position-sensitive state:

- appearance
- physical condition
- location
- possessions
- abilities and limitations
- goals and priorities
- fears, wounds, contradictions
- emotional state
- knowledge and beliefs
- public/private identity

Contracts and plans:

- strengths: capabilities or qualities that reliably solve problems
- one or two flaws, each with observable behavior and a real story or
  relationship cost
- voice fingerprint
- recognition anchors: baseline habit, stress response, relational change,
  contextual variation, and an explicit repetition limit
- humor profile
- intimacy/relationship profile
- daily-life grounding
- character arc and milestones

### 5.2 Relationship

- participants
- relationship type and labels
- objective dynamic
- each participant's perception
- public/private status
- trust, intimacy, attraction, conflict, dependency
- courtship behavior, personal boundaries, and relevant power constraints
- recurring interaction patterns
- recent deltas
- progression plan and milestones

### 5.3 Location

- identity and aliases
- parent geography
- physical layout
- sensory identity
- inhabitants and control
- access/travel constraints
- relevant history
- current condition by story position
- objects and scene-blocking landmarks

### 5.4 Faction and society

- identity, goals, resources, membership
- leadership and ranks
- relationships and conflicts
- laws, customs, politics, religion
- public knowledge versus hidden behavior
- position-sensitive status

### 5.5 Object

- identity and aliases
- appearance
- ownership/location history
- capabilities and limitations
- symbolic or promised significance
- current condition

### 5.6 Rule system

- domain: magic, technology, progression, economy, law, biology, combat
- authoritative rule statement
- prerequisites
- limits and exceptions
- who knows it
- when reader learns it
- examples and counterexamples
- validity range and provenance

## 6. Plot and Information Families

### 6.1 Arc

An intended progression over a node range. It is not marked complete merely
because a related event occurred.

### 6.2 Thread

An unresolved causal or dramatic line with status:

- open
- advanced
- resolved
- deferred
- abandoned

### 6.3 Promise

Anything emphasized enough to create reader expectation:

- setup
- reinforcement
- intended payoff
- subversion
- retirement
- abandonment warning

### 6.4 Milestone

A desired change with earliest/latest/target placement and evidence-based
completion.

### 6.5 Information item

One truth or proposition tracked separately for:

- objective world truth
- each character's knowledge or belief
- reader knowledge or suspicion
- planned reveal state

### 6.6 Revelation plan

- target information
- intended audience
- reveal method
- clues and prerequisites
- earliest/latest placement
- protected-before boundary
- intended certainty after delivery

### 6.7 Protected moment

- exact quote, action, image, reveal, callback, emotional turn, or transition
- verbatim, semantic, or inspirational fidelity
- placement window
- prerequisites
- status and exact fulfillment span

## 7. Guidelines and Craft Records

### 7.1 Always-on contract

A compact kernel:

1. engaging and rewarding
2. voice-separated and immersive
3. meaningfully advancing
4. character-logical
5. information delivered according to contract
6. promises and consequences respected
7. tonal elements integrated
8. continuity intact

### 7.2 Routed craft skill

Each craft skill stores:

- applicability triggers
- compact writer guidance
- contraindications
- protected tones
- required state fields
- audit rubric
- positive and negative exemplars
- context budget
- version

### 7.3 Voice contract

Separate contracts for:

- narrator
- POV filtering
- internal voice
- spoken character voice
- temporary scene modulation

## 8. Planning Versus Established State

Every projection must preserve this separation:

```text
planned event
≠
provisional event in unfinished draft
≠
established event in accepted prose
```

User views may place these side by side. Model projections label them
explicitly. Normal prose-writing retrieval excludes future plans except the
bounded active runway and protected instructions.

### 8.1 Author conversation and decisions

Author Room stores three separate record families:

- `AuthorConversationThread`: interaction history and bounded summaries
- `NarrativeDecisionProposal`: suggested structured changes awaiting approval
- `AuthorDecision`: an accepted durable decision with affected record versions

Conversation text is provenance, not canon or plan state. Accepting a proposal
creates an `AuthorDecision` and applies its validated record patches in one
story version. Rejecting it preserves proposal history without affecting the
story.

Later model contexts normally retrieve the accepted records and concise
decision, not the full conversation transcript.

### 8.2 Import workspace records

A prose or documentation import creates an isolated package:

- `ImportJob`
- `ImportSource`
- `ImportSourceBlock`
- `ImportStructureCandidate`
- `ImportRecordCandidate`
- `ImportIdentityMatch`
- `ImportConflict`
- `ImportCoverageReport`
- `ImportApprovalBatch`

Candidates carry source evidence and remain outside accepted story retrieval.
Approval creates normal record types; the import candidate remains as
provenance.

## 9. Record Creation Lifecycle

### 9.1 Discovery

Creates candidate intent, contracts, preferences, exclusions, and questions.

### 9.1.1 Prose-only import

Creates imported prose blocks, structural candidates, reconstructed
documentation candidates, identity/conflict reviews, and coverage reports.
The baseline story version does not exist until the user approves and commits
the import package.

### 9.2 Blueprint approval

Accepts story/volume/arc structure and long-range plans.

### 9.3 Chapter preflight

Creates or validates chapter and scene required packages.

### 9.4 Writer pass

Creates prose patch, revision, cursor, capsule, context manifest, provisional
change set, beat evidence, and local findings.

### 9.5 Scene close

Consolidates state, summary, quality result, completion evidence, and
documentation invalidations.

### 9.6 Chapter close

Creates exit snapshot, completion report, final summary, accepted retrieval
chunks, and updates parent arc/volume progress.

### 9.7 Manual edit

Uses the same patch, extraction, validation, and projection-invalidation
pipeline. User edits do not bypass documentation maintenance.

## 10. Human Document Catalog

The `Docs & Plans` workspace renders:

```text
STORY DESIGN
├── Intent & Reader Experience
├── Story Contract
├── Volume Contracts
└── Completion Reports

STORYBOARD
├── Volumes
├── Arcs
├── Chapters
├── Scenes
├── Beat Plans
└── Protected Moments

PEOPLE
├── Character Dossiers
├── Relationship Dossiers
└── Character Knowledge

WORLD
├── Places
├── History & Timeline
├── Cultures & Religions
├── Factions, Politics & Law
├── Economy & Currency
├── Magic / Technology / Progression
└── Creatures, Species & Objects

INFORMATION DESIGN
├── Reader Knowledge
├── Revelations
├── Clues & Mysteries
└── Protected Information

WRITING CONTRACTS
├── Narrator & POV
├── Character Voices
├── Style & Tone
├── Comedy
├── Romance & Relational Texture
├── Information Delivery
└── Quality Gate

ACTIVE TRACKING
├── Arcs
├── Threads
├── Promises
├── Author Decisions
├── Continuity Findings
├── Current Authoring State
└── OOC Suggestions

HISTORY & SOURCES
├── Story Versions
├── Imported Sources
├── Import Candidates & Coverage
├── Provenance
└── Superseded / Rejected Material
```

Human documents support narrative prose descriptions, tables, timelines,
graphs, diffs, filters, and provenance links.

## 11. Model Projection Catalog

Models never receive the human document page by default.

Projection types:

| Projection | Consumer |
|---|---|
| `StoryDirectionProjection` | Director |
| `BeatRunwayProjection` | Director/writer |
| `WriterStateProjection` | Writer |
| `VoiceProjection` | Writer/auditor |
| `EntityStateProjection` | Writer/extractor |
| `InformationBoundaryProjection` | Writer/auditor |
| `ObligationProjection` | Director/writer/auditor |
| `ContinuationProjection` | Writer |
| `ExtractionBaselineProjection` | Extractor |
| `AuditEvidenceProjection` | Auditor |
| `RepairProjection` | Revision coordinator |
| `SuggestionProjection` | Suggestion generator |

Each projection declares:

- source record IDs and revisions
- included fields
- omitted fields
- story position and branch
- token estimate
- deterministic versus retrieved origin
- projection schema version

## 12. Example Character Projection

Human dossier may be several pages. A writer projection might be:

```json
{
  "entity_id": "rorann",
  "position": "chapter-12/scene-3",
  "role": "pov",
  "current": {
    "location": "broodmother chamber",
    "physical": "uninjured after regeneration",
    "goal": "adapt to weaker venom before confronting broodmother",
    "knowledge": ["regeneration adapts after exposure"],
    "unknown": ["Lyra's exact safety plan"]
  },
  "voice": {
    "speech": "literal, concise, clinically observational",
    "internal": "goal-focused; does not label himself absurd",
    "avoid": ["self-aware comedy", "modern therapeutic vocabulary"]
  },
  "relationships": [
    {
      "with": "lyra",
      "dynamic": "protective frustration versus literal efficiency",
      "current_change": "she is increasingly willing to physically intervene"
    }
  ],
  "applicable_rules": ["regeneration.requires_survival", "venom.binds_tissue"],
  "source_record_ids": ["..."]
}
```

## 13. Projection Selection Rules

A record enters a model projection only through:

1. deterministic applicability
2. active beat/scene dependency
3. current entity/relationship participation
4. protected information or constraint relevance
5. ranked retrieval with minimum score
6. explicit user attachment
7. a model's bounded tool request

Record popularity alone is not sufficient.

## 14. Editing Rules

Human edits target structured fields through typed forms or an advanced
record editor.

- Editing a projection writes commands against source records.
- Editing future plans does not rewrite established history.
- Editing established facts may require a retcon or new branch.
- Conflicting edits create explicit conflicts.
- Deleting a projection is not equivalent to deleting its records.
- Required package records may be superseded but not silently removed.
- Provenance remains after supersession.

## 15. Projection Invalidation

Each projection records dependency IDs and revisions.

When a source changes:

1. mark affected cached projections stale
2. update fast summary fields synchronously when required by the next pass
3. rebuild human pages and embeddings asynchronously
4. never serve a stale projection as if it matches the current story version

## 16. Documentation Update Authority

Writer role:

- no documentation mutation

Author collaborator:

- reads story records and proposes decision/record patches
- cannot accept its own proposals

Extractor role:

- proposes evidence-backed change sets

Application layer:

- validates, applies provisional updates, closes validity ranges, records
  conflicts

Scene/chapter transaction:

- promotes validated records at the boundary selected by the user's authoring
  command: passage, scene, or chapter

User:

- may edit, accept, reject, waive, supersede, or retcon through service
  commands

## 17. Retention and Deletion

Retain:

- accepted and superseded record revisions
- provenance
- accepted/rejected prose revisions
- context manifests for committed prose
- audit and extraction results supporting accepted versions

May compact:

- expired continuation capsules after preserving their metadata/hash
- verbose model tool transcripts not needed for provenance
- cached human projections
- stale suggestions

Never use hard deletion for material referenced by an accepted story version.

## 18. Document-Model Tests

- Author Room transcript alone never changes a story projection
- accepted decision proposal creates durable decision and record revisions
- prose-only import candidates remain isolated until baseline approval
- every reconstructed established fact links to exact imported prose evidence
- every new story creates its required story package
- volume cannot enter active drafting without required volume records
- chapter job cannot start without required chapter/scene package
- planned and established values remain distinguishable in all projections
- a human character dossier and writer projection derive from the same records
- changing position produces historically correct state
- future knowledge is absent from writer projection
- source update invalidates every dependent cached view
- user edit routes through versioned commands
- manual prose edit triggers extraction and documentation maintenance
- superseded material remains attributable but excluded from normal retrieval
