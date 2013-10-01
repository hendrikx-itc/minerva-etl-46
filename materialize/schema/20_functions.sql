SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = off;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET escape_string_warning = off;

SET search_path = materialization, pg_catalog;


CREATE OR REPLACE FUNCTION to_char(materialization.type)
	RETURNS text
AS $$
	SELECT trend.to_base_table_name(src) || ' -> ' || trend.to_base_table_name(dst)
	FROM trend.trendstore src, trend.trendstore dst
	WHERE src.id = $1.src_trendstore_id AND dst.id = $1.dst_trendstore_id
$$ LANGUAGE SQL STABLE STRICT;


CREATE OR REPLACE FUNCTION update_state()
	RETURNS void
AS $$
	INSERT INTO materialization.state(type_id, timestamp, max_modified)
		SELECT mzb.type_id, mzb.timestamp, mzb.max_modified
		FROM materialization.materializables mzb
		LEFT JOIN materialization.state ON
			state.type_id = mzb.type_id AND
			state.timestamp = mzb.timestamp
		WHERE state.type_id IS NULL;

	UPDATE materialization.state
		SET max_modified = mzb.max_modified
	FROM materialization.materializables mzb
	WHERE
		state.type_id = mzb.type_id AND
		state.timestamp = mzb.timestamp AND
		(state.max_modified < mzb.max_modified OR state.max_modified IS NULL);

	WITH obsolete AS (
		SELECT state.type_id, state.timestamp
		FROM materialization.state
		LEFT JOIN materialization.materializables mzs ON
			mzs.type_id = state.type_id AND
			mzs.timestamp = state.timestamp
		WHERE mzs.type_id is null
	)
	DELETE FROM materialization.state
	USING obsolete
	WHERE state.type_id = obsolete.type_id AND state.timestamp = obsolete.timestamp;
$$ LANGUAGE SQL VOLATILE;


CREATE TYPE materialization_result AS (processed_max_modified timestamp with time zone, row_count integer);


CREATE OR REPLACE FUNCTION materialize(src trend.trendstore, dst trend.trendstore, "timestamp" timestamp with time zone)
	RETURNS materialization_result
AS $$
DECLARE
	schema_name character varying;
	table_name character varying;
	dst_table_name character varying;
	dst_partition trend.partition;
	max_modified_query character varying;
	data_query character varying;
	conn_str character varying;
	columns_part character varying;
	column_defs_part character varying;
	modified timestamp with time zone;
	processed_max_modified timestamp with time zone;
	row_count integer;
	result materialization.materialization_result;
	replicated_server_conn system.setting;
