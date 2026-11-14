--
-- PostgreSQL database dump
--

-- Dumped from database version 18.3
-- Dumped by pg_dump version 18.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: assert_transfer_ledger(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assert_transfer_ledger(checked_transfer_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  checked_transfer transfers%ROWTYPE;
  entry_count bigint;
  debit_count bigint;
  credit_count bigint;
BEGIN
  SELECT * INTO checked_transfer FROM transfers WHERE id = checked_transfer_id;
  IF NOT FOUND OR checked_transfer.status = 'pending' THEN RETURN; END IF;
  SELECT COUNT(*),
         COUNT(*) FILTER (WHERE account_id = checked_transfer.from_account_id AND amount = -checked_transfer.amount),
         COUNT(*) FILTER (WHERE account_id = checked_transfer.to_account_id AND amount = checked_transfer.amount)
    INTO entry_count, debit_count, credit_count
    FROM ledger_entries WHERE transfer_id = checked_transfer_id;
  IF checked_transfer.status = 'completed'
     AND NOT (entry_count = 2 AND debit_count = 1 AND credit_count = 1) THEN
    RAISE EXCEPTION 'completed transfer % has invalid ledger entries', checked_transfer_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF checked_transfer.status = 'failed' AND entry_count <> 0 THEN
    RAISE EXCEPTION 'failed transfer % must not have ledger entries', checked_transfer_id
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;


--
-- Name: check_ledger_row_transfer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_ledger_row_transfer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.transfer_id IS NOT NULL THEN PERFORM assert_transfer_ledger(NEW.transfer_id); END IF;
  RETURN NULL;
END;
$$;


--
-- Name: check_transfer_row_ledger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_transfer_row_ledger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_transfer_ledger(NEW.id);
  RETURN NULL;
END;
$$;


--
-- Name: forbid_ledger_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forbid_ledger_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'ledger_entries is append-only' USING ERRCODE = 'check_violation';
END;
$$;


--
-- Name: forbid_transfer_identity_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forbid_transfer_identity_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.from_account_id <> OLD.from_account_id
     OR NEW.to_account_id <> OLD.to_account_id
     OR NEW.amount <> OLD.amount
     OR NEW.idempotency_key <> OLD.idempotency_key THEN
    RAISE EXCEPTION 'transfer identity is immutable' USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.status <> 'pending' OR NEW.status NOT IN ('completed', 'failed') THEN
    RAISE EXCEPTION 'invalid transfer status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    balance numeric(18,2) DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT accounts_balance_non_negative CHECK ((balance >= (0)::numeric))
);


--
-- Name: accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.accounts_id_seq OWNED BY public.accounts.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ledger_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_entries (
    id bigint NOT NULL,
    transfer_id bigint,
    account_id bigint NOT NULL,
    amount numeric(18,2) NOT NULL,
    kind character varying DEFAULT 'transfer'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ledger_amount_non_zero CHECK ((amount <> (0)::numeric)),
    CONSTRAINT ledger_kind_matches_transfer CHECK ((((kind)::text = 'transfer'::text) = (transfer_id IS NOT NULL))),
    CONSTRAINT ledger_kind_valid CHECK (((kind)::text = ANY ((ARRAY['transfer'::character varying, 'deposit'::character varying])::text[])))
);


--
-- Name: ledger_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ledger_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ledger_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ledger_entries_id_seq OWNED BY public.ledger_entries.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transfers (
    id bigint NOT NULL,
    from_account_id bigint NOT NULL,
    to_account_id bigint NOT NULL,
    amount numeric(18,2) NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    idempotency_key character varying(255) NOT NULL,
    failure_reason character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT transfers_amount_positive CHECK ((amount > (0)::numeric)),
    CONSTRAINT transfers_distinct_accounts CHECK ((from_account_id <> to_account_id)),
    CONSTRAINT transfers_failure_reason_matches_status CHECK (((((status)::text = 'failed'::text) AND (failure_reason IS NOT NULL)) OR (((status)::text = ANY ((ARRAY['pending'::character varying, 'completed'::character varying])::text[])) AND (failure_reason IS NULL)))),
    CONSTRAINT transfers_idempotency_key_present CHECK ((char_length((idempotency_key)::text) > 0)),
    CONSTRAINT transfers_status_valid CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'completed'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: transfers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.transfers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: transfers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.transfers_id_seq OWNED BY public.transfers.id;


--
-- Name: accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts ALTER COLUMN id SET DEFAULT nextval('public.accounts_id_seq'::regclass);


--
-- Name: ledger_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries ALTER COLUMN id SET DEFAULT nextval('public.ledger_entries_id_seq'::regclass);


--
-- Name: transfers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transfers ALTER COLUMN id SET DEFAULT nextval('public.transfers_id_seq'::regclass);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: ledger_entries ledger_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: transfers transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transfers
    ADD CONSTRAINT transfers_pkey PRIMARY KEY (id);


--
-- Name: index_accounts_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_accounts_on_user_id ON public.accounts USING btree (user_id);


--
-- Name: index_ledger_entries_on_account_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_entries_on_account_id_and_created_at ON public.ledger_entries USING btree (account_id, created_at);


--
-- Name: index_ledger_entries_on_transfer_and_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ledger_entries_on_transfer_and_account ON public.ledger_entries USING btree (transfer_id, account_id) WHERE (transfer_id IS NOT NULL);


--
-- Name: index_transfers_on_from_account_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_transfers_on_from_account_id_and_created_at ON public.transfers USING btree (from_account_id, created_at);


--
-- Name: index_transfers_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_transfers_on_idempotency_key ON public.transfers USING btree (idempotency_key);


--
-- Name: index_transfers_on_to_account_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_transfers_on_to_account_id_and_created_at ON public.transfers USING btree (to_account_id, created_at);


--
-- Name: ledger_entries ledger_entries_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_entries_append_only BEFORE DELETE OR UPDATE ON public.ledger_entries FOR EACH ROW EXECUTE FUNCTION public.forbid_ledger_mutation();


--
-- Name: ledger_entries ledger_entries_transfer_consistent; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER ledger_entries_transfer_consistent AFTER INSERT ON public.ledger_entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_ledger_row_transfer();


--
-- Name: transfers transfers_immutable_identity_and_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER transfers_immutable_identity_and_status BEFORE UPDATE OF from_account_id, to_account_id, amount, idempotency_key, status ON public.transfers FOR EACH ROW EXECUTE FUNCTION public.forbid_transfer_identity_mutation();


--
-- Name: transfers transfers_ledger_consistent; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER transfers_ledger_consistent AFTER INSERT OR UPDATE ON public.transfers DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_transfer_row_ledger();


--
-- Name: ledger_entries ledger_entries_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: ledger_entries ledger_entries_transfer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_transfer_id_fkey FOREIGN KEY (transfer_id) REFERENCES public.transfers(id);


--
-- Name: transfers transfers_from_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transfers
    ADD CONSTRAINT transfers_from_account_id_fkey FOREIGN KEY (from_account_id) REFERENCES public.accounts(id);


--
-- Name: transfers transfers_to_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transfers
    ADD CONSTRAINT transfers_to_account_id_fkey FOREIGN KEY (to_account_id) REFERENCES public.accounts(id);


--
-- PostgreSQL database dump complete
--

INSERT INTO public.schema_migrations (version) VALUES
  ('20261114090000'),
  ('20261114090100');

