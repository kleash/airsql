-- AirSQL lab logins: one account per login method the server offers, each with a throwaway password (testenv/AGENT.md
-- lists them; the lab listens only on 127.0.0.1 and internal networks). SQL rather than a shell script, so that every
-- server's entrypoint runs it the same way.

-- airsql: everything, the lab tests' default; reader: only reads the fixture.
CREATE USER airsql@'%' IDENTIFIED BY 'airsql-pass';
GRANT ALL PRIVILEGES ON *.* TO airsql@'%' WITH GRANT OPTION;
CREATE USER reader@'%' IDENTIFIED BY 'reader-pass';
GRANT SELECT, SHOW VIEW ON fixture.* TO reader@'%';

-- The others where the server has their plugin, or for x509 where it trusts the lab CA (the hosts secure and wrongname,
-- docker-compose.yml: MariaDB's entrypoint seeds with TLS off); each may read the fixture. The password is the user
-- name and "-pass".
DELIMITER ;;
CREATE PROCEDURE fixture.lab_login(p_user VARCHAR(16), p_plugin VARCHAR(64))
BEGIN
    SET @lab_statement = NULL;
    IF p_plugin = 'x509' THEN
        IF @@hostname IN ('secure', 'wrongname') THEN
            SET @lab_statement = CONCAT('CREATE USER ', p_user, '@''%'' IDENTIFIED BY ''', p_user, '-pass'' REQUIRE X509');
        END IF;
    ELSEIF (SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_NAME = p_plugin AND PLUGIN_STATUS = 'ACTIVE') = 1 THEN
        SET @lab_statement = CASE
            WHEN p_plugin = 'pam' THEN CONCAT('CREATE USER ', p_user, '@''%'' IDENTIFIED VIA pam USING ''airsql''')
            WHEN VERSION() LIKE '%MariaDB%' THEN
                CONCAT('CREATE USER ', p_user, '@''%'' IDENTIFIED VIA ', p_plugin, ' USING PASSWORD(''', p_user, '-pass'')')
            ELSE CONCAT('CREATE USER ', p_user, '@''%'' IDENTIFIED WITH ', p_plugin, ' BY ''', p_user, '-pass''')
        END;
    END IF;
    IF @lab_statement IS NOT NULL THEN
        PREPARE lab_statement FROM @lab_statement;
        EXECUTE lab_statement;
        SET @lab_statement = CONCAT('GRANT SELECT ON fixture.* TO ', p_user, '@''%''');
        PREPARE lab_statement FROM @lab_statement;
        EXECUTE lab_statement;
        DEALLOCATE PREPARE lab_statement;
    END IF;
END;;
DELIMITER ;
CALL fixture.lab_login('native', 'mysql_native_password');
CALL fixture.lab_login('sha2', 'caching_sha2_password');
CALL fixture.lab_login('sha256', 'sha256_password');
CALL fixture.lab_login('ed25519', 'ed25519');
-- MariaDB's PAM plugin (only "secure" loads it); testenv/pam/check takes the password pam-pass.
CALL fixture.lab_login('pam', 'pam');
-- With the client certificate testenv/.certs/client.pem (and client-key.pem).
CALL fixture.lab_login('x509', 'x509');
DROP PROCEDURE fixture.lab_login;