BEGIN
	schema_name = 'trend';
	table_name = trend.to_base_table_name(src);
	dst_table_name = trend.to_base_table_name(dst);

	PERFORM trend.add_trend_to_trendstore(trendstore, col.name, col.datatype)
	FROM
	(
		SELECT name, datatype
		FROM trend.table_columns('trend', table_name)
		WHERE name NOT IN (SELECT name FROM trend.table_columns('trend', dst_table_name))
	) AS col,
	trend.trendstore
	WHERE trendstore.id = dst.id;

	PERFORM trend.modify_trendstore_columns(dst.id, array_agg(src_column))
	FROM trend.table_columns('trend', table_name) src_column
	JOIN trend.table_columns('trend', dst_table_name) dst_column ON
		src_column.name = dst_column.name
			AND
		src_column.datatype <> dst_column.datatype;

	dst_partition = trend.attributes_to_partition(dst, trend.timestamp_to_index(dst.partition_size, $3));
	EXECUTE format('DELETE FROM trend.%I WHERE timestamp = %L', dst_partition.table_name, timestamp);

	SELECT
		array_to_string(array_agg(quote_ident(name)), ', ') INTO columns_part
	FROM
		trend.table_columns(schema_name, table_name);

	max_modified_query = format('SELECT max_modified
	FROM materialization.materializables mz
	JOIN materialization.type ON type.id = mz.type_id
	WHERE
		mz.timestamp = %L AND
		type.src_trendstore_id = %L AND
		type.dst_trendstore_id = %L;', $3, src.id, dst.id);

	data_query = format('SELECT %s FROM %I.%I WHERE timestamp = %L',
		columns_part, schema_name, table_name, timestamp);

	replicated_server_conn = system.get_setting('replicated_server_conn');

	IF replicated_server_conn IS NULL THEN
		-- Local materialization
		EXECUTE max_modified_query INTO result.processed_max_modified;
		EXECUTE format('INSERT INTO trend.%I (%s) %s', dst_partition.table_name, columns_part, data_query);
	ELSE
		-- Remote materialization
		conn_str = replicated_server_conn.value;

		SELECT
			array_to_string(array_agg(format('%I %s', col.name, col.datatype)), ', ') INTO column_defs_part
		FROM
			trend.table_columns(schema_name, table_name) col;

		SELECT max_modified INTO result.processed_max_modified
		FROM public.dblink(conn_str, max_modified_query) AS r (max_modified timestamp with time zone);

		EXECUTE format('INSERT INTO trend.%I (%s) SELECT * FROM public.dblink(%L, %L) AS rel (%s)',
			dst_partition.table_name, columns_part, conn_str, data_query, column_defs_part);
	END IF;

	GET DIAGNOSTICS result.row_count = ROW_COUNT;

	IF result.row_count = 0 THEN
		RAISE NOTICE 'NO ROWS materialized FOR materialization of % -> %, %', src::text, dst::text, timestamp;
		RETURN result;
	END IF;

	UPDATE materialization.state SET processed_max_modified = result.processed_max_modified
	FROM materialization.type
	WHERE type.id = state.type_id AND state.timestamp = $3
	AND type.src_trendstore_id = $1.id
	AND type.dst_trendstore_id = $2.id;

	PERFORM trend.mark_modified(dst_partition.table_name, "timestamp", result.processed_max_modified);

	RETURN result;
END;
$$ LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE FUNCTION materialize(src_trendstore_id integer, dst_trendstore_id integer, "timestamp" timestamp with time zone)
	RETURNS materialization_result
AS $$
	SELECT materialization.materialize(src, dst, $3)
		FROM trend.trendstore src, trend.trendstore dst
		WHERE src.id = $1 AND dst.id = $2;
$$ LANGUAGE SQL VOLATILE;


CREATE OR REPLACE FUNCTION materialization(src text, dst text, "timestamp" timestamp with time zone)
	RETURNS materialization_result
AS $$
	SELECT materialization.materialize(src, dst, $3)
	FROM
		trend.trendstore src,
		trend.trendstore dst
	WHERE src::text = $1 and dst::text = $2;
$$ LANGUAGE SQL VOLATILE;


CREATE OR REPLACE FUNCTION materialize(materialization text, "timestamp" timestamp with time zone)
	RETURNS materialization_result
AS $$
	SELECT materialization.materialize(mt.src_trendstore_id, mt.dst_trendstore_id, $2)
	FROM materialization.type mt
	WHERE materialization.to_char(mt) = $1;
$$ LANGUAGE SQL VOLATILE;


CREATE OR REPLACE FUNCTION materialize(id integer, "timestamp" timestamp with time zone)
	RETURNS materialization_result
AS $$
	SELECT materialization.materialize(mt.src_trendstore_id, mt.dst_trendstore_id, $2)
	FROM materialization.type mt
	WHERE mt.id = $1;
$$ LANGUAGE SQL VOLATILE;


CREATE OR REPLACE FUNCTION define(src_trendstore_id integer, dst_trendstore_id integer)
	RETURNS materialization.type
AS $$
	INSERT INTO materialization.type (src_trendstore_id, dst_trendstore_id)
	VALUES ($1, $2)
	RETURNING type;
$$ LANGUAGE SQL VOLATILE;


CREATE OR REPLACE FUNCTION define(src trend.trendstore, dst trend.trendstore)
	RETURNS materialization.type
AS $$
	SELECT materialization.define($1.id, $2.id);
$$ LANGUAGE SQL VOLATILE;


CREATE OR REPLACE FUNCTION define(text, text)
	RETURNS materialization.type
AS $$
	SELECT
		materialization.define(src.id, dst.id)
	FROM
		trend.trendstore src,
		trend.trendstore dst
	WHERE src::text = $1 AND dst::text = $2;
$$ LANGUAGE SQL VOLATILE;


CREATE OR REPLACE FUNCTION define(trend.trendstore)
	RETURNS materialization.type
AS $$
	SELECT materialization.define(
		$1,
	trend.attributes_to_trendstore(substring(ds.name, '^v(.*)'), et.name, ts.granularity))
	FROM trend.view
	JOIN trend.trendstore ts on ts.id = view.trendstore_id
	JOIN directory.datasource ds on ds.id = ts.datasource_id
	JOIN directory.entitytype et on et.id = ts.entitytype_id
	WHERE view.trendstore_id = $1.id;
$$ LANGUAGE SQL VOLATILE;

COMMENT ON FUNCTION define(trend.trendstore)
IS 'Defines a new materialization with the convention that the datasource of
the source trendstore should start with a ''v'' for views and that the
destination trendstore has the same properties except for a datasource with a
name without the leading ''v''. A new trendstore and datasource are created if
they do not exist.';


CREATE OR REPLACE FUNCTION define(trend.view)
	RETURNS materialization.type
AS $$
	SELECT materialization.define(
		ts,
		trend.attributes_to_trendstore(substring(ds.name, '^v(.*)'), et.name, ts.granularity))
	FROM trend.trendstore ts
	JOIN directory.datasource ds on ds.id = ts.datasource_id
	JOIN directory.entitytype et on et.id = ts.entitytype_id
	WHERE ts.id = $1.trendstore_id;
$$ LANGUAGE SQL VOLATILE;

COMMENT ON FUNCTION define(trend.view)
IS 'Defines a new materialization with the convention that the datasource of
the source trendstore should start with a ''v'' for views and that the
destination trendstore has the same properties except for a datasource with a
name without the leading ''v''. A new trendstore and datasource are created if
they do not exist.';


CREATE OR REPLACE FUNCTION render_job_json(type_id integer, timestamp with time zone)
	RETURNS character varying
AS $$
	SELECT format('{"type_id": %s, "timestamp": "%s"}', $1, $2);
$$ LANGUAGE SQL IMMUTABLE;


CREATE OR REPLACE FUNCTION create_job(type_id integer, "timestamp" timestamp with time zone)
	RETURNS integer
AS $$
DECLARE
	description text;
	new_job_id integer;
BEGIN
	description := materialization.render_job_json(type_id, "timestamp");

	SELECT system.create_job('materialize', description, 1, job_source.id) INTO new_job_id
		FROM system.job_source
		WHERE name = 'compile-materialize-jobs';

	UPDATE materialization.state
		SET job_id = new_job_id
		WHERE state.type_id = $1 AND state.timestamp = $2;

	RETURN new_job_id;
END;
$$ LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE FUNCTION runnable(type materialization.type, "timestamp" timestamp with time zone, max_modified timestamp with time zone)
	RETURNS boolean
AS $$
	SELECT $1.enabled AND CASE
		WHEN trendstore.granularity = '1800' OR trendstore.granularity = '900' OR trendstore.granularity = '300' THEN
			$2 < now() AND $3 < now() - interval '180 seconds'
		WHEN trendstore.granularity = '3600' THEN
			$2 < now() - interval '15 minutes' AND $3 < now() - interval '5 minutes'
		ELSE
			$2 < now() - interval '3 hours' AND $3 < now() - interval '15 minutes'
		END
	FROM trend.trendstore WHERE id = $1.dst_trendstore_id;
$$ LANGUAGE SQL IMMUTABLE;


CREATE OR REPLACE FUNCTION open_job_slots(slot_count integer)
	RETURNS integer
AS $$
	SELECT greatest($1 - COUNT(*), 0)::integer
	FROM system.job
	WHERE type = 'materialize' AND (state = 'running' OR state = 'queued');
$$ LANGUAGE SQL STABLE;


CREATE OR REPLACE FUNCTION create_jobs_limited(tag varchar, job_limit integer)
	RETURNS integer
AS $$
DECLARE
	created_jobs integer := 0;
	new_job_count integer;
	runnable_materializations_query text;
	conn_str text;
	replicated_server_conn system.setting;
BEGIN
	new_job_count = materialization.open_job_slots(job_limit);

	replicated_server_conn = system.get_setting('replicated_server_conn');

	IF replicated_server_conn IS NULL THEN
		SELECT COUNT(materialization.create_job(type_id, timestamp)) INTO created_jobs
		FROM (
			SELECT type_id, timestamp
			FROM materialization.tagged_runnable_materializations trm
			WHERE trm.tag = $1
			LIMIT new_job_count
		) mzs;
	ELSE
		runnable_materializations_query = format('SELECT type_id, timestamp
			FROM materialization.tagged_runnable_materializations
			WHERE tag = ''%s''
			LIMIT %s', tag, new_job_count);

		SELECT COUNT(materialization.create_job(replicated_state.type_id, replicated_state.timestamp)) INTO created_jobs
		FROM public.dblink(replicated_server_conn.value, runnable_materializations_query)
			AS replicated_state(type_id integer, "timestamp" timestamp with time zone)
		JOIN materialization.tagged_runnable_materializations rj ON
			replicated_state.type_id = rj.type_id
				AND
			replicated_state.timestamp = rj.timestamp;
	END IF;

	RETURN created_jobs;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION tag(tag_name character varying, type_id integer)
	RETURNS materialization.type_tag_link
AS $$
	INSERT INTO materialization.type_tag_link (type_id, tag_id)
	SELECT $2, tag.id FROM directory.tag WHERE name = $1
	RETURNING *;
$$ LANGUAGE SQL VOLATILE;

COMMENT ON FUNCTION tag(character varying, type_id integer)
IS 'Add tag with name tag_name to materialization type with id type_id.
The tag must already exist.';


CREATE OR REPLACE FUNCTION tag(tag_name character varying, materialization.type)
	RETURNS materialization.type
AS $$
	INSERT INTO materialization.type_tag_link (type_id, tag_id)
	SELECT $2.id, tag.id FROM directory.tag WHERE name = $1
	RETURNING $2;
$$ LANGUAGE SQL VOLATILE;

COMMENT ON FUNCTION tag(character varying, materialization.type)
IS 'Add tag with name tag_name to materialization type. The tag must already exist.';


CREATE OR REPLACE FUNCTION untag(materialization.type)
	RETURNS materialization.type
AS $$
	DELETE FROM materialization.type_tag_link WHERE type_id = $1.id RETURNING $1;
$$ LANGUAGE SQL VOLATILE;

COMMENT ON FUNCTION untag(materialization.type)
IS 'Remove all tags from the materialization';


CREATE OR REPLACE FUNCTION reset(materialization.type)
	RETURNS void
AS $$
	DELETE FROM trend.partition WHERE trendstore_id = $1.dst_trendstore_id;
	DELETE FROM materialization.state WHERE type_id = $1.id;
$$ LANGUAGE SQL VOLATILE;

COMMENT ON FUNCTION reset(materialization.type)
IS 'Remove data (partitions) resulting from this materialization and the
corresponding state records, so materialization for all timestamps can be done
again';


CREATE OR REPLACE FUNCTION enable(materialization.type)
	RETURNS materialization.type
AS $$
	UPDATE materialization.type SET enabled = true WHERE id = $1.id RETURNING type;
$$ LANGUAGE SQL VOLATILE;


CREATE OR REPLACE FUNCTION disable(materialization.type)
	RETURNS materialization.type
AS $$
	UPDATE materialization.type SET enabled = false WHERE id = $1.id RETURNING type;
$$ LANGUAGE SQL VOLATILE;
