# ClawForge Narrative Studio Design

Status: Draft
Purpose: Architecture and data-model proposal for agentic long-form and branching fiction
UI companion: `docs/narrative-ui-design.md`
Index: [Narrative Studio Design Index](narrative-design-index.md)

## 1. Summary

Narrative Studio is a story-aware workflow hosted by the ClawForge daemon. It
uses ClawForge's provider routing, worker pool, streaming, and SQLite
infrastructure, but adds a domain-specific narrative service and storage model.

The system must support two related workflows:

1. Guided or choose-your-own-adventure writing, where the system proposes
   several meaningful continuations and the user selects or edits one.
2. Structured long-form authorship, where the system develops a premise into
   arcs, milestones, chapters, scenes, and polished prose that can be compiled
   into a readable manuscript.

Both workflows use the same story graph. A linear manuscript is a graph with
one accepted successor per node; branching fiction permits multiple outgoing
choice edges.

The authoritative story is not a collection of Markdown files and is not
defined by vector search results. It is a typed, versioned graph of accepted
facts, plans, states, rules, and prose revisions. Markdown and other documents
are import/export formats.

## 2. Source-Corpus Findings

The initial reference corpus is:

`<story-workspace>/books/example-story/documentation/`

It demonstrates the breadth a real story system must represent:

- Core themes and tone
- Character profiles and projected development
- Character voice examples
- Relationship phases and intimacy progression
- Acts, chapters, scene templates, and ending hooks
- Plot milestones and subplot schedules
- World rules, probability distributions, and progression systems
- Combat formulas, threat ranks, and response protocols
- Factions, governments, religions, military units, and noble houses
- Writing constraints and chapter quality checks
- Present canon, future plans, sequel ideas, and speculative possibilities

The corpus also demonstrates why unstructured files cannot be the runtime
source of truth:

- Facts are repeated across multiple documents.
- The same milestone appears at different approximate chapters.
- Present facts and projected future facts are mixed together.
- Rules have chapter ranges in which they become known or valid.
- Character attributes change over time.
- Headers sometimes disagree with their contents, such as a named seven-act
  structure containing more than seven acts.
- Some statements are requirements, some are suggestions, and some merely
  describe candidate sequel material.
- A retrieval model cannot reliably distinguish accepted canon from a
  superseded or rejected plan without explicit metadata.

Narrative Studio must preserve the useful richness of this documentation while
making authority, scope, chronology, and provenance explicit.

## 3. Goals

- Maintain exact, queryable story structure without loading the whole
  manuscript into a model prompt.
- Let an agent retrieve only the facts, summaries, excerpts, and style examples
  needed for the current operation.
- Make prose through anchored, revision-checked patches, normally one to
  several paragraphs at a time, rather than treating a chapter as one model
  output.
- Let the writer inspect, write, re-read, and advance its story position
  through narrative tools during a longer authoring job.
- Keep planned events separate from events established in accepted prose.
- Track changing character, relationship, faction, and world state over time.
- Support linear, branching, and hybrid narratives with one data model.
- Save every generated alternative without silently making an unselected
  direction canonical.
- Automatically accept completed prose in the active writing flow and update
  its derived documentation without requiring a separate confirmation step.
- Make every automatic mutation versioned and undoable.
- Detect contradictions and continuity risks before committing changes.
- Preserve provenance for imported and AI-generated information.
- Compile accepted nodes into a complete readable manuscript.
- Permit human-readable Markdown and JSON export without using either as the
  live source of truth.

## 4. Non-Goals

- Fully autonomous publication without user review
- Treating embeddings as an authoritative fact database
- Loading all story documentation or prose for every generation
- Letting an adapter directly mutate SQLite tables
- Replacing the generic ClawForge knowledge base for non-story use
- Requiring a different model provider for each narrative role
- Using unstructured assistant text as the authoritative prose mutation path
- Making a full chapter the default atomic unit of model-generated prose

## 5. System Boundary

```text
Narrative Studio Web UI
        |
NarrativeWebController (HTTP + SSE + typed UI events)
        |
NarrativeService
        |
        +-- NarrativeJobRuntime
        +-- AuthoringOrchestrator
        +-- NarrativeContextCompiler
        +-- NarrativeValidator
        +-- NarrativeCompiler
        +-- NarrativeStores
        |
Shared InferenceRuntime + ProviderRegistry
Storage Connection/SQLite
```

The adapter is responsible for transport and presentation. It does not own
story logic.

The service is responsible for commands, authorization of mutations,
transactions, and emitting domain events.

The orchestrator is responsible for agentic planning and model calls.

The context builder is responsible for deterministic graph retrieval and
filtered semantic retrieval.

The validator is responsible for schema validation, continuity checks, and
conflict reporting.

The compiler walks an accepted branch and produces a manuscript or interactive
story package.

### 5.1 Ownership and dependency boundary

Narrative is a first-class subsystem, not a feature implemented inside
`core/engine.zig`, `adapters/web_adapter.zig`, or `workers/pool.zig`.

Dependency direction is one-way:

```text
adapters/web/narrative_controller.zig
                |
                v
        narrative/root.zig public API
                |
      +---------+----------+
      v                    v
application workflows   domain model
      |                    ^
      v                    |
context / validation / storage / inference gateway
      |                    |
      +----> shared InferenceRuntime
      +----> storage Connection

core, inference, storage primitives, and adapters never import narrative
internals
```

Responsibilities:

- `core/engine.zig` remains the generic chat application. It contains no story
  graph, beat, prose patch, continuation capsule, or narrative job logic.
- Shared provider invocation, bounded tool-loop execution, cancellation, and
  streaming are extracted from the chat engine into a small standalone
  `inference` build module. Both `Engine` and Narrative depend on it.
- `NarrativeService` is the public command/query façade. It does not contain
  model prompts, SQL statements, or HTTP serialization.
- The narrative application layer owns authoring state machines and
  transactions.
- Narrative domain modules own types and invariants and should remain usable
  without HTTP, providers, or SQLite.
- Narrative context modules own context compilation, budgets, pacing
  envelopes, retrieval, and manifests.
- Narrative inference modules translate narrative operation contracts into
  generic shared inference invocations.
- Narrative storage modules own SQL and migrations for narrative tables.
- The narrative job runtime owns its queues, worker threads, cancellation,
  continuation checkpoints, and event log.
- The web controller owns route parsing and JSON/SSE mapping only.

The existing formal `Adapter` abstraction represents an independently running
transport. Because Narrative Studio is mounted on the existing web origin, it
should initially be a controller composed by `WebAdapter`, not a second HTTP
listener pretending to be an adapter. If a future CLI, desktop process, or
remote narrative protocol is added, it calls the same `NarrativeService`.

### 5.2 Proposed module layout

```text
src/
├── inference/
│   ├── root.zig
│   ├── runtime.zig                # generic provider invocation
│   ├── tool_loop.zig              # bounded, policy-driven tool execution
│   └── invocation.zig             # request/result/stream/cancel contracts
├── core/
│   └── engine.zig                 # existing chat application
├── narrative/
│   ├── root.zig                   # only public narrative exports
│   ├── runtime.zig                # subsystem composition and lifecycle
│   ├── domain/
│   │   ├── ids.zig
│   │   ├── story.zig
│   │   ├── structure.zig
│   │   ├── canon.zig
│   │   ├── prose.zig
│   │   ├── authoring_job.zig
│   │   └── events.zig
│   ├── application/
│   │   ├── service.zig
│   │   ├── commands.zig
│   │   ├── queries.zig
│   │   └── authoring/
│   │       ├── chapter_loop.zig
│   │       ├── writer_pass.zig
│   │       ├── completion.zig
│   │       └── revision_coordinator.zig
│   ├── context/
│   │   ├── compiler.zig
│   │   ├── budgets.zig
│   │   ├── pacing_envelope.zig
│   │   ├── continuation_capsule.zig
│   │   ├── retrieval.zig
│   │   └── manifest.zig
│   ├── inference/
│   │   ├── gateway.zig
│   │   ├── roles.zig
│   │   ├── contracts.zig
│   │   └── tool_registry.zig
│   ├── tools/
│   │   ├── retrieval.zig
│   │   ├── manuscript.zig
│   │   └── schemas.zig
│   ├── validation/
│   │   ├── prose_patch.zig
│   │   ├── continuity.zig
│   │   └── quality_gate.zig
│   ├── storage/
│   │   ├── stores.zig
│   │   ├── migrations.zig
│   │   ├── prose_store.zig
│   │   ├── story_store.zig
│   │   └── job_store.zig
│   ├── jobs/
│   │   ├── pool.zig
│   │   ├── queue.zig
│   │   ├── runner.zig
│   │   └── event_bus.zig
│   └── compiler/
│       ├── manuscript.zig
│       └── export.zig
└── adapters/
    └── web/
        └── narrative_controller.zig
```

Files should be split by responsibility before they approach the project's
500–800 meaningful-line guideline. `root.zig` exposes service interfaces and
domain DTOs; callers do not reach into application, storage, or job internals.

The Zig build graph enforces the boundary:

```text
api + tools ──> inference
inference + storage ──> narrative
inference + existing stores ──> core
core + narrative ──> adapters
core + narrative + adapters ──> daemon executable
```

The `narrative` module does not import `core`. This makes accidental use of
`Engine`, chat sessions, chat prompt assembly, or process-wide chat state a
compile-time architectural violation rather than a code-review preference.

### 5.3 Composition root

`main.zig` should only construct and connect the subsystem:

```text
NarrativeRuntime.init(
    allocator,
    config.narrative,
    inference_runtime,
    database_connection_factory,
)
→ narrative_runtime.start()
→ web_adapter.setNarrativeService(narrative_runtime.service())
```

Shutdown performs the inverse order. Detailed store construction, migrations,
worker creation, and event wiring remain inside `NarrativeRuntime.init`, so
`main.zig` gains only a small lifecycle block.

## 6. Authority and Lifecycle

Every mutable narrative record has an explicit lifecycle:

- `candidate`: proposed by a user, import, or model but not canonical
- `accepted`: part of the active canonical version
- `rejected`: retained for history but excluded from normal retrieval
- `superseded`: previously accepted but replaced by a later version
- `conflicted`: cannot be accepted until an identified contradiction is
  resolved

Every assertion also has a narrative truth class:

- `established`: occurred or was stated in accepted prose
- `planned`: intended for a future node but not yet established
- `constraint`: authorial requirement that generated work must obey
- `hypothesis`: in-world or authorial theory that may be false
- `inferred`: extracted by a model and awaiting confirmation

These dimensions must not be collapsed. An accepted plan is authoritative as a
plan, but it is not yet an established in-world event.

Narrative Studio distinguishes exploratory generation from active writing:

- Direction options and alternate drafts remain candidates until selected.
- Prose generated for the selected active direction is accepted automatically
  when generation and validation complete.
- Facts, state deltas, summaries, indexes, and documentation views derived from
  that prose are committed automatically with it.
- A user can revise or undo the resulting story version, but is not asked to
  approve routine documentation updates.

### 6.1 Authoring modes

Narrative Studio has explicit workflow modes with different model behavior:

- `author_room`: normal tool-enabled conversation about the selected story
  scope, with explicit decision proposals
- `discovery`: interview the user, expose creative tradeoffs, and build an
  intent model
- `blueprint`: turn accepted intent into story or arc structure without
  drafting prose
- `active_writing`: plan scenes, write prose, and maintain documentation
- `revision`: alter existing prose or structure while preserving provenance
- `playback`: traverse an accepted branch as interactive fiction

A new story begins in discovery mode. A major new arc can re-enter discovery
mode with the existing story canon supplied as fixed context.

The transition into active writing is explicit. The model must not begin an
opening chapter merely because it has enough material to improvise one.

#### 6.1.1 Author Room conversation

Author Room is the normal conversational surface for asking questions,
exploring ideas, resolving uncertainties, and reasoning about the story
without entering a formal discovery or writing job.

Examples:

- "Would Lyra plausibly trust him after this chapter?"
- "What are three ways to reveal the currency system naturally?"
- "Did we ever establish who owns the venom manuals?"
- "I think the second arc should end differently; what would that break?"
- "Make this preference part of the story plan."

The collaborator receives the selected story position, relevant structured
records, bounded manuscript tools, and the same branch/knowledge protections
as other narrative roles. It does not receive the entire story or generic chat
history automatically.

Conversation messages are not story truth. When the discussion reaches a
durable decision, the collaborator creates a `NarrativeDecisionProposal`
containing:

- concise decision
- affected records
- proposed structured patches
- consequences and conflicts
- evidence from the conversation and story
- intended scope: story, volume, arc, chapter, scene, or one operation

The UI presents the proposal as an approval card. Only user acceptance applies
the structured changes. Rejection or continued discussion leaves canon and
plans unchanged.

Author Room may inspect documentation and propose changes to intent, plans,
facts, rules, preferences, beat plans, and protected moments. It cannot write
manuscript prose, accept its own proposals, or mutate documentation directly.

Accepted decisions become durable records, so later model operations retrieve
the decision rather than replaying the full conversation. Conversation threads
may then be summarized or archived.

### 6.2 Guided discovery interview

Discovery is a structured, adaptive conversation rather than a static setup
form. Its purpose is both to capture what the user already wants and to help
the user discover preferences they have not yet articulated.

The interview explores, as relevant:

- desired reader experience and emotional promise
- premise, central dramatic question, themes, and anti-themes
- genre, subgenre, influences, and expectations to fulfill or subvert
- protagonist desire, need, wound, contradiction, and agency
- central relationships and desired progression
- opposition, pressure, stakes, and failure consequences
- setting, society, economy, culture, religion, and world systems
- what should remain mysterious and what should be understood early
- preferred information-delivery and exposition methods
- point of view, tense, distance, voice, and prose density
- pacing, length, act shape, chapter shape, and scene rhythm
- power progression, mystery progression, romance progression, or other
  genre-specific structures
