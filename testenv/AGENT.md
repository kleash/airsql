# AirSQL's Docker test lab

Every MySQL and MariaDB version AirSQL supports, seeded with one fixture, plus the routes AirSQL connects through: an
SSH bastion and a second jump host, HTTP proxies (Basic and Digest), a SOCKS5 proxy, ProxySQL, a path with added
latency and a private certificate authority. It is the Compose project `airsql-lab` (containers `airsql-lab-*`). Every
published port listens on 127.0.0.1 only, in 44300-44399. It needs Docker Desktop, and internet access for the first
start, which pulls and builds the images.

```sh
testenv/up.sh                          # the whole lab; the first start seeds every server (several minutes)
testenv/up.sh mysql84 bastion secure   # only these services, and what they depend on
AIRSQL_LAB=1 ./test.sh                 # every test, the lab's included (testenv/up.sh first, unless all of it runs)
testenv/down.sh                        # removes the lab: containers, networks, data (--images: the images it built)
```

`up.sh` is safe to run again: it builds what changed, starts what isn't running and waits until every server is
healthy and every published port answers. It seeds three servers at a time: the whole lab takes about 1.5 GB of
Docker's memory once running, and more while seeding. On a busy Docker, start only what a test needs. If Docker runs
out of memory anyway, the kernel stops a lab server first, never another project's container (`oom_score_adj`).

One lab serves every checkout of the repository, and only the main checkout (git's first worktree, the parent of
`git rev-parse --git-common-dir`) starts it: in another worktree `up.sh` refuses, as it would make a new key and CA
there and point the lab's containers at that worktree's files, which go when the worktree does. `AIRSQL_LAB=1
./test.sh` uses the lab as it is while every service of it runs, and runs `up.sh` only when one isn't running (in a
worktree it then stops and says what to run in the main checkout). The tests in any worktree use the main checkout's
key and certificates (`Lab.testenv`).

## Servers

On every server: `root` / `airsql-root` (the lab's own setup only), `airsql` / `airsql-pass` (every privilege: what
tests use unless they test a login method) and `reader` / `reader-pass` (SELECT and SHOW VIEW on `fixture`). The other
logins are one per login method, each with the password `<user>-pass` and SELECT on `fixture`.

| Service | From the Mac | Server | Logins | Notes |
|---|---|---|---|---|
| mysql57 | 127.0.0.1:44357 | MySQL 5.7.44 | native, sha256 | x86-64 only: emulated on Apple silicon |
| mysql80 | 127.0.0.1:44380 | MySQL 8.0.46 | native, sha2, sha256 | |
| mysql84 | 127.0.0.1:44384 | MySQL 8.4.13 | native, sha2, sha256 | the only one with performance_schema on |
| mysql97 | 127.0.0.1:44397 | MySQL 9.7.4 | sha2, sha256 | no mysql_native_password since 9.0 |
| mariadb105 | 127.0.0.1:44305 | MariaDB 10.5.29 | native, ed25519 | |
| mariadb106 | 127.0.0.1:44306 | MariaDB 10.6.28 | native, ed25519 | |
| mariadb1011 | 127.0.0.1:44311 | MariaDB 10.11.19 | native, ed25519 | |
| mariadb114 | 127.0.0.1:44314 | MariaDB 11.4.13 | native, ed25519 | |
| mariadb118 | 127.0.0.1:44318 | MariaDB 11.8.9 | native, ed25519 | |
| many | 127.0.0.1:44350 | MariaDB 11.4.13 | native, ed25519 | also `many_tables`: 5,000 tables |
| proxysql | 127.0.0.1:44333 | ProxySQL 3.0 | airsql only | in front of mariadb114 |
| slow | 127.0.0.1:44340 | mysql84 | as mysql84 | every packet the relay sends waits 50 ms (tc netem) |
| secure | secure:3306, inside | MariaDB 11.4.13 | native, ed25519, pam, x509 | TLS certificate for the name `secure` |
| wrongname | wrongname:3306, inside | MySQL 8.4.13 | native, sha2, sha256, x509 | TLS certificate for `elsewhere.invalid` |
| deep | deep:3306, behind jump | MariaDB 11.4.13 | native, ed25519 | |

Logins: `native` mysql_native_password, `sha2` caching_sha2_password, `sha256` sha256_password, `ed25519` MariaDB's
ed25519, `pam` MariaDB's PAM plugin (it asks through the client's dialog plugin; testenv/pam checks the password),
`x509` REQUIRE X509 (the password and the client certificate below).

## Routes

Each database answers only through its own route: the servers above with a port on 127.0.0.1 directly (nothing inside
the lab reaches them but proxysql and slow); the others only from internal networks with no way in or out.

| Hop | From the Mac | Login | Reaches |
|---|---|---|---|
| bastion | 127.0.0.1:44322 (SSH) | `bastion` / `airsql-bastion`, or the key | secure:3306, wrongname:3306, jump:22 |
| jump | jump:22, through the bastion | `jump` / `airsql-jump`, or the key | deep:3306 |
| proxy | 127.0.0.1:44328 (HTTP CONNECT, Basic) | `airsql` / `airsql-proxy` | bastion:22, jump:22, secure:3306, wrongname:3306 |
| digestproxy | 127.0.0.1:44329 (HTTP CONNECT, Digest only) | `airsql` / `airsql-proxy` | the same |
| socksproxy | 127.0.0.1:44310 (SOCKS5) | `airsql` / `airsql-proxy` | the same |

