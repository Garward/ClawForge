# ClawForge Narrative Studio UI and Web Architecture

Status: Draft
Companion: `docs/narrative-system-design.md`
Index: [Narrative Studio Design Index](narrative-design-index.md)

## 1. Decision

Narrative Studio should be a first-class page served by the existing ClawForge
web adapter:

```text
http://127.0.0.1:8081/            Chat
http://127.0.0.1:8081/narrative   Narrative Studio
```

It should reuse ClawForge's visual language and familiar controls while
providing a task-specific authoring workspace.

PyQt is not recommended for the initial implementation. A separate desktop UI
would duplicate:

- theme and component work
- model and provider controls
- authentication and configuration
- background-job presentation
- streaming and cancellation behavior
- session and version navigation
- cross-platform packaging

The web application can later be embedded in Qt WebEngine, Tauri, or another
desktop shell without changing the narrative service.

Narrative Studio is a web surface, not a place to put narrative domain logic.
The UI calls `NarrativeService`; it does not edit SQLite directly or build
model prompts.

## 2. Existing ClawForge Patterns to Preserve

The existing web interface establishes:

- dark Forge theme
- orange primary accent
- 48-pixel global header
- persistent left sidebar
- compact controls and squared two-pixel radii
- model selection in the header
- connection and job status
- streaming output
- expandable tool/job details
- configuration drawers and modals
- background cancellation and steering

Narrative Studio should reuse shared design tokens:

```css
--bg-deep: #0d0d0d;
--bg-primary: #1a1a1a;
--bg-sidebar: #141414;
--bg-header: #111111;
--bg-input: #0f0f0f;
--accent-primary: #d4760a;
--accent-hover: #f59e0b;
--text-primary: #e5e5e5;
--text-secondary: #94a3b8;
--text-muted: #64748b;
--border-primary: #2a2a2a;
--radius: 2px;
```

Narrative-specific colors are semantic and secondary:

- structure: muted blue
- character and relationship: muted violet
- world and information: muted teal
- accepted/canonical: green
- candidate/provisional: orange
- warning/conflict: amber
- rejected/superseded: muted red/gray

Color is never the only status indicator.

### 2.1 Reader reference

The reference reader at:

`<story-workspace>/books/reader/example-story.html`

establishes several useful reading patterns:

- serif prose typography using Georgia/Times-style fallbacks
- approximately 1.1rem prose with 1.8 line height
- generous chapter padding
- bounded 1200-pixel application width
- one chapter displayed at a time
- table-of-contents drawer
- previous/next chapter navigation
- reading progress
- saved reading position
- fullscreen
- selectable dark reading themes

Narrative Studio should preserve those principles while simplifying the number
of visual themes and applying the ClawForge shell, orange accent, status
language, and component patterns.

The reference reader embeds all chapter prose, CSS, and JavaScript into one
large generated HTML file. Narrative Studio should not preserve that
implementation detail. It fetches the selected chapter from versioned storage
and keeps styling, components, and prose data separate.

## 3. Product Principles

### 3.1 Familiar shell, specialized workspace

Users should recognize ClawForge immediately, but Narrative Studio should not
look like a chat window with extra buttons.

### 3.2 Structure and prose remain connected

The user should be able to move from volume contract to arc, chapter, scene,
and prose without losing the surrounding purpose and state.

### 3.3 AI work is visible but not intrusive

Generation appears as proposals, streaming prose, findings, version changes,
and contextual recommendations. Routine documentation updates do not open
approval dialogs.

### 3.4 Canonical state is legible

Candidate, accepted, conflicted, inferred, and superseded material must be
visually distinguishable.

### 3.5 Progressive disclosure

The interface should not show the outline, story bible, timeline, prompt
manifest, audits, and prose editor simultaneously. Workspace modes expose the
information relevant to the current task.

### 3.6 Autosave with trustworthy undo

Manual edits autosave. AI operations create story versions. The header always
shows save state, current version, and undo availability.

### 3.7 Manuscript-first book IDE

The manuscript is the primary artifact. Planning, documentation, AI assistance,
and auditing surround it rather than replacing it.

Read, Edit, and Review are modes of one `ManuscriptCanvas`, not separate
representations that may drift apart:

- `Read`: clean publication-like rendering with all authoring marks hidden
- `Edit`: the same typography and dimensions with editable prose and restrained
  structural affordances
- `Review`: the same prose with findings, provenance, and version differences
  available as annotations

The selected chapter, scroll position, text selection, and reader preferences
survive mode changes.

## 4. Global Application Shell

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ClawForge  [Chat] [Narrative Studio]  Rorann's Rage ▾ Author Room Model ▾ ⚙│
├──────────────────┬───────────────────────────────────────────┬───────────────┤
│ Story navigation │ Current workspace                         │ Suggestions   │
│                  │                                           │               │
│ Dashboard        │                                           │ Contextual    │
│ Author Room      │                                           │ information   │
│ Discovery        │                                           │ and controls  │
│ Import & Sources │                                           │               │
│ Blueprint        │                                           │               │
│ Manuscript       │                                           │               │
│ Docs & Plans     │                                           │               │
│ Characters       │                                           │               │
│ Relationships    │                                           │               │
│ World            │                                           │               │
│ Timeline         │                                           │               │
│ Threads          │                                           │               │
│ Style & Voice    │                                           │               │
│ Review           │                                           │               │
├──────────────────┴───────────────────────────────────────────┴───────────────┤
│ Background jobs / generation stream / findings drawer                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Header

Left:

