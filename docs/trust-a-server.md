---
title: Trust a server
nav_order: 6
---

# Trust a server

When a server's certificate isn't one macOS trusts (it is self-signed, or from your company's own certificate
authority), AirSQL shows its SHA-256 fingerprint and asks before connecting.

1. Compare the fingerprint with the one the server's administrator gave you.
2. If they match, choose **Trust**. AirSQL remembers the certificate for this connection (the editor's TLS tab shows
   it, with **Forget**) and refuses any other.
3. If they don't, choose **Cancel**: you may not be talking to the server you think.

If a trusted server later shows another certificate, AirSQL says so and doesn't connect unless you choose **Trust the
New Certificate**. Do that only when the administrator told you the certificate changed.

## SSH hosts

The first time a connection goes through an SSH host, AirSQL shows the host's key fingerprint the same way. **Trust**
lets ssh remember the key in `~/.ssh/known_hosts`. If the key ever changes, ssh refuses to connect and AirSQL says
which host it was: ask its administrator before removing the old key from `known_hosts`.
