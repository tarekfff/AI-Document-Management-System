# 🗂️ AI Document Management System — n8n Workflow

> An intelligent, multi-intent document management pipeline built with **n8n**, **GPT-4o**, **PostgreSQL (pgvector)**, and **Google Drive**. Designed for Kuwait Civil Aviation, this system auto-classifies uploaded files, organizes them in Drive, enables semantic search, and generates/refines Arabic documents using RAG.

---

## 📌 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Intent Router](#intent-router)
- [Workflow Modules](#workflow-modules)
  - [1. AUTO\_SAVE — File Upload & Classification](#1-auto_save--file-upload--classification)
  - [2. SEARCH\_FILES — Semantic Vector Search](#2-search_files--semantic-vector-search)
  - [3. CHAT — Context-Aware Q\&A](#3-chat--context-aware-qa)
  - [4. DOCUMENT\_GENERATION — RAG Document Creator](#4-document_generation--rag-document-creator)
  - [5. DOCUMENT\_REFINEMENT — Iterative Editing](#5-document_refinement--iterative-editing)
  - [6. Conversation Management APIs](#6-conversation-management-apis)
- [Database Schema](#database-schema)
- [API Endpoints](#api-endpoints)
- [Tech Stack](#tech-stack)
- [Key Design Decisions](#key-design-decisions)
- [Setup & Configuration](#setup--configuration)
- [Environment Variables / Credentials](#environment-variables--credentials)
- [Flow Diagram](#flow-diagram)

---

## Overview

This workflow acts as a **full document intelligence backend** exposed over HTTP webhooks. A single entry point accepts any request — file upload, question, search query, or document creation command — and routes it to the appropriate processing pipeline using an AI-powered intent classifier.

### Core Capabilities

| Capability | Description |
|---|---|
| 📄 **Auto-Classification** | GPT-4o reads file content + user message to classify documents by type, category, and employee |
| 🗂️ **Smart Drive Organization** | Automatically builds nested Google Drive folder hierarchies (`HR/Warnings/Ahmed/2025`) |
| 🔍 **Semantic Search** | pgvector cosine similarity search over document embeddings |
| 📝 **RAG Document Generation** | Creates new Arabic business documents using similar past documents as context |
| ✏️ **Iterative Refinement** | Edit generated documents through conversation (`"add a paragraph about..."`) |
| 💬 **Conversational Memory** | Full multi-turn history stored per session in PostgreSQL |
| 🧠 **Learning Patterns** | Confidence-weighted classification patterns improve over time |

---

## Architecture

```
HTTP POST /auto-save-files
         │
         ▼
 ┌───────────────────┐
 │  Extract Request  │  ← Parse multipart/form-data or JSON+base64
 │       Data        │
 └────────┬──────────┘
          │
          ▼
 ┌───────────────────┐
 │ Duplicate Check   │  ← Query DB by (filename + session_id)
 └────────┬──────────┘
          │ new file
          ▼
 ┌───────────────────┐
 │  Convert Binary   │  ← Normalize to n8n binary format
 └────────┬──────────┘
          │
          ▼
 ┌────────────────────────┐
 │  Analyze Intent (AI)   │  ← GPT-4o-mini classifies intent
 │  AUTO_SAVE / SEARCH /  │
 │  CHAT / GENERATE /     │
 │  REFINE                │
 └────────┬───────────────┘
          │
          ▼
 ┌───────────────────┐
 │  Switch by Intent │  ← Routes to correct sub-pipeline
 └───────────────────┘
```

---

## Intent Router

The central **`Analyze Intent (Fixed)`** node uses `gpt-4o-mini` to classify each request with strict priority rules:

```
PRIORITY 1:  Files uploaded?              → AUTO_SAVE     (always wins)
PRIORITY 2:  Modify/edit keywords?        → DOCUMENT_REFINEMENT
PRIORITY 3:  Create/write/generate?       → DOCUMENT_GENERATION
PRIORITY 4:  Find/search/show?            → SEARCH_FILES
PRIORITY 5:  Everything else              → CHAT
```

The router returns structured JSON:
```json
{
  "intent": "AUTO_SAVE",
  "confidence": "high",
  "reasoning": "File uploaded (Priority 1)",
  "detected_entities": {
    "has_file": true,
    "file_count": 1,
    "keywords_found": [],
    "priority_rule": "PRIORITY_1_FILE_UPLOAD"
  }
}
```

---

## Workflow Modules

### 1. AUTO_SAVE — File Upload & Classification

**Trigger:** File attached to request (any intent with `files.length > 0`)

**Pipeline:**

```
Load Conversation History
        │
        ▼
Extract PDF Content          ← n8n ExtractFromFile node
        │
        ▼
Load Learning Patterns       ← Top 100 patterns from DB (confidence > 0.5)
        │
        ▼
Build Classification Prompt  ← Combines: user message + PDF content + learned patterns
        │
        ▼
Classify File with AI        ← GPT-4o, JSON output mode
        │
        ▼
Generate File Embedding1     ← Enriches: classification labels + PDF text
        │
        ▼
Generate File Embedding      ← POST /v1/embeddings (text-embedding-ada-002)
        │
        ▼
Prepare Database Insert      ← Validates content, builds INSERT SQL
        │
        ▼
Save to Database             ← files table with pgvector embedding
        │
        ▼
Create Folder Path           ← Splits "HR/Warnings/Ahmed/2025" into levels
        │
  ┌─────▼──────┐
  │  Loop per  │   For each level:
  │   folder   │   1. Search for folder in Drive
  │   level    │   2. Create if missing / use existing
  └─────┬──────┘
        │
        ▼
Upload to Final Folder       ← Google Drive upload
        │
        ▼
Save Drive Link              ← UPDATE files SET google_drive_file_id = ...
        │
        ▼
Prepare Conversation Update  ← Appends messages to session history
        │
        ▼
Update Conversation          ← UPSERT into conversations table
        │
        ▼
Respond Success              ← Returns file metadata + Drive link
```

**Classification Output Example:**
```json
{
  "file_type": "warning",
  "file_type_display": "Warning",
  "file_type_arabic": "تحذير",
  "category": "HR",
  "subcategory": "Disciplinary Warning",
  "employee_name": "Ahmed",
  "google_drive_folder": "HR/Warnings/Ahmed/2025",
  "confidence_score": 0.95,
  "language": "ar",
  "reasoning": "Classified based on user message 'warning letter for Ahmed' and file content..."
}
```

**Duplicate Prevention:**
Before processing, the workflow queries the DB for `(original_file_name, session_id)`. If found, it returns the existing record immediately with HTTP 200 and skips all processing.

---

### 2. SEARCH_FILES — Semantic Vector Search

**Trigger:** Intent = `SEARCH_FILES`

**Pipeline:**

```
AI Search Analyzer           ← Extract: employee, category, date range, semantic query
        │
        ▼
Build Enriched Search        ← Prepend Arabic + English domain keywords
Embedding
        │
        ▼
Generate Search Embedding    ← text-embedding-ada-002
        │
        ▼
Build Vector Search Query    ← pgvector cosine similarity SQL
        │                       + optional WHERE filters (category, employee, date)
        ▼
Execute Vector Search        ← Threshold: similarity >= 0.5, LIMIT 50
        │
        ▼
Format Vector Results        ← Sorted by similarity, includes Drive links
        │
        ▼
Get Conversation + Update    ← Append search to session history
        │
        ▼
Respond Search Results
```

**SQL Pattern:**
```sql
SELECT id, file_name, employee_name, category,
       google_drive_web_view_link,
       1 - (content_embedding <=> '[...]'::vector) as similarity
FROM files
WHERE deleted_at IS NULL
  AND content_embedding IS NOT NULL
  AND google_drive_web_view_link IS NOT NULL
  AND 1 - (content_embedding <=> '[...]'::vector) >= 0.5
ORDER BY content_embedding <=> '[...]'::vector
LIMIT 50;
```

---

### 3. CHAT — Context-Aware Q&A

**Trigger:** Intent = `CHAT`

**Pipeline:**

```
Get Conversation History     ← Load full_history from DB
        │
        ▼
Extract Files from History   ← Pull file content stored in assistant messages
        │                       (no extra DB query — content lives in history JSON)
        ▼
AI Chat with Full Content    ← GPT-4o with system prompt containing:
        │                       • User question
        │                       • Full file contents (up to session files)
        │                       • Last 10 conversation messages
        ▼
Format Chat Response
        │
        ▼
Update Conversation + Respond
```

**Key insight:** File content is stored directly inside the conversation history JSON (`msg.file_content`), so chat can reference any previously uploaded document without additional DB queries.

---

### 4. DOCUMENT_GENERATION — RAG Document Creator

**Trigger:** Intent = `DOCUMENT_GENERATION`

**Pipeline:**

```
Extract Request Data1
        │
        ▼
Load Conversation            ← Session history for context
        │
        ▼
Process Conversation         ← Build context string from last 5 messages
        │
        ▼
AI Document Type Analyzer    ← Classify: document_type, category, keywords
        │
        ▼
Build Enriched Embedding     ← Combine type + keywords + Arabic/English terms
        │
        ▼
Generate Request Embedding   ← text-embedding-ada-002
        │
        ▼
Find Similar Documents       ← pgvector search (similarity >= 0.5, LIMIT 5)
        │
        ▼
Execute SQL Query
        │
        ▼
Build RAG Prompt             ← System prompt with:
        │                       • User request
        │                       • Conversation history
        │                       • Up to 5 similar real documents as examples
        ▼
RAG Document Generator       ← GPT-4o generates Arabic document
        │
        ▼
Generate Document Embedding  ← Embed the generated document
        │
        ▼
Save Generated Document      ← INSERT into files table
        │
        ▼
Build + Execute Upsert       ← Save conversation with document content
        │
        ▼
Format Response + Respond
```

**RAG Prompt Structure:**
```
USER REQUEST: "Write a sick leave approval for Ahmed..."
RECENT CONVERSATION: [last 3 turns]
SIMILAR DOCUMENTS: 
  Example 1 (87% similar): [actual document content]
  Example 2 (74% similar): [actual document content]
INSTRUCTIONS: Create professional Arabic document following Kuwait Civil Aviation standards
```

---

### 5. DOCUMENT_REFINEMENT — Iterative Editing

**Trigger:** Intent = `DOCUMENT_REFINEMENT`

**Pipeline:**

```
Get Last Generated Document  ← Most recent file in this session
        │
        ▼
Check Document Exists        ← Returns error if no prior document
        │
        ▼
If Document Exists?          ┬── NO  → Respond Error (400)
        │                    │
        │ YES                │
        ▼
Build Refinement Prompt      ← Current document (full text) + user modification request
        │
        ▼
AI Document Refiner          ← GPT-4o with strict rules:
        │                       • Modify ONLY what was requested
        │                       • Keep same format/structure
        │                       • Output clean Arabic text (no markdown fences)
        ▼
Strip Markdown               ← Remove any ``` code fences
        │
        ▼
Generate Modified Embedding  ← New embedding for updated content
        │
        ▼
UPDATE files SET             ← content_text, content_embedding, version++
        │                       + append to ai_classification.modification_history
        ▼
Build Conversation Update SQL
        │
        ▼
Execute + Format + Respond   ← Returns updated document + version number
```

**Modification keywords detected:**
- Arabic: `أضف`, `احذف`, `عدل`, `غير`, `حسّن`, `اجعل أقصر`, `اجعل أطول`
- English: `add`, `remove`, `change`, `edit`, `improve`, `shorten`, `expand`

---

### 6. Conversation Management APIs

All conversation endpoints share `webhookId: 98b211e8...` and are distinguished by path:

| Endpoint | Method | Description |
|---|---|---|
| `GET /get-conversations` | GET | List all sessions for a user |
| `GET /get-conversation/:session_id` | GET | Full history + file metadata for one session |
| `GET /search-conversations` | GET | Full-text search across conversation content |
| `PATCH /rename-conversation/:session_id` | PATCH | Update `context_summary` (title) |
| `DELETE /delete-conversation/:session_id` | DELETE | Soft delete (mark inactive) or hard delete |

**Soft vs Hard Delete:**
```
?hard=false (default) → UPDATE is_active = FALSE
?hard=true            → DELETE FROM conversations
```

**CORS:** All management endpoints include `Access-Control-Allow-Origin: *` headers and handle `OPTIONS` preflight requests with a `204 No Content` response.

---

## Database Schema

### `files` table

```sql
CREATE TABLE files (
    id                        SERIAL PRIMARY KEY,
    uuid                      UUID DEFAULT gen_random_uuid(),
    file_name                 TEXT,
    original_file_name        TEXT,
    file_size_bytes           INTEGER,
    mime_type                 TEXT,
    file_extension            TEXT,
    file_type                 TEXT,                    -- e.g. "warning"
    file_type_display         TEXT,                    -- e.g. "Warning"
    file_type_arabic          TEXT,                    -- e.g. "تحذير"
    category                  TEXT,                    -- HR | Finance | Legal | ...
    category_arabic           TEXT,
    subcategory               TEXT,
    employee_name             TEXT,
    employee_name_normalized  TEXT,
    google_drive_folder       TEXT,                    -- "HR/Warnings/Ahmed/2025"
    google_drive_file_id      TEXT,
    google_drive_web_view_link TEXT,
    google_drive_folder_id    TEXT,
    google_drive_uploaded     BOOLEAN DEFAULT FALSE,
    content_text              TEXT,                    -- Extracted PDF text (up to 50k chars)
    content_summary           TEXT,
    content_embedding         vector(1536),            -- pgvector, text-embedding-ada-002
    ai_classification         JSONB,                   -- Full GPT-4o output
    confidence_score          FLOAT,
    language                  TEXT,                    -- ar | en | mixed
    version                   INTEGER DEFAULT 1,
    uploaded_by               TEXT,
    session_id                TEXT,
    created_at                TIMESTAMPTZ DEFAULT NOW(),
    updated_at                TIMESTAMPTZ,
    deleted_at                TIMESTAMPTZ
);
```

### `conversations` table

```sql
CREATE TABLE conversations (
    id               SERIAL PRIMARY KEY,
    session_id       TEXT UNIQUE NOT NULL,
    user_id          TEXT,
    message_count    INTEGER DEFAULT 0,
    last_message     TEXT,
    last_ai_response TEXT,
    file_ids         INTEGER[],                -- Array of referenced file IDs
    context_summary  TEXT,                    -- Used as display title
    full_history     JSONB,                   -- Complete message array
    started_at       TIMESTAMPTZ DEFAULT NOW(),
    last_activity    TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ,
    metadata         JSONB DEFAULT '{}',
    is_active        BOOLEAN DEFAULT TRUE
);
```

### `patterns` table

```sql
CREATE TABLE patterns (
    id              SERIAL PRIMARY KEY,
    pattern_key     TEXT,                     -- Matched keyword/phrase
    file_type       TEXT,
    category        TEXT,
    folder_template TEXT,
    confidence      FLOAT,
    usage_count     INTEGER DEFAULT 0
);
```

**`full_history` message structure:**
```json
[
  {
    "role": "user",
    "content": "هذه إجازة مرضية لأحمد",
    "file_name": "sick_leave.pdf",
    "intent": "AUTO_SAVE",
    "timestamp": "2025-01-15T10:30:00Z"
  },
  {
    "role": "assistant",
    "content": "File classified as Sick Leave...",
    "file_id": 42,
    "file_content": "...full extracted PDF text...",
    "classification": { "type": "Sick Leave", "category": "Medical", ... },
    "file_info": { "id": 42, "uuid": "...", "name": "sick_leave.pdf" },
    "timestamp": "2025-01-15T10:30:05Z"
  }
]
```

---

## API Endpoints

### Main Entry Point

```
POST /webhook/auto-save-files
Content-Type: multipart/form-data

Fields:
  file          (binary)   - The PDF/document file
  message       (string)   - User's description or question
  session_id    (string)   - Session identifier (UUIDv4 recommended)
  user_id       (string)   - User identifier
```

```
POST /webhook/auto-save-files
Content-Type: application/json

{
  "files": [{ "name": "doc.pdf", "data": "<base64>", "mimeType": "application/pdf" }],
  "message": "This is Ahmed's sick leave certificate",
  "session_id": "sess-abc123",
  "user_id": "user-001"
}
```

**Response (AUTO_SAVE success):**
```json
{
  "success": true,
  "file": {
    "id": 42,
    "name": "Sick Leave - sick_leave.pdf",
    "type": "Sick Leave",
    "category": "Medical",
    "folder": "Medical/Ahmed/2025"
  },
  "google_drive": {
    "link": "https://drive.google.com/file/d/..."
  },
  "formatted_response": "✅ **تم حفظ الملف بنجاح!**\n\n📄 **اسم الملف:** ..."
}
```

### Conversation APIs

```
GET  /webhook/get-conversations?user_id=user-001&limit=20
GET  /webhook/get-conversation/sess-abc123?include_files=true
GET  /webhook/search-conversations?user_id=user-001&q=ahmed+medical
PATCH /webhook/rename-conversation/sess-abc123  { "title": "Ahmed's Documents" }
DELETE /webhook/delete-conversation/sess-abc123?hard=false
```

---

## Tech Stack

| Component | Technology |
|---|---|
| **Workflow Engine** | n8n (self-hosted) |
| **AI Models** | GPT-4o (classification, generation, refinement), GPT-4o-mini (intent, search analysis) |
| **Embeddings** | OpenAI `text-embedding-ada-002` (1536 dimensions) |
| **Vector Database** | PostgreSQL + `pgvector` extension |
| **File Storage** | Google Drive API v3 |
| **PDF Extraction** | n8n `ExtractFromFile` node |
| **Runtime** | Node.js (via n8n Code nodes) |

---

## Key Design Decisions

### 1. Content in Conversation History
File content is stored inside `full_history` JSONB alongside the assistant message. This means the CHAT pipeline can access any previously uploaded document's full text without an extra DB query — trading storage for query efficiency.

### 2. Folder Loop Architecture
Google Drive folder creation uses a **recursive loop pattern**: the workflow splits the target path (`HR/Warnings/Ahmed/2025`) into parts, processes each level in sequence (search → create if missing → record ID), and passes the result forward. This handles arbitrarily deep folder structures.

### 3. Dollar-Quoted SQL Strings
All dynamic SQL uses PostgreSQL dollar-quoting (`$tag$value$tag$`) instead of escaped single quotes for user-provided strings, preventing SQL injection and quote-escaping bugs in complex Arabic text.

### 4. Duplicate Detection
Before any processing, the workflow checks `(original_file_name, session_id)` against the DB. This prevents re-uploading the same file if a webhook is retried, returning the cached result instantly.

### 5. Enriched Embeddings
Both file and search embeddings are **enriched** before generation — Arabic terms (`نموذج شهادة إجازة`), English terms (`form certificate leave`), and classification labels are prepended to the raw text. This improves cross-language similarity matching in a bilingual (Arabic/English) domain.

### 6. Pattern Learning
The `patterns` table stores high-confidence classifications. These are loaded (top 100 by `usage_count DESC, confidence DESC`) and injected into every classification prompt, allowing the system to learn organizational naming conventions over time.

---

## Setup & Configuration

### Prerequisites

- n8n instance (v1.x+)
- PostgreSQL 14+ with `pgvector` extension installed:
  ```sql
  CREATE EXTENSION IF NOT EXISTS vector;
  ```
- Google Cloud project with Drive API enabled
- OpenAI API key

### Database Setup

Run the schema DDL to create `files`, `conversations`, and `patterns` tables. Then create the vector index:

```sql
CREATE INDEX ON files USING ivfflat (content_embedding vector_cosine_ops)
  WITH (lists = 100);
```

### Google Drive

1. Create a root folder in Google Drive
2. Copy its folder ID
3. Set `ROOT_FOLDER_ID` in the **`Create Folder Path`** Code node:
   ```js
   const ROOT_FOLDER_ID = 'your-root-folder-id-here';
   ```

### n8n Import

1. Copy the workflow JSON
2. In n8n: **Workflows → Import from JSON**
3. Configure credentials (see below)
4. Activate the workflow

---

## Environment Variables / Credentials

Configure the following credentials in n8n's credential manager:

| Credential Name | Type | Used By |
|---|---|---|
| `OpenAi account` | OpenAI API | All GPT-4o and embedding nodes |
| `Postgres account` | PostgreSQL | All database nodes |
| `Google Drive account` | Google Drive OAuth2 | Drive upload, folder creation |

No environment variables are needed beyond n8n's built-in credential system.

---

## Flow Diagram

```
                    ┌─────────────────────────────┐
                    │   POST /auto-save-files      │
                    └──────────────┬──────────────┘
                                   │
                          ┌────────▼────────┐
                          │  Extract Data   │
                          └────────┬────────┘
                                   │
                          ┌────────▼────────┐
                          │ Duplicate Check │──── EXISTS ──► Return cached
                          └────────┬────────┘
                                   │ NEW
                          ┌────────▼────────┐
                          │ Analyze Intent  │
                          └────────┬────────┘
                                   │
               ┌───────────────────┼───────────────────────┐
               │                   │                       │
    ┌──────────▼──────┐  ┌─────────▼──────┐   ┌──────────▼────────┐
    │   AUTO_SAVE     │  │ SEARCH_FILES   │   │ DOCUMENT_GENERATION│
    │                 │  │                │   │                    │
    │ Extract PDF     │  │ AI Analyze     │   │ Load History       │
    │ Classify AI     │  │ Embed Query    │   │ Analyze Type       │
    │ Embed File      │  │ Vector Search  │   │ Find Similar Docs  │
    │ Save to DB      │  │ Return Links   │   │ RAG Generate       │
    │ Build Drive     │  └────────────────┘   │ Save + Embed       │
    │ Folders         │                       └────────────────────┘
    │ Upload File     │
    │ Update Conv.    │       ┌──────────────┐   ┌──────────────────┐
    └─────────────────┘       │     CHAT     │   │ DOCUMENT_REFINE  │
                              │              │   │                  │
                              │ Load History │   │ Get Last Doc     │
                              │ Extract File │   │ Build Prompt     │
                              │ Content      │   │ AI Refine        │
                              │ GPT-4o QA    │   │ Update Version   │
                              └──────────────┘   └──────────────────┘
```

---

## License

MIT — feel free to adapt this workflow for your own document management needs.

---

*Built with n8n · OpenAI · PostgreSQL pgvector · Google Drive API*