- ClawForge logo
- `Chat` and `Narrative` surface switcher
- responsive navigation toggle

Center:

- story selector
- active volume and branch
- selected story-position breadcrumb
- authoring-mode badge: Author Room, Discovery, Blueprint, Writing, Revision,
  Playback
- connection and autosave state

Right:

- manuscript mode switch when applicable: Read, Edit, Review
- active generation model
- background-job indicator
- version history and undo
- compile/export
- settings

The model selector may have per-role overrides in settings, but the header
shows the active role/model for the current operation.

#### 4.1.1 Model selection

Narrative Studio reuses the normal web adapter's existing searchable,
provider-grouped model dropdown and provider-prefixed model IDs. The dropdown
continues to use the shared `/api/models` catalog, including live Ollama
discovery and OpenRouter pricing where available.

The Narrative header displays:

```text
[Passage Writer] [anthropic:claude-sonnet-4-6 ▾]
```

The role label is explicit so changing a model is never ambiguous.

The dropdown includes:

- `Inherit story default`
- `Inherit Narrative/daemon default`
- provider groups and searchable model entries
- price labels when known
- compatibility warning or disabled state for roles requiring tools
- effective context-window and budget summary

`Story model settings` exposes a role matrix:

| Role | Model | Budget | Timeout |
|---|---|---:|---:|
| Story default | daemon default | inherited | inherited |
| Author Room | inherit | role default | role default |
| Discovery | inherit | role default | role default |
| Director | inherit | role default | role default |
| Passage Writer | selected model | 6–12K | configured |
| Extractor | faster model or inherit | 4–8K | configured |
| Auditor | inherit | 16–28K | configured |
| Repair | writer or inherit | 6–14K | configured |
| Suggestions | faster model or inherit | 6–12K | configured |
| Importer | inherit | 8–16K | configured |

Changing story settings affects new one-turn operations and future jobs.
Active jobs show a `Pinned for this job` badge. Applying a different model to
an active job requires an explicit `Use from next safe pass` action and is
recorded in job history.

Narrative model choices persist in the story's `NarrativeModelProfile`, not in
the selected generic chat session.

#### 4.1.2 Entering Narrative Studio

The global header permanently exposes the surface switcher immediately after
the ClawForge brand:

```text
ClawForge v0.2  │  Chat  Narrative Studio
```

In the current Web Adapter layout, it occupies the unused top-bar space to the
right of the logo and before the centered daemon status. The active surface
uses the existing orange accent, restrained underline/background, and keyboard
focus treatment. It is not hidden in Settings or the chat-session sidebar.

Behavior:

- `Chat` opens the existing chat surface at `/`.
- `Narrative Studio` opens `/narrative`.
- Switching to Narrative replaces the left `Sessions` sidebar with the story
  and workspace navigation.
- Switching back restores the previous chat session and scroll position.
- Returning to Narrative restores the last story, workspace, selected node,
  and manuscript position.
- Direct/deep Narrative URLs remain bookmarkable.

First entry:

```text
No stories
→ Narrative welcome
→ [Create Story] [Import Manuscript] [Import Documentation]

Existing stories
→ last Narrative location, when valid
→ otherwise Story Dashboard
```

The shared shell changes surfaces through client routing rather than opening a
second port or separate desktop window. Background jobs continue running while
the user moves between Chat and Narrative. If an existing non-resumable
foreground chat stream would be interrupted by navigation, the UI warns or
waits for its safe completion; the switch itself never implies job
cancellation.

Responsive behavior:

- wide header: `Chat` and `Narrative Studio` text tabs
- narrow header: compact chat/book icons with accessible labels
- keyboard: the surface switcher is reachable before surface-specific
  navigation

### 4.2 Story navigation

The left sidebar changes from chat sessions to story workspaces:

- Dashboard
- Author Room
- Discovery
- Import & Sources
- Blueprint
- Manuscript
- Docs & Plans
- Characters
- Relationships
- World
- Timeline
- Arcs, Threads & Promises
- Style, Voice & Craft
- Review & Continuity

The lower section contains:

- recent scenes
- bookmarked records
- active generation jobs
- story settings

### 4.3 Suggestions and Inspector rail

The right rail has three tabs:

- Suggestions
- Inspector
- Context Used

Suggestions is the default while writing. It is explicitly labeled
out-of-character and displays:

- recommended next directions
- opportunities for callbacks, promises, relationships, comedy, revelations,
  action, or quiet character grounding
- continuity and pacing risks
- questions worth resolving before the next scene

Suggestion cards show rationale, affected narrative tracks, related records,
confidence, and story version. The user can pin, use, dismiss, or ask for
alternatives. They never become canon merely by appearing.

Suggestions refresh after prose and automatic documentation updates. Stale
suggestions remain visible only in history or when pinned.

Inspector follows current selection:

- volume contract
- arc purpose
- chapter quality gate
- scene card and narrative tracks
- current pacing envelope: recent movement, active beat, lookahead, and
  remaining scene/chapter space
- pending protected quotes and moments in the current placement window
- next-pass continuation capsule
- character state
- relationship state
- open promises
- revelation instructions
- voice contracts
- routed craft skills
- continuity findings
- provenance and source spans

Context Used displays the latest operation's context manifest:

- deterministically loaded records
- retrieved summaries and prose excerpts
- narrative tools called
- craft skills loaded
- target, actual, and hard-ceiling token allocation
- excluded or summarized items and the reason for each decision
- output reserve and remaining safety margin

Before generation, this tab shows a context preview grouped by:

