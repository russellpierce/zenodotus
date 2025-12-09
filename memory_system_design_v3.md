# LLM-Driven Memory System Design

## Core Design Belief

**Vector search is necessary but insufficient.** While embeddings excel at surface-level similarity, they fail at:
- Conceptual relationships that don't share vocabulary
- Temporal reasoning ("what was I thinking before this decision?")
- Contextual relevance ("this matters NOW because...")
- Inferential connections ("A implies B, B relates to C")

LLMs can reason about relevance in ways embeddings cannot. This system treats memory retrieval as an agentic task, not just similarity matching.

## Design Assumptions

1. **Latency is not a primary constraint.** This system prioritizes retrieval quality and explainability over speed. Use cases are personal knowledge management, research assistance, and high-stakes decision support where waiting 2-5 seconds for well-reasoned retrieval is acceptable.

2. **Quality over throughput.** The system optimizes for precision and recall of truly relevant memories, not queries-per-second.

3. **Memories are living documents.** Following MemGPT/Letta patterns, autonomous agents continuously review and modify memories. The system must support version tracking, attribution, and temporal reasoning about memory evolution.

## Architecture

### 1. Base Storage Layer (PostgreSQL + pgvector)

```
memories:        id, key (base64), name (human-readable), value (500 chars), 
                 embedding, temporal fields (created, modified, reviewed, tended, accessed)
memory_versions: full history of value changes with attribution
tags:            id, name
memory_tags:     junction table with attribution
edges:           graph relationships with attribution
```

**Key addressing:**
- `key`: Auto-generated base64 identifier (compact, collision-free)
- `name`: Optional human-readable identifier (e.g., "quarterly-goals-2024", "mom-birthday")

**Rationale:** Direct key access (O(1) lookup), normalized tags, flexible graph structure, full audit trail.

### 2. Temporal Tracking

Each memory maintains five timestamps:

| Field | Purpose | Updated By |
|-------|---------|------------|
| `created_at` | Birth of memory | System (insert) |
| `modified_at` | Last value change | System (update trigger) |
| `last_reviewed_at` | Agent flagged for review | Review agent |
| `last_tended_at` | Agent performed maintenance | Tending agent |
| `last_accessed_at` | Retrieved in a query | Retrieval system |

**Temporal queries enabled:**
- "What was I thinking about X last month?"
- "Show memories I haven't revisited in 90 days"
- "What changed since my last session?"

### 3. Version History

Every modification to a memory's value is preserved:

```
memory_versions:
  - memory_id: reference to parent memory
  - value: the previous content
  - embedding: the previous embedding
  - modified_at: when this version was current
  - modified_by: 'user', 'agent:condenser', 'agent:corrector', etc.
  - modification_reason: why the change was made
```

**Use cases:**
- Audit trail for agent modifications
- "Undo" capability
- Reasoning about how understanding evolved
- Detecting drift or corruption

### 4. Tag-Based B-tree Organization

**Self-organizing taxonomy:**
- Memories start with broad tags
- When tag combinations exceed K memories, LLM reviews and generates distinguishing subtags
- Automatic granularity adjustment as corpus grows

**Why this works:** LLMs can analyze semantic clusters and identify meaningful distinctions that pure vector clustering would miss. The K-threshold creates a natural decision tree over semantic space.

### 5. Discovery Mechanism

**Primary retrieval paths:**
1. **LLM-driven discovery** - Agent reasons about what might be relevant given current context
2. **Tag navigation** - Browse or search tag combinations 
3. **Graph traversal** - Follow explicit relationships between memories
4. **Temporal filtering** - Narrow by time windows
5. **Vector fallback** - Similarity search when other methods fail

**Workflow example:**
```
Context: "User discussing database optimization"
→ LLM identifies: recent database work, performance concerns, PostgreSQL expertise
→ Queries tags: ['database', 'performance'] 
→ Filters: modified in last 30 days
→ Follows edges: contradiction links to previous approaches
→ Vector search: finds related but differently-worded experiences
→ Surfaces: 3 relevant memories with explicit reasoning
```

## Agent-Driven Memory Maintenance

Following MemGPT/Letta patterns, autonomous agents continuously improve the memory corpus.

### Agent Types

| Agent | Responsibility | Triggers `last_tended_at` |
|-------|---------------|---------------------------|
| **Reviewer** | Scans memories, flags for attention | No (sets `last_reviewed_at`) |
| **Tagger** | Adds/refines tags based on content analysis | Yes |
| **Linker** | Creates edges between related memories | Yes |
| **Condenser** | Summarizes verbose memories | Yes |
| **Corrector** | Fixes errors, updates stale facts | Yes |
| **Archiver** | Marks memories for deprecation | Yes |

### Maintenance Workflow

```
1. Reviewer agent scans memories_needing_review view
   → Sets last_reviewed_at, may flag issues

2. Tending agents process memories_needing_tending view
   → Tagger: analyzes content, adds/removes tags
   → Linker: finds relationships, creates edges
   → Condenser: if value is verbose, summarizes (preserves original in version history)
   → Sets last_tended_at after modifications

3. All modifications:
   → Recorded in memory_versions with modified_by attribution
   → Include modification_reason for audit
```

