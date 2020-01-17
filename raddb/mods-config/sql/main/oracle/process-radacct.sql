#  -*- text -*-
#
#  main/oracle/process-radacct.sql -- Schema extensions for processing radacct entries
#
#  $Id$

--  ---------------------------------
--  - Per-user data usage over time -
--  ---------------------------------
--
--  An extension to the standard schema to hold per-user data usage statistics
--  for arbitrary periods.
--
--  The data_usage_by_period table is populated by periodically calling the
--  fr_new_data_usage_period stored procedure.
--
--  This table can be queried in various ways to produce reports of aggregate
--  data use over time. For example, if the fr_new_data_usage_period SP is
--  invoked one per day just after midnight, to produce usage data with daily
--  granularity, then a reasonably accurate monthly bandwidth summary for a
--  given user could be obtained with:
--
--      SELECT
--          MIN(TO_CHAR(period_start, 'YYYY-Month')) AS month,
--          SUM(acctinputoctets)/1000/1000/1000 AS GB_in,
--          SUM(acctoutputoctets)/1000/1000/1000 AS GB_out
--      FROM
--          data_usage_by_period
--      WHERE
--          username='bob' AND
--          period_end IS NOT NULL
--      GROUP BY
--          TRUNC(period_start,'month');
--
--      +----------------+----------------+-----------------+
--      | MONTH          | GB_IN          | GB_OUT          |
--      +----------------+----------------+-----------------+
--      | 2019-July      | 5.782279230000 | 50.545664820000 |
--      | 2019-August    | 4.230543340000 | 48.523096420000 |
--      | 2019-September | 4.847360590000 | 48.631835480000 |
--      | 2019-October   | 6.456763250000 | 51.686231930000 |
--      | 2019-November  | 6.362537730000 | 52.385710570000 |
--      | 2019-December  | 4.301524440000 | 50.762240270000 |
--      | 2020-January   | 5.436280540000 | 49.067775280000 |
--      +----------------+----------------+-----------------+
--
CREATE TABLE data_usage_by_period (
    id NUMBER GENERATED BY DEFAULT AS IDENTITY,
    username VARCHAR(64) NOT NULL,
    period_start TIMESTAMP WITH TIME ZONE NOT NULL,
    period_end TIMESTAMP WITH TIME ZONE,
    acctinputoctets NUMERIC(19),
    acctoutputoctets NUMERIC(19),
    PRIMARY KEY (id)
);
CREATE UNIQUE INDEX idx_data_usage_by_period_username_period_start ON data_usage_by_period (username,period_start);
CREATE INDEX idx_data_usage_by_period_period_start ON data_usage_by_period (period_start);

--
--  Stored procedure that when run with some arbitrary frequency, say
--  once per day by cron, will process the recent radacct entries to extract
--  time-windowed data containing acct{input,output}octets ("data usage") per
--  username, per period.
--
--  Each invocation will create new rows in the data_usage_by_period tables
--  containing the data used by each user since the procedure was last invoked.
--  The intervals do not need to be identical but care should be taken to
--  ensure that the start/end of each period aligns well with any intended
--  reporting intervals.
--
--  It can be invoked by running:
--
--      CALL fr_new_data_usage_period();
--
--
CREATE OR REPLACE PROCEDURE fr_new_data_usage_period
AS
    v_start TIMESTAMP WITH TIME ZONE;
    v_end TIMESTAMP WITH TIME ZONE;
BEGIN

    SELECT COALESCE(MAX(period_start), TO_DATE('1970-01-01','YYYY-MM-DD')) INTO v_start FROM data_usage_by_period;
    SELECT CAST(CURRENT_TIMESTAMP AS DATE) INTO v_end FROM dual;

    BEGIN

    --
    -- Add the data usage for the sessions that were active in the current
    -- period to the table. Include all sessions that finished since the start
    -- of this period as well as those still ongoing.
    --
    MERGE INTO data_usage_by_period d
        USING (
            SELECT
                username,
                MIN(v_start) period_start,
                MIN(v_end) period_end,
                SUM(acctinputoctets) AS acctinputoctets,
                SUM(acctoutputoctets) AS acctoutputoctets
            FROM
                radacct
            WHERE
                acctstoptime > v_start OR
                acctstoptime IS NULL
            GROUP BY
                username
        ) s
        ON ( d.username = s.username AND d.period_start = s.period_start )
        WHEN MATCHED THEN
            UPDATE SET
                acctinputoctets = d.acctinputoctets + s.acctinputoctets,
                acctoutputoctets = d.acctoutputoctets + s.acctoutputoctets,
                period_end = v_end
        WHEN NOT MATCHED THEN
            INSERT
                (username, period_start, period_end, acctinputoctets, acctoutputoctets)
            VALUES
                (s.username, s.period_start, s.period_end, s.acctinputoctets, s.acctoutputoctets);

    --
    -- Create an open-ended "next period" for all ongoing sessions and carry a
    -- negative value of their data usage to avoid double-accounting when we
    -- process the next period. Their current data usage has already been
    -- allocated to the current and possibly previous periods.
    --
    INSERT INTO data_usage_by_period (username, period_start, period_end, acctinputoctets, acctoutputoctets)
    SELECT *
    FROM (
        SELECT
            username,
            v_end + NUMTODSINTERVAL(1,'SECOND'),
            NULL,
            0 - SUM(acctinputoctets),
            0 - SUM(acctoutputoctets)
        FROM
            radacct
        WHERE
            acctstoptime IS NULL
        GROUP BY
            username
    ) s;

    END;

END;
/