So: an SSH tunnel is the bastion to secure or wrongname; a jump chain is the bastion, then jump, to deep; SSH through a
proxy is a proxy to bastion:22; a proxy-only route is a proxy to secure:3306 or wrongname:3306. Both SSH hosts forward
TCP and take the lab key, `testenv/.keys/id_lab` (made by up.sh, gitignored), as well as their passwords.

## TLS

`up.sh` makes a certificate authority in `testenv/.certs` (gitignored): `ca.pem`; `secure.pem`, for the name `secure`
only; `wrongname.pem`, for `elsewhere.invalid`; and `client.pem` with `client-key.pem` for the x509 login. Server
certificates last 800 days (macOS takes at most 825) and are made again a week before they expire.

- A check of secure's certificate passes only against the name the connection was made with, `secure`: against
  127.0.0.1, localhost or a tunnel's socket it must fail. Connector/C 3.4 skips verification for local connections by
  default, and a tunnel's end is local: the check has to be AirSQL's own.
- wrongname's certificate comes from the lab CA, so the chain is good, but its name is wrong: verification must fail.
- mysql57, the MySQL 8 and 9 servers and MariaDB 11.4 and later present self-signed certificates of their own (the
  Trust sheet's case); MariaDB 10.5 to 10.11 have no TLS.

## The fixture (testenv/seed)

The same `fixture` database on every server: `all_types` (every column type: JSON, BIT(1) to BIT(64), ENUM, SET,
spatial, BINARY(16), DECIMAL(65,30), TIMESTAMP(3), ZEROFILL; rows of everyday values, extremes and NULLs), `places`
(a spatial index), a shop (`customers`, `products`, `orders`, `order_items`, `employees`: foreign keys with CASCADE,
RESTRICT and SET NULL, a composite key, virtual and stored generated columns, a CHECK, triggers), `no_pk_log` (no
primary key, duplicate rows), `unique_no_pk`, `myisam_notes` (MyISAM), `latin1_legacy`, `texts` (emoji, Arabic,
Hebrew, mixed direction, combining marks, control characters, quotes, a right-to-left column name), `legacy_dates`
(zero dates), names at the 64-character limit and names that need quoting, three views, two functions, three
procedures (one with two result sets), two events and `big`, a million rows. Also the database
`this_database_name_is_sixty_four_characters_long_the_most_it_has`, and on `many`, `many_tables` (t0001 to t5000).

A server runs seed/ once, when its data folder is new. After changing seed/, run `testenv/down.sh` and then
`testenv/up.sh` (or for one server: `docker compose -f testenv/docker-compose.yml rm -sfv mysql84`, then
`testenv/up.sh mysql84`).

## Rules for tests and agents

- Swift tests reach the lab through `Tests/AirSQLTests/Support/Lab.swift` (`Lab.mysql84`, `Lab.secure`, `Lab.airsql`,
  `Lab.forward(to:throughJump:)`, `Lab.sshConfig`, `Lab.caFile`, …) and run only with `AIRSQL_LAB=1`.
- Read the shared databases; write only in databases of your own, named `lane_<x>_*`, and drop them afterwards. Never
  change the lab's accounts, server settings or containers from a test.
- Keep ssh away from `~/.ssh`: use `Lab.sshConfig` (or `-F` with a config of your own) with the lab key, a throwaway
  known_hosts and `IdentityAgent none`.
- A throwaway AirSQL app (its own `AIRSQL_SUPPORT_DIR`) on an SSH route needs `AIRSQL_SSH_DIR` too: its tunnels then
  include `$AIRSQL_SSH_DIR/config` instead of `~/.ssh/config`. Make it first: `mkdir -p $T/ssh && chmod 700 $T/ssh &&
  printf 'UserKnownHostsFile %s/ssh/known_hosts\nIdentityAgent none\nIdentityFile none\n' "$T" > $T/ssh/config`, then
  `open -n build/AirSQL.app --env AIRSQL_SUPPORT_DIR=$T/support --env AIRSQL_SSH_DIR=$T/ssh`. Without it, trusting the
  bastion's host key writes the user's `~/.ssh/known_hosts`.
- The passwords here are throwaway values for a lab that listens only on 127.0.0.1 and internal networks: never use them
  anywhere else, and never put real credentials into the lab.
- `down.sh` removes only `airsql-lab`. Leave other projects' containers alone (`porter-lab-*`, `mysqlmacclient-test-*`
  and other agents' own).
- CI has no Docker: route tests there use `Tests/AirSQLTests/Support/` instead (`TestServer`, a throwaway sshd;
  `TestProxy` and `TestSOCKS`, proxies with Basic, Digest and SOCKS5 logins) with servers that CI installs itself.