- intended ending, emotional destination, and acceptable uncertainty
- branching depth and player agency for interactive stories
- content boundaries, required material, and unwanted tropes

The interviewer should not dump a hundred generic questions at once. It asks
small coherent batches, records each answer immediately, and selects later
questions based on uncertainty and consequence.

For choices the user has not considered, it should:

1. Explain why the decision affects the story.
2. Offer meaningfully different options with likely consequences.
3. Recommend an option when the current intent supports one.
4. Accept combinations or a provisional "discover during writing" answer.
5. Point out tensions between answers without treating them as errors.

Examples:

- "Should readers understand the magic cost before the protagonist does, learn
  it alongside them, or discover later that the accepted explanation was
  incomplete?"
- "Do you want the romance to create safety within the larger conflict, or
  should intimacy itself remain a source of danger?"
- "Is the ending destination known so we can build promises toward it, or do
  you want several viable destinations preserved?"

Discovery is resumable. The user can leave, return, revise an earlier answer,
or ask the system to explore alternatives before committing.

### 6.3 Intent model

Interview answers populate a versioned `NarrativeIntentProfile`, not a prose
summary alone. Each decision records:

- topic and structured value
- user rationale
- hard, soft, or exploratory commitment
- confidence
- alternatives considered
- dependencies and tensions
- source conversation turn
- whether the system may revisit it automatically

The profile also records open design questions and the system's current
understanding of the desired reader experience.

This lets the blueprint agent distinguish:

- fixed requirements it must obey
- strong preferences it should normally preserve
- provisional choices it may challenge
- unanswered questions it must resolve before drafting

### 6.4 Blueprint readiness

The system maintains readiness checks rather than an arbitrary minimum number
of questions.

A story is ready for blueprinting when it has enough definition to create:

- a coherent story promise
- a protagonist or focal force with agency
- sustained conflict or pressure
- an intended change over time
- a world and rule scope appropriate to the premise
- an information-delivery strategy
- an initial structural horizon
- explicit unresolved decisions that may safely remain open

An arc is ready when its purpose, entering state, pressure, intended change,
relationship to existing threads, information reveals, and exit possibilities
are understood.

Before transition, the system presents a structured design brief with:

- settled intent
- provisional intent
- open questions
- detected tensions
- proposed blueprint strategy

The user approves or edits this brief once. Routine documentation updates after
writing remain automatic.

### 6.5 Volume contract

Blueprinting begins with the largest useful planning horizon, normally a
volume, book, season, or campaign. The system asks the user to define its
approximate destination before recommending arcs.

The volume interview asks:

- What should roughly have happened by the end?
- How should the protagonist and major supporting characters have changed?
- Which relationships should form, deepen, fracture, or remain unresolved?
- What new information should the reader know, suspect, or falsely believe?
- How should the reader discover each important piece of information?
- Which questions should be answered, and which larger questions should open?
- Which promises should pay off in this volume?
- What should change in the world, conflict, or balance of power?
- What emotional experience should the ending provide?
- What should make the reader want the next volume?

The result is a versioned `NarrativeVolumeContract` containing:

- entering and target story state
- entering and target character state
- entering and target relationship state
- target reader-understanding state
- required revelations and allowed delivery modes
- required, optional, and prohibited outcomes
- promises to pay off, defer, or introduce
- desired tonal and experiential trajectory
- sequel-facing open questions

Targets may be approximate. The contract describes direction and required
payoffs without forcing every intermediate event.

### 6.6 Backward arc design

The blueprint agent works backward from the volume contract and forward from
the entering state. It proposes several compatible arc structures rather than
pretending there is one correct outline.

Each recommended arc includes:

- its dramatic engine: the pressure that keeps producing events
- entering and exiting state
- central question or conflict
- character and relationship movement
- revelations, clue progression, and delivery methods
- promises introduced, reinforced, or paid off
- world and plot consequences
- likely escalation pattern
- entertainment profile
- connection to the preceding and following arcs
- risks such as repetition, tonal monotony, stalled plot, premature reveal, or
  forced romance

The system explains why each arc helps reach the volume destination and offers
alternatives with different pacing or emphasis.

For example:

```json
{
  "title": "The Failed Apprenticeship",
  "dramatic_engine": "The protagonist must learn a system from a teacher they do not trust.",
  "advances": {
    "plot": "Reveals why the northern wards are failing.",
    "character": "Forces the protagonist to admit an area of incompetence.",
    "relationship": "Turns rivalry with the teacher into reluctant respect.",
    "world": "Demonstrates the cost and limits of ward magic.",
    "reader_understanding": "Moves ward failure from mystery to partial causal model."
  },
  "information_delivery": [
    {
      "item": "ward resonance",
      "mode": "instruction",
      "dramatic_context": "A lesson becomes a contest over whose model predicts a live failure."
    },
    {
      "item": "the official history is incomplete",
      "mode": "environmental_inference",
      "evidence": ["erased names", "mismatched repair dates"]
    }
  ],
  "entertainment_profile": ["mystery", "competitive dialogue", "dangerous demonstration", "dry comedy"],
  "exit_state": "The protagonist can repair ordinary wards but suspects deliberate sabotage."
}
```

### 6.7 Narrative tracks

Blueprinting and scene planning track several dimensions of movement:

- external plot and causality
- character goals, beliefs, and capabilities
- relationships and power dynamics
- reader knowledge and mystery
- world change and understanding
- theme and moral pressure
- setup and payoff
- tone, tension, relief, wonder, comedy, romance, and action

Not every scene advances every track. A scene should normally make a primary
move and one or more secondary moves. The system favors combining functions:

- action exposes character priorities and changes later options
- comedy reveals a relationship dynamic or releases pressure before escalation
- romance changes trust, vulnerability, commitment, or decision-making
- instruction creates conflict, application, failure, or discovery
- worldbuilding constrains an immediate choice
- quiet aftermath converts action into consequence and character change

This avoids treating "romance scene," "comedy scene," "action scene," and
"plot scene" as isolated mandatory categories.

### 6.8 Contextual craft guidance

During discovery and blueprinting, the system acts as a creative advisor. It
offers concise guidance relevant to the user's current decision rather than
reciting a universal writing handbook.

General heuristics include:

- Entertainment comes from anticipation, change, consequence, contrast, and
  meaningful uncertainty, not constant spectacle.
- Action must alter state; otherwise it is choreography without consequence.
- Comedy works best when it emerges from character, situation, expectation, or
  status and does not erase consequences the story wants readers to feel.
- Romance becomes structural when intimacy changes choices, risk, loyalty,
  self-understanding, or the cost of failure.
- Relationship development needs interaction under changing pressure, not
  repeated declarations of the same dynamic.
- Exposition is most engaging when knowing the information helps someone act,
  argue, predict, fail, or survive.
- Quiet scenes remain active when a decision, interpretation, bond, plan, or
  emotional state changes.
- Tonal variety creates contrast; tonal randomness breaks the story contract.
- Setups should create curiosity before their payoff becomes necessary.
- Arc endings should resolve or transform their central pressure while
  generating the conditions for the next arc.

These are configurable guidelines, not fixed content quotas. The system should
explain tradeoffs and diagnose imbalance, but the user's intended experience
controls the final mixture.

### 6.9 Relational humanity and romance-aware defaults

Narrative Studio uses a house heuristic that most stories benefit from some
romantic, flirtatious, intimate, or partnership-oriented texture even when
romance is not the primary genre.

During discovery, the system should normally ask:

- Should this story contain a primary romance, secondary romance, background
  attraction, occasional flirtation, established partnership, or no romance?
- Which characters plausibly experience attraction toward whom?
- Should romantic material provide warmth, tension, vulnerability, humor,
  conflict, political consequence, family possibility, or contrast with the
  main plot?
- How much narrative attention should it receive?
- What age, cultural, professional, or power-dynamic complications apply, if
  they are actually relevant to this relationship?

Ordinary attraction, teasing, flirtation, asking someone out, or testing
interest does not require a pre-negotiated consent ritual in the story bible.
Characters reveal whether attention is welcome through their responses, and
those responses shape what happens next. Explicit consent constraints belong
in documentation when material sexual escalation, coercion, abuse, or a
meaningful power imbalance is part of the intended story—not as boilerplate
attached to every romance.

Each fictional project carries one compact declaration in `StoryIdentity`: the
characters and events are fictional unless the author explicitly identifies
sourced material, and depicting flawed, immoral, intrusive, reckless, or
antagonistic behavior is not endorsement. This is project metadata, not language
to repeat through relationship records or prose prompts.

As a product-level recommendation, the discovery system may suggest at least
light romantic or flirtatious texture for roughly 60–70% of otherwise
compatible stories. This is a recommendation prior, not a content quota or a
requirement imposed against the user's intent.

For stories where romance is not central, appropriate expressions include:

- brief mutual attraction without a full subplot
- an established couple whose daily behavior reveals character
- restrained flirting during moments where it naturally fits
- a past or distant relationship that affects present choices
- a developing bond that remains unresolved during the current volume
- awareness of attraction that a character chooses not to pursue
- family hopes or anxieties relevant to risk and legacy

These beats should be proportionate to the story contract. They should
humanize characters, change a relationship, reveal vulnerability, create
stakes, or provide tonal contrast. They should not repeatedly interrupt urgent
action, manufacture attraction between every compatible pair, or turn a
non-romance premise into a slice-of-life romantic comedy unless the user wants
that evolution.

### 6.10 Character intimacy profile

Each significant character may have independent structured dimensions for:

- romantic orientation and interest
- sexual orientation and interest
- desire for partnership
- desire for children or legacy
- desire for physical affection
- need for companionship, belonging, or recognition
- comfort with vulnerability
- cultural and personal courtship behavior
- boundaries and unavailable relationships when they are character-relevant
- current life circumstances affecting any of the above

These dimensions must not be collapsed into a single procreation instinct.
Characters can want sex without children, children without romance, romance
without sex, companionship without romance, or none of these. Aromantic,
asexual, celibate, infertile, traumatized, duty-bound, nonhuman, or simply
uninterested characters are ordinary valid possibilities and do not require
villainy or pathology as justification.

Villains and psychologically unstable characters may still experience
attraction, attachment, jealousy, family loyalty, or the desire for legacy.
Those desires should follow their characterization rather than serving as an
automatic exemption or inclusion.

### 6.11 Daily-life grounding

Romance is one way to make characters feel lived-in, but not the only one.
Every major character should have some evidence of life beyond their immediate
plot function:

- friendships and rivalries
- family or chosen family
- food, sleep, clothing, hygiene, and physical comfort
- work habits and private routines
- money and material constraints
- humor and leisure
- faith, ritual, community, or civic obligation
- private ambitions and minor frustrations
- affection, loneliness, grief, embarrassment, or pride

The planner should periodically look for compact opportunities to ground
characters through these details while combining them with plot, relationship,
theme, or world movement. Daily-life grounding is not a demand for standalone
slice-of-life scenes.

### 6.12 Romance integration checks

When romantic material is present, the system checks:

- attraction arises from specific character perception and interaction
- flirtation reflects the participants' voices and boundaries
- interest, disinterest, reciprocity, and rejection are legible through
  character behavior
- relationship movement affects later choices or emotional stakes
- romantic beats respect the urgency and tone of surrounding events
- repeated beats develop rather than restate attraction
- material sexual escalation, coercion, or power imbalance is treated
  intentionally when present
- non-romantic relationships retain meaningful narrative space
- the romance does not consume more structural weight than the chosen profile

At volume and arc planning time, the system can recommend where a small number
of relational beats would add warmth, contrast, or consequence. It should
prefer multi-function scenes over inserting disconnected "romance content."

### 6.13 Comedy contract

Comedy is planned as tone, character behavior, and scene dynamics rather than
as a quota of explicit jokes. During discovery, the system asks:

- How funny should the story feel overall?
- Should comedy be dry, warm, absurd, dark, witty, awkward, physical, or rare?
- Which characters intentionally make jokes?
- Which characters are funny without realizing it?
- Who tends to react, escalate, deflate, misunderstand, or remain unmoved?
- What subjects should not be treated comedically?
- May humor appear during danger, grief, horror, romance, or only around them?
- Should recurring comic dynamics evolve into intimacy, conflict, or payoff?

The result is a story-level `NarrativeComedyContract` with:

- target comedic frequency and intensity
- preferred and prohibited comedy modes
- tonal placement rules
- character and relationship comedy profiles
- subjects and moments protected from undercutting
- recurring dynamics and callbacks
- genre-specific expectations

Frequency is descriptive rather than a jokes-per-chapter requirement. A story
can feel consistently warm or wry while containing very few punchlines.

### 6.14 Comedy taxonomy

`narrative_comedy_types` begins with a reusable taxonomy:

- `character_incongruity`: behavior is funny because it clashes with ordinary
  expectations while remaining true to the character
- `situational_absurdity`: circumstances are inherently ridiculous even when
  everyone treats them seriously
- `reaction`: another character's response supplies the comic emphasis
- `deadpan`: extreme material is delivered with calm literal seriousness
- `understatement`: language deliberately minimizes an obvious extreme
- `overstatement`: disproportionate language expresses panic, pride, or
  frustration
- `misunderstanding`: characters operate from different interpretations
- `knowledge_asymmetry`: one participant or the reader understands what
  another does not
- `status_reversal`: authority, competence, dignity, or control changes hands
- `verbal_wit`: phrasing, wordplay, rhetorical reversal, or precision creates
  humor
- `banter`: reciprocal verbal play develops a relationship or contest
- `callback`: an earlier detail returns with changed context
- `running_dynamic`: a recurring character interaction develops across scenes
- `escalation`: repetitions become progressively more consequential or absurd
- `rule_of_three`: a pattern establishes, reinforces, then turns
- `bathos`: grandeur drops abruptly into mundane or anticlimactic reality
- `dramatic_irony`: the reader understands a comic contradiction hidden from
  characters
