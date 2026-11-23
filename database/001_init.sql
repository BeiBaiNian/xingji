-- Run as the database owner/administrator, never as a daily application login.
BEGIN;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='xingji_client') THEN
    CREATE ROLE xingji_client NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS xingji;
REVOKE ALL ON SCHEMA xingji FROM PUBLIC;
GRANT USAGE ON SCHEMA xingji TO xingji_client;

CREATE TABLE IF NOT EXISTS xingji.vaults (
  id uuid PRIMARY KEY,
  envelope jsonb NOT NULL,
  envelope_revision bigint NOT NULL DEFAULT 1,
  cursor bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS xingji.vault_access (
  vault_id uuid NOT NULL REFERENCES xingji.vaults(id),
  db_role name NOT NULL,
  PRIMARY KEY(vault_id,db_role)
);
CREATE TABLE IF NOT EXISTS xingji.devices (
  vault_id uuid NOT NULL REFERENCES xingji.vaults(id),
  device_id uuid NOT NULL,
  db_role name NOT NULL,
  ack_cursor bigint NOT NULL DEFAULT 0,
  last_seen timestamptz NOT NULL DEFAULT now(),
  revoked boolean NOT NULL DEFAULT false,
  PRIMARY KEY(vault_id,device_id)
);
CREATE TABLE IF NOT EXISTS xingji.records (
  vault_id uuid NOT NULL REFERENCES xingji.vaults(id),
  record_id uuid NOT NULL,
  revision bigint NOT NULL,
  packet jsonb NOT NULL,
  PRIMARY KEY(vault_id,record_id)
);
CREATE TABLE IF NOT EXISTS xingji.changes (
  vault_id uuid NOT NULL REFERENCES xingji.vaults(id),
  cursor bigint NOT NULL,
  record_id uuid NOT NULL,
  revision bigint NOT NULL,
  operation_id uuid NOT NULL,
  packet jsonb NOT NULL,
  written_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(vault_id,cursor),
  UNIQUE(vault_id,operation_id)
);

CREATE OR REPLACE FUNCTION xingji.authorize(p_vault uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM xingji.vault_access WHERE vault_id=p_vault AND db_role=session_user) THEN
    RAISE EXCEPTION 'vault access denied' USING ERRCODE='42501';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION xingji.api_version()
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$ SELECT 1 $$;

CREATE OR REPLACE FUNCTION xingji.api_list_vaults()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('vault_id',v.id,'envelope',v.envelope,
   'envelope_revision',v.envelope_revision) ORDER BY v.created_at),'[]'::jsonb)
 FROM xingji.vaults v JOIN xingji.vault_access a ON a.vault_id=v.id WHERE a.db_role=session_user
$$;

