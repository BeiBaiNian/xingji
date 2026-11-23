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