- `social_awkwardness`: incompatible expectations, etiquette, or self-awareness
  create tension
- `physical`: movement, timing, spatial relationships, or bodily mishap creates
  humor
- `gallows`: humor is used by characters to endure danger, grief, or horror
- `observational`: a character notices a truthful absurdity in ordinary life
- `satire`: institutions, values, or conventions are exposed through comic
  exaggeration or contrast
- `meta`: genre or narrative conventions are acknowledged; allowed only when
  compatible with the story contract

A beat may use several types simultaneously. The taxonomy helps retrieval,
planning, variation, and auditing; it is not a requirement to label comedy in
the prose.

### 6.15 Character humor profiles

Comedy must arise from individual perception and behavior rather than giving
every character the author's same joke voice.

Each significant character may have a `NarrativeHumorProfile` containing:

- what they genuinely find funny
- whether they intentionally try to be funny
- their production modes: dry, teasing, performative, literal, absurd,
  self-deprecating, cutting, playful, or none
- verbal rhythm and typical level of restraint
- preferred targets and subjects
- what they never joke about
- whether humor is affection, defense, control, deflection, cruelty, coping, or
  social performance
- how they respond to other people's humor
- embarrassment and dignity thresholds
- comic blind spots
- recurring dynamics with particular characters
- how the profile changes through the story

Pair and group dynamics are stored separately because comedy often exists
between characters:

- instigator and reactor
- performer and deadpan audience
- literal thinker and exasperated interpreter
- rival escalators
- mutual teasers
- dignified authority and chaos agent
- two serious characters trapped in an absurd situation

These roles are tendencies, not permanent assignments. Reversing them can
become a meaningful relationship or character-development beat.

### 6.16 Appropriate placement and tonal protection

Comedy is especially useful for:

- revealing personality under low or high pressure
- demonstrating relationship familiarity
- releasing tension after consequence has landed
- making exposition or training dramatically active
- creating contrast before escalation
- showing coping behavior
- grounding powerful characters in ordinary frustration
- exposing institutional absurdity
- making repeated procedures feel fresh

Comedy needs additional scrutiny when:

- a death, trauma, humiliation, or irreversible loss has not emotionally landed
- a scene depends on horror, awe, intimacy, or suspense remaining unbroken
- the joke targets a vulnerable character rather than revealing the person
  making it
- flirtation or ridicule may be read as coercion
- a quip would erase the apparent cost of violence
- humor depends on characters becoming temporarily less intelligent
- the same reaction or banter pattern has already been exhausted

Protected moments may prohibit comedy entirely, permit only character-specific
gallows humor, or delay relief until the following scene.

### 6.17 Avoiding forced comedy

The planner and auditor apply these checks:

- The beat follows from character goals, perception, or the actual situation.
- Removing the joke does not reveal that the scene stopped solely to entertain
  the audience.
- The humor also reveals, changes, demonstrates, relieves, contrasts, or pays
  off something relevant.
- Characters retain their established intelligence and competence.
- Dialogue voices remain distinct.
- Reactions are proportionate to personality and context.
- Recurring humor escalates, transforms, or gains new meaning.
- Serious consequences remain serious after the laugh.
- The prose does not explain why a line is funny.
- Other characters do not laugh merely to certify a joke.
- The system does not insert humor because a fixed number of pages have passed.

Comedy can be the primary purpose of a scene, but even a comic set piece should
normally leave the plot, relationship, reader understanding, or character
state somewhere new.

### 6.18 Worked pattern: "Venom Resistance Training, Apparently"

The Rorann's Rage venom-training scene supplied during design is a reference
pattern for integrated character comedy.

Its comic engine is not a sequence of detachable jokes. It is a collision
between two sincere models of reality:

- Rorann views deliberate venom exposure as efficient empirical training.
- Lyra views the same behavior as obvious self-destructive insanity.
- Rorann's regeneration makes his reasoning materially possible without making
  it socially or emotionally normal.
- Lyra's escalating reaction aligns with the reader while revealing protective
  attachment.

The scene combines:

- character incongruity
- deadpan and understatement
- reaction comedy
- escalation
- retrospective absurdity when Rorann reveals he has done this before
- linguistic contrast between clinical observation and emotional alarm
- physical comedy when Lyra prevents the next experiment
- a recurring manual/documentation dynamic

It remains tasteful and structurally useful because it also:

- demonstrates regeneration and venom mechanics
- establishes preparation for the stronger broodmother venom
- reveals Rorann's history and dangerous learning habits
- develops Lyra's protective role and frustration
- creates physical proximity consistent with their relationship
- changes future behavior by motivating new safety manuals

The serious physical description preserves the danger. Lyra's horror prevents
the scene from implying that tissue destruction has no emotional meaning, even
though Rorann can heal it. The humor therefore grows from characterization and
consequence rather than canceling them.

The reusable pattern is:

```text
Character A follows internally consistent but abnormal logic
      +
Character B recognizes its human or social absurdity
      +
The situation has real plot/world consequences
      +
Reactions escalate without either character abandoning their voice
      =
Personal, integrated comedy
```

## 7. Story Graph

### 7.1 Narrative nodes

`narrative_nodes` represents structural units:

- series
- book
- act
- arc
- chapter
- scene
- beat
- ending

Each node contains:

- stable UUID
- story UUID
- optional parent UUID
- node type
- title
- sortable ordinal within its parent
- lifecycle status
- short purpose
- synopsis
- point of view
- setting and story-time references
- desired tone and pacing
- generation status
- accepted prose revision UUID, when applicable
- optimistic concurrency revision

The hierarchy describes containment. Edges describe narrative flow.

### 7.2 Narrative edges

`narrative_edges` represents:

- normal continuation
- user-visible choice
- conditional transition
- flashback or memory relation
- alternate branch
- convergence

An edge contains source and destination nodes, branch scope, optional choice
text, preconditions, predicted consequences, and acceptance status.

### 7.3 Branches

`narrative_branches` records named paths through the graph. A branch has a base
node, optional parent branch, lifecycle status, and head node.

Records scoped to a branch are visible only while traversing that branch and
its ancestors. This prevents rejected or sibling-branch facts from entering
the active context.

### 7.4 Hierarchical beat plans

Prose generation requires an accepted beat plan. Planning occurs at multiple
levels:

```text
story turning points
→ volume milestones
→ arc movements
→ chapter beats
→ scene beats
→ passage obligations
```

The complete novel does not need paragraph-level planning before Chapter One.
Story, volume, and arc beats establish the long-range route. Before a chapter
authoring job begins, its chapter and scene beat plan must be sufficiently
resolved to establish pacing, required moments, and exit conditions. The
director may refine later scene beats during the job, but it cannot ask the
writer to improvise without a current beat and bounded lookahead.

Each `NarrativeBeatPlan` entry contains:

- stable beat UUID and parent structural node
- required, preferred, conditional, or optional status
- narrative purpose and affected tracks
- entry assumptions and desired exit change
- prerequisites and allowed ordering constraints
- estimated narrative space or pacing weight
- desired tension and emotional movement
- information delivered, withheld, or made inferable
- characters and relationships involved
- interaction contracts for every planned exchange:
  - speaker and listener
  - relationship state at entry
  - immediate speaker goal and emotional posture
  - openness and speech mode
  - what may be expressed and what must remain withheld
  - social moves that would contradict the current story state
  - expected relationship shift
  - `locked`, `strongly_implied`, or `provisional` certainty with evidence
- completion test
- associated protected moment anchors
- planned, active, satisfied, skipped, waived, or superseded lifecycle

Beat plans are authorial intent, not canon. Their status advances only when
accepted prose provides supporting source spans.

The interaction contract, rather than the passage writer, answers “would this
character speak to this person this way at this point in the story?” The writer
may choose natural wording but cannot independently change familiarity,
guardedness, disclosure, hostility, flirtation, or vulnerability. If the
planner lacks enough evidence for a strong answer, it marks the posture
`provisional` for author review instead of hiding uncertainty inside prose.

### 7.5 Protected moment anchors

Some planned material must survive context compression exactly. A
`NarrativeMomentAnchor` represents:

- an exact quote
- a required action or gesture
- a visual image or sensory detail
- a reveal or realization
- a callback
- an emotional turn
- a transition or scene-ending line

Each anchor records:

- stable UUID and owning beat
- payload and anchor kind
- fidelity: `verbatim`, `semantic`, or `inspirational`
- intended speaker or actor
- placement window
- prerequisites and facts that must remain hidden beforehand
- whether surrounding wording may be adapted
- status: `pending`, `placed`, `waived`, or `superseded`
- provenance and, once placed, exact prose source span

A pending `verbatim` anchor is copied exactly into every writer context in its
placement window. It is never replaced by an embedding or lossy summary.
Semantic anchors may be compacted but must preserve their required meaning.

Patch validation detects candidate satisfaction but does not silently mark an
anchor placed. The post-patch extractor identifies the source span, verifies
speaker, prerequisites, placement, and fidelity, then advances the anchor.
Until that succeeds, it remains in the next context.

If a definitive quote no longer fits naturally, the writer must leave it
pending and report the conflict. Changing or waiving it is a plan revision,
not an incidental prose choice.

## 8. Canon and State Model

### 8.1 Entities

`narrative_entities` stores stable things that can be referenced:

- character
- relationship
- location
- faction
- culture
- religion
- organization
- rank or title
- creature species
- object
- ability
- rule system
- technique
- event
- concept

Entities have stable UUIDs, canonical names, aliases, descriptions, lifecycle
status, and provenance.

Names are display values and may change. References use UUIDs.

### 8.2 Atomic facts

`narrative_facts` stores atomic assertions rather than undifferentiated profile
documents.

Example:

```json
{
  "subject_id": "character-rorann",
  "predicate": "humanity_scale",
  "value": 5,
  "value_type": "number",
  "truth_class": "planned",
  "valid_from_node_id": "chapter-60",
  "valid_to_node_id": "chapter-60",
  "branch_id": "main",
  "status": "accepted",
  "confidence": 1.0,
  "source_ids": ["source-story-bible", "source-milestones"]
}
```

Other examples:

- character age at a story position
- character affinity
- military rank during a range
- relationship trust level
- faction membership
- who knows a secret
- ownership of an object
- world-rule availability after its discovery
- threat-rank response requirement

Fact values may be scalar, entity references, or validated JSON values.
Frequently queried predicates may later receive dedicated projection tables,
but the fact identity and provenance remain stable.

### 8.3 State deltas and snapshots

Accepted scenes produce `narrative_state_deltas`, such as:

- character injured
- location destroyed
- secret revealed to a character
- relationship trust increased
- object transferred
- plot thread opened or resolved

The current state for a branch is derived by replaying accepted deltas along
the path. `narrative_state_snapshots` periodically materializes that state for
fast loading. Snapshots are caches and can be rebuilt from accepted facts and
deltas.

### 8.4 Relationships

Relationships are entities so they can have their own changing state:

- participants
- relationship type
- trust
- intimacy
- conflict
- public/private status
- phase
- key milestones

This supports relationship arcs without encoding all state on either
participant.

## 9. Arcs, Threads, and Milestones

`narrative_arcs` describes intended development across a node range:

- character arc
- relationship arc
- plot arc
- mystery
- political arc
- thematic arc
- power progression

`narrative_threads` tracks promises and unresolved material:

- setup
- question
- foreshadowing
- obligation
- danger
- relationship tension

Thread status is explicit: `open`, `advanced`, `resolved`, `abandoned`, or
`deferred`.

`narrative_milestones` associates a desired or established change with an exact
node or allowed node range. A range expresses authorial flexibility without
turning an approximate chapter into a false exact fact.

Example:

```json
{
  "arc_id": "rorann-humanity",
  "kind": "character_change",
  "summary": "First genuine smile",
  "earliest_node_id": "chapter-22",
  "latest_node_id": "chapter-28",
  "target_node_id": null,
  "completion": "planned",
  "required": true
}
```

## 10. World Rules and Constraints

`narrative_rules` stores typed rules:

- magic mechanics
- combat formulas
- social or political rules
- religious practices
- technology limitations
- narrative tone rules
- chapter construction requirements
- prohibited outcomes

Rules have:

- category and scope
- structured expression, where feasible
- human-readable explanation
- severity: `hard`, `soft`, or `advisory`
- validity range
- discovery range, distinct from validity
- branch scope
- lifecycle and provenance

Validity and discovery are separate. A magic rule may always be true in-world
while remaining unknown to characters until chapter 120.

Formula-like rules should retain a structured form:

```json
{
  "operator": "add",
  "terms": [
    {"operator": "multiply", "terms": ["strength", "weapon_modifier"]},
    "technique_bonus",
    "affinity_synergy"
  ]
}
```

The prose explanation remains available for humans and model context.

## 11. Style and Voice

Style is split into rules and examples.

`narrative_style_rules` stores:

- narrative person and tense
- viewpoint restrictions
- tone
- descriptive density
- pacing preferences
- dialogue conventions
- recurring imagery
- prohibited habits
- per-character voice constraints

`narrative_exemplars` stores short, approved passages or dialogue samples with:

- character and POV scope
- situation tags
- qualities demonstrated
- positive or negative classification
- source and revision
- embedding

The context builder retrieves a small number of relevant exemplars. It does
not load an entire dialogue-examples document.

User feedback can create or adjust style rules:

- "Too clinical outside Rorann's POV"
- "Keep Lyra enthusiastic without making her childish"
- "Use fewer sentence fragments in combat"

### 11.1 Tone and voice hierarchy

Every story defines a `NarrativeVoiceContract` that separates several layers:

1. **World and genre register**: vocabulary, assumptions, imagery, technology,
   cultural references, and degree of formality available to the work.
