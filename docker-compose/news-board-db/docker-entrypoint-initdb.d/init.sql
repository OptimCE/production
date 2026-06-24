-- ============================================================================
-- Local database schema (LOCAL_DATABASE_URL) — News Board annex.
--
-- This file is the single source of truth for the LOCAL database only.
-- CRM tables (community, app_user, audit_log, community_subscription) live in a
-- separate DB and are NOT declared here (read by id via the CRM connection).
--
-- Mirrors shared/models/local_models.py. When changing models, update this file
-- and add a migration under scripts/sql/migrations/.
-- ============================================================================

-- ---- Shared utilities ------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at := CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS schema_version (
    version      INTEGER     PRIMARY KEY,
    description  TEXT        NOT NULL,
    applied_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT into schema_version (version, description) VALUES(
       1, 'News board: post, post_poll, post_poll_vote'
) ON CONFLICT DO NOTHING;


-- ---- post ------------------------------------------------------------------
-- A board entry: a Markdown post (type=0) or a poll (type=1 single, 2 multiple).
-- `post` is the Markdown SOURCE (rendered + sanitised on read). `author_id` is a
-- logical ref to a core user (Keycloak sub) — no FK (separate DB); `author_email`
-- is a display snapshot. Poll columns (expires_at + the visibility matrix) are
-- null for plain posts.
CREATE TABLE IF NOT EXISTS post (
    id                 INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_community       INTEGER      NOT NULL,

    author_id          VARCHAR(255) NOT NULL,
    author_email       VARCHAR(256) NULL,

    -- 0=post, 1=poll_single_choice, 2=poll_multiple_choice
    type               SMALLINT     NOT NULL DEFAULT 0,
    post               TEXT         NOT NULL,

    -- Poll vote deadline; null for plain posts.
    expires_at         TIMESTAMPTZ  NULL,

    -- Poll visibility matrix (null for plain posts):
    --   admin_visibility : 0=aggregate, 1=full
    --   member_visibility: 0=none, 1=aggregate, 2=full
    --   member_display   : 0=never, 1=before_vote, 2=after_vote, 3=when_poll_ends
    admin_visibility   SMALLINT     NULL,
    member_visibility  SMALLINT     NULL,
    member_display     SMALLINT     NULL,

    created_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_post_id_community ON post (id_community);
CREATE INDEX IF NOT EXISTS idx_post_community_created ON post (id_community, created_at DESC);

DROP TRIGGER IF EXISTS trg_post_set_updated_at ON post;
CREATE TRIGGER trg_post_set_updated_at
    BEFORE UPDATE ON post
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ---- post_poll -------------------------------------------------------------
-- A selectable poll option. Frozen (no add/edit/remove) once the first vote
-- exists — enforced in the API. display_order gives a stable render order.
CREATE TABLE IF NOT EXISTS post_poll (
    id                 INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_community       INTEGER      NOT NULL,
    id_post            INTEGER      NOT NULL REFERENCES post (id) ON DELETE CASCADE,
    option_value       TEXT         NOT NULL,
    display_order      SMALLINT     NOT NULL DEFAULT 0,

    created_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_post_poll_id_post ON post_poll (id_post);
CREATE INDEX IF NOT EXISTS idx_post_poll_id_community ON post_poll (id_community);

DROP TRIGGER IF EXISTS trg_post_poll_set_updated_at ON post_poll;
CREATE TRIGGER trg_post_poll_set_updated_at
    BEFORE UPDATE ON post_poll
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ---- post_poll_vote --------------------------------------------------------
-- One row per (option, voter). voter_id is a logical ref to a core user
-- (Keycloak sub). UNIQUE (id_post_poll, voter_id) prevents a double-click
-- casting the same option twice. Single-choice "one option per poll" is enforced
-- transactionally in the service layer.
CREATE TABLE IF NOT EXISTS post_poll_vote (
    id                 INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_community       INTEGER      NOT NULL,
    id_post            INTEGER      NOT NULL REFERENCES post (id) ON DELETE CASCADE,
    id_post_poll       INTEGER      NOT NULL REFERENCES post_poll (id) ON DELETE CASCADE,
    voter_id           VARCHAR(255) NOT NULL,

    created_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_post_poll_vote_option_voter UNIQUE (id_post_poll, voter_id)
);

CREATE INDEX IF NOT EXISTS idx_post_poll_vote_post_voter ON post_poll_vote (id_post, voter_id);
CREATE INDEX IF NOT EXISTS idx_post_poll_vote_id_post_poll ON post_poll_vote (id_post_poll);
CREATE INDEX IF NOT EXISTS idx_post_poll_vote_id_community ON post_poll_vote (id_community);

DROP TRIGGER IF EXISTS trg_post_poll_vote_set_updated_at ON post_poll_vote;
CREATE TRIGGER trg_post_poll_vote_set_updated_at
    BEFORE UPDATE ON post_poll_vote
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