- required contracts
- next-pass continuation capsule
- hierarchical pacing envelope
- current story state
- structural plan
- relevant documentation
- exact prose
- retrieved excerpts
- user-attached material

The preview uses concise titles and token estimates rather than exposing a
wall of serialized prompt text. Each item can be opened at its source record.
User-controlled items can be attached or removed here; system-required
constraints are visibly locked. After generation, estimates are replaced by
the final manifest actually sent to the model.

The pacing-envelope group is always visible for new prose. It shows the
volume/arc/chapter/scene/beat trajectory in compact form and reports whether
the pacing-sufficiency preflight passed. If the current obligation, immediate
lookbehind, lookahead, exit condition, or remaining narrative space is
unknown, writing is blocked while the director plans or retrieves the missing
information.

The continuation capsule appears as a compact `Next pass handoff` card. It
shows required and preferred items, remaining pass lifetime, and source prose
links. The user can pin, edit, or remove model-proposed items; system-derived
physical state and other hard continuity items are locked unless the prose or
story state is corrected. Capsule history remains inspectable per patch but
only the active bounded capsule is injected.

For a whole-chapter job, Context Used shows a stage switcher:

- chapter architecture
- each scene and passage patch
- chapter audit
- repair, when run

This avoids misleading the user into thinking one enormous context packet was
used for the entire chapter.

The rail can collapse to preserve writing width.

### 4.4 Job drawer

The bottom drawer reuses existing ClawForge background-job patterns:

- queued/running/completed state
- current chapter, scene, beat, and anchored prose cursor
- current stage: planning, retrieval, patching, extraction, local check,
  scene gate, chapter audit, repair
- accepted patch count, words written, remaining beats, and job ceilings
- active next-pass handoff and items consumed by the latest patch
- small candidate/accepted prose patches and structured progress
- pause, resume, cancel, and steer
- context-manifest access
- audit findings
- documentation changes

`Write chapter` starts this job loop; it does not stream a chapter-sized model
completion. The drawer advances passage by passage and can pause cleanly after
any accepted patch. Steering applies at the next patch boundary unless the
current tool call can be safely cancelled.

Completed routine jobs collapse automatically.

### 4.5 Persistent story position

The active story position is always visible as a breadcrumb:

```text
Volume 1 / Arc 2: Broken Trust / Chapter 12 / Scene 3: Venom Training
```

Selecting a volume, arc, chapter, scene, documentation record, or prose range
changes:

- the central workspace
- the Inspector contents
- the Suggestions scope
- the model's operation profile
- deterministic context and permitted retrieval
- available authoring actions

Selection is therefore part of the model request, not merely UI navigation.
The currently selected node is visually distinct in every tree, outline, and
timeline view.

### 4.6 Reading and focus layouts

Normal authoring layout keeps navigation and the right rail available.

Reader focus layout hides both rails and reduces the header to:

- ClawForge/story identity
- chapter title and progress
- Read/Edit/Review mode
- Contents
- typography preferences
- fullscreen/exit focus

Moving the pointer or using a keyboard shortcut reveals controls; prose remains
stable and does not reflow unnecessarily.

Editor focus layout keeps the same centered manuscript but permits opening the
Suggestions rail as an overlay. AI assistance therefore remains available
without permanently narrowing the reading column.

## 5. Primary Workspaces

### 5.1 Story Dashboard

Purpose: answer "Where is this story, and what needs attention?"

Cards:

- active volume and progress
- current branch and head scene
- latest prose
- open arcs and threads
- high-salience overdue promises
- upcoming milestones
- unresolved continuity conflicts
- current relationship trajectories
- reader-understanding state for major mysteries
- recent automatic documentation changes

Primary actions:

- Continue writing
- Continue discovery
- Plan next arc
- Review blueprint
- Run boundary audit
- Compile current branch

The dashboard avoids vanity metrics. Word count is useful, but story-state
movement and unresolved obligations are more important.

### 5.2 Discovery

```text
┌──────────────────────── Interview ───────────────────────┬─ Living Brief ───┐
│                                                         │ Story promise     │
│ Model question and explanation                          │ Hard intent       │
│                                                         │ Soft intent       │
│ [Option A]  [Option B]  [Option C]                      │ Provisional       │
│                                                         │ Open questions    │
│ User response                                           │ Tensions          │
│                                                         │ Readiness         │
│ Why this matters / recommendation                       │                   │
│                                                         │                   │
│ [Explore alternatives] [Answer provisionally]           │                   │
└─────────────────────────────────────────────────────────┴───────────────────┘
```

The interview resembles chat because conversation is the right interaction
here, but every answer updates the structured brief immediately.

Features:

- question history grouped by topic
- option cards with consequences
- free-form answer
- "I don't know—help me explore"
- commitment control: hard, soft, provisional
- revisit previous decision
- design-tension warnings
- story/volume/arc readiness checklist
- approve design brief

The living brief is editable without requiring the user to locate the original
conversation turn.

#### 5.2.1 Author Room

Author Room is a normal story-aware conversation workspace:

```text
┌─ Story Scope ─────┬──────────── Conversation ────────────┬─ Proposals ──────┐
│ Main branch       │ User: Would Lyra trust him here?     │ Decision pending │
│ Volume 1          │                                      │ Records affected │
│ Arc 2             │ Collaborator answer with evidence    │ Consequences     │
│ Chapter 12        │ and links to story records.          │ Conflicts        │
│                   │                                      │                  │
│ Attached          │ [Ask follow-up...]                   │ [Accept] [Edit]  │
└───────────────────┴──────────────────────────────────────┴──────────────────┘
```

