---
title: Users and roles
nav_order: 19
---

# Users and roles

**Users and Roles** lists a server's logins and roles and changes them. Open it from **Database ▸ Users and Roles**, from
a connection's right-click menu, or with a click on the **Users and Roles** row at the end of its tree.

The list shows each account's name, host, kind, login method, whether it has a password (never what it is), whether it's
locked or expired, its limits and what it must show of TLS. Under the list is what the selected account holds, in the
server's own words, with any password hash masked. Filter, sorting, **Copy List** and **Export List…** work as on the
[host page](navigator.md).

Reading the list needs SELECT on the `mysql` database; AirSQL says so when your login doesn't have it.

## Add or change an account

**New User…**, **New Role…**, **Edit…** (or a double-click) and **Clone User…** open the same sheet. **Next…** shows the SQL,
and nothing runs until you press **Run**. Each statement takes effect at once, and the first that fails stops the rest:
press Refresh to see where it got to.

- **Login**: the name, the host (`%` is anywhere), the login method and the password. Leave the password empty to keep
  it. **Generate** fills both fields with a random password. **Copy** then copies it, marked so clipboard managers skip it;
  it can't be shown. To change the login method, type a new password too.
- **Locked** keeps the account but refuses its logins. **Password expired** makes it choose a new one at its next login.
- **Limits**: statements, changes and logins an hour, connections at once (0 is no limit), and what it must show of TLS.
- **Privileges**: the whole server, then each database, table, column and routine it has something on. Each privilege
  has a tick, marked **reads**, **writes** or **administers**; the list is the server's own. **Add Level…** adds one more;
  `%` and `_` in a database's name match several, `\_` is a real underscore.
- **Roles**: the roles it takes on, whether it can pass each one on, and which are on at login. MariaDB has one default
  role, MySQL several. Roles need MySQL 8 or any MariaDB.

**Clone User…** starts a new login with the selected one's settings, privileges and roles. The password isn't copied.

**Drop User…** asks you to type the name first, and warns when it's the login AirSQL is using.

## Who may do what on one object

Right-click a database, table or routine in the tree and choose **Modify Grants…**. Choose the login or role, and its sheet
opens at that object's ticks.

## An expired password

When the server says your own password has expired, connecting asks for a new one, changes it and goes on. The new
password goes to the server only: a password saved in your Keychain stays as it was, so update it in the connection's
settings. A password you just typed with Remember in Keychain is replaced by the new one. Read-only and Production connections don't offer this: they say the password has expired, and connecting stops.

## What protects these

- Read-only and Production connections refuse every change here, and agents can't make one. The buttons and menu items
  say why.
- A password you type is sent to the server and kept nowhere else: not in the [SQL log](sql-log.md), history or AirSQL's
  settings. The [SQL preview](sql-preview.md) and Copy SQL show `<secret>`, so a copied statement needs its password put
  back, and the sheet doesn't offer a Liquibase changeset.
- When a server's error would quote the statement, AirSQL leaves its words out.