2. **Narrator voice**: the narrator's syntax, vocabulary, attitude, metaphor
   sources, emotional distance, knowledge, and relationship to the reader.
3. **POV lens**: what the focal character notices, ignores, understands,
   misinterprets, and emotionally emphasizes.
4. **Internal voice**: the focal character's private diction and thought
   patterns when directly represented.
5. **Spoken character voice**: each speaker's vocabulary, rhythm, register,
   evasions, humor, and emotional expression.
6. **Scene modulation**: temporary pacing and tonal pressure such as horror,
   intimacy, comedy, awe, urgency, grief, or calm.

Lower layers may influence selection and emphasis without accidentally
replacing higher layers. A clinical character may cause the narration to
notice measurable details while the narrator retains its own established
syntax and metaphors.

The voice contract explicitly selects a permeability mode:

- `separated`: narrator diction remains distinct from character diction
- `lightly_filtered`: narrator remains distinct while description follows POV
  attention and judgment
- `free_indirect`: narrator and POV diction intentionally blend under defined
  conditions
- `first_person_identity`: narrator and POV are the same voice, while spoken
  voices of other characters remain distinct

Free indirect discourse is not treated as an error when selected. Unplanned
bleed is always a defect.

Each voice profile may specify:

- preferred and prohibited vocabulary
- sentence length and structural tendencies
- metaphor and comparison sources
- degree of abstraction versus sensory observation
- profession, culture, education, age, and period markers
- emotional directness
- humor and profanity patterns
- characteristic omissions and evasions
- example passages
- words or constructions reserved for another voice

### 11.2 Voice and immersion checks

The system evaluates prose spans for:

- narrator diction drifting into a speaking character's fingerprint
- multiple characters sharing the same syntax, wit, or emotional vocabulary
- POV narration asserting knowledge the focal character cannot access
- narrator commentary explaining the author's intent from outside the story
- modern, technical, cultural, or idiomatic language unsupported by the world
- metaphors requiring concepts unavailable to narrator or POV
- abrupt tense, person, distance, or permeability changes
- scene-tone modulation overwriting the story's base voice
- system, outline, prompt, or documentation language leaking into prose
- characters naming feelings or themes in ways inconsistent with their voice

Immersion does not require archaic language or invisible narration. It requires
that every word feel available to the selected narrator, character, world, and
mode.

### 11.3 Continuous writing guidelines

Narrative Studio maintains a reusable guideline registry distinct from a
story's prose style. Guidelines express general craft expectations evaluated
during planning, drafting, post-prose extraction, and continuity auditing.

Initial guidelines include:

- Every scene must cause a meaningful change in plot, character,
  relationship, knowledge, danger, or reader understanding.
- Every introduced detail must have an identifiable narrative function.
- Emphasized specificity creates a reader expectation and must be tracked.
- Repeated images, objects, phrases, locations, and behaviors must develop
  rather than recur accidentally.
- Revelations and resolutions must have prior support unless deliberate
  disorientation is part of the story contract.
- Character decisions must follow from available knowledge, motivation, and
  pressure.
- Consequences must persist until the story establishes their resolution.
- Point-of-view prose must not assert inaccessible knowledge as fact.
- Dialogue should alter knowledge, power, emotion, intention, or action rather
  than merely restating shared information.
- Major emotional or capability changes require sufficient setup and
  transition.

Guidelines have severity, scope, evaluation stage, configurable exceptions,
and machine-readable check instructions. They produce evidence-backed findings
rather than a single subjective quality score.

### 11.4 Story promise ledger

The principle commonly summarized as "if the story shows it, it must matter"
is represented by `narrative_story_promises`.

A promise begins when prose introduces an element with potential reader
salience:

- an unusually specific object or physical detail
- a named place, person, law, ritual, or historical event
- a character habit, fear, desire, injury, possession, or secret
- an unanswered question or unexplained reaction
- a repeated image or phrase
- foreshadowing
- a stated plan, threat, prediction, or obligation

Each promise records:

- the introduced element and source prose span
- branch and story position
- salience and recurrence count
- intended function
- connected entities, arcs, themes, and threads
- expected payoff window, when known
- lifecycle status
- reinforcement and payoff evidence

Supported functions are:

- `plot`: enables or changes later events
- `character`: reveals or develops a person
- `relationship`: establishes or changes a dynamic
- `world`: establishes a rule, culture, constraint, or lived reality
- `theme`: contributes to the story's argument or motif
- `tone`: creates atmosphere relevant to the intended experience
- `setup`: creates a specific future expectation
- `misdirection`: intentionally shapes an incorrect expectation
- `continuity_anchor`: makes later descriptions or actions coherent

This avoids an overly literal implementation in which every background spoon
must become a weapon. A spoon may establish poverty, ritual, nervous behavior,
or domestic warmth and therefore still has a function. A conspicuously
engraved spoon described twice has higher salience and creates a stronger
future obligation.

Promise lifecycle states are:

- `introduced`
- `reinforced`
- `complicated`
- `paid_off`
- `subverted`
- `retired`
- `overdue`

Retirement requires a recorded reason. An unresolved promise is not
automatically an error; the auditor considers salience, elapsed story distance,
the expected payoff window, genre, and whether the active arc is ending.

### 11.5 Constant evaluation loop

Guidelines are checked at multiple stages:

1. The planner checks whether a proposed scene advances existing obligations
   and avoids introducing excessive new ones.
2. The context builder supplies the drafter with relevant open promises and
   recent introduced elements.
3. The post-prose extractor registers new promises and identifies
   reinforcement, complication, payoff, or accidental abandonment.
4. The continuity auditor reports unsupported specificity, forgotten
   high-salience promises, unearned payoffs, and repetitions without
   development.
5. Act, chapter, and arc boundary audits apply stricter checks for overdue
   obligations.

The system may suggest future uses for an introduced element, but suggestions
remain planned candidates. It must not silently rewrite the outline merely to
justify an accidental detail.

### 11.6 Information-delivery contract

Every story and major arc defines how readers are expected to learn about its
world, characters, systems, history, and mysteries. This is a hard craft
contract, not a request to "avoid exposition" in the abstract.

Supported delivery modes include:

- `instruction`: a teacher, mentor, briefing, lesson, or demonstration
  explicitly explains a concept
- `demonstration`: the reader observes a rule being used successfully
- `consequence`: the reader sees the cost of a rule before receiving its
  explanation
- `environmental_inference`: material conditions, behavior, architecture,
  prices, rituals, or other clues imply the truth
- `dialogue_conflict`: characters reveal information because they disagree,
  negotiate, accuse, persuade, or correct one another
- `document`: an in-world letter, law, inscription, report, interface, or
  historical source conveys information
- `investigation`: characters and readers assemble evidence together
- `dramatic_irony`: readers learn something that focal characters do not
- `unreliable_explanation`: the story supplies an explanation intended to be
  incomplete, biased, or false
- `withheld`: the information remains deliberately unavailable while fair
  clues accumulate

Direct instruction is valid when the scene naturally contains a knowledge
asymmetry and a reason to teach. A classroom can explain magic to students and
the reader simultaneously. The explanation should still involve character
goals, misunderstanding, risk, disagreement, application, or consequence so
the teacher does not become an authorial reference manual.

Environmental inference is valid only when the prose supplies enough
consistent evidence for the intended conclusion. The system must distinguish
"the reader can reasonably infer this" from "the author knows this but never
put it on the page."

### 11.7 Revelation planning

`narrative_information_items` represents information the story may disclose:

- fact, rule, history, identity, motive, relationship, danger, or secret
- required prerequisite knowledge
- affected entities and arcs
- reader importance
- mystery sensitivity

`narrative_revelation_plans` defines:

- target information item
- intended delivery mode
- intended story-position window
- viewpoint and possible delivering characters
- evidence or clue requirements
- desired reader state after the reveal
- characters who should gain or retain the knowledge
- whether the information is complete, partial, misleading, or confirmed
- later application or payoff

Reader understanding is tracked separately from world truth and character
knowledge:

- `unknown`
- `noticed`
- `suspected`
- `partially_understood`
- `misled`
- `understood`
- `confirmed`

This allows the system to answer three different questions:

1. What is actually true?
2. Which characters know or believe it at this point?
3. What can a careful reader reasonably understand at this point?

### 11.8 Revelation checks

The planner checks that every intended explanation has a dramatic reason to
occur and that inference-based reveals have sufficient clues.

The drafter receives only revelation instructions relevant to the current
scene, including what must remain unstated.

The post-prose extractor records:

- explicit claims made in prose
- evidence and environmental clues shown
- which characters witnessed or learned them
- the likely resulting reader state
- whether the planned delivery mode was followed

The auditor flags:

- reference-manual exposition with no scene-level motive
- characters explaining shared knowledge solely for the reader
- conclusions unsupported by visible evidence
- accidental early revelation
- viewpoint knowledge leaks
- repeated explanations after reader understanding is established
- terminology introduced before enough grounding exists
- mysteries withheld without fair clue progression

Story-level defaults may favor one mode, while individual concepts override
it. A progression-fantasy academy may use frequent instruction for foundational
rules but require rare abilities to be discovered through dangerous
experimentation. A mystery may require environmental inference for the central
crime while allowing direct explanation of routine police procedure.

### 11.9 Ordered scene and chapter quality gate

Every completed scene receives a compact evaluation. Every completed chapter
receives the same evaluation across both its individual scenes and its total
shape.

The checks are ordered. A lower-priority success cannot compensate for failure
of a higher-priority requirement.

#### Priority 1: Was it engaging and rewarding to read?

"Fun" means appropriate reader engagement, not mandatory comedy or happiness.
A tragic, frightening, romantic, contemplative, or disturbing scene can be fun
to read when it creates compelling attention and reward.

Check:

- Is there a source of curiosity, anticipation, tension, emotion, wonder,
  humor, recognition, dread, or satisfaction?
- Does the experience change rather than remain on one emotional and rhythmic
  level?
- Are the strongest moments dramatized rather than summarized away?
- Does the scene contain unnecessary passages where neither experience nor
  meaning develops?
- Does the ending create satisfaction, consequence, or desire to continue?
- Would the intended reader miss anything enjoyable if the scene were reduced
  to an outline bullet?

Failure at Priority 1 triggers revision even when the scene is structurally
correct.

#### Priority 2: Did voice separation and immersion remain intact?

Check:

- Does the narrator remain within its voice contract?
- Does the POV lens select only available perceptions and knowledge?
- Does each character sound like themselves rather than the narrator, another
  character, or a generic witty model?
- Are intentional free-indirect passages permitted and controlled?
- Does every image, idiom, explanation, and observation belong to the world?
- Did documentation language, modern assumptions, author commentary, or model
  phrasing leak into the prose?
- Did comedy, romance, action, or exposition preserve the base narrative
  identity?

Unintentional voice bleed, knowledge leakage, or out-of-world intrusion is a
hard failure.

#### Priority 3: Did something meaningfully advance?

The external plot need not move in every scene, but at least one durable track
must change:

- causal plot position
- character goal, belief, capability, decision, or state
- relationship trust, intimacy, conflict, obligation, or power
- reader knowledge, suspicion, or interpretation
- world state or understanding
- danger, opportunity, cost, or available options
- setup, complication, reinforcement, or payoff

The evaluator identifies the before state, after state, and evidence in prose.
If it cannot name a meaningful delta, the scene must be revised, combined with
another scene, or intentionally classified as a rare experiential interlude
with a documented purpose.

#### Priority 4: Did behavior follow character logic?

- Decisions follow goals, knowledge, pressure, and established capability.
- Emotional movement has sufficient cause.
- Competence is preserved unless the failure is motivated.
- Relationships affect behavior at their current stage.

#### Priority 5: Was information delivered correctly?

- Revelations follow their delivery contract.
- Inference has visible evidence.
- Direct explanation has a scene-level reason.
- Required information is clear enough for its intended reader state.
- Protected information remains unrevealed.

#### Priority 6: Were promises and consequences respected?

- Introduced specificity has a narrative function.
- Existing high-salience promises are reinforced, complicated, paid off, or
  intentionally deferred.
- Prior injuries, decisions, losses, and changes still matter.
- Payoffs are supported by setup.

#### Priority 7: Did tonal elements integrate rather than compete?

- Comedy, romance, action, quiet life, exposition, and horror serve the scene.
- Relief does not erase consequence.
- Intimacy does not ignore urgent pressure without reason.
- Action does not suspend character and causality.
- The mixture matches the scene and volume contracts.

#### Priority 8: Is continuity intact?

- Timeline, location, travel, possession, knowledge, abilities, world rules,
  names, and physical state remain coherent.
- Branch-specific facts do not leak across paths.
- The scene creates no unresolved hard contradiction.

#### Priority 9: Is the prose technically effective?

- Sentences are clear and intentionally varied.
- Description is specific without becoming inert.
- Dialogue attribution and spatial action remain legible.
- Repetition is purposeful.
- Paragraph and scene transitions control pace.

#### Priority 10: Does the chapter work as a complete unit?

For chapter-level evaluation:

- Scenes build rather than merely coexist.
- The chapter has a discernible experiential and structural shape.
- Its opening establishes useful momentum.
- Its ending changes expectation, state, or urgency.
- Narrative tracks are balanced according to the blueprint.
- The chapter earns its place in the arc.

### 11.10 Quality-gate output and revision

The evaluator returns evidence-backed structured results:

```json
{
  "scope": "chapter",
  "scope_id": "chapter-12",
  "result": "revise",
  "highest_failed_priority": 2,
  "checks": [
    {
      "priority": 1,
      "code": "engagement.reward",
      "result": "pass",
      "evidence": ["The failed demonstration reverses the scene objective."]
    },
    {
      "priority": 2,
      "code": "voice.narrator_character_bleed",
      "result": "fail",
      "spans": ["paragraph-18"],
      "explanation": "The narrator adopts Lyra's all-caps emotional phrasing outside dialogue."
    }
  ],
  "revision_constraints": [
    "Preserve the demonstration outcome and Rorann's spoken deadpan.",
    "Restore the narrator's established observational register."
  ]
}
```