The user can:

- select story, volume, arc, chapter, scene, or prose scope
- attach documentation records or manuscript excerpts
- ask factual, structural, creative, or continuity questions
- brainstorm without changing anything
- request alternatives and consequences
- ask the collaborator to turn a conclusion into a decision proposal
- accept, edit, reject, or continue discussing a proposal

The collaborator uses compact story tools and cites record/prose evidence.
Conversation is not automatically injected into writing jobs. Accepted
decisions update structured records; later jobs retrieve those records.

The right rail separates:

- pending decision proposals
- proposed record changes
- affected plans and canon
- unresolved questions
- accepted decisions from this thread

#### 5.2.2 Import & Sources

The import workspace offers:

- documentation import
- prose-only documentation reconstruction
- combined manuscript and documentation import

Prose-only import displays staged review tabs:

```text
Structure
→ Characters & Aliases
→ Relationships
→ World & Rules
→ Timeline & State
→ Knowledge & Revelations
→ Arcs, Threads & Promises
→ Voice, Style & Craft
→ Baseline Commit
```

Every candidate shows its exact manuscript evidence, confidence, conflicts,
and proposed classification as established or inferred. The user can accept,
edit, merge, reject, or defer individual candidates and can batch-accept a
reviewed conflict-free group.

A coverage panel shows:

- processed and unprocessed chapters
- extraction confidence by document family
- unresolved identities
- contradictions
- facts lacking exact evidence
- inferred authorial intent that requires confirmation

Nothing enters canonical retrieval until `Commit baseline story version`.

### 5.3 Volume Contract

Displayed inside Discovery or Blueprint:

- entering state
- target plot state
- target character changes
- target relationship changes
- target reader knowledge/suspicion
- revelation methods
- promises to pay off, defer, or introduce
- desired final emotional effect
- next-volume hooks

Each target is marked required, preferred, provisional, or prohibited.

The user can ask for:

- completeness critique
- alternative destinations
- risk analysis
- arc recommendations

### 5.4 Blueprint

Blueprint has three synchronized views:

1. Hierarchy tree
2. Arc recommendation board
3. Selected-node inspector

```text
┌─ Structure ────────┬─ Arc Board ───────────────────────────┬─ Arc Inspector ─┐
│ Volume 1           │ Candidate A   Candidate B              │ Purpose         │
│ ├─ Arc 1           │ ┌─────────┐   ┌─────────┐              │ Entering state  │
│ │  ├─ Ch 1         │ │ Mystery │   │ Rivalry │              │ Exit state      │
│ │  └─ Ch 2         │ │ + trust │   │ + action│              │ Revelations     │
│ ├─ Arc 2           │ └─────────┘   └─────────┘              │ Tracks advanced │
│ └─ Unplanned       │                                        │ Risks           │
└────────────────────┴────────────────────────────────────────┴────────────────┘
```

Hierarchy interactions:

- expand/collapse
- drag to reorder within valid structural scope
- add act, arc, chapter, scene, or beat
- duplicate as candidate branch
- lock accepted structure
- mark flexible planning horizon
- open a chapter or scene beat plan

The beat-plan editor presents an ordered runway rather than a prose outline.
Each beat shows:

- purpose and completion test
- entry and intended exit change
- pacing weight
- required, preferred, conditional, or optional status
- information delivered or withheld
- protected quotes and moments
- dependencies and allowed ordering

Protected moment cards distinguish:

- `Verbatim`: exact wording must enter writer context unchanged
- `Semantic`: meaning and function must be preserved
- `Inspirational`: optional creative target

Pending anchors remain visibly attached to their placement window. Placed
anchors link to their exact manuscript span; conflicts can be revised, moved,
waived, or left pending, but never disappear silently.

Arc cards show:

- dramatic engine
- entering and exit state
- narrative tracks advanced
- revelation strategy
- entertainment profile
- setup/payoff
- risks

The user can select, combine, edit, or request alternatives.

The first implementation uses a hierarchy and edge list. A visual node graph
is useful for branching stories but should not delay the linear-authoring MVP.

Selecting hierarchy levels changes model behavior:

- volume selection offers destination and arc architecture operations
- arc selection offers escalation, progression, and revelation operations
- chapter selection offers chapter-shape and scene-sequencing operations
- scene selection offers direction, drafting, and local auditing operations

The selection breadcrumb and active operation mode update immediately.

### 5.5 Manuscript

