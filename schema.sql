-- ============================================================
-- AI DOCUMENT MANAGEMENT SYSTEM — Full Database Setup
-- PostgreSQL 14+ required
-- pgvector extension required
-- Run this file once on a fresh database
-- ============================================================


-- ============================================================
-- 0. EXTENSIONS
-- ============================================================

CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector: for content_embedding
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";   -- for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- for trigram text search indexes


-- ============================================================
-- 1. TABLE: files
--    Stores every uploaded and AI-generated document
-- ============================================================

CREATE TABLE IF NOT EXISTS files (

    -- Identity
    id                          SERIAL          PRIMARY KEY,
    uuid                        UUID            NOT NULL DEFAULT gen_random_uuid(),

    -- File metadata
    file_name                   TEXT            NOT NULL,           -- Display name (e.g. "Warning - letter.pdf")
    original_file_name          TEXT,                               -- Original uploaded filename
    file_size_bytes             INTEGER         DEFAULT 0,
    mime_type                   TEXT,
    file_extension              TEXT,

    -- AI Classification
    file_type                   TEXT,                               -- slug  e.g. "warning"
    file_type_display           TEXT,                               -- English label e.g. "Warning"
    file_type_arabic            TEXT,                               -- Arabic label e.g. "تحذير"
    category                    TEXT,                               -- HR | Finance | Legal | Medical | Administrative
    category_arabic             TEXT,
    subcategory                 TEXT,                               -- e.g. "Disciplinary Warning"

    -- Employee
    employee_name               TEXT,                               -- Raw name from classification
    employee_name_normalized    TEXT,                               -- Lowercase/normalized for deduplication

    -- Google Drive
    google_drive_folder         TEXT,                               -- Full path e.g. "HR/Warnings/Ahmed/2025"
    google_drive_file_id        TEXT,                               -- Drive file ID after upload
    google_drive_web_view_link  TEXT,                               -- Public view link
    google_drive_folder_id      TEXT,                               -- Drive folder ID of final folder
    google_drive_uploaded       BOOLEAN         DEFAULT FALSE,

    -- Content
    content_text                TEXT,                               -- Extracted PDF text (up to 50 000 chars)
    content_summary             TEXT,                               -- Short AI summary
    content_embedding           vector(1536),                       -- text-embedding-ada-002 output

    -- AI metadata
    ai_classification           JSONB,                              -- Full GPT-4o JSON response
    confidence_score            FLOAT           DEFAULT 0,
    language                    TEXT            DEFAULT 'ar',       -- ar | en | mixed

    -- Versioning (for AI-generated/refined documents)
    version                     INTEGER         DEFAULT 1,

    -- Ownership
    uploaded_by                 TEXT            DEFAULT 'anonymous',
    session_id                  TEXT,

    -- Timestamps
    created_at                  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ,
    deleted_at                  TIMESTAMPTZ                         -- soft-delete

);


-- ============================================================
-- 2. TABLE: conversations
--    Stores full multi-turn session history per session_id
-- ============================================================

CREATE TABLE IF NOT EXISTS conversations (

    -- Identity
    id                  SERIAL          PRIMARY KEY,
    session_id          TEXT            NOT NULL UNIQUE,            -- e.g. "sess-abc123"

    -- Ownership
    user_id             TEXT            NOT NULL DEFAULT 'anonymous',

    -- Counters & previews
    message_count       INTEGER         DEFAULT 0,
    last_message        TEXT,                                       -- Last user message (preview)
    last_ai_response    TEXT,                                       -- Last assistant message (preview)

    -- Linked files
    file_ids            INTEGER[]       DEFAULT ARRAY[]::INTEGER[], -- Array of files.id

    -- Display
    context_summary     TEXT,                                       -- Used as conversation title in UI

    -- Full history
    full_history        JSONB           DEFAULT '[]'::JSONB,        -- Array of message objects

    -- Extra metadata
    metadata            JSONB           DEFAULT '{}'::JSONB,

    -- State
    is_active           BOOLEAN         DEFAULT TRUE,

    -- Timestamps
    started_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    last_activity       TIMESTAMPTZ              DEFAULT NOW(),
    updated_at          TIMESTAMPTZ

);