### Agent Interaction Tracking

The system tracks how agents interact with memories over time:

```
agents:              id, name, description
agent_memory_stats:  agent_id, memory_id, times_served, times_relevant, timestamps
```

| Field | Purpose |
|-------|---------|
| `times_served` | How often this memory was surfaced to the agent |
| `times_relevant` | How often the agent judged the memory relevant |
| `last_served_at` | Most recent surfacing |
| `last_relevant_at` | Most recent relevance judgment |

**Use cases:**
- Identify memories that are frequently surfaced but rarely relevant (retrieval noise)
- Find high-signal memories (high relevance ratio)
- Detect agent-specific relevance patterns (memory X is relevant to agent A but not B)
- Guide tag/edge refinement based on empirical relevance data

### K-Constraint Refinement

When a tag combination accumulates > K memories:
1. LLM analyzes the cluster
2. Identifies distinguishing characteristics
3. Proposes new subtags
4. User approves or agent auto-applies (configurable)
5. Existing memories re-tagged

## Key Advantages Over Pure Vector Systems

1. **Explainable retrieval** - LLM states why memory is relevant, not just similarity score
2. **Multi-hop reasoning** - Can chain: "X relates to Y, Y contradicts Z, therefore Z is relevant"
3. **Context-aware** - Same memory surfaces differently depending on task vs casual chat
4. **Self-improving** - Tag refinement and agent tending improve future retrievals
5. **Handles absence** - Can reason "no relevant memory exists for this novel situation"
6. **Temporal intelligence** - Native support for time-based queries and reasoning
7. **Full audit trail** - Every change tracked with attribution

## Alternative Retrieval Approaches

### Dense Retrieval + Reranking

**Description:** Two-stage pipeline where fast vector search retrieves top-N candidates (e.g., 50-100), then an LLM reranks them for final selection.

**How it works:** First stage uses approximate nearest neighbor search for speed. Second stage applies expensive but accurate LLM reasoning only to the shortlist. Relevance scoring is a runtime operation, not persisted.

**Integration:** No schema changes required. Implement as retrieval strategy that calls vector search first, then LLM reasoning on candidates only.

**Tradeoff:** Faster (sub-second) but may miss conceptually relevant memories outside vector top-N.

### Hierarchical/Matryoshka Embeddings

**Description:** Embeddings where truncated prefixes remain meaningful. First 256 dims capture coarse semantics, full 1536 dims capture fine detail.

**Integration:**
```sql
ALTER TABLE memories ADD COLUMN embedding_256 vector(256);
CREATE INDEX idx_memories_embedding_256 ON memories 
    USING ivfflat (embedding_256 vector_cosine_ops);
```

**Tradeoff:** Progressive similarity without explicit tags. Requires Matryoshka-trained embeddings. Less explainable than tag-based organization.

### Temporal Embedding Augmentation

**Description:** Combine semantic search with explicit temporal filtering rather than encoding time into embeddings.

**Integration:** Already included in base schema via temporal indexes:
```sql
CREATE INDEX idx_memories_created ON memories(created_at DESC);
CREATE INDEX idx_memories_modified ON memories(modified_at DESC);
-- etc.
```

**Usage:** Application layer combines vector similarity with temporal predicates:
```sql
SELECT * FROM memories
WHERE embedding <=> query_embedding < 0.3
  AND modified_at > NOW() - INTERVAL '30 days'
ORDER BY embedding <=> query_embedding;
```

## Progressive Disclosure

Tags and edges create natural navigation layers:
- Level 1: Browse high-level tags
- Level 2: Refine with tag combinations
- Level 3: Explore graph neighborhoods
- Level 4: Deep dive specific memories
- Level 5: View version history

LLM acts as guide, suggesting which paths to explore based on user intent.

## Implementation Strategy

**Phase 1:** Basic CRUD with tags, vector search, and temporal tracking
**Phase 2:** Version history and modification attribution
**Phase 3:** LLM-driven tag refinement when hitting K-constraint
**Phase 4:** Edge creation (LLM identifies relationships during memory addition)
**Phase 5:** Agentic retrieval (LLM actively reasons about relevance)
**Phase 6:** Autonomous maintenance agents (reviewer, tagger, linker)
**Phase 7:** Memory elaboration/condensation agents
**Phase 8:** Alternative retrieval integration (reranking, hierarchical embeddings)

## Why This Matters

Current memory systems (RAG, vector stores) treat retrieval as information retrieval. This system treats it as knowledge work. The LLM doesn't just find similar text—it understands why something matters in context, how pieces relate, and what's missing.

Memories aren't static records. They're living documents that agents can review, refine, connect, and condense. The version history ensures nothing is lost while enabling continuous improvement.

It's the difference between a filing cabinet and a research assistant with perfect recall.
