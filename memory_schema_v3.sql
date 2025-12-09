-- Memory system schema with tags, graph edges, temporal tracking, and version history
-- PostgreSQL with pgvector extension

CREATE EXTENSION IF NOT EXISTS vector;

-- Base memories table with temporal tracking
CREATE TABLE memories (
    id SERIAL PRIMARY KEY,
    key TEXT UNIQUE NOT NULL,  -- base64 encoded id (auto-generated)
    name TEXT UNIQUE,  -- optional human-addressable name (free text)
    value VARCHAR(500) NOT NULL,
    embedding vector(1536),  -- OpenAI ada-002 dimension, adjust as needed
    
    -- Temporal tracking
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    modified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_reviewed_at TIMESTAMP,  -- agent flagged for review
    last_tended_at TIMESTAMP,    -- agent performed maintenance (tag/edge updates)
    last_accessed_at TIMESTAMP   -- retrieved in a query
);

-- Version history for memory values
CREATE TABLE memory_versions (
    id SERIAL PRIMARY KEY,
    memory_id INTEGER NOT NULL,
    value VARCHAR(500) NOT NULL,
    embedding vector(1536),
    modified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    modified_by TEXT,  -- 'user', 'agent:tagger', 'agent:condenser', etc.
    modification_reason TEXT,  -- why was this change made
    FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE
);

-- Normalized tag names
CREATE TABLE tags (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) UNIQUE NOT NULL
);

-- Many-to-many: memories <-> tags
CREATE TABLE memory_tags (
    memory_id INTEGER NOT NULL,
    tag_id INTEGER NOT NULL,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    added_by TEXT,  -- 'user', 'agent:tagger', etc.
    PRIMARY KEY (memory_id, tag_id),
    FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE,
    FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
);

-- Graph edges between memories
CREATE TABLE edges (
    id SERIAL PRIMARY KEY,
    from_memory_id INTEGER NOT NULL,
    to_memory_id INTEGER NOT NULL,
    bidirectional BOOLEAN DEFAULT FALSE,
    edge_type VARCHAR(50),  -- 'relates_to', 'contradicts', 'elaborates', 'supersedes', etc.
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_by TEXT,  -- 'user', 'agent:linker', etc.
    FOREIGN KEY (from_memory_id) REFERENCES memories(id) ON DELETE CASCADE,
    FOREIGN KEY (to_memory_id) REFERENCES memories(id) ON DELETE CASCADE,
    UNIQUE (from_memory_id, to_memory_id, edge_type)
);

-- Indexes for tag queries
CREATE INDEX idx_memory_tags_tag ON memory_tags(tag_id);
CREATE INDEX idx_memory_tags_memory ON memory_tags(memory_id);

-- Indexes for edge traversal
CREATE INDEX idx_edges_from ON edges(from_memory_id);
CREATE INDEX idx_edges_to ON edges(to_memory_id);

-- Indexes for vector similarity search
CREATE INDEX idx_memories_embedding ON memories USING ivfflat (embedding vector_cosine_ops);

-- Temporal indexes for time-based queries
CREATE INDEX idx_memories_created ON memories(created_at DESC);
CREATE INDEX idx_memories_modified ON memories(modified_at DESC);
CREATE INDEX idx_memories_reviewed ON memories(last_reviewed_at DESC NULLS LAST);
CREATE INDEX idx_memories_tended ON memories(last_tended_at DESC NULLS LAST);
CREATE INDEX idx_memories_accessed ON memories(last_accessed_at DESC NULLS LAST);

-- Index for human-readable name lookup
CREATE INDEX idx_memories_name ON memories(name) WHERE name IS NOT NULL;

-- Version history index
CREATE INDEX idx_memory_versions_memory ON memory_versions(memory_id, modified_at DESC);