```text
┌─ Contents ────────┬──────────── Manuscript Canvas ─────────────┬─ Suggestions ──┐
│ Ch 12             │ [Read] [Edit] [Review]      43%  Aa  ⛶    │ Pay off manual │
│ ├─ Arrival        │                                            │ Hint adaptation│
│ ├─ Training       │ Chapter Twelve                             │ Let Lyra redirect
│ └─ Consequence    │ Venom Resistance Training, Apparently      │ Continuity risk│
│                   │                                            │                │
│ Ch 13             │ Rorann crouched beside the ruptured sac... │ [Inspector]    │
│                   │                                            │ [Context Used] │
├───────────────────┴────────────────────────────────────────────┴────────────────┤
│ Prev chapter [Offer 4 directions] [Write passage] [Write chapter] [Audit] Next │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Reader mode

Reader mode is the clarity baseline:

- serif prose font
- configurable font size, line height, and reading-column width
- recommended column width of approximately 68–78 characters
- generous paragraph spacing
- visually quiet chapter title
- no audit marks, scene boundaries, AI controls, or status chips inside prose
- one chapter loaded as the primary reading unit
- previous/next chapter navigation
- Contents drawer with chapter status
- chapter and volume progress
- saved chapter and scroll position
- fullscreen and focus modes

Default Forge reading values:

```css
--reader-font: Georgia, "Times New Roman", serif;
--reader-size: clamp(17px, 1.1vw, 20px);
--reader-line-height: 1.75;
--reader-width: 74ch;
--reader-canvas: #1a1a1a;
--reader-text: #dedede;
```

The reader canvas should have a quieter surface than general UI panels.
ClawForge orange is used for controls and progress, not prose text.

#### Edit mode

Edit mode preserves reader typography and line measure. It adds:

- editable paragraph and scene blocks
- autosave with debounce
- restrained scene-boundary controls in the gutter
- selection-based revision
- selection actions: revise, expand, tighten, check voice, inspect context
- bounded prose patches as visible candidate continuations
- live chapter-agent cursor and pause/steer controls
- side-by-side or inline revision comparison
- accept candidate direction before generation
- undo by story version
- optional Suggestions, Inspector, or Context Used rail

Editing must not expose raw storage JSON or make prose resemble source code.
Markdown shortcuts may be supported, but chapter and scene structure comes
from narrative nodes rather than heading syntax alone.

#### Review mode

Review mode preserves the same line wrapping while adding:

- subtle finding underlines
- comment markers in the outer gutter
- voice/provenance overlays on request
- accepted/candidate revision comparison
- chapter quality-gate summary
- repair controls in the right rail

Annotations must not shift prose position when toggled. This keeps reading,
editing, and reviewing perceptually connected.

#### Manuscript canvas architecture

`ManuscriptCanvas` is backed by a swappable editor adapter:

- reader renderer
- initial dependable block/text editor
- future richer editor

All adapters read and write the same chapter revision model. The MVP should
prioritize reliable text handling, selection stability, undo, and identical
read/edit line wrapping over advanced formatting.

Only the current chapter and small adjacent metadata are loaded initially.
Adjacent chapters may be prefetched, while old chapters are retrieved through
summaries, excerpts, or explicit reads for model context.

The scene inspector displays only high-value active context. Full
documentation remains one click away.

The right rail refreshes only after the accepted prose version, documentation
changes, and audit findings are available. This ensures recommendations are
based on what was actually written rather than the pre-draft plan.

### 5.6 Docs & Plans

This is the fast, readable view of the system-maintained authoring material.

The workspace uses a fixed hierarchy rather than exposing arbitrary files:

```text
STORY DESIGN
├── Intent & Reader Experience
├── Series / Story Contract
└── Volume Contracts

STORYBOARD
├── Volumes
│   └── Acts / Arcs
│       └── Chapters
│           └── Scenes / Beats
├── Milestones
└── Branches

PEOPLE
├── Characters
├── Relationships
└── Character Knowledge

WORLD
├── Places & Geography
├── History & Timeline
├── Cultures & Religions
├── Factions, Politics & Law
├── Economy, Currency & Trade
├── Magic / Technology / Progression
└── Creatures, Species & Objects

INFORMATION DESIGN
├── Reader Knowledge
├── Revelations
├── Clues & Mysteries
└── Hidden / Protected Information

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
├── Story Promises
├── Continuity Findings
└── OOC Suggestions

