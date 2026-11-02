// What each introspection query returned for the fixture schema below, on throwaway containers of the official Docker
// images, read through each server's own client with `--xml` (so NULL and '' differ): `SchemaCache.load()` with the
// databases `airsql_fixture` and `airsql other`, then `loadStatistics("airsql_fixture")`. One section per query kind
// (`ReplaySource.kind(of:)`); a row's values are separated by "|", NULL is \N, and \\, \|, \t, \n, \r are escaped.
// MySQL 8.4 and 9.7 return the same schema in a different row order.

enum SchemaFixtures {
    /// mariadb:11.8 (11.8.9)
    static let mariadb118 = #"""
        == server
        11.8.9-MariaDB-ubu2404|0|STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
        == databases
        information_schema|utf8mb3|utf8mb3_general_ci
        performance_schema|utf8mb3|utf8mb3_general_ci
        sys|utf8mb3|utf8mb3_general_ci
        airsql other|latin1|latin1_swedish_ci
        airsql_fixture|utf8mb4|utf8mb4_unicode_ci
        mysql|utf8mb4|utf8mb4_uca1400_ai_ci
        == tables
        airsql other|refs|BASE TABLE|InnoDB|
        airsql_fixture|log|BASE TABLE|MyISAM|
        airsql_fixture|customers|BASE TABLE|InnoDB|People who buy
        airsql_fixture|order_seq|SEQUENCE|InnoDB|
        airsql_fixture|orders|BASE TABLE|InnoDB|
        airsql_fixture|we`ird 'name' ✓|BASE TABLE|InnoDB|
        airsql_fixture|customer_emails|VIEW|\N|VIEW
        airsql_fixture|order_lines|BASE TABLE|InnoDB|
        airsql_fixture|audit|SYSTEM VERSIONED|InnoDB|
        == routines
        airsql_fixture|add_customer|PROCEDURE|\N|Adds one
        airsql_fixture|order_count|FUNCTION|int(11)|
        == triggers
        airsql_fixture|orders_bi|orders|BEFORE|INSERT|1
        airsql_fixture|orders_au|orders|AFTER|UPDATE|1
        == events
        airsql_fixture|purge_log|DISABLED|Clears the log
        == columns
        airsql other|refs|id|1|int|int(11)|NO|\N||\N|\N|\N|
        airsql other|refs|customer_id|2|int|int(10) unsigned|YES|NULL||\N|\N|\N|
        airsql_fixture|log|at|1|datetime|datetime|NO|\N||\N|\N|\N|
        airsql_fixture|log|message|2|varchar|varchar(200)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|id|1|int|int(10) unsigned|NO|\N|auto_increment|\N|\N|\N|
        airsql_fixture|customers|email|2|varchar|varchar(255)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|name|3|varchar|varchar(100)|NO|'it''s'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|note|4|text|text|YES|NULL||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|status|5|enum|enum('new','active','gone')|NO|'new'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|flags|6|set|set('a','b')|YES|NULL||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|balance|7|decimal|decimal(10,2)|NO|0.00||\N|\N|\N|
        airsql_fixture|customers|bits|8|bit|bit(3)|NO|b'101'||\N|\N|\N|
        airsql_fixture|customers|created|9|timestamp|timestamp|NO|current_timestamp()||\N|\N|\N|
        airsql_fixture|customers|updated|10|datetime|datetime(3)|YES|current_timestamp(3)|on update current_timestamp(3)|\N|\N|\N|
        airsql_fixture|customers|prefs|11|longtext|longtext|YES|NULL||\N|utf8mb4|utf8mb4_bin|
        airsql_fixture|customers|path|12|varchar|varchar(20)|YES|'C:\\\\tmp'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|token|13|char|char(36)|NO|uuid()||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|word|14|varchar|varchar(10)|NO|'NULL'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|secret|15|int|int(11)|YES|NULL|INVISIBLE|\N|\N|\N|
        airsql_fixture|customers|email_domain|16|varchar|varchar(255)|YES|NULL|VIRTUAL GENERATED|substring_index(`email`,'@',-1)|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|name_upper|17|varchar|varchar(100)|YES|NULL|STORED GENERATED|ucase(`name`)|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_seq|next_not_cached_value|1|bigint|bigint(21)|NO|\N||\N|\N|\N|
        airsql_fixture|order_seq|minimum_value|2|bigint|bigint(21)|NO|\N||\N|\N|\N|
        airsql_fixture|order_seq|maximum_value|3|bigint|bigint(21)|NO|\N||\N|\N|\N|
        airsql_fixture|order_seq|start_value|4|bigint|bigint(21)|NO|\N||\N|\N|\N|start value when sequences is created or value if RESTART is used
        airsql_fixture|order_seq|increment|5|bigint|bigint(21)|NO|\N||\N|\N|\N|increment value
        airsql_fixture|order_seq|cache_size|6|bigint|bigint(21) unsigned|NO|\N||\N|\N|\N|
        airsql_fixture|order_seq|cycle_option|7|tinyint|tinyint(1) unsigned|NO|\N||\N|\N|\N|0 if no cycles are allowed, 1 if the sequence should begin a new cycle when maximum_value is passed
        airsql_fixture|order_seq|cycle_count|8|bigint|bigint(21)|NO|\N||\N|\N|\N|How many cycles have been done
        airsql_fixture|orders|id|1|bigint|bigint(20)|NO|\N|auto_increment|\N|\N|\N|
        airsql_fixture|orders|customer_id|2|int|int(10) unsigned|YES|NULL||\N|\N|\N|
        airsql_fixture|orders|region|3|char|char(2)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|orders|number|4|int|int(11)|NO|\N||\N|\N|\N|
        airsql_fixture|orders|total|5|decimal|decimal(12,2)|NO|\N||\N|\N|\N|
        airsql_fixture|orders|parent_id|6|bigint|bigint(20)|YES|NULL||\N|\N|\N|
        airsql_fixture|we`ird 'name' ✓|col `1|1|int|int(11)|YES|NULL||\N|\N|\N|
        airsql_fixture|we`ird 'name' ✓|naïve "x"|2|varchar|varchar(5)|YES|'a''b'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customer_emails|id|1|int|int(10) unsigned|NO|0||\N|\N|\N|
        airsql_fixture|customer_emails|email|2|varchar|varchar(255)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_lines|region|1|char|char(2)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_lines|number|2|int|int(11)|NO|\N||\N|\N|\N|
        airsql_fixture|order_lines|line|3|smallint|smallint(6)|NO|\N||\N|\N|\N|
        airsql_fixture|order_lines|qty|4|int|int(11)|NO|1||\N|\N|\N|
        airsql_fixture|audit|id|1|int|int(11)|NO|\N||\N|\N|\N|
        airsql_fixture|audit|what|2|varchar|varchar(50)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|audit|address|3|inet6|inet6|YES|NULL||\N|\N|\N|
        == indexes
        airsql other|refs|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql other|refs|customer_id|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql_fixture|customers|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|customers|email|0|1|email|\N|A|BTREE||YES|\N
        airsql_fixture|customers|name_prefix|1|1|name|10|A|BTREE||YES|\N
        airsql_fixture|customers|created_desc|1|1|created|\N|D|BTREE||NO|\N
        airsql_fixture|customers|note_text|1|1|note|\N|\N|FULLTEXT||YES|\N
        airsql_fixture|orders|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|orders|customer|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|orders_parent|1|1|parent_id|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|3|line|\N|A|BTREE||YES|\N
        airsql_fixture|audit|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        == foreignKeys
        airsql other|refs|refs_ibfk_1|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|orders|orders_customer|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|orders|orders_parent|parent_id|1|airsql_fixture|orders|id
        airsql_fixture|order_lines|lines_order|region|1|airsql_fixture|orders|region
        airsql_fixture|order_lines|lines_order|number|2|airsql_fixture|orders|number
        == foreignKeyRules
        airsql other|refs|refs_ibfk_1|RESTRICT|RESTRICT
        airsql_fixture|orders|orders_customer|CASCADE|SET NULL
        airsql_fixture|orders|orders_parent|RESTRICT|CASCADE
        airsql_fixture|order_lines|lines_order|RESTRICT|RESTRICT
        == checks
        airsql_fixture|customers|prefs|json_valid(`prefs`)|YES
        airsql_fixture|orders|total|`total` >= 0|YES
        airsql_fixture|orders|total_small|`total` < 1000000|YES
        == statistics
        airsql_fixture|log|0|0|1024|0|\N|2026-11-02 17:53:22|2026-11-02 17:53:22|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|customers|0|16384|81920|0|1|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|order_seq|1|0|0|0|\N|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Fixed|
        airsql_fixture|orders|0|16384|49152|0|1|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|we`ird 'name' ✓|0|16384|0|0|\N|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|customer_emails|\N|\N|\N|\N|\N|\N|\N|\N|\N|\N
        airsql_fixture|order_lines|0|16384|0|0|\N|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|audit|0|16384|0|0|\N|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        """#

    /// mariadb:10.5 (10.5.29)
    static let mariadb105 = #"""
        == server
        10.5.29-MariaDB-ubu2004|0|STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
        == databases
        information_schema|utf8|utf8_general_ci
        performance_schema|utf8|utf8_general_ci
        airsql other|latin1|latin1_swedish_ci
        airsql_fixture|utf8mb4|utf8mb4_unicode_ci
        mysql|utf8mb4|utf8mb4_general_ci
        == tables
        airsql other|refs|BASE TABLE|InnoDB|
        airsql_fixture|log|BASE TABLE|MyISAM|
        airsql_fixture|customers|BASE TABLE|InnoDB|People who buy
        airsql_fixture|order_seq|SEQUENCE|InnoDB|
        airsql_fixture|orders|BASE TABLE|InnoDB|
        airsql_fixture|we`ird 'name' ✓|BASE TABLE|InnoDB|
        airsql_fixture|customer_emails|VIEW|\N|VIEW
        airsql_fixture|order_lines|BASE TABLE|InnoDB|
        airsql_fixture|audit|SYSTEM VERSIONED|InnoDB|
        == routines
        airsql_fixture|add_customer|PROCEDURE|\N|Adds one
        airsql_fixture|order_count|FUNCTION|int(11)|
        == triggers
        airsql_fixture|orders_bi|orders|BEFORE|INSERT|1
        airsql_fixture|orders_au|orders|AFTER|UPDATE|1
        == events
        airsql_fixture|purge_log|DISABLED|Clears the log
        == columns
        airsql other|refs|id|1|int|int(11)|NO|\N||\N|\N|\N|
        airsql other|refs|customer_id|2|int|int(10) unsigned|YES|NULL||\N|\N|\N|
        airsql_fixture|log|at|1|datetime|datetime|NO|\N||\N|\N|\N|
        airsql_fixture|log|message|2|varchar|varchar(200)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|id|1|int|int(10) unsigned|NO|\N|auto_increment|\N|\N|\N|
        airsql_fixture|customers|email|2|varchar|varchar(255)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|name|3|varchar|varchar(100)|NO|'it''s'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|note|4|text|text|YES|NULL||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|status|5|enum|enum('new','active','gone')|NO|'new'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|flags|6|set|set('a','b')|YES|NULL||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|balance|7|decimal|decimal(10,2)|NO|0.00||\N|\N|\N|
        airsql_fixture|customers|bits|8|bit|bit(3)|NO|b'101'||\N|\N|\N|
        airsql_fixture|customers|created|9|timestamp|timestamp|NO|current_timestamp()||\N|\N|\N|
        airsql_fixture|customers|updated|10|datetime|datetime(3)|YES|current_timestamp(3)|on update current_timestamp(3)|\N|\N|\N|
        airsql_fixture|customers|prefs|11|longtext|longtext|YES|NULL||\N|utf8mb4|utf8mb4_bin|
        airsql_fixture|customers|path|12|varchar|varchar(20)|YES|'C:\\\\tmp'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|token|13|char|char(36)|NO|uuid()||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|word|14|varchar|varchar(10)|NO|'NULL'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|secret|15|int|int(11)|YES|NULL|INVISIBLE|\N|\N|\N|
        airsql_fixture|customers|email_domain|16|varchar|varchar(255)|YES|NULL|VIRTUAL GENERATED|substring_index(`email`,'@',-1)|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|name_upper|17|varchar|varchar(100)|YES|NULL|STORED GENERATED|ucase(`name`)|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_seq|next_not_cached_value|1|bigint|bigint(21)|NO|\N||\N|\N|\N|
        airsql_fixture|order_seq|minimum_value|2|bigint|bigint(21)|NO|\N||\N|\N|\N|
        airsql_fixture|order_seq|maximum_value|3|bigint|bigint(21)|NO|\N||\N|\N|\N|
        airsql_fixture|order_seq|start_value|4|bigint|bigint(21)|NO|\N||\N|\N|\N|start value when sequences is created or value if RESTART is used
        airsql_fixture|order_seq|increment|5|bigint|bigint(21)|NO|\N||\N|\N|\N|increment value
        airsql_fixture|order_seq|cache_size|6|bigint|bigint(21) unsigned|NO|\N||\N|\N|\N|
        airsql_fixture|order_seq|cycle_option|7|tinyint|tinyint(1) unsigned|NO|\N||\N|\N|\N|0 if no cycles are allowed, 1 if the sequence should begin a new cycle when maximum_value is passed
        airsql_fixture|order_seq|cycle_count|8|bigint|bigint(21)|NO|\N||\N|\N|\N|How many cycles have been done
        airsql_fixture|orders|id|1|bigint|bigint(20)|NO|\N|auto_increment|\N|\N|\N|
        airsql_fixture|orders|customer_id|2|int|int(10) unsigned|YES|NULL||\N|\N|\N|
        airsql_fixture|orders|region|3|char|char(2)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|orders|number|4|int|int(11)|NO|\N||\N|\N|\N|
        airsql_fixture|orders|total|5|decimal|decimal(12,2)|NO|\N||\N|\N|\N|
        airsql_fixture|orders|parent_id|6|bigint|bigint(20)|YES|NULL||\N|\N|\N|
        airsql_fixture|we`ird 'name' ✓|col `1|1|int|int(11)|YES|NULL||\N|\N|\N|
        airsql_fixture|we`ird 'name' ✓|naïve "x"|2|varchar|varchar(5)|YES|'a''b'||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customer_emails|id|1|int|int(10) unsigned|NO|0||\N|\N|\N|
        airsql_fixture|customer_emails|email|2|varchar|varchar(255)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_lines|region|1|char|char(2)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_lines|number|2|int|int(11)|NO|\N||\N|\N|\N|
        airsql_fixture|order_lines|line|3|smallint|smallint(6)|NO|\N||\N|\N|\N|
        airsql_fixture|order_lines|qty|4|int|int(11)|NO|1||\N|\N|\N|
        airsql_fixture|audit|id|1|int|int(11)|NO|\N||\N|\N|\N|
        airsql_fixture|audit|what|2|varchar|varchar(50)|NO|\N||\N|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|audit|address|3|inet6|inet6|YES|NULL||\N|\N|\N|
        == indexes
        airsql other|refs|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql other|refs|customer_id|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql_fixture|customers|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|customers|email|0|1|email|\N|A|BTREE||YES|\N
        airsql_fixture|customers|name_prefix|1|1|name|10|A|BTREE||YES|\N
        airsql_fixture|customers|created_desc|1|1|created|\N|A|BTREE||YES|\N
        airsql_fixture|customers|note_text|1|1|note|\N|\N|FULLTEXT||YES|\N
        airsql_fixture|orders|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|orders|customer|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|orders_parent|1|1|parent_id|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|3|line|\N|A|BTREE||YES|\N
        airsql_fixture|audit|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        == foreignKeys
        airsql other|refs|refs_ibfk_1|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|orders|orders_customer|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|orders|orders_parent|parent_id|1|airsql_fixture|orders|id
        airsql_fixture|order_lines|lines_order|region|1|airsql_fixture|orders|region
        airsql_fixture|order_lines|lines_order|number|2|airsql_fixture|orders|number
        == foreignKeyRules
        airsql other|refs|refs_ibfk_1|RESTRICT|RESTRICT
        airsql_fixture|orders|orders_customer|CASCADE|SET NULL
        airsql_fixture|orders|orders_parent|RESTRICT|CASCADE
        airsql_fixture|order_lines|lines_order|RESTRICT|RESTRICT
        == checks
        airsql_fixture|customers|prefs|json_valid(`prefs`)|YES
        airsql_fixture|orders|total|`total` >= 0|YES
        airsql_fixture|orders|total_small|`total` < 1000000|YES
        == statistics
        airsql_fixture|log|0|0|1024|0|\N|2026-11-02 18:00:19|2026-11-02 18:00:19|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|customers|0|16384|81920|0|1|2026-11-02 18:00:19|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|order_seq|1|16384|0|0|\N|2026-11-02 18:00:19|\N|utf8mb4_unicode_ci|Fixed|
        airsql_fixture|orders|0|16384|49152|0|1|2026-11-02 18:00:19|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|we`ird 'name' ✓|0|16384|0|0|\N|2026-11-02 18:00:19|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|customer_emails|\N|\N|\N|\N|\N|\N|\N|\N|\N|\N
        airsql_fixture|order_lines|0|16384|0|0|\N|2026-11-02 18:00:19|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|audit|0|16384|0|0|\N|2026-11-02 18:00:19|\N|utf8mb4_unicode_ci|Dynamic|
        """#

    /// mysql:9 (9.7.4)
    static let mysql97 = #"""
        == server
        9.7.4|0|ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
        == databases
        mysql|utf8mb4|utf8mb4_0900_ai_ci
        information_schema|utf8mb3|utf8mb3_general_ci
        performance_schema|utf8mb4|utf8mb4_0900_ai_ci
        sys|utf8mb4|utf8mb4_0900_ai_ci
        airsql_fixture|utf8mb4|utf8mb4_unicode_ci
        airsql other|latin1|latin1_swedish_ci
        == tables
        airsql other|refs|BASE TABLE|InnoDB|
        airsql_fixture|customer_emails|VIEW|\N|VIEW
        airsql_fixture|customers|BASE TABLE|InnoDB|People who buy
        airsql_fixture|log|BASE TABLE|MyISAM|
        airsql_fixture|order_lines|BASE TABLE|InnoDB|
        airsql_fixture|orders|BASE TABLE|InnoDB|
        airsql_fixture|we`ird 'name' ✓|BASE TABLE|InnoDB|
        == routines
        airsql_fixture|order_count|FUNCTION|int|
        airsql_fixture|add_customer|PROCEDURE|\N|Adds one
        == triggers
        airsql_fixture|orders_bi|orders|BEFORE|INSERT|1
        airsql_fixture|orders_au|orders|AFTER|UPDATE|1
        == events
        airsql_fixture|purge_log|DISABLED|Clears the log
        == columns
        airsql other|refs|customer_id|2|int|int unsigned|YES|\N|||\N|\N|
        airsql other|refs|id|1|int|int|NO|\N|||\N|\N|
        airsql_fixture|customer_emails|email|2|varchar|varchar(255)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customer_emails|id|1|int|int unsigned|NO|0|||\N|\N|
        airsql_fixture|customers|balance|7|decimal|decimal(10,2)|NO|0.00|||\N|\N|
        airsql_fixture|customers|bits|8|bit|bit(3)|NO|b'101'|||\N|\N|
        airsql_fixture|customers|created|9|timestamp|timestamp|NO|CURRENT_TIMESTAMP|DEFAULT_GENERATED||\N|\N|
        airsql_fixture|customers|email|2|varchar|varchar(255)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|email_domain|16|varchar|varchar(255)|YES|\N|VIRTUAL GENERATED|substring_index(`email`,_utf8mb4\\'@\\',-(1))|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|flags|6|set|set('a','b')|YES|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|id|1|int|int unsigned|NO|\N|auto_increment||\N|\N|
        airsql_fixture|customers|name|3|varchar|varchar(100)|NO|it's|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|name_upper|17|varchar|varchar(100)|YES|\N|STORED GENERATED|upper(`name`)|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|note|4|text|text|YES|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|path|12|varchar|varchar(20)|YES|C:\\tmp|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|prefs|11|json|json|YES|\N|||\N|\N|
        airsql_fixture|customers|secret|15|int|int|YES|\N|INVISIBLE||\N|\N|
        airsql_fixture|customers|status|5|enum|enum('new','active','gone')|NO|new|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|token|13|char|char(36)|NO|uuid()|DEFAULT_GENERATED||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|updated|10|datetime|datetime(3)|YES|CURRENT_TIMESTAMP(3)|DEFAULT_GENERATED on update CURRENT_TIMESTAMP(3)||\N|\N|
        airsql_fixture|customers|word|14|varchar|varchar(10)|NO|NULL|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|log|at|1|datetime|datetime|NO|\N|||\N|\N|
        airsql_fixture|log|message|2|varchar|varchar(200)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_lines|line|3|smallint|smallint|NO|\N|||\N|\N|
        airsql_fixture|order_lines|number|2|int|int|NO|\N|||\N|\N|
        airsql_fixture|order_lines|qty|4|int|int|NO|1|||\N|\N|
        airsql_fixture|order_lines|region|1|char|char(2)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|orders|customer_id|2|int|int unsigned|YES|\N|||\N|\N|
        airsql_fixture|orders|id|1|bigint|bigint|NO|\N|auto_increment||\N|\N|
        airsql_fixture|orders|number|4|int|int|NO|\N|||\N|\N|
        airsql_fixture|orders|parent_id|6|bigint|bigint|YES|\N|||\N|\N|
        airsql_fixture|orders|region|3|char|char(2)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|orders|total|5|decimal|decimal(12,2)|NO|\N|||\N|\N|
        airsql_fixture|we`ird 'name' ✓|col `1|1|int|int|YES|\N|||\N|\N|
        airsql_fixture|we`ird 'name' ✓|naïve "x"|2|varchar|varchar(5)|YES|a'b|||utf8mb4|utf8mb4_unicode_ci|
        == indexes
        airsql other|refs|customer_id|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql other|refs|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|customers|created_desc|1|1|created|\N|D|BTREE||NO|\N
        airsql_fixture|customers|email|0|1|email|\N|A|BTREE||YES|\N
        airsql_fixture|customers|email_lower|1|1|\N|\N|A|BTREE||YES|lower(`email`)
        airsql_fixture|customers|name_prefix|1|1|name|10|A|BTREE||YES|\N
        airsql_fixture|customers|note_text|1|1|note|\N|\N|FULLTEXT||YES|\N
        airsql_fixture|customers|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|3|line|\N|A|BTREE||YES|\N
        airsql_fixture|orders|customer|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|orders_parent|1|1|parent_id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|2|number|\N|A|BTREE||YES|\N
        == foreignKeys
        airsql other|refs|refs_ibfk_1|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|order_lines|lines_order|region|1|airsql_fixture|orders|region
        airsql_fixture|order_lines|lines_order|number|2|airsql_fixture|orders|number
        airsql_fixture|orders|orders_customer|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|orders|orders_parent|parent_id|1|airsql_fixture|orders|id
        == foreignKeyRules
        airsql_fixture|orders|orders_customer|CASCADE|SET NULL
        airsql_fixture|orders|orders_parent|NO ACTION|CASCADE
        airsql_fixture|order_lines|lines_order|NO ACTION|NO ACTION
        airsql other|refs|refs_ibfk_1|NO ACTION|NO ACTION
        == checks
        airsql_fixture|orders|orders_chk_1|(`total` >= 0)|YES
        airsql_fixture|orders|total_small|(`total` < 1000000)|NO
        == setup
        == statistics
        airsql_fixture|customer_emails|\N|\N|\N|\N|\N|2026-11-02 18:15:04|\N|\N|\N|\N
        airsql_fixture|customers|0|16384|98304|0|1|2026-11-02 18:15:04|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|log|0|0|1024|0|1|2026-11-02 18:15:04|2026-11-02 18:15:04|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|order_lines|0|16384|0|0|\N|2026-11-02 18:15:04|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|orders|0|16384|49152|0|1|2026-11-02 18:15:04|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|we`ird 'name' ✓|0|16384|0|0|\N|2026-11-02 18:15:04|\N|utf8mb4_unicode_ci|Dynamic|
        """#

    /// mysql:8.4 (8.4.13)
    static let mysql84 = #"""
        == server
        8.4.13|0|ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
        == databases
        mysql|utf8mb4|utf8mb4_0900_ai_ci
        information_schema|utf8mb3|utf8mb3_general_ci
        performance_schema|utf8mb4|utf8mb4_0900_ai_ci
        sys|utf8mb4|utf8mb4_0900_ai_ci
        airsql_fixture|utf8mb4|utf8mb4_unicode_ci
        airsql other|latin1|latin1_swedish_ci
        == tables
        airsql other|refs|BASE TABLE|InnoDB|
        airsql_fixture|customer_emails|VIEW|\N|VIEW
        airsql_fixture|customers|BASE TABLE|InnoDB|People who buy
        airsql_fixture|log|BASE TABLE|MyISAM|
        airsql_fixture|order_lines|BASE TABLE|InnoDB|
        airsql_fixture|orders|BASE TABLE|InnoDB|
        airsql_fixture|we`ird 'name' ✓|BASE TABLE|InnoDB|
        == routines
        airsql_fixture|add_customer|PROCEDURE|\N|Adds one
        airsql_fixture|order_count|FUNCTION|int|
        == triggers
        airsql_fixture|orders_bi|orders|BEFORE|INSERT|1
        airsql_fixture|orders_au|orders|AFTER|UPDATE|1
        == events
        airsql_fixture|purge_log|DISABLED|Clears the log
        == columns
        airsql_fixture|customers|balance|7|decimal|decimal(10,2)|NO|0.00|||\N|\N|
        airsql_fixture|customers|bits|8|bit|bit(3)|NO|b'101'|||\N|\N|
        airsql_fixture|customers|created|9|timestamp|timestamp|NO|CURRENT_TIMESTAMP|DEFAULT_GENERATED||\N|\N|
        airsql_fixture|customers|email|2|varchar|varchar(255)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|email_domain|16|varchar|varchar(255)|YES|\N|VIRTUAL GENERATED|substring_index(`email`,_utf8mb4\\'@\\',-(1))|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|flags|6|set|set('a','b')|YES|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|id|1|int|int unsigned|NO|\N|auto_increment||\N|\N|
        airsql_fixture|customers|name|3|varchar|varchar(100)|NO|it's|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|name_upper|17|varchar|varchar(100)|YES|\N|STORED GENERATED|upper(`name`)|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|note|4|text|text|YES|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|path|12|varchar|varchar(20)|YES|C:\\tmp|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|prefs|11|json|json|YES|\N|||\N|\N|
        airsql_fixture|customers|secret|15|int|int|YES|\N|INVISIBLE||\N|\N|
        airsql_fixture|customers|status|5|enum|enum('new','active','gone')|NO|new|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|token|13|char|char(36)|NO|uuid()|DEFAULT_GENERATED||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|updated|10|datetime|datetime(3)|YES|CURRENT_TIMESTAMP(3)|DEFAULT_GENERATED on update CURRENT_TIMESTAMP(3)||\N|\N|
        airsql_fixture|customers|word|14|varchar|varchar(10)|NO|NULL|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|orders|customer_id|2|int|int unsigned|YES|\N|||\N|\N|
        airsql_fixture|orders|id|1|bigint|bigint|NO|\N|auto_increment||\N|\N|
        airsql_fixture|orders|number|4|int|int|NO|\N|||\N|\N|
        airsql_fixture|orders|parent_id|6|bigint|bigint|YES|\N|||\N|\N|
        airsql_fixture|orders|region|3|char|char(2)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|orders|total|5|decimal|decimal(12,2)|NO|\N|||\N|\N|
        airsql_fixture|order_lines|line|3|smallint|smallint|NO|\N|||\N|\N|
        airsql_fixture|order_lines|number|2|int|int|NO|\N|||\N|\N|
        airsql_fixture|order_lines|qty|4|int|int|NO|1|||\N|\N|
        airsql_fixture|order_lines|region|1|char|char(2)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|log|at|1|datetime|datetime|NO|\N|||\N|\N|
        airsql_fixture|log|message|2|varchar|varchar(200)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|we`ird 'name' ✓|col `1|1|int|int|YES|\N|||\N|\N|
        airsql_fixture|we`ird 'name' ✓|naïve "x"|2|varchar|varchar(5)|YES|a'b|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customer_emails|email|2|varchar|varchar(255)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customer_emails|id|1|int|int unsigned|NO|0|||\N|\N|
        airsql other|refs|customer_id|2|int|int unsigned|YES|\N|||\N|\N|
        airsql other|refs|id|1|int|int|NO|\N|||\N|\N|
        == indexes
        airsql_fixture|customers|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|customers|email|0|1|email|\N|A|BTREE||YES|\N
        airsql_fixture|customers|name_prefix|1|1|name|10|A|BTREE||YES|\N
        airsql_fixture|customers|created_desc|1|1|created|\N|D|BTREE||NO|\N
        airsql_fixture|customers|email_lower|1|1|\N|\N|A|BTREE||YES|lower(`email`)
        airsql_fixture|customers|note_text|1|1|note|\N|\N|FULLTEXT||YES|\N
        airsql_fixture|orders|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|orders|customer|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|orders_parent|1|1|parent_id|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|3|line|\N|A|BTREE||YES|\N
        airsql other|refs|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql other|refs|customer_id|1|1|customer_id|\N|A|BTREE||YES|\N
        == foreignKeys
        airsql other|refs|refs_ibfk_1|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|order_lines|lines_order|region|1|airsql_fixture|orders|region
        airsql_fixture|order_lines|lines_order|number|2|airsql_fixture|orders|number
        airsql_fixture|orders|orders_customer|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|orders|orders_parent|parent_id|1|airsql_fixture|orders|id
        == foreignKeyRules
        airsql_fixture|orders|orders_customer|CASCADE|SET NULL
        airsql_fixture|orders|orders_parent|NO ACTION|CASCADE
        airsql_fixture|order_lines|lines_order|NO ACTION|NO ACTION
        airsql other|refs|refs_ibfk_1|NO ACTION|NO ACTION
        == checks
        airsql_fixture|orders|orders_chk_1|(`total` >= 0)|YES
        airsql_fixture|orders|total_small|(`total` < 1000000)|NO
        == setup
        == statistics
        airsql_fixture|customer_emails|\N|\N|\N|\N|\N|2026-11-02 17:53:22|\N|\N|\N|\N
        airsql_fixture|customers|0|16384|98304|0|1|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|log|0|0|1024|0|1|2026-11-02 17:53:22|2026-11-02 17:53:22|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|order_lines|0|16384|0|0|\N|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|orders|0|16384|49152|0|1|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|we`ird 'name' ✓|0|16384|0|0|\N|2026-11-02 17:53:22|\N|utf8mb4_unicode_ci|Dynamic|
        """#

    /// mysql:5.7 (5.7.44, linux/amd64)
    static let mysql57 = #"""
        == server
        5.7.44|0|ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
        == databases
        information_schema|utf8|utf8_general_ci
        airsql other|latin1|latin1_swedish_ci
        airsql_fixture|utf8mb4|utf8mb4_unicode_ci
        mysql|utf8mb4|utf8mb4_general_ci
        performance_schema|utf8|utf8_general_ci
        sys|utf8|utf8_general_ci
        == tables
        airsql other|refs|BASE TABLE|InnoDB|
        airsql_fixture|customer_emails|VIEW|\N|VIEW
        airsql_fixture|customers|BASE TABLE|InnoDB|People who buy
        airsql_fixture|log|BASE TABLE|MyISAM|
        airsql_fixture|order_lines|BASE TABLE|InnoDB|
        airsql_fixture|orders|BASE TABLE|InnoDB|
        airsql_fixture|we`ird 'name' ✓|BASE TABLE|InnoDB|
        == routines
        airsql_fixture|add_customer|PROCEDURE|\N|Adds one
        airsql_fixture|order_count|FUNCTION|int(11)|
        == triggers
        airsql_fixture|orders_bi|orders|BEFORE|INSERT|1
        airsql_fixture|orders_au|orders|AFTER|UPDATE|1
        == events
        airsql_fixture|purge_log|DISABLED|Clears the log
        == columns
        airsql other|refs|id|1|int|int(11)|NO|\N|||\N|\N|
        airsql other|refs|customer_id|2|int|int(10) unsigned|YES|\N|||\N|\N|
        airsql_fixture|customer_emails|id|1|int|int(10) unsigned|NO|0|||\N|\N|
        airsql_fixture|customer_emails|email|2|varchar|varchar(255)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|id|1|int|int(10) unsigned|NO|\N|auto_increment||\N|\N|
        airsql_fixture|customers|email|2|varchar|varchar(255)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|name|3|varchar|varchar(100)|NO|it's|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|note|4|text|text|YES|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|status|5|enum|enum('new','active','gone')|NO|new|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|flags|6|set|set('a','b')|YES|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|balance|7|decimal|decimal(10,2)|NO|0.00|||\N|\N|
        airsql_fixture|customers|bits|8|bit|bit(3)|NO|b'101'|||\N|\N|
        airsql_fixture|customers|created|9|timestamp|timestamp|NO|CURRENT_TIMESTAMP|||\N|\N|
        airsql_fixture|customers|updated|10|datetime|datetime(3)|YES|CURRENT_TIMESTAMP(3)|on update CURRENT_TIMESTAMP(3)||\N|\N|
        airsql_fixture|customers|prefs|11|json|json|YES|\N|||\N|\N|
        airsql_fixture|customers|path|12|varchar|varchar(20)|YES|C:\\tmp|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|word|13|varchar|varchar(10)|NO|NULL|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|email_domain|14|varchar|varchar(255)|YES|\N|VIRTUAL GENERATED|substring_index(`email`,'@',-(1))|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|customers|name_upper|15|varchar|varchar(100)|YES|\N|STORED GENERATED|upper(`name`)|utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|log|at|1|datetime|datetime|NO|\N|||\N|\N|
        airsql_fixture|log|message|2|varchar|varchar(200)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_lines|region|1|char|char(2)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|order_lines|number|2|int|int(11)|NO|\N|||\N|\N|
        airsql_fixture|order_lines|line|3|smallint|smallint(6)|NO|\N|||\N|\N|
        airsql_fixture|order_lines|qty|4|int|int(11)|NO|1|||\N|\N|
        airsql_fixture|orders|id|1|bigint|bigint(20)|NO|\N|auto_increment||\N|\N|
        airsql_fixture|orders|customer_id|2|int|int(10) unsigned|YES|\N|||\N|\N|
        airsql_fixture|orders|region|3|char|char(2)|NO|\N|||utf8mb4|utf8mb4_unicode_ci|
        airsql_fixture|orders|number|4|int|int(11)|NO|\N|||\N|\N|
        airsql_fixture|orders|total|5|decimal|decimal(12,2)|NO|\N|||\N|\N|
        airsql_fixture|orders|parent_id|6|bigint|bigint(20)|YES|\N|||\N|\N|
        airsql_fixture|we`ird 'name' ✓|col `1|1|int|int(11)|YES|\N|||\N|\N|
        airsql_fixture|we`ird 'name' ✓|naïve "x"|2|varchar|varchar(5)|YES|a'b|||utf8mb4|utf8mb4_unicode_ci|
        == indexes
        airsql other|refs|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql other|refs|customer_id|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql_fixture|customers|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|customers|email|0|1|email|\N|A|BTREE||YES|\N
        airsql_fixture|customers|name_prefix|1|1|name|10|A|BTREE||YES|\N
        airsql_fixture|customers|created_desc|1|1|created|\N|A|BTREE||YES|\N
        airsql_fixture|customers|note_text|1|1|note|\N|\N|FULLTEXT||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|order_lines|PRIMARY|0|3|line|\N|A|BTREE||YES|\N
        airsql_fixture|orders|PRIMARY|0|1|id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|1|region|\N|A|BTREE||YES|\N
        airsql_fixture|orders|region_number|0|2|number|\N|A|BTREE||YES|\N
        airsql_fixture|orders|customer|1|1|customer_id|\N|A|BTREE||YES|\N
        airsql_fixture|orders|orders_parent|1|1|parent_id|\N|A|BTREE||YES|\N
        == foreignKeys
        airsql other|refs|refs_ibfk_1|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|order_lines|lines_order|region|1|airsql_fixture|orders|region
        airsql_fixture|order_lines|lines_order|number|2|airsql_fixture|orders|number
        airsql_fixture|orders|orders_customer|customer_id|1|airsql_fixture|customers|id
        airsql_fixture|orders|orders_parent|parent_id|1|airsql_fixture|orders|id
        == foreignKeyRules
        airsql other|refs|refs_ibfk_1|RESTRICT|RESTRICT
        airsql_fixture|order_lines|lines_order|RESTRICT|RESTRICT
        airsql_fixture|orders|orders_customer|CASCADE|SET NULL
        airsql_fixture|orders|orders_parent|RESTRICT|CASCADE
        == statistics
        airsql_fixture|customer_emails|\N|\N|\N|\N|\N|\N|\N|\N|\N|\N
        airsql_fixture|customers|0|16384|81920|0|1|2026-11-02 17:59:51|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|log|0|0|1024|0|\N|2026-11-02 17:59:51|2026-11-02 17:59:51|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|order_lines|0|16384|0|0|\N|2026-11-02 17:59:51|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|orders|0|16384|49152|0|1|2026-11-02 17:59:51|\N|utf8mb4_unicode_ci|Dynamic|
        airsql_fixture|we`ird 'name' ✓|0|16384|0|0|\N|2026-11-02 17:59:51|\N|utf8mb4_unicode_ci|Dynamic|
        """#

    /// The fixture schema as created on MariaDB (10.5 leaves out what its version comments mark).
    static let mariadbDDL = #"""
        CREATE DATABASE airsql_fixture CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE DATABASE `airsql other` CHARACTER SET latin1;
        USE airsql_fixture;

        CREATE TABLE customers (
          id INT UNSIGNED NOT NULL AUTO_INCREMENT,
          email VARCHAR(255) NOT NULL,
          name VARCHAR(100) NOT NULL DEFAULT 'it''s',
          note TEXT NULL,
          status ENUM('new','active','gone') NOT NULL DEFAULT 'new',
          flags SET('a','b') NULL DEFAULT NULL,
          balance DECIMAL(10,2) NOT NULL DEFAULT 0.00,
          bits BIT(3) NOT NULL DEFAULT b'101',
          created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated DATETIME(3) NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
          prefs JSON NULL,
          path VARCHAR(20) NULL DEFAULT 'C:\\tmp',
          token CHAR(36) NOT NULL DEFAULT (uuid()),
          word VARCHAR(10) NOT NULL DEFAULT 'NULL',
          secret INT NULL INVISIBLE,
          email_domain VARCHAR(255) AS (SUBSTRING_INDEX(email, '@', -1)) VIRTUAL,
          name_upper VARCHAR(100) AS (UPPER(name)) STORED,
          PRIMARY KEY (id),
          UNIQUE KEY email (email),
          KEY name_prefix (name(10)),
          KEY created_desc (created /*M!100800 DESC */) /*M!100600 IGNORED */,
          FULLTEXT KEY note_text (note)
        ) ENGINE=InnoDB COMMENT='People who buy';

        CREATE TABLE orders (
          id BIGINT NOT NULL AUTO_INCREMENT,
          customer_id INT UNSIGNED NULL,
          region CHAR(2) NOT NULL,
          number INT NOT NULL,
          total DECIMAL(12,2) NOT NULL CHECK (total >= 0),
          parent_id BIGINT NULL,
          PRIMARY KEY (id),
          UNIQUE KEY region_number (region, number),
          KEY customer (customer_id),
          CONSTRAINT orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id) ON DELETE SET NULL ON UPDATE CASCADE,
          CONSTRAINT orders_parent FOREIGN KEY (parent_id) REFERENCES orders (id) ON DELETE CASCADE,
          CONSTRAINT total_small CHECK (total < 1000000)
        ) ENGINE=InnoDB;

        CREATE TABLE order_lines (
          region CHAR(2) NOT NULL,
          number INT NOT NULL,
          line SMALLINT NOT NULL,
          qty INT NOT NULL DEFAULT 1,
          PRIMARY KEY (region, number, line),
          CONSTRAINT lines_order FOREIGN KEY (region, number) REFERENCES orders (region, number)
        ) ENGINE=InnoDB;

        CREATE TABLE log (
          at DATETIME NOT NULL,
          message VARCHAR(200) NOT NULL
        ) ENGINE=MyISAM;

        CREATE TABLE `we``ird 'name' ✓` (
          `col ``1` INT NULL,
          `naïve "x"` VARCHAR(5) NULL DEFAULT 'a\'b'
        );

        CREATE TABLE audit (
          id INT NOT NULL PRIMARY KEY,
          what VARCHAR(50) NOT NULL,
          address INET6 NULL
        ) WITH SYSTEM VERSIONING;

        CREATE SEQUENCE order_seq START WITH 100;

        CREATE VIEW customer_emails AS SELECT id, email FROM customers;

        DELIMITER //
        CREATE PROCEDURE add_customer(IN p_email VARCHAR(255)) COMMENT 'Adds one'
        BEGIN
          INSERT INTO customers (email) VALUES (p_email);
        END//
        CREATE FUNCTION order_count(c INT) RETURNS INT DETERMINISTIC READS SQL DATA
          RETURN (SELECT COUNT(*) FROM orders WHERE customer_id = c)//
        DELIMITER ;

        CREATE TRIGGER orders_bi BEFORE INSERT ON orders FOR EACH ROW SET NEW.total = ABS(NEW.total);
        CREATE TRIGGER orders_au AFTER UPDATE ON orders FOR EACH ROW INSERT INTO log VALUES (NOW(), 'order changed');
        CREATE EVENT purge_log ON SCHEDULE EVERY 1 DAY DISABLE COMMENT 'Clears the log' DO DELETE FROM log;

        USE `airsql other`;
        CREATE TABLE refs (
          id INT NOT NULL PRIMARY KEY,
          customer_id INT UNSIGNED NULL,
          FOREIGN KEY (customer_id) REFERENCES airsql_fixture.customers (id)
        ) ENGINE=InnoDB;
        """#

    /// The fixture schema as created on MySQL (5.7 leaves out what its version comments mark).
    static let mysqlDDL = #"""
        CREATE DATABASE airsql_fixture CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE DATABASE `airsql other` CHARACTER SET latin1;
        USE airsql_fixture;

        CREATE TABLE customers (
          id INT UNSIGNED NOT NULL AUTO_INCREMENT,
          email VARCHAR(255) NOT NULL,
          name VARCHAR(100) NOT NULL DEFAULT 'it''s',
          note TEXT NULL,
          status ENUM('new','active','gone') NOT NULL DEFAULT 'new',
          flags SET('a','b') NULL DEFAULT NULL,
          balance DECIMAL(10,2) NOT NULL DEFAULT 0.00,
          bits BIT(3) NOT NULL DEFAULT b'101',
          created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated DATETIME(3) NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
          prefs JSON NULL,
          path VARCHAR(20) NULL DEFAULT 'C:\\tmp',
          /*!80013 token CHAR(36) NOT NULL DEFAULT (uuid()), */
          word VARCHAR(10) NOT NULL DEFAULT 'NULL',
          /*!80023 secret INT NULL INVISIBLE, */
          email_domain VARCHAR(255) AS (SUBSTRING_INDEX(email, '@', -1)) VIRTUAL,
          name_upper VARCHAR(100) AS (UPPER(name)) STORED,
          PRIMARY KEY (id),
          UNIQUE KEY email (email),
          KEY name_prefix (name(10)),
          KEY created_desc (created /*!80000 DESC */) /*!80000 INVISIBLE */,
          /*!80013 KEY email_lower ((LOWER(email))), */
          FULLTEXT KEY note_text (note)
        ) ENGINE=InnoDB COMMENT='People who buy';

        CREATE TABLE orders (
          id BIGINT NOT NULL AUTO_INCREMENT,
          customer_id INT UNSIGNED NULL,
          region CHAR(2) NOT NULL,
          number INT NOT NULL,
          total DECIMAL(12,2) NOT NULL /*!80016 CHECK (total >= 0) */,
          parent_id BIGINT NULL,
          PRIMARY KEY (id),
          UNIQUE KEY region_number (region, number),
          KEY customer (customer_id),
          CONSTRAINT orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id) ON DELETE SET NULL ON UPDATE CASCADE,
          CONSTRAINT orders_parent FOREIGN KEY (parent_id) REFERENCES orders (id) ON DELETE CASCADE
          /*!80016 , CONSTRAINT total_small CHECK (total < 1000000) NOT ENFORCED */
        ) ENGINE=InnoDB;

        CREATE TABLE order_lines (
          region CHAR(2) NOT NULL,
          number INT NOT NULL,
          line SMALLINT NOT NULL,
          qty INT NOT NULL DEFAULT 1,
          PRIMARY KEY (region, number, line),
          CONSTRAINT lines_order FOREIGN KEY (region, number) REFERENCES orders (region, number)
        ) ENGINE=InnoDB;

        CREATE TABLE log (
          at DATETIME NOT NULL,
          message VARCHAR(200) NOT NULL
        ) ENGINE=MyISAM;

        CREATE TABLE `we``ird 'name' ✓` (
          `col ``1` INT NULL,
          `naïve "x"` VARCHAR(5) NULL DEFAULT 'a\'b'
        );

        CREATE VIEW customer_emails AS SELECT id, email FROM customers;

        DELIMITER //
        CREATE PROCEDURE add_customer(IN p_email VARCHAR(255)) COMMENT 'Adds one'
        BEGIN
          INSERT INTO customers (email) VALUES (p_email);
        END//
        CREATE FUNCTION order_count(c INT) RETURNS INT DETERMINISTIC READS SQL DATA
          RETURN (SELECT COUNT(*) FROM orders WHERE customer_id = c)//
        DELIMITER ;

        CREATE TRIGGER orders_bi BEFORE INSERT ON orders FOR EACH ROW SET NEW.total = ABS(NEW.total);
        CREATE TRIGGER orders_au AFTER UPDATE ON orders FOR EACH ROW INSERT INTO log VALUES (NOW(), 'order changed');
        CREATE EVENT purge_log ON SCHEDULE EVERY 1 DAY DISABLE COMMENT 'Clears the log' DO DELETE FROM log;

        USE `airsql other`;
        CREATE TABLE refs (
          id INT NOT NULL PRIMARY KEY,
          customer_id INT UNSIGNED NULL,
          FOREIGN KEY (customer_id) REFERENCES airsql_fixture.customers (id)
        ) ENGINE=InnoDB;
        """#
}