-- Agent interaction tracking
CREATE TABLE agents (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,  -- human-readable agent identifier
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Track how often each agent sees/finds relevant each memory
CREATE TABLE agent_memory_stats (
    agent_id INTEGER NOT NULL,
    memory_id INTEGER NOT NULL,
    times_served INTEGER DEFAULT 0,      -- how often this memory was surfaced to agent
    times_relevant INTEGER DEFAULT 0,    -- how often agent judged it relevant
    last_served_at TIMESTAMP,
    last_relevant_at TIMESTAMP,
    PRIMARY KEY (agent_id, memory_id),
    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE,
    FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE
);

CREATE INDEX idx_agent_memory_stats_agent ON agent_memory_stats(agent_id);
CREATE INDEX idx_agent_memory_stats_memory ON agent_memory_stats(memory_id);

-- Helper function to record a memory being served to an agent
CREATE OR REPLACE FUNCTION record_memory_served(p_agent_id INTEGER, p_memory_id INTEGER) 
RETURNS VOID AS $$
BEGIN
    INSERT INTO agent_memory_stats (agent_id, memory_id, times_served, last_served_at)
    VALUES (p_agent_id, p_memory_id, 1, CURRENT_TIMESTAMP)
    ON CONFLICT (agent_id, memory_id) DO UPDATE
    SET times_served = agent_memory_stats.times_served + 1,
        last_served_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql;

-- Helper function to record a memory judged relevant by an agent
CREATE OR REPLACE FUNCTION record_memory_relevant(p_agent_id INTEGER, p_memory_id INTEGER) 
RETURNS VOID AS $$
BEGIN
    INSERT INTO agent_memory_stats (agent_id, memory_id, times_relevant, last_relevant_at)
    VALUES (p_agent_id, p_memory_id, 1, CURRENT_TIMESTAMP)
    ON CONFLICT (agent_id, memory_id) DO UPDATE
    SET times_relevant = agent_memory_stats.times_relevant + 1,
        last_relevant_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql;

-- Function to encode integer to base64
CREATE OR REPLACE FUNCTION int_to_base64(n INTEGER) RETURNS TEXT AS $$
DECLARE
    alphabet TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    result TEXT := '';
    remainder INTEGER;
BEGIN
    IF n = 0 THEN
        RETURN substr(alphabet, 1, 1);
    END IF;
    
    WHILE n > 0 LOOP
        remainder := n % 64;
        result := substr(alphabet, remainder + 1, 1) || result;
        n := n / 64;
    END LOOP;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Trigger to auto-generate base64 key on insert
CREATE OR REPLACE FUNCTION generate_memory_key() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.key IS NULL THEN
        NEW.key := int_to_base64(NEW.id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_memory_key 
    BEFORE INSERT ON memories
    FOR EACH ROW
    WHEN (NEW.key IS NULL)
    EXECUTE FUNCTION generate_memory_key();

-- Trigger to archive previous value before update
CREATE OR REPLACE FUNCTION archive_memory_version() RETURNS TRIGGER AS $$
BEGIN
    IF OLD.value IS DISTINCT FROM NEW.value THEN
        INSERT INTO memory_versions (memory_id, value, embedding, modified_at)
        VALUES (OLD.id, OLD.value, OLD.embedding, OLD.modified_at);
        NEW.modified_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER archive_on_update
    BEFORE UPDATE ON memories
    FOR EACH ROW
    EXECUTE FUNCTION archive_memory_version();

-- Trigger to update last_accessed_at (call explicitly or via function)
CREATE OR REPLACE FUNCTION touch_memory_accessed(memory_key TEXT) RETURNS VOID AS $$
BEGIN
    UPDATE memories SET last_accessed_at = CURRENT_TIMESTAMP WHERE key = memory_key;
END;
$$ LANGUAGE plpgsql;

-- View: memories needing review (not reviewed in 30 days, or never)
CREATE VIEW memories_needing_review AS
SELECT * FROM memories
WHERE last_reviewed_at IS NULL 
   OR last_reviewed_at < CURRENT_TIMESTAMP - INTERVAL '30 days'
ORDER BY COALESCE(last_reviewed_at, created_at) ASC;

-- View: memories needing tending (reviewed but not tended)
CREATE VIEW memories_needing_tending AS
SELECT * FROM memories
WHERE last_reviewed_at IS NOT NULL
  AND (last_tended_at IS NULL OR last_tended_at < last_reviewed_at)
ORDER BY last_reviewed_at ASC;

-- View: tag combination counts for K-constraint checking
CREATE VIEW tag_combination_counts AS
SELECT 
    STRING_AGG(t.name, ',' ORDER BY t.name) as tag_combo,
    COUNT(DISTINCT mt.memory_id) as memory_count
FROM memory_tags mt
JOIN tags t ON mt.tag_id = t.id
GROUP BY mt.memory_id
HAVING COUNT(*) > 0;

-- View: memory with full version history
CREATE VIEW memory_with_history AS
SELECT 
    m.id,
    m.key,
    m.name,
    m.value as current_value,
    m.created_at,
    m.modified_at,
    (SELECT COUNT(*) FROM memory_versions mv WHERE mv.memory_id = m.id) as version_count
FROM memories m;

-- Example queries:

-- Get memory by human-readable name:
-- SELECT * FROM memories WHERE name = 'my-important-note';

-- Get full history of a memory:
-- SELECT mv.* FROM memory_versions mv
-- JOIN memories m ON mv.memory_id = m.id
-- WHERE m.key = 'A' OR m.name = 'my-important-note'
-- ORDER BY mv.modified_at DESC;

-- Find memories accessed in last 7 days:
-- SELECT * FROM memories 
-- WHERE last_accessed_at > CURRENT_TIMESTAMP - INTERVAL '7 days'
-- ORDER BY last_accessed_at DESC;

-- Find stale memories (created > 90 days ago, never tended):
-- SELECT * FROM memories
-- WHERE created_at < CURRENT_TIMESTAMP - INTERVAL '90 days'
--   AND last_tended_at IS NULL;

-- Update memory value (triggers version archival):
-- UPDATE memories SET value = 'new content', modified_at = CURRENT_TIMESTAMP 
-- WHERE key = 'A';