-- ============================================================
-- 3. TABLE: patterns
--    Learned classification patterns that improve over time.
--    The workflow loads the top 100 (confidence > 0.5) into
--    every classification prompt.
-- ============================================================

CREATE TABLE IF NOT EXISTS patterns (

    id              SERIAL      PRIMARY KEY,

    pattern_key     TEXT        NOT NULL,   -- Keyword/phrase that triggers this pattern
                                            -- e.g. "تحذير", "sick leave", "invoice"

    file_type       TEXT        NOT NULL,   -- Slug matched to files.file_type
    category        TEXT        NOT NULL,   -- HR | Finance | Legal | Medical | Administrative

    folder_template TEXT,                   -- e.g. "HR/{Subcategory}/{Employee}/{year}"

    confidence      FLOAT       NOT NULL DEFAULT 0.5,   -- 0.0 – 1.0
    usage_count     INTEGER     NOT NULL DEFAULT 0,     -- Incremented on each match

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ

);


-- ============================================================
-- 4. INDEXES — files
-- ============================================================

-- Primary lookups used in duplicate-check query
CREATE INDEX IF NOT EXISTS idx_files_original_name_session
    ON files (original_file_name, session_id)
    WHERE deleted_at IS NULL;

-- Session lookup (used heavily by chat & refinement)
CREATE INDEX IF NOT EXISTS idx_files_session_id
    ON files (session_id)
    WHERE deleted_at IS NULL;

-- Vector similarity search (IVFFlat — tune `lists` for your dataset size)
-- Rule of thumb: lists = rows / 1000, minimum 10
CREATE INDEX IF NOT EXISTS idx_files_embedding
    ON files USING ivfflat (content_embedding vector_cosine_ops)
    WITH (lists = 100);

-- Category + employee filter (used in search pipeline)
CREATE INDEX IF NOT EXISTS idx_files_category
    ON files (category)
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_files_employee
    ON files (employee_name_normalized)
    WHERE deleted_at IS NULL AND employee_name_normalized IS NOT NULL;

-- Date range filter
CREATE INDEX IF NOT EXISTS idx_files_created_at
    ON files (created_at DESC)
    WHERE deleted_at IS NULL;

-- Drive upload status (used when filtering search results to files with links)
CREATE INDEX IF NOT EXISTS idx_files_drive_uploaded
    ON files (google_drive_uploaded)
    WHERE deleted_at IS NULL;


-- ============================================================
-- 5. INDEXES — conversations
-- ============================================================

-- Primary lookup by session
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_session_id
    ON conversations (session_id);

-- User's conversation list
CREATE INDEX IF NOT EXISTS idx_conversations_user_active
    ON conversations (user_id, is_active, last_activity DESC);

-- Full-text search across conversation content
CREATE INDEX IF NOT EXISTS idx_conversations_fts
    ON conversations
    USING GIN (
        to_tsvector('english',
            COALESCE(context_summary, '') || ' ' ||
            COALESCE(last_message, '') || ' ' ||
            COALESCE(last_ai_response, '')
        )
    );


-- ============================================================
-- 6. INDEXES — patterns
-- ============================================================

-- Lookup by keyword
CREATE INDEX IF NOT EXISTS idx_patterns_key
    ON patterns (pattern_key);

-- Ordered load used in classification prompt
CREATE INDEX IF NOT EXISTS idx_patterns_ranking
    ON patterns (confidence DESC, usage_count DESC)
    WHERE confidence > 0.5;


-- ============================================================
-- 7. SEED DATA — patterns
--    Starter patterns so the classifier has a baseline.
--    Add more as your organization's documents accumulate.
-- ============================================================

