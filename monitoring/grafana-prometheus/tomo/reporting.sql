-- Read-only reporting functions that kam-09 and kam-10 query through the
-- grafana_reader role. connect-tomo.sh runs this file as the database
-- superuser; it is safe to run again.
--
-- The role holds no privilege on any Tomo table. It can only call these
-- functions, and each returns rows without content: no message text, no
-- prompt, no name, email, or identity. A member appears only as member_key, a
-- keyed hash that is stable within this install and cannot be reversed without
-- the key in tomo_reporting.member_key_secret, which the role cannot read.
--
-- The bodies are plain SQL strings, so PostgreSQL records no dependency on
-- Tomo's tables. A Tomo migration therefore never fails because of this file;
-- a renamed column only makes the panel that reads it report an error.

SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS tomo_reporting;
REVOKE ALL ON SCHEMA tomo_reporting FROM PUBLIC;

CREATE TABLE IF NOT EXISTS tomo_reporting.member_key_secret (
    secret text NOT NULL
);
REVOKE ALL ON tomo_reporting.member_key_secret FROM PUBLIC;
INSERT INTO tomo_reporting.member_key_secret (secret)
SELECT encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text || gen_random_uuid()::text, 'UTF8')), 'hex')
 WHERE NOT EXISTS (SELECT 1 FROM tomo_reporting.member_key_secret);

-- Audit rows name a member as "google:<sub>"; turns name the bare sub.
CREATE OR REPLACE FUNCTION tomo_reporting.member_key(principal text)
RETURNS text LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
    SELECT left(encode(sha256(convert_to(
               (SELECT secret FROM tomo_reporting.member_key_secret LIMIT 1)
               || CASE WHEN principal LIKE 'google:%' THEN substr(principal, 8) ELSE principal END,
               'UTF8')), 'hex'), 16)
$$;
REVOKE ALL ON FUNCTION tomo_reporting.member_key(text) FROM PUBLIC;

-- One row per model call.
CREATE OR REPLACE FUNCTION tomo_reporting.model_calls(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (
    created_at timestamptz, purpose text, route text, model text, outcome text, error_class text,
    latency_ms integer, input_tokens integer, output_tokens integer,
    cache_read_tokens integer, cache_write_tokens integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT created_at, purpose, route, COALESCE(NULLIF(model_id, ''), 'Unattributed'), outcome,
           error_class, latency_ms, prompt_token_count, response_token_count,
           prompt_cache_read_tokens, prompt_cache_write_tokens
      FROM public.llm_audit_event
     WHERE created_at >= p_from AND created_at < p_to
$$;

-- One row per member input: a message, a steer of a running answer, or a stop.
CREATE OR REPLACE FUNCTION tomo_reporting.turns(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (
    accepted_at timestamptz, started_at timestamptz, completed_at timestamptz,
    kind text, status text, execution_mode text, reasoning_effort text, agent_name text, model text,
    approval_mode text, uses_connectors boolean, uses_subagents boolean,
    conversation_key text, member_key text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT accepted_at, started_at, completed_at, kind, status, execution_mode, reasoning_effort, agent_name,
           COALESCE(NULLIF(model_catalog_id, ''), NULLIF(model_deployment_id, ''), 'Default model'),
           approval_mode,
           COALESCE(cardinality(connector_ids), 0) > 0,
           COALESCE(cardinality(subagent_ids), 0) > 0,
           tomo_reporting.member_key(conversation_id::text),
           tomo_reporting.member_key(actor_sub)
      FROM public.conversation_input
     WHERE accepted_at >= p_from AND accepted_at < p_to
$$;

-- Each member's first and last input across all history, for new members and retention.
CREATE OR REPLACE FUNCTION tomo_reporting.members(p_to timestamptz)
RETURNS TABLE (member_key text, first_input_at timestamptz, last_input_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT tomo_reporting.member_key(actor_sub), min(accepted_at), max(accepted_at)
      FROM public.conversation_input
     WHERE kind IN ('message', 'steer') AND accepted_at < p_to
     GROUP BY actor_sub
$$;

-- One row per member action in the audit log: the action name and outcome only, never the payload.
CREATE OR REPLACE FUNCTION tomo_reporting.member_events(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (occurred_at timestamptz, action text, outcome text, target_kind text, member_key text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT occurred_at, action, outcome, target_kind, tomo_reporting.member_key(actor_id)
      FROM public.audit_event
     WHERE actor_kind = 'requester' AND occurred_at >= p_from AND occurred_at < p_to
$$;

-- One row per thumbs-up or thumbs-down on an answer, with what produced that
-- answer: the latest turn in the same conversation that finished before the vote.
CREATE OR REPLACE FUNCTION tomo_reporting.answer_votes(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (
    occurred_at timestamptz, vote text, member_key text,
    model text, agent_name text, execution_mode text, reasoning_effort text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT vote.occurred_at, vote.payload ->> 'vote', tomo_reporting.member_key(vote.actor_id),
           COALESCE(NULLIF(turn.model_catalog_id, ''), NULLIF(turn.model_deployment_id, ''), 'Default model'),
           turn.agent_name, turn.execution_mode, turn.reasoning_effort
      FROM public.audit_event AS vote
      LEFT JOIN LATERAL (
          SELECT input.model_catalog_id, input.model_deployment_id, input.agent_name,
                 input.execution_mode, input.reasoning_effort
            FROM public.conversation_input AS input
           WHERE input.conversation_id::text = vote.payload ->> 'conversation_id'
             AND input.kind IN ('message', 'steer')
             AND input.completed_at <= vote.occurred_at
           ORDER BY input.completed_at DESC
           LIMIT 1
      ) AS turn ON true
     WHERE vote.action = 'member.chat.feedback'
       AND vote.occurred_at >= p_from AND vote.occurred_at < p_to
$$;

-- One row per brokered call to a connector or external capability tool.
CREATE OR REPLACE FUNCTION tomo_reporting.connector_calls(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (created_at timestamptz, finished_at timestamptz, tool text, capability text, status text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT created_at, finished_at, tool_name, capability, status
      FROM public.capability_invocation_receipt
     WHERE created_at >= p_from AND created_at < p_to
$$;

DO $$
DECLARE fn text;
BEGIN
    FOREACH fn IN ARRAY ARRAY[
        'tomo_reporting.model_calls(timestamptz, timestamptz)',
        'tomo_reporting.turns(timestamptz, timestamptz)',
        'tomo_reporting.members(timestamptz)',
        'tomo_reporting.member_events(timestamptz, timestamptz)',
        'tomo_reporting.answer_votes(timestamptz, timestamptz)',
        'tomo_reporting.connector_calls(timestamptz, timestamptz)']
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', fn);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO grafana_reader', fn);
    END LOOP;
END $$;
GRANT USAGE ON SCHEMA tomo_reporting TO grafana_reader;