Revision starts with the highest failed priority. It must preserve passing
higher-priority qualities while repairing lower ones. The system does not
flatten voice or remove enjoyable character texture merely to improve a
technical score.

## 12. Prose, Revisions, and Retrieval

`narrative_prose_revisions` stores immutable drafts:

- node UUID
- parent revision UUID
- full text or content path
- author source: user, model, import
- model and generation job
- lifecycle status
- word count and content hash
- creation time

`narrative_prose_patches` records the ordered mutations that produced a
revision:

- parent and resulting revision UUIDs
- operation and stable anchors
- inserted, replaced, deleted, or moved blocks
- chapter, scene, beat, and job cursor
- model invocation and context-manifest UUID
- validation result and provisional change-set UUID
- creation time

Accepted prose is chunked into `narrative_prose_chunks` by semantic passage,
not arbitrary fixed token boundaries. Each chunk records:

- story, branch, node, and revision
- ordinal position
- characters
- POV
- location
- timeline position
- involved threads and entities
- short chunk summary
- embedding
- canonical visibility

Rejected and superseded revisions remain searchable only when explicitly
requested.

Raw prose retrieval is used for exact callbacks, descriptions, voice, and
local continuity. Structural planning should primarily operate on typed state,
summaries, and milestones.

### 12.1 Prose is written through scoped patches

The writer model does not return a chapter as ordinary assistant text. It
operates against a revisioned manuscript buffer through narrative tools.

The default mutation unit is a `ProsePatch` containing one coherent passage,
normally one to three paragraphs. A patch may contain several more paragraphs
when they form one inseparable exchange or micro-sequence. A complete scene is
the high-end unit and must be explicitly requested by the operation profile;
it is never the default for a chapter job.

```json
{
  "node_id": "scene-uuid",
  "expected_revision_id": "revision-uuid",
  "operation": "insert_after",
  "anchor": {
    "block_id": "paragraph-42",
    "content_hash": "..."
  },
  "prose": "...",
  "beat_ids": ["beat-3"],
  "intent": "Lyra realizes what Rorann is about to do."
}
```

Supported mutations are:

- insert before or after an anchored block
- replace an exact anchored range
- delete an exact anchored range
- move a block range within the same revision

Every mutation requires an expected revision and stable block anchors. A stale
revision fails with the new revision ID and a small surrounding diff; the
model must re-read before retrying. The system never asks the model to
reproduce all unchanged prose.

After a successful patch, the tool returns:

- new revision and block IDs
- the accepted local prose window
- remaining scene beats
- updated word-count and pacing indicators
- provisional facts and state changes extracted from the patch
- blocking continuity or voice findings
- the writer's next legal operations

This result gives the agent an external working memory and an exact cursor.
The model does not need to remember its place from chat history.

### 12.2 Passage authoring loop

A chapter or scene authoring job repeatedly performs:

```text
inspect current cursor and remaining beats
→ retrieve only missing story dependencies
→ compose one bounded passage
→ finish writer pass with anchored prose patch and continuation capsule
→ extract provisional state and run local checks
→ re-read the accepted boundary
→ continue, repair, close the scene, or stop
```

Each passage cycle is a fresh bounded model invocation. The writer may use
read-only retrieval tools inside that invocation, but a successful
`finish_writer_pass` ends the writer turn. That terminal tool atomically
submits an anchored `ProsePatch` and proposed continuation capsule. Extraction
and checks run outside the model, then the context builder compiles the next
invocation from durable state. Tool transcripts and discarded reasoning from
earlier cycles are not replayed automatically.

This distinction is important: the chapter job is one long agentic process,
but it is not one endlessly growing model conversation.

The loop has explicit ceilings for patch count, wall time, output words, and
tool calls. Reaching a ceiling creates a resumable checkpoint rather than
prompting the model to rush through the remaining chapter.

The orchestrator, not the model's conversation transcript, owns:

- current chapter, scene, beat, and prose cursor
- exact accepted revision
- completed and remaining beats
- job-local character, relationship, timeline, and reader-knowledge state
- context manifests used by each patch
- local findings and repairs still required

Passage extraction updates this working state after every accepted patch.
Broad documentation views and embeddings may be refreshed asynchronously.
At a scene boundary, the system runs the complete scene quality gate and
commits the scene prose plus consolidated documentation changes in one story
version. If the job pauses mid-scene, its patch revisions and provisional
state remain recoverable but are clearly marked as an unfinished checkpoint.

### 12.3 Continuation capsules

Structured story state captures durable truth, but it does not fully capture
the immediate handoff between two small prose passes. Each successful writer
pass therefore creates a job-local `ContinuationCapsule`.

The model proposes anything the next pass must retain to remain locally
coherent:

- an unfinished physical action or movement
- exact blocking and where characters or objects currently are
- an unanswered line of dialogue or conversational thread
- immediate emotional momentum or subtext
- a sentence-rhythm or tonal handoff
- an exact fragment intended to open the next passage
- a detail that must not be repeated
- a near-term intention not important enough for permanent documentation

Example terminal tool call:

```json
{
  "patch": {
    "expected_revision_id": "revision-uuid",
    "operation": "insert_after",
    "anchor": {"block_id": "paragraph-42", "content_hash": "..."},
    "prose": "..."
  },
  "continue_context": {
    "handoff": "Lyra has grabbed the larger venom sac against Rorann's chest.",
    "items": [
      {
        "kind": "unfinished_action",
        "value": "Rorann has not yet responded to the physical restraint.",
        "priority": "required",
        "ttl_passes": 1,
        "source_block_ids": ["paragraph-43"]
      },
      {
        "kind": "dialogue_thread",
        "value": "Preserve the contrast between Lyra's panic and Rorann's literal calm.",
        "priority": "preferred",
        "ttl_passes": 2,
        "source_block_ids": ["paragraph-41", "paragraph-43"]
      }
    ]
  }
}
```

The post-patch extractor validates and augments the proposal from accepted
prose, the writer cursor, provisional state deltas, remaining beats, and
pending protected moments. Unsupported claims are rejected. Required
continuity detected by the system is added even when the writer omits it.

The next writer invocation receives the capsule automatically, immediately
after its cursor and exact prose boundary. Capsules are deliberately small:

- target 200–600 tokens
- hard ceiling 1,000 tokens
- default lifetime of one pass
- explicit priority and remaining TTL on every item
- source block IDs for factual handoff claims

An item is consumed, renewed with evidence, promoted into provisional
structured state, or expired. Capsules cannot override canon, beat plans,
protected moment anchors, or hard constraints. They are not embedded as story
documentation and cannot accumulate indefinitely.

This creates two complementary memory channels:

```text
durable typed state       = what remains true
continuation capsule      = what the next writer must keep in mind right now
```

## 13. Automatic Documentation Maintenance

Story documentation is a collection of generated views over a finite set of
typed narrative records. It is maintained after every completed prose
generation without user input.

### 13.1 Documentation registry

The initial registry covers the recurring documentation families used by most
stories:

| Documentation family | Structured sources |
|---|---|
| Story identity | premise, genre, themes, tone, audience, promises |
| Structure | volume contracts, books, acts, arcs, chapters, scenes, beats, branches, hooks |
| Characters | identity, appearance, traits, goals, abilities, possessions, knowledge, current state |
| Relationships | participants, dynamic, trust, intimacy, conflict, phase, progression |
| World facts | geography, locations, history, cultures, languages, species |
| Society | factions, politics, laws, ranks, organizations, religions, customs |
| Economy | currencies, denominations, prices, trade, resources, measurements |
| Systems | magic, technology, combat, progression, limitations, formulas |
| Timeline | events, dates, ages, travel, simultaneity, causal ordering |
| Plot management | arcs, threads, mysteries, story promises, introduced elements, milestones, foreshadowing |
| Information design | revelation plans, clue chains, reader understanding, character knowledge |
| Style and voice | narrator contract, POV permeability, character voices, prose rules, comedy contract, humor profiles, exemplars, negative preferences |
| Continuity | active state, established facts, contradictions, unresolved warnings |

This registry is extensible, but a new story should normally reuse these
families rather than inventing arbitrary document types. Genre-specific
material is represented by entities, facts, relationships, rules, and events
within the same families.

For example, a fantasy currency and a science-fiction credit system are both
economy records. A cultivation realm and a military rank are both progression
or social-hierarchy records with different predicates.

### 13.2 Post-prose pipeline

When prose generation finishes, the daemon performs:

```text
Completed prose
      |
      +-- Save immutable prose revision
      +-- Produce scene summary and retrieval chunks
      +-- Extract mentioned entities and aliases
      +-- Extract new facts and changed facts
      +-- Extract character and relationship state deltas
      +-- Extract timeline events and knowledge transfers
      +-- Update clues, revelations, and reader-understanding state
      +-- Advance/open/resolve plot threads
      +-- Register, reinforce, or pay off story promises
      +-- Record comedy modes, callbacks, and character dynamics
      +-- Detect newly established world and system rules
      +-- Evaluate continuous writing guidelines
      +-- Run the ordered scene quality gate
      +-- Validate against the prior branch snapshot
      +-- Build the next branch snapshot
      +-- Refresh embeddings and affected documentation views
      +-- Commit one new story version
```

The extraction result uses a schema-validated `NarrativeChangeSet`. It includes
the prose revision, additions, state transitions, closed validity ranges,
thread changes, warnings, and provenance spans pointing into the prose.

### 13.3 Update behavior

Updates are incremental. The daemon does not regenerate an entire story bible
after each scene.

- A newly introduced fact creates an accepted fact with a source span.
- A changing fact closes the prior fact's validity range and creates its
  successor.
- A relationship event appends a state delta and may advance its progression
  phase.
- A shown clue or explanation advances its revelation plan and the modeled
  reader and character knowledge states.
- An emphasized new detail creates or updates a tracked story promise.
- A mentioned but unchanged fact reinforces provenance without duplicating it.
- A planned milestone satisfied by the prose becomes established.
- A planned event contradicted by accepted prose is marked displaced or
  conflicted; the prose remains authoritative.
- New aliases are linked to an existing entity when identity is unambiguous.
- Scene summaries, entity tags, and prose chunks are regenerated only for the
  affected revision.

### 13.4 Non-blocking conflict policy

Documentation maintenance must not stop the writing flow for routine
ambiguity.

- Safe additions and state transitions commit automatically.
- Low-confidence extractions are stored as inferred records and excluded from
  authoritative retrieval.
- Direct contradictions create a `narrative_conflict` containing both claims,
  their evidence, and a suggested resolution.
- Hard world-rule violations are surfaced with the completed prose and may
  trigger one automatic repair pass when configured.
- Unresolved conflicts appear in a review inbox and continuity audits, but no
  approval dialog is required to finish the scene.

The story-version transaction makes automatic updates reversible. Undoing a
prose version also removes or supersedes the documentation changes derived
from it and restores the previous branch snapshot.

### 13.5 Documentation projections

Human-readable documentation is rendered on demand from structured records:

- character dossier at the current scene or any earlier point
- relationship progression timeline
- world encyclopedia
- economy and currency guide
- magic or technology system handbook
- faction and political landscape
- active outline and milestone schedule
- open-thread ledger
- style and character-voice guide
- continuity report

These projections may be cached, but the cache is invalidated by the typed
records it depends on. They are never independently edited copies of canon.

## 14. Context Construction

Narrative context is assembled for a specific command, story, branch, and
node. It is not a global top-K similarity search.

### 14.1 Deterministic context

Always load as required by the operation:

- story identity and active version
- active branch ancestry
- current node and structural neighbors
- scene card
- narrator, POV, scene-tone, and speaking-character voice contracts
- POV character state
- facts known, believed, or unknown to that POV character
- entities explicitly referenced by the scene
- world rules applying at this story position
- active hard constraints
- arcs and milestones intersecting the node
- compact volume, arc, chapter, scene, and beat trajectory
- recent pacing movement and bounded lookahead
- pending protected moment anchors in or approaching their placement window
- open threads relevant to the node
- open story promises whose setup, reinforcement, or payoff is relevant
- revelation instructions, clue obligations, and facts that must remain hidden
- relevant character, relationship, and story-level comedy profiles
- final passage of the previous accepted scene
- active validated continuation capsule for the writer cursor

### 14.2 Semantic context

Search only after filtering by:

- story UUID
- accepted canonical visibility
- active branch ancestry
- story position not later than the current node, unless planning
- requested entity, POV, location, arc, or thread tags
- retrieval source type

Then rank eligible summaries, facts, exemplars, and prose chunks using hybrid
FTS/vector search.

### 14.3 Context packet and budget policy

The model does not receive the same human-readable pages displayed in Docs &
Plans. `NarrativeContextBuilder` compiles relevant records into a compact
`NarrativeContextPacket`:

- stable record ID and source type
- concise authoritative value
- story-position and branch scope
- planned, established, inferred, or conflicted status
- only fields relevant to the operation
- provenance pointer rather than full source text

The full generated character dossier, world handbook, or Markdown plan is not
included unless the user explicitly attaches it. This prevents duplicated
prose and decorative headings from consuming context.

The usable input budget is:

```text
minimum(
    operation hard ceiling,
    model context window
      - reserved output
      - tool-result reserve
      - safety margin
)
```

Default operation targets:

| Operation | Target input | Hard input ceiling | Output reserve |
|---|---:|---:|---:|
| Direction suggestions | 6K | 10K | 2K |
| Exact paragraph revision | 4–8K | 10K | 400–1,200 |
| Passage prose patch | 6–12K | 16K | 600–1,800 |
| Scene plan | 8–12K | 16K | 2K |
| Explicit scene-at-once draft | 14–20K | 24K | 3–5K |
| Chapter architecture | 10–16K | 20K | 3K |
| Chapter coherence audit | 16–28K | 36K | 3K |
| Documentation analysis | 8–14K | 20K | 3K |
| Arc/volume planning | 12–20K | 28K | 4K |

Larger model windows do not automatically increase these targets. Additional
context must earn inclusion through deterministic applicability, retrieval
score, explicit attachment, or a narrative tool request.

Every included item and truncation decision is logged in the context manifest.

### 14.3.1 Paragraph and passage context recipe

A paragraph revision or bounded prose patch normally receives:

| Context | Target |
|---|---:|
| User instruction and output contract | 300–700 |
| Active cursor plus 2–6 surrounding paragraphs | 800–3,000 |
| Validated continuation capsule | 200–600 |
| Hierarchical pacing envelope | 1,500–3,000 |
| Compact always-on writing contract | 400–800 |
| Routed narrator, POV, character voice, and craft rules | 400–1,200 |
| Relevant current character/relationship state | 400–900 |
| Applicable world facts and hard rules | 300–800 |
| Active promise/revelation tied to the passage | 200–600 |
| One or two retrieved exemplars or callbacks | 0–1,000 |

An exact paragraph revision targets 4–8K input tokens with a 10K ceiling. A
new passage patch targets 6–12K with a 16K ceiling because it may need more of
the entering state and dialogue participants.

The always-on writing contract is a short compiled kernel containing the
ordered quality priorities and universal prohibitions. Detailed comedy,
romance, action, exposition, mystery, or other guidance is routed only when
the scene card, prose, or user request activates it. Following every guideline
does not mean pasting every guideline into every call.

A paragraph revision does not automatically receive:

- the whole chapter
- unrelated character dossiers
- the entire world bible
- previous authoring chat
- future arc plans

It can request a chapter excerpt or specific documentation record through a
tool when the local change depends on broader context.

### 14.3.2 Hierarchical pacing envelope

Local prose alone is insufficient for good pacing. Every new-prose patch
receives a compact `PacingEnvelope` that preserves trajectory at several
scales:

| Scale | Included signal |
|---|---|
| Volume | destination, current phase, and what must not resolve yet |
| Arc | present escalation step, arc movement, and next structural turn |
| Chapter | purpose, entering/exit state, target shape, and scene sequence |
| Scene | purpose, tension movement, emotional turn, and exit condition |
| Beat | current obligation, entry state, desired change, and completion test |
| Lookbehind | what the last one or two beats accomplished |
| Lookahead | next two or three beats and what this passage must leave available |
| Anchors | exact or semantic moments pending in the current placement window |

The envelope also carries a small pacing ledger:

- target and current chapter/scene word ranges
- approximate progress through the chapter and current scene
- recent tension and emotional-intensity movement
- dialogue, action, exposition, reflection, comedy, and relationship texture
  used recently
- revelations delivered or deliberately withheld
- protected quotes and moments approaching, placed, or still pending
- unresolved setup introduced in the recent runway
- repetition and stagnation warnings

This is structured telemetry and concise intent, not thousands of words of
outline prose. A typical envelope costs 1.5–3K tokens while making the next
move much more obvious than a large undifferentiated chapter excerpt.

The context builder runs a pacing-sufficiency gate before invoking the writer.
It must be able to answer:

1. What changed immediately before this cursor?
2. What must this passage accomplish?
3. What must it avoid resolving or revealing?
4. What should become possible immediately afterward?
5. How much narrative space remains in the scene and chapter?

If any answer is missing or contradictory, the system plans or retrieves
first instead of asking the writer to guess.

Under context pressure, compression order is explicit:

1. Remove optional style exemplars.
2. Remove authoring-conversation excerpts.
3. Compress distant prose into summaries.
4. Reduce unrelated entity detail.
5. Compress higher-level plans to their directional constraints.

The active continuation capsule, current beat, immediate lookbehind, bounded
lookahead, exit condition, and hard revelation constraints are never dropped.
Pending verbatim anchors in their placement window are also never summarized
or dropped. If those cannot fit, the operation fails preflight rather than
generating under-informed prose.

### 14.3.3 Explicit scene-at-once context recipe

A complete scene draft is an opt-in high-output operation, not the default
writer behavior. When explicitly selected, it normally receives:

| Context | Target |
|---|---:|
| Operation contract and selected craft rules | 700–1,200 |
| Scene card, beats, purpose, and exit target | 700–1,200 |
| Entering branch state | 1,500–3,000 |
| Relevant character and relationship state | 1,000–2,000 |
| Applicable world facts and rules | 800–2,000 |
| Promises, threads, milestones, and revelations | 800–1,500 |
| Previous scene ending | 800–1,500 |
| Earlier prose in the current chapter | 0–6,000 |
| Retrieved past excerpts and style exemplars | 500–2,000 |
| User direction | 200–700 |

Target total: 14–20K tokens. Hard ceiling: 24K.

### 14.3.4 Whole-chapter operation

"Write chapter" is not one giant generation call. It is an orchestrated
workflow:

```text
Chapter architecture
→ scene cards and transitions
→ open scene 1 at beat 1
→ write an anchored passage patch
→ extract job-local state and advance the cursor
→ re-read the local boundary
→ repeat passage patches until the scene closes
→ run the scene quality gate
→ repeat for later scenes
→ assemble chapter
→ chapter quality gate and coherence audit
→ one coordinated repair if required
→ commit chapter and documentation atomically
```

The architecture call receives 10–16K tokens:

- volume and arc destination
- chapter contract
- entering state
- required milestones, promises, and revelations
- previous chapter summary and ending
- relevant character/relationship trajectories
- applicable voice and craft contracts
- bounded older callbacks

Each writer turn follows the paragraph/passage recipe above and normally adds
one to three paragraphs through `apply_prose_patch`. The writer can call
retrieval tools before committing a patch and can inspect the accepted local
boundary afterward. It receives the exact immediately preceding prose,
structured summaries of completed scenes, and only the earlier passages
needed for callbacks or coherence.

The chapter audit receives:

- complete generated chapter, normally 5–10K tokens
- chapter contract and scene cards
- entering and proposed exit state
- compact relevant canon
- required promises, revelations, and narrative tracks
- narrator/voice contract and ordered quality gate

Target audit input: 16–28K tokens. Hard ceiling: 36K.

Every accepted patch is saved as a recoverable draft revision while the
workflow runs. Its extracted changes update a job-local working snapshot.
Scene closures create stronger checkpoints and consolidate documentation.
Unfinished work does not partially change canonical story state. After the
chapter passes the quality gate, the accepted scene versions and remaining
chapter-level documentation changes commit as one story version. An
interrupted workflow can resume from its last accepted patch and exact cursor.

The default chapter workflow therefore uses many small, revision-checked
authoring turns instead of relying on one model to retain coherence through a
very long output. “Write chapter” is an orchestration goal, never permission
for a chapter-sized prose response.

### 14.4 Selection-scoped operation profiles

The selected story object determines model role, available operations, context
recipe, and prompt emphasis.

| Selection | Primary model behavior | Default context |
|---|---|---|
| Story/series | intent, theme, long-range architecture | intent profile, series promises, volume summaries |
| Volume | destination and arc architecture | volume contract, entering state, reader targets, arc summaries |
| Arc | escalation and progression design | arc contract, adjacent arcs, milestones, threads, revelation plan |
| Chapter | chapter shape and scene sequencing | chapter goal, scene cards, entering state, previous chapter summary |
| Scene | direction selection and prose drafting | scene card, current state, previous ending, relevant facts and excerpts |
| Prose selection | local revision or analysis | selected text, containing scene, voice rules, requested craft skill |
| Documentation record | canon editing and implications | record, provenance, dependents, conflicts, valid story range |

These are `NarrativeOperationProfile` records rather than hard-coded prompt
strings. Each profile specifies:

- model role and instruction template
- required deterministic context
- permitted semantic retrieval sources
- raw-prose budget
- allowed narrative tools
- default craft skills
- output contract
- audit requirements

Changing selection changes the operation profile before the next model call.
The UI always displays the active selection and model mode.

### 14.5 Conversation isolation and context priority

Narrative Studio must not use the normal chat adapter's conversation replay as
its primary context mechanism.

Every narrative operation starts from a fresh operation context built in this
priority order:

1. Current user instruction
2. Selected story, branch, version, and structural position
3. Applicable intent, volume, arc, chapter, and scene contracts
4. Authoritative canon and current state
5. Relevant promises, threads, revelations, guidelines, and craft profiles
6. Active continuation capsule and immediately preceding prose boundary
7. Immediately preceding scene or chapter boundary text
8. Retrieved summaries and exact prose excerpts
9. A small amount of directly relevant authoring conversation, only when
   necessary

Authoring conversation is treated as interaction history, not story truth.
Durable user decisions are extracted into intent profiles, contracts, plans,
rules, or records. Once captured structurally, the original conversation does
not need to remain in the drafting prompt.

The generic ClawForge compacted-message history is not supplied to narrative
drafting by default. A narrative operation may retrieve an earlier author
discussion explicitly when the user refers to it, but it must not inherit
dozens of unrelated chat turns simply because they share a session.

Raw prose follows the same principle:

- previous scene ending may load automatically
- relevant scene and chapter summaries load cheaply
- semantically relevant passages load as bounded excerpts
- an entire past chapter loads only on explicit request or a specialized audit
- the manuscript is never dumped wholesale into normal drafting context

### 14.6 Narrative authoring tools

The narrative model receives read-only, story-aware retrieval tools:

- `get_story_position_context`
- `get_volume_contract`
- `get_arc_plan`
- `get_chapter_plan`
- `get_scene_card`
- `get_storyboard_node`
- `list_storyboard_children`
- `query_story_documentation`
- `get_character_state`
- `get_relationship_state`
- `get_reader_knowledge`
- `get_revelation_plan`
- `get_open_threads`
- `get_story_promises`
- `search_past_chapters`
- `get_chapter_summary`
- `read_chapter_excerpt`
- `read_past_chapter`
- `search_prose`
- `get_context_manifest`

All tools require explicit story and branch scope. Position-sensitive tools
default to the selected node and prevent future or sibling-branch leakage.

`search_past_chapters` returns ranked chapter/scene summaries and matching
snippets. `read_chapter_excerpt` expands a bounded region. `read_past_chapter`
returns a complete chapter only when the model or user genuinely needs exact
long-form context.

The model may request additional information during an operation. Tool results
are added to the context manifest, remain subject to the operation token
budget, and do not become permanent prompt baggage.

Writer-role agents additionally receive narrowly scoped manuscript tools:

- `inspect_prose_window`
- `inspect_writer_cursor`
- `inspect_patch_result`
- `mark_beat_progress`
- `request_local_audit`
- `close_scene`
- `checkpoint_authoring_job`
- `finish_writer_pass`

They do not receive arbitrary filesystem writes or a `write_chapter_text`
tool. `finish_writer_pass` is the sole normal writer mutation path. It
atomically invokes the underlying `apply_prose_patch` operation and stores the
validated continuation capsule, enforcing revision IDs, stable anchors,
patch-size limits, node scope, and schema validation. Direct
`apply_prose_patch` remains available to the human editor and controlled
repair operations. `close_scene` succeeds only after required beats are
addressed and the configured scene gate has no blocking findings.

An agent loop may use many tool calls, but each call and model turn is bounded.
The job controller decides whether to continue from explicit state:

```text
continue when:
  chapter completion condition is false
  AND no blocking finding or user pause exists
  AND job budget remains

otherwise:
  checkpoint, request repair, finish, or wait for user steering
```

This makes “write chapter” a durable orchestration command rather than a
prompt asking for a long completion.

## 15. Agentic Workflows

### 15.1 Direction proposal

1. Load current state, open threads, arcs, and upcoming milestones.
2. Generate structurally distinct directions.
3. Predict consequences and affected records for each direction.
4. Validate hard constraints.
5. Save candidates.
6. Present choices without accepting any of them.

### 15.2 Scene planning and drafting

1. Create or update a candidate scene card.
2. Create or validate the ordered scene beat plan and protected moment
   anchors.
3. Retrieve deterministic scene context.
4. Let the agent request narrowly scoped additional context.
5. Initialize the writer cursor at the first incomplete beat.
6. Let the writer apply a bounded anchored prose patch.
7. Extract provisional facts, state deltas, beat satisfaction, and placed
   moment anchors from the accepted patch.
8. Run cheap local continuity, voice, and constraint checks.
9. Re-read the accepted boundary and repeat steps 4–8 until the scene
   completion condition is met.
10. Run the ordered scene quality gate and repair through further scoped
    patches when necessary.
11. Before a chapter job becomes `complete`, run the chapter documentation
    extractor over the accepted prose and mutable records. Apply validated
    record replacements, store beat evidence, and record a
    `ChapterDocumentationUpdate`.
12. If extraction fails, retain the accepted prose and pause the job in a
    recoverable post-processing state. Resuming retries extraction; it never
    writes the chapter passage a second time.
13. Commit scene prose, consolidated facts, deltas, summaries, embeddings, and
    documentation invalidations in one story-version transaction.
14. Present the prose, warnings, structural consequences, and undo control.

### 15.3 Continuity audit

The auditor compares a candidate against:

- facts valid at the scene position
- branch-local state
- knowledge possessed by each character
- timeline and travel feasibility
- ability and world rules
- unresolved and prematurely resolved threads
- introduced elements, open promises, and payoff support
- voice and POV constraints
- milestone pacing

Warnings have stable codes, severity, evidence, and suggested resolutions.
They are not merely prose commentary.

### 15.4 Craft skill packs