HISTORY & SOURCES
├── Story Versions
├── Imported Documents
├── Provenance
└── Superseded / Rejected Material
```

The top-level view has two presentation tabs:

- `Plans`: future intent, structure, milestones, revelations, and promises
- `Current Documentation`: what is established at the selected story position

The hierarchy remains stable between tabs. For example, a character page can
show current established state beside planned arc milestones without merging
them.

Controls:

- story-position selector
- current versus future-plan visibility
- canonical, inferred, conflicted, and superseded filters
- branch selector
- source/provenance toggle
- search
- pin to Inspector
- attach to next model operation

The default view shows concise generated documentation, not raw rows or JSON.
Advanced views expose structured records and provenance when needed.

Docs & Plans can be opened from:

- the permanent left navigation
- `Open full documentation` in the Inspector
- clicking an entity, promise, revelation, or plan link
- the manuscript selection menu
- the command palette
- a suggestion card's related-record links

The right rail can display a pinned documentation card while the manuscript
remains centered. Opening the full workspace is only necessary for broader
reading or editing.

Each documentation record has a context control:

- `Auto`: the context builder includes it only when relevant
- `Attach once`: include it in the next operation
- `Pin for node`: include it for operations on the selected story node
- `Exclude from semantic retrieval`: available through explicit tools only

System-required facts and hard constraints cannot be excluded from operations
where they apply.

Selecting a documentation section changes the model to documentation-analysis
mode. It can explain implications, find conflicts, or propose updates without
accidentally drafting prose.

### 5.7 Characters

List and detail layout:

- identity, aliases, role
- current state at selected story position
- traits, goals, wounds, contradictions
- possessions, abilities, knowledge
- voice fingerprint
- humor and intimacy profile
- arc and milestones
- relationship graph
- state timeline
- source provenance

A story-position scrubber shows how the dossier changes over time without
mixing future plans into current state.

### 5.8 Relationships

Views:

- relationship list
- selected pair/group profile
- phase and current dynamic
- trust, intimacy, conflict, obligation, and power
- milestone timeline
- planned versus established progression
- relevant prose moments
- comedy dynamics
- unresolved relationship promises

This view must represent friendships, family, rivalry, mentorship, loyalty, and
other non-romantic relationships equally well.

### 5.9 World

Generated documentation projections:

- places and geography
- cultures and religions
- factions and politics
- currencies and economy
- technology and magic
- combat and progression systems
- creatures and species
- terminology and aliases

Each record shows:

- canonical statement
- validity and discovery range
- who knows it
- how readers learned or will learn it
- sources
- conflicts

### 5.10 Timeline and Reader Knowledge

Timeline layers:

- objective event chronology
- chapter/scene presentation order
- per-character knowledge
- modeled reader understanding
- planned revelations and clue chains

Filters prevent this from becoming one unreadable graph.

### 5.11 Arcs, Threads & Promises

Kanban/list modes:

- introduced/open
- reinforced/advanced
- complicated
- due soon
- paid off/resolved
- deferred
- overdue/conflicted

Items show salience, expected window, linked scenes, entities, and evidence.

### 5.12 Style, Voice & Craft

Panels:

- narrator contract
- POV permeability
- character voice fingerprints
- tone and protected moments
- comedy contract and humor profiles
- romance/relational profile
- information-delivery contract
- enabled craft skills
- positive and negative exemplars
- ordered quality-gate rubric

The UI edits structured fields while offering an advanced JSON view for
debugging.

### 5.13 Review & Continuity

Findings are grouped by priority and scope:

- engagement
- voice and immersion
- story movement
- character logic
- revelation
- promises and consequences
- tonal integration
- continuity
- prose mechanics
- chapter shape

Each finding includes:

- severity
- exact prose spans
- evidence
- affected structured records
- suggested repair
- status

Actions:

- repair selected
- repair all compatible findings
- mark intentional
- defer
- inspect source/context manifest

Specialist and boundary audits are launched here.

## 6. Core Interaction Flows

### 6.1 New story

```text
Create story
→ Discovery interview
→ Approve intent brief
→ Define Volume 1 contract
→ Review arc recommendations
→ Select/combine arcs
→ Generate initial blueprint
→ Approve writing horizon
→ Approve the first chapter and scene beat plan
→ Draft first scene
```

### 6.1.1 Import existing story

```text
Choose import type
→ Register manuscript and/or documentation sources
→ Detect structure
→ Extract candidate documentation with exact evidence
→ Review structure and identities
→ Review documentation families
→ Resolve conflicts and inferred intent
→ Commit approved baseline story version
→ Open Dashboard, Author Room, or Blueprint
```

### 6.2 Continue story

```text
Open dashboard
→ Continue at active scene
→ Review 4 proposed directions
→ Select/edit direction
→ Stream prose
→ Automatic extraction/documentation/audit
→ OOC suggestion board refreshes from committed state
→ New version appears with undo
```

### 6.3 Manual edit

```text
Edit prose
→ Autosave working revision
→ Pause detects completed edit
→ Re-extract affected scene only
→ Update documentation and findings
→ Commit version
```

Large manual edits should require an explicit "Finish edit" action to avoid
running extraction repeatedly while the user is typing.

### 6.4 Revise from finding

```text
Select finding
→ Highlight evidence and affected context
→ Show proposed repair constraints
→ Stream candidate revision
→ Compare
→ Accept automatically when launched as selected repair
→ Undo available
```

### 6.5 Read, notice, edit, continue

```text
Read chapter in focus mode
→ Notice a weak or incorrect passage
→ Select text and switch to Edit without reflow
→ Edit directly or request an AI revision
→ Review diff in place
→ Commit version
→ Return to clean Read mode at the same position
→ Continue to next chapter
```

## 7. Front-End Architecture

The existing `src/adapters/web/index.html` is a large single-file application.
Narrative Studio should not extend that pattern.

Proposed layout:

```text
src/adapters/web/
├── index.html
├── shared/
│   ├── theme.css
│   ├── shell.css
│   ├── api.js
│   ├── sse.js
│   ├── dropdown.js
│   └── modal.js
└── narrative/
    ├── index.html
    ├── narrative.css
    ├── app.js
    ├── router.js
    ├── store.js
    ├── api.js
    ├── components/
    │   ├── app-shell.js
    │   ├── story-nav.js
    │   ├── inspector.js
    │   ├── suggestion-board.js
    │   ├── context-manifest.js
    │   ├── manuscript-canvas.js
    │   ├── reader-controls.js
    │   ├── contents-drawer.js
    │   ├── job-drawer.js
    │   ├── status-chip.js
    │   └── revision-diff.js
    └── workspaces/
        ├── dashboard.js
        ├── author-room.js
        ├── discovery.js
        ├── import-sources.js
        ├── blueprint.js
        ├── manuscript.js
        ├── docs-plans.js
        ├── characters.js
        ├── relationships.js
        ├── world.js
        ├── timeline.js
        ├── promises.js
        ├── style.js
        └── review.js