CREATE OR REPLACE FUNCTION xingji.api_bootstrap(p_vault uuid,p_envelope jsonb,p_device uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
DECLARE v_new uuid; v_result jsonb;
BEGIN
 IF p_envelope->>'vault_id' IS DISTINCT FROM p_vault::text OR p_envelope->>'format' IS DISTINCT FROM '1'
    OR octet_length(p_envelope::text)>16384 THEN
   RAISE EXCEPTION 'invalid envelope' USING ERRCODE='22023';
 END IF;
 INSERT INTO xingji.vaults(id,envelope) VALUES(p_vault,p_envelope)
 ON CONFLICT DO NOTHING RETURNING id INTO v_new;
 IF v_new IS NOT NULL THEN
   INSERT INTO xingji.vault_access(vault_id,db_role) VALUES(p_vault,session_user);
 END IF;
 PERFORM xingji.authorize(p_vault);
 INSERT INTO xingji.devices(vault_id,device_id,db_role) VALUES(p_vault,p_device,session_user)
 ON CONFLICT DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM xingji.devices WHERE vault_id=p_vault AND device_id=p_device
   AND db_role=session_user AND NOT revoked) THEN
   RAISE EXCEPTION 'device access denied' USING ERRCODE='42501';
 END IF;
 UPDATE xingji.devices SET last_seen=now() WHERE vault_id=p_vault AND device_id=p_device;
 SELECT jsonb_build_object('envelope',envelope,'envelope_revision',envelope_revision,
   'cursor',cursor,'created',v_new IS NOT NULL) INTO v_result FROM xingji.vaults WHERE id=p_vault;
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION xingji.api_put(p_vault uuid,p_device uuid,p_base bigint,p_packet jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
DECLARE v_record uuid; v_operation uuid; v_packet jsonb; v_old xingji.records%ROWTYPE;
 v_previous xingji.changes%ROWTYPE; v_revision bigint; v_cursor bigint;
BEGIN
 PERFORM xingji.authorize(p_vault);
 IF NOT EXISTS(SELECT 1 FROM xingji.devices WHERE vault_id=p_vault AND device_id=p_device
   AND db_role=session_user AND NOT revoked) THEN
   RAISE EXCEPTION 'device access denied' USING ERRCODE='42501';
 END IF;
 IF p_packet->>'vault_id' IS DISTINCT FROM p_vault::text OR p_packet->>'format' IS DISTINCT FROM '1'
   OR p_packet->>'key_version' IS DISTINCT FROM '1' OR jsonb_typeof(p_packet->'deleted') IS DISTINCT FROM 'boolean'
   OR p_base<0 OR octet_length(p_packet::text)>2097152
   OR octet_length(decode(p_packet->>'nonce','base64')) IS DISTINCT FROM 24
   OR coalesce(octet_length(decode(p_packet->>'payload','base64')),0)<16 THEN
   RAISE EXCEPTION 'invalid encrypted record' USING ERRCODE='22023';
 END IF;
 v_record := (p_packet->>'record_id')::uuid;
 v_operation := (p_packet->>'operation_id')::uuid;
 -- Store a strict allow-list; a buggy client cannot smuggle plaintext fields here.
 v_packet := jsonb_build_object('vault_id',p_vault,'record_id',v_record,'operation_id',v_operation,
   'format',1,'key_version',1,'deleted',(p_packet->>'deleted')::boolean,
   'nonce',p_packet->>'nonce','payload',p_packet->>'payload');
 -- All writers lock the same row BEFORE checking versions and allocating a cursor.
 -- A later cursor can never commit before an earlier cursor in this vault.
 PERFORM 1 FROM xingji.vaults WHERE id=p_vault FOR UPDATE;
 SELECT * INTO v_previous FROM xingji.changes WHERE vault_id=p_vault AND operation_id=v_operation;
 IF FOUND THEN
   IF v_previous.packet<>v_packet OR v_previous.record_id<>v_record THEN
     RAISE EXCEPTION 'operation id reused with different content' USING ERRCODE='22023';
   END IF;
   RETURN jsonb_build_object('status','ok','revision',v_previous.revision,'cursor',v_previous.cursor);
 END IF;
 SELECT * INTO v_old FROM xingji.records WHERE vault_id=p_vault AND record_id=v_record;
 IF coalesce(v_old.revision,0)<>p_base THEN
   RETURN jsonb_build_object('status','conflict','revision',coalesce(v_old.revision,0),'packet',v_old.packet);
 END IF;
 v_revision:=p_base+1;
 UPDATE xingji.vaults SET cursor=cursor+1 WHERE id=p_vault RETURNING cursor INTO v_cursor;
 INSERT INTO xingji.records(vault_id,record_id,revision,packet) VALUES(p_vault,v_record,v_revision,v_packet)
 ON CONFLICT(vault_id,record_id) DO UPDATE SET revision=excluded.revision,packet=excluded.packet;
 INSERT INTO xingji.changes(vault_id,cursor,record_id,revision,operation_id,packet)
 VALUES(p_vault,v_cursor,v_record,v_revision,v_operation,v_packet);
 PERFORM pg_notify('xingji_changes',p_vault::text);
 RETURN jsonb_build_object('status','ok','revision',v_revision,'cursor',v_cursor);
END $$;

CREATE OR REPLACE FUNCTION xingji.api_changes(p_vault uuid,p_after bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
DECLARE result jsonb;
BEGIN
 PERFORM xingji.authorize(p_vault);
 SELECT coalesce(jsonb_agg(jsonb_build_object('cursor',cursor,'revision',revision,'packet',packet) ORDER BY cursor),'[]'::jsonb)
 INTO result FROM (SELECT cursor,revision,packet FROM xingji.changes WHERE vault_id=p_vault AND cursor>p_after
 ORDER BY cursor LIMIT 200) page;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION xingji.api_ack(p_vault uuid,p_device uuid,p_cursor bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
BEGIN
 PERFORM xingji.authorize(p_vault);
 IF p_cursor<0 OR p_cursor>(SELECT cursor FROM xingji.vaults WHERE id=p_vault) THEN
   RAISE EXCEPTION 'invalid cursor';
 END IF;
 UPDATE xingji.devices SET ack_cursor=greatest(ack_cursor,p_cursor),last_seen=now()
 WHERE vault_id=p_vault AND device_id=p_device AND db_role=session_user AND NOT revoked;
 IF NOT FOUND THEN RAISE EXCEPTION 'device access denied' USING ERRCODE='42501'; END IF;
END $$;

CREATE OR REPLACE FUNCTION xingji.api_devices(p_vault uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
DECLARE result jsonb;
BEGIN
 PERFORM xingji.authorize(p_vault);
 SELECT coalesce(jsonb_agg(jsonb_build_object('device_id',device_id,'cursor',ack_cursor,
   'last_seen',last_seen,'revoked',revoked)),'[]'::jsonb) INTO result
 FROM xingji.devices WHERE vault_id=p_vault;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION xingji.api_update_envelope(p_vault uuid,p_base bigint,p_envelope jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
DECLARE v_revision bigint;
BEGIN
 PERFORM xingji.authorize(p_vault);
 IF p_envelope->>'vault_id' IS DISTINCT FROM p_vault::text OR p_envelope->>'format' IS DISTINCT FROM '1'
   OR octet_length(p_envelope::text)>16384 THEN RAISE EXCEPTION 'invalid envelope'; END IF;
 PERFORM 1 FROM xingji.vaults WHERE id=p_vault FOR UPDATE;
 -- Retry of a committed password change is idempotent.
 SELECT envelope_revision INTO v_revision FROM xingji.vaults WHERE id=p_vault AND envelope=p_envelope;
 IF FOUND THEN RETURN v_revision; END IF;
 UPDATE xingji.vaults SET envelope=p_envelope,envelope_revision=envelope_revision+1
 WHERE id=p_vault AND envelope_revision=p_base RETURNING envelope_revision INTO v_revision;
 IF NOT FOUND THEN RAISE EXCEPTION 'envelope revision conflict' USING ERRCODE='40001'; END IF;
 PERFORM pg_notify('xingji_changes',p_vault::text);
 RETURN v_revision;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA xingji FROM PUBLIC,xingji_client;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA xingji FROM PUBLIC,xingji_client;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA xingji FROM PUBLIC,xingji_client;
GRANT EXECUTE ON FUNCTION xingji.api_version(),xingji.api_list_vaults(),
 xingji.api_bootstrap(uuid,jsonb,uuid),xingji.api_put(uuid,uuid,bigint,jsonb),
 xingji.api_changes(uuid,bigint),xingji.api_ack(uuid,uuid,bigint),
 xingji.api_devices(uuid),xingji.api_update_envelope(uuid,bigint,jsonb) TO xingji_client;
COMMIT;
-- Upgrade an existing XingJi schema as its owner/administrator.
-- Transactional and repeatable. Does not purge any memo during installation.
BEGIN;
CREATE TABLE IF NOT EXISTS xingji.purges (
  vault_id uuid NOT NULL REFERENCES xingji.vaults(id),
  record_id uuid NOT NULL,
  revision bigint NOT NULL,
  cursor bigint NOT NULL,
  packet jsonb NOT NULL,
  PRIMARY KEY(vault_id,record_id)
);
CREATE INDEX IF NOT EXISTS changes_record_idx ON xingji.changes(vault_id,record_id);

DO $$ BEGIN
 IF to_regprocedure('xingji.api_put_v1(uuid,uuid,bigint,jsonb)') IS NULL THEN
   ALTER FUNCTION xingji.api_put(uuid,uuid,bigint,jsonb) RENAME TO api_put_v1;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION xingji.api_put(p_vault uuid,p_device uuid,p_base bigint,p_packet jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
DECLARE v_deleted xingji.purges%ROWTYPE;
BEGIN
 PERFORM xingji.authorize(p_vault);
 IF NOT EXISTS(SELECT 1 FROM xingji.devices WHERE vault_id=p_vault AND device_id=p_device
   AND db_role=session_user AND NOT revoked) THEN
   RAISE EXCEPTION 'device access denied' USING ERRCODE='42501';
 END IF;
 PERFORM 1 FROM xingji.vaults WHERE id=p_vault FOR UPDATE;
 SELECT * INTO v_deleted FROM xingji.purges
 WHERE vault_id=p_vault AND record_id=(p_packet->>'record_id')::uuid;
 IF FOUND THEN
   RETURN jsonb_build_object('status','purged','revision',v_deleted.revision,
     'cursor',v_deleted.cursor,'packet',v_deleted.packet);
 END IF;
 RETURN xingji.api_put_v1(p_vault,p_device,p_base,p_packet);
END $$;

CREATE OR REPLACE FUNCTION xingji.api_purge(p_vault uuid,p_device uuid,p_packet jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
DECLARE v_record uuid; v_operation uuid; v_packet jsonb;
 v_revision bigint; v_cursor bigint; v_deleted xingji.purges%ROWTYPE;
BEGIN
 PERFORM xingji.authorize(p_vault);
 IF NOT EXISTS(SELECT 1 FROM xingji.devices WHERE vault_id=p_vault AND device_id=p_device
   AND db_role=session_user AND NOT revoked) THEN
   RAISE EXCEPTION 'device access denied' USING ERRCODE='42501';
 END IF;
 IF p_packet->>'vault_id' IS DISTINCT FROM p_vault::text OR p_packet->>'format' IS DISTINCT FROM '1'
   OR p_packet->>'key_version' IS DISTINCT FROM '1' OR p_packet->'deleted' IS DISTINCT FROM 'true'::jsonb
   OR octet_length(p_packet::text)>8192
   OR octet_length(decode(p_packet->>'nonce','base64')) IS DISTINCT FROM 24
   OR coalesce(octet_length(decode(p_packet->>'payload','base64')),0)<16 THEN
   RAISE EXCEPTION 'invalid purge marker' USING ERRCODE='22023';
 END IF;
 v_record := (p_packet->>'record_id')::uuid;
 v_operation := (p_packet->>'operation_id')::uuid;
 v_packet := jsonb_build_object('vault_id',p_vault,'record_id',v_record,'operation_id',v_operation,
   'format',1,'key_version',1,'deleted',true,'nonce',p_packet->>'nonce','payload',p_packet->>'payload');
 PERFORM 1 FROM xingji.vaults WHERE id=p_vault FOR UPDATE;
 SELECT * INTO v_deleted FROM xingji.purges WHERE vault_id=p_vault AND record_id=v_record;
 IF FOUND THEN
   RETURN jsonb_build_object('status','purged','revision',v_deleted.revision,
     'cursor',v_deleted.cursor,'packet',v_deleted.packet);
 END IF;
 SELECT coalesce(max(revision),0)+1 INTO v_revision FROM xingji.records
 WHERE vault_id=p_vault AND record_id=v_record;
 UPDATE xingji.vaults SET cursor=cursor+1 WHERE id=p_vault RETURNING cursor INTO v_cursor;
 INSERT INTO xingji.purges(vault_id,record_id,revision,cursor,packet)
 VALUES(p_vault,v_record,v_revision,v_cursor,v_packet);
 DELETE FROM xingji.records WHERE vault_id=p_vault AND record_id=v_record;
 -- Preserve contiguous cursors, but remove every previous encrypted content
 -- version. Clients authenticate this marker before erasing their own copies.
 UPDATE xingji.changes SET packet='{}'::jsonb
 WHERE vault_id=p_vault AND record_id=v_record;
 INSERT INTO xingji.changes(vault_id,cursor,record_id,revision,operation_id,packet)
 VALUES(p_vault,v_cursor,v_record,v_revision,v_operation,'{}'::jsonb);
 PERFORM pg_notify('xingji_changes',p_vault::text);
 RETURN jsonb_build_object('status','purged','revision',v_revision,'cursor',v_cursor,'packet',v_packet);
END $$;

CREATE OR REPLACE FUNCTION xingji.api_changes(p_vault uuid,p_after bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$
DECLARE result jsonb;
BEGIN
 PERFORM xingji.authorize(p_vault);
 SELECT coalesce(jsonb_agg(jsonb_build_object('cursor',cursor,'revision',revision,'packet',packet) ORDER BY cursor),'[]'::jsonb)
 INTO result FROM (
   SELECT c.cursor,coalesce(p.revision,c.revision) AS revision,coalesce(p.packet,c.packet) AS packet
   FROM xingji.changes c LEFT JOIN xingji.purges p ON p.vault_id=c.vault_id AND p.record_id=c.record_id
   WHERE c.vault_id=p_vault AND c.cursor>p_after ORDER BY c.cursor LIMIT 200
 ) page;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION xingji.api_version()
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,xingji AS $$ SELECT 2 $$;

REVOKE ALL ON xingji.purges FROM PUBLIC,xingji_client;
REVOKE ALL ON FUNCTION xingji.api_put_v1(uuid,uuid,bigint,jsonb),
 xingji.api_put(uuid,uuid,bigint,jsonb),xingji.api_purge(uuid,uuid,jsonb),xingji.api_version() FROM PUBLIC,xingji_client;
GRANT EXECUTE ON FUNCTION xingji.api_put(uuid,uuid,bigint,jsonb),
 xingji.api_purge(uuid,uuid,jsonb),xingji.api_version() TO xingji_client;
COMMIT;