Romance, comedy, action, mystery, horror, dialogue, exposition, pacing, and
other craft domains are represented as modular `NarrativeCraftSkill` packs.
A pack is not necessarily a separate agent. It is a versioned bundle of:

- compact drafting guidance
- applicability triggers
- required narrative tracks and scene signals
- contraindications and protected tones
- relevant character or relationship profile fields
- a structured audit rubric
- positive and negative exemplars
- maximum prompt budget
- preferred evaluation model tier

Skill content is split into independently retrievable sections. Loading the
comedy skill does not require injecting its full taxonomy, discovery questions,
worked examples, and audit rubric into a drafting prompt. The router selects
only the guidance required for the current stage.

### 15.5 Skill routing

Narrative Studio uses three skill-loading layers:

1. **Always-on craft kernel**: a short invariant block covering causality,
   character motivation, POV integrity, meaningful scene change, consequence,
   story promises, and faithfulness to the scene contract.
2. **Pre-draft routed skills**: selected from the scene card, narrative tracks,
   character profiles, revelation plans, tone protections, and user intent.
3. **Post-draft detected skills**: added to auditing when extraction discovers
   an unplanned romantic, comedic, action, horror, or revelation beat.

Example:

```json
{
  "scene_tracks": {
    "primary": ["dangerous_training", "world_rule_demonstration"],
    "secondary": ["relationship", "comedy"]
  },
  "protected_tones": ["physical_danger_remains_real"],
  "routed_skills": [
    {"id": "action_consequence", "sections": ["drafting_rules"]},
    {"id": "integrated_comedy", "sections": ["character_incongruity", "tonal_protection"]},
    {"id": "relationship_progression", "sections": ["protective_attachment"]}
  ]
}
```

The drafting agent may request an additional skill section through a bounded
`load_narrative_skill` operation when it recognizes a genuine gap. Requests are
logged in the context manifest and constrained by the scene token budget. The
model is not expected to decide all routing from scratch.

The current generic ClawForge skill matcher should not be the only router for
this system. Narrative routing must consider structured scene state, not just
tool names and the latest user message.

### 15.6 Audit cascade

Running independent romance, comedy, plot, pacing, and continuity agents after
every scene would be expensive and can produce conflicting rewrites.
Narrative Studio instead uses a cascading audit:

#### Level 0: deterministic checks

No model call:

- schema and required-field validation
- branch and chronology checks
- entity and knowledge-scope checks
- prohibited content and protected-tone checks
- unresolved hard conflicts
- scene contract completion

#### Level 1: post-prose extraction

A small or economical model produces the `NarrativeChangeSet` already required
for documentation maintenance. It also identifies which craft dimensions
actually appeared in the prose and assigns confidence.

This is not an additional pass solely for quality auditing; it is part of the
normal persistence pipeline.

#### Level 2: consolidated routed audit

When triggered, one audit call receives the selected rubrics for all relevant
dimensions. It returns separate structured findings such as:

- `plot.causality`
- `romance.progression`
- `comedy.character_specificity`
- `comedy.tonal_undercut`
- `revelation.fair_evidence`
- `pacing.scene_movement`

The call evaluates interactions between dimensions, which isolated auditors
would miss. For example, it can recognize that a comedic reaction also
advances romance and explains a healing rule rather than judging the same beat
three times independently.

Level 2 is triggered by:

- low extraction confidence
- hard or high-severity guideline risk
- an important relationship, revelation, action, or payoff scene
- an unexpected tonal mode
- accumulated unresolved warnings
- explicit user preference for stricter auditing

Routine low-risk connective scenes may skip it.

#### Level 3: specialist escalation

A dedicated specialist audit runs only when:

- the consolidated audit finds a high-severity domain problem
- a scene is structurally central to that domain
- the user asks for specialist scrutiny
- the system is preparing a major revision

Examples include a first confession, climactic joke payoff, mystery reveal,
complex battle, traumatic death, or politically sensitive world explanation.

#### Level 4: boundary audit

At chapter, arc, and volume boundaries, background jobs evaluate longer-range
patterns that no single-scene audit can see:

- romantic or relationship progression across time
- comedy repetition, saturation, and tonal distribution
- plot causality and stalled threads
- promise setup and payoff
- character arc pacing
- revelation fairness and reader understanding
- action escalation and persistent consequences

Boundary audits may use specialists in parallel because their cost is
amortized over many scenes.

### 15.7 Revision coordination

Auditors produce findings and suggested changes, not independent rewritten
scenes. One revision coordinator ranks findings by severity and story intent,
detects conflicts between suggestions, and performs at most one coherent
repair pass unless a hard failure remains.

This prevents:

- a comedy auditor adding jokes that weaken grief
- a romance auditor adding intimacy that breaks pacing or established
  characterization
- a plot auditor removing character texture because it is not direct action
- several specialists repeatedly rewriting one another's fixes

A practical default per scene is therefore:

```text
several bounded writer-pass calls
+ incremental deterministic extraction after each patch
+ 0 or 1 economical model extraction at scene close
+ 0 or 1 consolidated audit call
+ 0 or 1 coordinated repair call
```

Specialist and long-range audits run selectively or at structural boundaries.
Static skill prefixes can use provider prompt caching where supported.

### 15.8 Out-of-character suggestion generation

After prose, documentation extraction, and any repair complete, a lightweight
background step refreshes an out-of-character suggestion set for the current
story position.

Suggestions may identify:

- plausible next directions
- opportunities to advance an open thread or promise
- relationship or character-development opportunities
- comedy, relief, intimacy, action, or quiet-life opportunities
- revelation and clue-placement opportunities
- continuity risks
- pacing risks
- questions the author may want to answer before continuing
- useful callbacks to earlier chapters

Each `NarrativeSuggestion` contains:

- type and concise title
- explanation and evidence
- affected narrative tracks
- related records and past prose
- predicted consequences
- urgency and confidence
- source story version and selected node
- status: live, pinned, used, dismissed, or stale

Suggestions are explicitly out of character and non-canonical. They are advice
for the author, not prose, story facts, or automatic outline changes.

When the story version advances:

- suggestions invalidated by new prose become stale
- satisfied suggestions become used
- still-relevant pinned suggestions survive
- new suggestions are generated from the updated documentation and state

Suggestion generation can reuse the extraction model or run as a cheap
background job. It must never delay saving completed prose.

### 15.9 Compilation

The compiler walks an accepted path and:

- verifies every prose-bearing node has an accepted revision
- applies chapter ordering
- renders front matter and chapter headings
- reports missing or conflicted nodes
- exports Markdown, plain text, and later EPUB/DOCX

For branching stories it can compile one chosen path or an interactive package.

### 15.10 Latency and cost control

The small-patch architecture deliberately spends more model round trips to
gain control and quality. Performance work must reduce overhead around those
turns rather than quietly restoring chapter-sized generations.

Use these controls:

- Keep the stable writer contract, tool schemas, and craft prefixes byte-stable
  so provider prompt caching can reuse them.
- Cache serialized structured records by story version and content hash.
- Precompute the next beat's deterministic context, pacing envelope, and
  likely retrieval candidates while the current writer call is running.
- Run independent retrieval, rule selection, and context serialization in
  parallel before invocation.
- Perform obvious cursor, anchor, word-count, beat, and state checks
  deterministically rather than calling a model.
- Route ambiguous extraction and routine documentation work to a faster,
  cheaper model when evaluation shows it is reliable.
- Batch embeddings, documentation projections, and non-blocking suggestions
  at scene boundaries or in background jobs.
- Reserve expensive creative audits for scene/chapter boundaries or triggered
  risks instead of auditing every paragraph with another model.
- Reuse provider connections and avoid re-sending tool transcripts from prior
  writer passes.
- Stream the candidate prose field to the UI while the terminal tool call is
  being formed, but expose it as uncommitted until validation succeeds.

Patch size is adaptive within strict limits. One to three paragraphs remains
the default. The controller may allow a larger coherent passage for a
low-risk transition, sustained action exchange, or dialogue run when:

- the current beat and exit condition are unambiguous
- no protected reveal or continuity hazard is near
- involved state is small and stable
- recent patches have passed without repair

It should contract back to one paragraph around reveals, delicate emotional
turns, complex blocking, lore delivery, branch points, or repeated failures.
A whole scene remains opt-in, and a whole chapter is never a prose-call size.

The writer loop is sequential because the next passage depends on accepted
prose. Speculative parallel prose generation is disabled by default; discarded
branches usually waste more tokens and create more coordination work than
they save in latency.

Performance evaluation must report separately:

- time to first visible prose
- median writer-pass latency
- chapter wall time
- writer, extraction, audit, and repair token cost
- prompt-cache hit rate
- patches per scene and repairs per patch
- user interventions and accepted-prose retention

The optimization target is cost and latency per accepted, retained word—not
raw tokens per call or minimum model-call count.

## 16. Structured Model Contracts

Planning, extraction, and auditing calls must return schema-validated data.
Writer calls terminate in schema-validated `finish_writer_pass` tool calls.
The prose field may stream to the UI as a candidate, but prose and continuation
metadata commit together only after the tool validates.

Example direction proposal:

```json
{
  "options": [
    {
      "title": "The command fractures",
      "summary": "Rorann's refusal divides the outpost leadership.",
      "tone": ["tense", "political"],
      "advances_threads": ["political-weaponization"],
      "delays_threads": ["romance-trust"],
      "predicted_deltas": [],
      "risks": ["Delays the planned first joint hunt"],
      "next_scene_card": {}
    }
  ]
}
```

Invalid output is repaired or rejected before it reaches storage.

## 17. Proposed Storage Groups

The exact SQL belongs in a later schema specification. The initial logical
groups are:

- Story/version: `narrative_stories`, `narrative_versions`,
  `narrative_branches`, `narrative_intent_profiles`,
  `narrative_discovery_sessions`, `narrative_volume_contracts`
- Structure: `narrative_nodes`, `narrative_edges`
- Canon: `narrative_entities`, `narrative_aliases`, `narrative_facts`
- State: `narrative_state_deltas`, `narrative_state_snapshots`
- Planning: `narrative_arcs`, `narrative_threads`,
  `narrative_milestones`, `narrative_beat_plans`,
  `narrative_moment_anchors`, `narrative_story_promises`
- Information: `narrative_information_items`,
  `narrative_revelation_plans`, `narrative_reader_state`,
  `narrative_character_knowledge`
- Rules/style: `narrative_rules`, `narrative_style_rules`,
  `narrative_exemplars`, `narrative_guidelines`,
  `narrative_guideline_findings`, `narrative_comedy_contracts`,
  `narrative_humor_profiles`, `narrative_comedy_beats`,
  `narrative_craft_skills`, `narrative_voice_contracts`,
  `narrative_audit_findings`, `narrative_quality_gate_results`
- Prose: `narrative_prose_revisions`, `narrative_prose_patches`,
  `narrative_prose_chunks`
- Workflow: `narrative_proposals`, `narrative_decisions`,
  `narrative_jobs`, `narrative_context_manifests`,
  `narrative_change_sets`, `narrative_continuation_capsules`,
  `narrative_suggestions`
- Integrity: `narrative_conflicts`, `narrative_sources`,
  `narrative_source_spans`

All story tables use stable UUIDs externally. SQLite integer row IDs may be
used internally for indexing.

## 18. Story Import

### 18.1 Documentation import

The Rorann's Rage corpus should be imported through a staged reconciliation
workflow:

1. Register each document and content hash as a source.
2. Split by semantic section while retaining source line spans.
3. Classify sections as profiles, rules, milestones, outlines, style,
   exemplars, or general notes.
4. Extract candidate entities, facts, arcs, milestones, and rules.
5. Normalize names and suggest entity merges.
6. Detect duplicate and conflicting assertions.
7. Present conflicts and uncertain classifications to the user.
8. Accept reconciled records into the first story version.
9. Preserve original Markdown as source evidence.

The importer must never silently declare all extracted statements canonical.

### 18.2 Prose-only reconstruction

The user may import a manuscript with no story bible and ask Narrative Studio
to reconstruct documentation from the prose.

The importer:

1. Registers the manuscript and preserves its exact source.
2. Detects books/volumes, chapters, scene boundaries, and POV where possible.
3. Creates immutable imported prose revisions and stable block IDs.
4. Summarizes chapters and scenes.
5. Extracts candidate entities, aliases, relationships, locations, objects,
   factions, rules, timeline events, and information state.
6. Reconstructs position-sensitive facts and state deltas from evidence spans.
7. Infers voice, tone, humor, relationship, and information-delivery patterns.
8. Identifies apparent arcs, threads, promises, milestones, and protected
   recurring moments as inferred candidates.
9. Separates what prose establishes from what the importer merely infers about
   authorial intent.
10. Detects contradictions, uncertain identity merges, and missing context.
11. Produces human-readable candidate documentation and a coverage report.
12. Requires user approval before creating the baseline accepted story
    version.

Review is staged rather than requiring approval of thousands of rows at once:

- story/chapter structure
- characters and aliases
- relationships
- world and rule systems
- timeline and state
- knowledge, mysteries, and revelations
- arcs, threads, and promises
- voice, style, comedy, and relational patterns

Every candidate links to exact manuscript evidence. The user can accept a
category, accept individual records, merge identities, edit values, mark an
inference as intentional, or reject it. Batch acceptance is allowed only for
conflict-free, evidence-backed candidates visible in the review summary.

Until approval, reconstructed records remain candidates in an import workspace
and are excluded from normal canonical retrieval. Accepted records and
imported prose are committed together as the first baseline story version.

Markdown export can later regenerate human-readable story-bible views from the
database, including:

- character dossier at a selected chapter
- active plot threads
- relationship development timeline
- world-system handbook
- chapter outline
- voice and style guide

These views are projections of the authoritative model.

## 19. Adapter and Protocol Requirements

Narrative Studio should use explicit story, branch, node, and session IDs on
every request. It must not depend on ClawForge's process-wide active session.