```

### 7.1 Technology recommendation

Start with browser-native ES modules and shared CSS tokens:

- no separate Node build required
- consistent with current ClawForge deployment
- modules instead of one monolithic HTML file
- small reusable component functions or Web Components
- native History API for `/narrative/...` routes
- normalized client store

If interaction complexity later makes this cumbersome, the page can migrate to
a component framework without changing its APIs. The backend must not depend
on frontend framework details.

### 7.2 State ownership

Server-owned canonical state:

- story versions
- structure
- facts and documentation
- prose revisions
- jobs and findings
- versioned OOC suggestions

Client-owned view state:

- selected workspace and record
- active story-position selection
- panel widths/collapse state
- filters
- unsaved input
- manuscript mode, reading preferences, chapter, and scroll position
- open modals

The client store is a normalized cache keyed by stable UUID. Domain events
update the cache. If an event version is skipped, the client reloads the story
snapshot.

### 7.3 Routing

Browser routes:

```text
/                                      # Chat
/narrative
/narrative/story/:storyId/author-room
/narrative/story/:storyId/discovery
/narrative/story/:storyId/import
/narrative/story/:storyId/blueprint
/narrative/story/:storyId/manuscript/:nodeId
/narrative/story/:storyId/characters/:entityId
/narrative/story/:storyId/relationships/:entityId
/narrative/story/:storyId/world/:entityId
/narrative/story/:storyId/timeline
/narrative/story/:storyId/review
```

The web adapter serves `narrative/index.html` as the fallback for these routes.
The client stores the last valid route for each surface independently.

## 8. Backend Web Architecture

### 8.1 Same-origin controller

Add a narrative HTTP controller beneath the web adapter:

```text
WebAdapter
    └── WebRouter
        ├── ChatWebController
        ├── StaticController
        └── NarrativeWebController
                └── NarrativeService
```

The controller parses HTTP, validates IDs and request schemas, calls the
service, and serializes responses. It does not contain narrative workflows or
SQL.

Suggested web transport modules:

```text
src/adapters/
├── web_adapter.zig               # listener lifecycle and router delegation
└── web/
    ├── router.zig
    ├── request.zig
    ├── response.zig
    ├── sse_writer.zig
    ├── chat_controller.zig
    ├── static_controller.zig
    └── narrative_controller.zig