INSERT INTO patterns (pattern_key, file_type, category, folder_template, confidence, usage_count)
VALUES
    -- Arabic HR patterns
    ('تحذير',           'warning',          'HR',            'HR/Warnings/{Employee}/{year}',           0.95, 10),
    ('إجازة مرضية',     'sick_leave',       'Medical',       'Medical/{Employee}/{year}',               0.95, 10),
    ('إجازة سنوية',     'annual_leave',     'HR',            'HR/Leaves/{Employee}/{year}',             0.90, 8),
    ('شهادة طبية',      'medical_cert',     'Medical',       'Medical/{Employee}/{year}',               0.90, 8),
    ('عقد عمل',         'contract',         'HR',            'HR/Contracts/{Employee}/{year}',          0.85, 5),
    ('قرار',            'decision',         'Administrative','Administrative/Decisions/{year}',         0.80, 5),
    ('كتاب رسمي',       'official_letter',  'Administrative','Administrative/Letters/{year}/{month}',   0.85, 7),
    ('طلب',             'request',          'Administrative','Administrative/Requests/{year}/{month}',  0.75, 4),
    ('تقرير',           'report',           'Administrative','Administrative/Reports/{year}/{month}',   0.80, 6),

    -- English HR patterns
    ('warning letter',  'warning',          'HR',            'HR/Warnings/{Employee}/{year}',           0.95, 8),
    ('sick leave',      'sick_leave',       'Medical',       'Medical/{Employee}/{year}',               0.95, 8),
    ('annual leave',    'annual_leave',     'HR',            'HR/Leaves/{Employee}/{year}',             0.90, 6),
    ('medical certificate', 'medical_cert', 'Medical',       'Medical/{Employee}/{year}',               0.90, 6),
    ('employment contract', 'contract',     'HR',            'HR/Contracts/{Employee}/{year}',          0.85, 4),
    ('official letter', 'official_letter',  'Administrative','Administrative/Letters/{year}/{month}',   0.85, 5),

    -- Finance patterns
    ('فاتورة',          'invoice',          'Finance',       'Finance/Invoices/{year}/{month}',         0.95, 10),
    ('invoice',         'invoice',          'Finance',       'Finance/Invoices/{year}/{month}',         0.95, 10),
    ('receipt',         'receipt',          'Finance',       'Finance/Receipts/{year}/{month}',         0.90, 7),
    ('إيصال',           'receipt',          'Finance',       'Finance/Receipts/{year}/{month}',         0.90, 7),
    ('purchase order',  'purchase_order',   'Finance',       'Finance/PurchaseOrders/{year}/{month}',   0.85, 5),
    ('أمر شراء',        'purchase_order',   'Finance',       'Finance/PurchaseOrders/{year}/{month}',   0.85, 5),

    -- Legal patterns
    ('عقد',             'contract',         'Legal',         'Legal/Contracts/{year}',                  0.80, 4),
    ('اتفاقية',         'agreement',        'Legal',         'Legal/Agreements/{year}',                 0.85, 4),
    ('agreement',       'agreement',        'Legal',         'Legal/Agreements/{year}',                 0.85, 4),
    ('مذكرة تفاهم',     'mou',              'Legal',         'Legal/MOU/{year}',                        0.90, 3)

ON CONFLICT DO NOTHING;


-- ============================================================
-- 8. HELPER FUNCTION — update updated_at automatically
-- ============================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_files_updated_at
    BEFORE UPDATE ON files
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE TRIGGER trg_conversations_updated_at
    BEFORE UPDATE ON conversations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE TRIGGER trg_patterns_updated_at
    BEFORE UPDATE ON patterns
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ============================================================
-- 9. HELPER FUNCTION — increment pattern usage
--    Call this after a successful classification that matched
--    a known pattern (optional — wire into n8n if desired)
-- ============================================================

CREATE OR REPLACE FUNCTION increment_pattern_usage(p_key TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE patterns
    SET
        usage_count = usage_count + 1,
        confidence  = LEAST(confidence + 0.01, 1.0)  -- cap at 1.0
    WHERE pattern_key = p_key;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- 10. VERIFY — run this to confirm everything was created
-- ============================================================

SELECT
    'files'         AS table_name, COUNT(*) AS rows FROM files
UNION ALL SELECT
    'conversations' AS table_name, COUNT(*) AS rows FROM conversations
UNION ALL SELECT
    'patterns'      AS table_name, COUNT(*) AS rows FROM patterns;