The adapter should emit typed SSE events:

- `job_started`
- `prose_patch_proposed`
- `prose_patch_accepted`
- `prose_patch_rejected`
- `writer_cursor_changed`
- `proposal_created`
- `structure_changed`
- `continuity_warning`
- `revision_saved`
- `revision_accepted`
- `documentation_updated`
- `context_manifest_ready`
- `job_completed`
- `job_failed`

Narrative work uses its own `NarrativeRuntime`, job pool, and per-worker SQLite
connections. It reuses the standalone inference runtime but does not create or
call the chat-oriented `Engine`. Generic shell and filesystem tools are
disabled by default. Narrative operations are exposed as domain commands or
tools.

## 20. Initial Service Commands

- `create_story`
- `start_author_room_thread`
- `continue_author_room_thread`
- `propose_story_decision`
- `accept_story_decision`
- `reject_story_decision`
- `start_discovery`
- `continue_discovery`
- `get_intent_profile`
- `approve_design_brief`
- `create_volume_contract`
- `recommend_arc_structures`
- `generate_blueprint`
- `start_arc_discovery`
- `import_story_documentation`
- `start_prose_reconstruction_import`
- `get_import_review`
- `approve_import_candidates`
- `reject_import_candidates`
- `commit_import_baseline`
- `get_story_dashboard`
- `get_narrative_model_profile`
- `update_narrative_model_profile`
- `change_job_role_model`
- `get_node_context`
- `propose_directions`
- `accept_direction`
- `create_or_update_scene_card`
- `start_chapter_authoring_job`
- `pause_authoring_job`
- `resume_authoring_job`
- `steer_authoring_job`
- `get_writer_cursor`
- `inspect_prose_window`
- `apply_prose_patch`
- `finish_writer_pass`
- `get_continuation_capsule`
- `checkpoint_authoring_job`
- `close_scene`
- `draft_scene_at_once` (explicit opt-in profile only)
- `revise_scene`
- `audit_continuity`
- `accept_revision`
- `reject_revision`
- `query_canon`
- `query_timeline`
- `query_open_threads`
- `query_story_promises`
- `query_revelation_plan`
- `get_story_position_context`
- `get_storyboard_node`
- `list_storyboard_children`
- `query_story_documentation`
- `search_past_chapters`
- `get_chapter_summary`
- `read_chapter_excerpt`
- `read_past_chapter`
- `load_narrative_skill`
- `run_craft_audit`
- `run_boundary_audit`
- `run_chapter_quality_gate`
- `search_prose`
- `get_documentation_view`
- `get_documentation_changes`
- `get_story_suggestions`
- `pin_story_suggestion`
- `dismiss_story_suggestion`
- `undo_story_version`
- `compile_story`

Commands return typed results and domain events rather than requiring clients
to parse Markdown.

## 21. Delivery Phases

### Phase 0: Runtime seams

- Extract generic provider invocation, streaming, cancellation, and bounded
  tool-loop mechanics from `core/engine.zig` into a standalone `inference`
  build module
- Move provider/model enumeration behind the shared inference `ModelCatalog`
  while preserving the existing `/api/models` response behavior
- Keep existing chat behavior passing through the extracted primitives
- Add the standalone `narrative` build module with enforced one-way imports
- Add `NarrativeRuntime`, its dedicated job pool, event bus, and connection
  ownership without implementing story behavior yet
- Split reusable HTTP request/response/router primitives from
  `web_adapter.zig`
- Add a thin narrative controller mount with a health endpoint

### Phase 1: Domain foundation

- Finalize terminology and SQL schema
- Add narrative migrations and stores
- Implement stories, branches, nodes, entities, facts, sources, and revisions
- Implement intent profiles, discovery sessions, and blueprint readiness
- Implement information items, revelation plans, and knowledge-state tracking
- Implement automatic story-version transactions, undo, and optimistic
  concurrency
- Add deterministic context queries

### Phase 2: Corpus importer

- Import Markdown sources with line-level provenance
- Import prose-only manuscripts and reconstruct candidate documentation
- Extract typed candidate records
- Add merge/conflict reconciliation UI
- Add staged approval and baseline-version commit
- Validate against the Rorann's Rage corpus

### Phase 3: Narrative orchestration

- Add direction, beat-plan, passage-patch writer loop, extraction, and audit
  workflows
- Add the post-prose `NarrativeChangeSet` pipeline
- Add craft-skill routing and consolidated audit rubrics
- Add specialist escalation and chapter/arc/volume boundary audits
- Add ordered scene and chapter quality gates with voice-integrity checks
- Add structured output schemas
- Add context manifests and token budgets
- Add filtered hybrid retrieval
- Add selection-scoped operation profiles and narrative retrieval tools
- Add post-update out-of-character suggestion generation

### Phase 4: Narrative web controller and studio

- Story dashboard
- Tool-enabled Author Room with decision proposals
- Import review and coverage workspace
- Outline/branch graph
- Story bible and timeline views
- Candidate choice cards
- Prose editor with revision comparison
- Continuity warnings, version history, and undo controls

### Phase 5: Compilation and refinement

- Linear manuscript compilation
- Branching playback and export
- Style learning from user feedback
- Retrieval evaluation and continuity test suite

## 22. Acceptance Criteria for the Architecture

The design is viable when it can:

- Keep all story-domain, authoring-loop, context-compilation, and narrative
  job logic out of `core/engine.zig` and transport adapters.
- Mount Narrative Studio through one thin web controller that depends only on
  the public `NarrativeService` API.
- Reuse provider and tool-loop mechanics through standalone inference
  primitives
  without importing `core` or calling the chat-oriented `Engine.process()`
  path.
- Run narrative jobs in a dedicated runtime and worker pool with independent
  database connections and lifecycle.
- Reuse the existing provider-grouped model catalog and selector while storing
  story defaults and per-role overrides independently from chat sessions.
- Snapshot resolved role models for active jobs and expose every explicit
  mid-job switch in history and context manifests.
- Import the reference corpus without losing source provenance.
- Hold normal story-aware Author Room conversations that can inspect story
  records and prose without treating conversation as canon.
- Convert a conversational conclusion into an explicit user-approved decision
  proposal and durable structured changes.
- Reconstruct candidate documentation from a prose-only manuscript, link every
  established claim to exact evidence, and require staged user approval before
  baseline commit.
- Represent repeated and conflicting milestones without choosing silently.
- Answer "What is true about Rorann at chapter 60 on the main branch?"
  deterministically.
- Answer "What was planned but not yet established by chapter 60?"
  separately.
- Conduct a resumable discovery interview and produce a structured intent
  profile before generating story or arc structure.
- Define a volume-level destination for story state, character and relationship
  change, reader understanding, revelations, promises, and emotional effect.
- Recommend alternative arc paths that explain how they reach the volume
  contract and what narrative tracks they advance.
- Prevent active prose drafting until the design brief and initial blueprint
  are ready.
- Require an accepted chapter/scene beat runway before prose generation while
  allowing later planning horizons to remain flexible.
- Carry pending verbatim quotes and other protected moments across fresh
  writer invocations until validated prose places, revises, or waives them.
- Link every satisfied protected moment to its exact accepted prose span.
- Draft a scene without loading all documentation or preceding prose.
- Keep a normal paragraph operation within its 4–8K target and 10K hard input
  ceiling unless the user explicitly changes the operation profile.
- Supply every new-prose patch with a compact multi-scale pacing envelope
  covering immediate movement, the active obligation, bounded lookahead,
  protected future material, and remaining scene/chapter space.
- Refuse prose generation when pacing preflight cannot determine what the
  passage must accomplish and preserve.
- Treat "write chapter" as a resumable agent loop whose prose mutations are
  anchored, revision-checked passage patches rather than a chapter-sized
  model response.
- Default each prose patch to one coherent passage, normally one to three
  paragraphs, and require explicit opt-in for a complete scene generation.
- Reject stale or oversized prose patches without reproducing or overwriting
  unchanged manuscript text.
- Restore an interrupted authoring job at its exact accepted revision, scene,
  beat, and block cursor.
- Atomically save each writer patch with a bounded continuation capsule and
  inject that capsule into the next fresh writer invocation.
- Validate model-proposed handoff items against accepted prose, augment
  omitted hard continuity automatically, and prevent capsules from becoming
  an accumulating substitute for structured state.
- Keep intermediate chapter state job-local and commit accepted prose plus
  documentation changes atomically.
- Build narrative prompts from selected story position and structured state
  without replaying generic chat history by default.
- Retrieve past chapters progressively through summaries, excerpts, and
  explicit full-chapter reads.
- Prevent facts from a rejected draft or sibling branch entering normal
  generation context.
- Show exactly which records and prose excerpts were supplied to a generation.
- Show estimated context before generation and the exact stage-by-stage
  context manifest after generation.
- Finish a scene and update its structured documentation without another user
  interaction.
- Track emphasized details as story promises and identify their later
  reinforcement, payoff, subversion, retirement, or abandonment.
- Track world truth, character knowledge, and reader understanding separately.
- Detect explanations that violate the story's selected information-delivery
  contract.
- Recommend proportionate romantic or relational texture when compatible with
  story intent without forcing it onto individual characters or changing the
  primary genre.
- Give major characters daily-life grounding beyond their immediate plot
  function.
- Represent distinct character humor profiles and produce comedy from
  character, situation, reaction, and consequence rather than generic jokes.
- Preserve serious consequences and protected tones when comedy is present.
- Keep narrator, POV, internal, and spoken-character voices within their
  configured separation or intentional permeability contracts.
- Apply the ordered quality gate so engagement, immersion/voice integrity, and
  meaningful advancement take precedence over lower-level polish.
- Route compact craft-skill sections from structured scene intent instead of
  loading every craft guide into every prompt.
- Use one consolidated audit for routine multi-domain evaluation and reserve
  specialist auditors for high-risk scenes and structural boundaries.
- Refresh non-canonical author suggestions after prose and documentation
  updates without delaying the prose commit.
- Commit a scene and all of its structural consequences atomically.
- Undo a prose version and restore its prior documentation state.
- Rebuild a human-readable story bible from structured storage.
- Compile accepted prose into a coherent manuscript.

## 23. Initial Implementation Decisions

### 23.1 Dedicated tables versus typed facts

Use dedicated tables for identity, structure, prose, jobs, versions, branches,
relationships, information state, plans, and other records with strong
invariants or frequent joins. Use typed atomic facts for extensible entity
attributes. Add materialized projections only after query profiling.

Do not place the whole domain into one entity-attribute-value table.

### 23.2 Story position identity

Stable node UUIDs are authoritative. Human-readable volume/chapter/scene
ordinal paths are derived, indexed projection fields. Reordering changes the
path but never identity or provenance references.

### 23.3 Extraction authority

Model self-reported confidence alone never creates authoritative canon.

Automatic provisional application requires:

- allowlisted operation/predicate
- accepted prose evidence
- valid story position and subject
- no hard conflict
- schema and deterministic validation

User-authored explicit facts and deterministic consequences may be accepted
directly. Ambiguous semantic extraction remains provisional or inferred until
the enclosing authoring boundary commits. Conflicting extraction is always
recorded as conflicted regardless of confidence.

Thresholds may rank review priority but do not replace these gates.

### 23.4 Automatic hard-rule repair

A deterministic blocking violation may trigger one automatic local repair
when the affected range is unambiguous and protected passing material can be
preserved. Otherwise the job checkpoints and surfaces the conflict. Model-only
suspicions produce findings, not automatic rewrites.

### 23.5 World-rule execution

MVP rules are typed declarative records with dedicated deterministic validators
for known rule families. Arbitrary user-authored executable expressions are
not supported. Models may interpret descriptive rules, but cannot execute code
stored in story documentation.

### 23.6 Story versus generic project

`NarrativeStory` is its own top-level workspace object with an optional link to
a generic ClawForge project. It does not require a one-to-one project row and
does not inherit generic project chat/session context automatically.

### 23.7 Role model configuration

Every narrative role has an independent optional model, token budget, and
timeout override. Unspecified roles inherit a narrative default, then the
global provider default. The active writer model is never silently replaced
with a cheaper model; routing changes are visible in the job and context
manifest.

Narrative Studio reuses ClawForge's existing model catalog behavior and
provider-prefixed IDs:

- searchable provider-grouped dropdown
- daemon/default inheritance
- live Ollama model discovery
- enabled Anthropic, OpenAI, OpenRouter, and Codex providers
- OpenRouter pricing metadata when available
- custom provider-prefixed model IDs where the provider permits them

Model enumeration must move behind the shared `inference` module's
`ModelCatalog` interface rather than remain coupled to
`WebAdapter.handleApiModels` or a chat `Engine`. Both Chat and Narrative web
controllers serialize that shared catalog.

Resolution order:

```text
explicit one-operation override
→ active job role override
→ story role override
→ story narrative default
→ global narrative role/default
→ provider/global daemon default
```

Narrative roles include:

- Author Room collaborator
- discovery interviewer
- structure director
- passage writer
- change extractor
- local model checker
- boundary auditor
- revision coordinator
- suggestion generator
- import reconciler

Every authoring job snapshots its resolved model profile at start so a settings
change cannot silently switch prose voice halfway through a chapter. The user
may explicitly apply a model change at the next safe pass boundary; that
change is recorded in the job history and context manifests.

Author Room and other one-turn operations resolve the latest profile at the
start of each turn.

The normalized catalog should expose, when known:

- stable provider-prefixed model ID
- provider and display label
- availability
- context-window ceiling
- tool/function-call support
- structured-output support
- streaming support
- input/output price metadata

Narrative role selectors filter or warn on incompatible capabilities. Writer,
extractor, director, auditor, and repair roles require reliable tool or
structured-output support. Context budgets always clamp to the selected
model's known window; selecting a larger model never causes optional context
to fill the available window automatically.