```

The narrative subsystem itself lives under `src/narrative/` as specified in
the system architecture. The controller imports only its public
`narrative/root.zig` API.

`web_adapter.zig` should not gain a narrative route for every command. It
delegates the `/narrative` and `/api/narrative/v1` prefixes to one controller.
The controller uses a compact route table and typed request DTOs rather than a
large chain of narrative-specific `if` statements.

This is not initially registered as another formal ClawForge `Adapter` because
it shares the existing HTTP listener and origin. It is a separate controller
and application subsystem. A future independently hosted narrative service
can add a true adapter without moving story logic.

### 8.2 Connection concurrency

The current web adapter accepts a connection and handles it inline on one
adapter thread. Long-running generation or SSE would prevent that thread from
accepting other requests.

Before Narrative Studio streaming, the web server needs:

- a lightweight accept loop
- a bounded connection worker pool
- request body and connection limits
- per-request ownership of buffers
- no shared mutable per-turn engine state
- graceful shutdown and worker joining

Static files and short reads run on connection workers. Narrative generation
is always enqueued as a job rather than executed on an HTTP worker.

### 8.3 Narrative runtime

Narrative jobs use:

- explicit story, branch, node, session, and expected-version IDs
- a dedicated NarrativeService runtime
- per-worker SQLite connections
- provider registry shared read-only or through a synchronized interface
- request-scoped context and tool state
- job cancellation token
- typed event stream

They must not depend on ClawForge's process-wide active session.

### 8.4 Narrative model invocation

Narrative Studio does not call the normal chat path with a long replayed
message history.

Each operation creates a fresh `NarrativeOperationRequest`:

```json
{
  "story_id": "uuid",
  "branch_id": "uuid",
  "story_version": 42,
  "selection": {
    "kind": "scene",
    "id": "uuid"
  },
  "operation": "start_chapter_authoring_job",
  "user_instruction": "Keep Lyra's reaction restrained at first.",
  "conversation_refs": []
}
```

`NarrativeContextBuilder` derives the prompt from:

- selection-specific operation profile
- structured plans and documentation
- current branch state
- directly relevant prose boundary
- routed craft skills
- bounded retrieval

The generic chat session remains available for author interaction history, but
its compacted messages are not automatically supplied to drafting calls.
Durable user decisions are stored in the narrative model and retrieved from
there.

ClawForge should factor reusable provider resolution, streaming, and tool-loop
mechanics out of the chat engine where necessary. Narrative Studio reuses
those mechanics without inheriting generic chat prompt assembly.

The current `/api/models` behavior should be preserved behind the shared
inference `ModelCatalog`. The existing web selector and Narrative selector use
the same response and identifiers; Narrative must not maintain a second
hard-coded model list.

The normalized response may extend existing model objects with optional
capability and context-window fields while remaining compatible with string
entries:

```json
{
  "id": "openrouter:provider/model",
  "context_window": 131072,
  "supports_tools": true,
  "supports_structured_output": true,
  "supports_streaming": true,
  "input_cost": "0.000003",
  "output_cost": "0.000015"
}
```

### 8.5 Job event bus

Each job has an ordered event stream:

```json
{
  "job_id": "uuid",
  "sequence": 17,
  "story_version": 42,
  "type": "prose_patch_accepted",
  "payload": {
    "revision_id": "uuid",
    "scene_id": "uuid",
    "beat_id": "uuid",
    "cursor_block_id": "paragraph-43"
  }
}
```

The event bus retains a bounded recent history so clients can reconnect with
the last sequence number.

Event types include:

- job stage
- proposal
- prose patch proposed/accepted/rejected
- writer cursor changed
- structure change
- documentation change
- finding
- suggestion-set update
- version committed
- job completed/failed/cancelled

### 8.6 Optimistic concurrency

Every modifying command includes `expected_version`.

- Matching version: execute normally.
- Stale but mergeable manual edit: return merge information.
- Stale structural or AI command: return HTTP 409 with current version.

The UI never silently overwrites work from another tab or background job.

## 9. API Shape

Read endpoints:

```text
GET /api/narrative/v1/stories
GET /api/narrative/v1/stories/:id/snapshot
GET /api/narrative/v1/stories/:id/nodes/:nodeId
GET /api/narrative/v1/stories/:id/views/:viewType
GET /api/narrative/v1/stories/:id/plans/:planType
GET /api/narrative/v1/stories/:id/suggestions
GET /api/narrative/v1/stories/:id/model-profile
GET /api/narrative/v1/stories/:id/findings
GET /api/narrative/v1/stories/:id/chapters/search
GET /api/narrative/v1/stories/:id/chapters/:chapterId/summary
GET /api/narrative/v1/stories/:id/chapters/:chapterId/excerpt
GET /api/narrative/v1/jobs/:jobId
GET /api/narrative/v1/jobs/:jobId/events
```

Commands:

```text
POST /api/narrative/v1/stories
POST /api/narrative/v1/stories/:id/commands
PUT  /api/narrative/v1/stories/:id/model-profile
POST /api/narrative/v1/jobs/:jobId/model-switch
POST /api/narrative/v1/stories/:id/suggestions/:suggestionId/pin
POST /api/narrative/v1/stories/:id/suggestions/:suggestionId/dismiss
POST /api/narrative/v1/jobs/:jobId/cancel
POST /api/narrative/v1/jobs/:jobId/steer
```

Command envelope:

```json
{
  "type": "start_chapter_authoring_job",
  "expected_version": 41,
  "branch_id": "uuid",
  "node_id": "chapter-uuid",
  "payload": {
    "direction_id": "uuid"
  }
}
```

Async response:

```json
{
  "accepted": true,
  "job_id": "uuid",
  "story_id": "uuid",
  "base_version": 41
}
```

Manual CRUD may use explicit PATCH endpoints where immediate field validation
and autosave are clearer than an async command.

## 10. Streaming Strategy

Use SSE for narrative jobs because event flow is primarily server-to-client
and ClawForge already uses SSE concepts.

Required behavior:

- reconnect with last event sequence
- no duplicate delta application
- heartbeat
- explicit terminal event
- cancellation through separate POST
- event history lookup after page reload

The page should never treat a dropped browser connection as job cancellation.

## 11. Accessibility and Responsive Behavior

- full keyboard navigation
- visible focus states
- labeled controls and status changes
- reduced-motion support
- non-color status labels
- resizable panels with keyboard-accessible alternatives
- minimum readable editor width

At medium widths:

- inspector becomes a drawer
- story navigation narrows to icons plus tooltips

At small widths:

- one workspace panel at a time
- navigation and inspector become overlays
- prose editing remains possible
- graph visualization is replaced by hierarchy view

Narrative Studio is desktop-first because long-form authoring benefits from
width, but it should remain usable for review and guided choices on mobile.

## 12. MVP Scope

### Phase UI-1: Shared shell and foundation

- extract reusable Forge theme tokens
- add Chat/Narrative navigation
- serve `/narrative` and modular assets
- implement story selector, navigation, inspector, job drawer
- reuse the shared model dropdown and add story/per-role model profiles
- add connection worker pool
- add NarrativeService command/event boundary
- add selection-scoped operation profiles and context builder

### Phase UI-2: Discovery and blueprint

- tool-enabled Author Room and decision proposals
- discovery interview
- living intent brief
- volume contract
- arc recommendation cards
- hierarchy editor
- Docs & Plans workspace
- prose/documentation import review and baseline commit

### Phase UI-3: Writing

- chapter/scene tree
- shared Read/Edit/Review manuscript canvas
- reader typography, Contents, progress, saved position, and fullscreen
- prose editor with stable selection and matching line measure
- direction choices
- streaming generation
- version history, diff, and undo
- automatic documentation-change summary
- OOC suggestion board
- past-chapter summary, excerpt, and exact-read tools
- preflight and final Context Used manifests
- stage-by-stage context inspection for chapter jobs

### Phase UI-4: Documentation and review

- characters and relationships
- world and timeline
- threads and promises
- style and voice
- ordered quality gate and findings

### Phase UI-5: Branching and compilation

- branch management
- graph visualization
- playback mode
- manuscript and interactive export

## 13. Explicit Deferrals

- PyQt-native UI
- real-time multi-user collaborative editing
- advanced rich-text pagination
- visual branch graph in the first release
- plugin marketplace for craft skills
- EPUB/DOCX layout controls beyond basic export

## 14. Validation Scenarios

The UI architecture is successful when a user can:

- move from Chat to Narrative Studio without learning a new visual language
- conduct discovery while watching the intent model update
- define a volume destination and compare arc recommendations
- understand what a selected arc advances and reveals
- select a structural level and see the model change into the appropriate
  planning, drafting, revision, or documentation mode
- read the manuscript with publication-like clarity and no authoring clutter
- switch between Read, Edit, and Review without losing position or changing
  line wrapping
- write or generate prose without losing scene purpose
- retrieve a relevant past chapter without loading the entire manuscript
- inspect character, relationship, promise, and revelation context on demand
- see automatic documentation updates without confirmation fatigue
- see refreshed non-canonical suggestions based on the prose actually committed
- inspect exactly which structured records, excerpts, and tools shaped a model
  operation
- understand why a quality gate failed and where
- compare and undo an AI revision
- leave during generation and reconnect without losing the job
- use Chat while a narrative job continues in the background
- compile the accepted branch into a readable manuscript
