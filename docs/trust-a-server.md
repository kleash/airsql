# Trust a server

When a server's certificate isn't one macOS trusts (it is self-signed, or from your company's own certificate
authority), AirSQL shows its SHA-256 fingerprint and asks before connecting.

1. Compare the fingerprint with the one the server's administrator gave you.
2. If they match, choose **Trust**. AirSQL remembers the certificate and warns you if it ever changes.
3. If they don't, choose **Cancel**: you may not be talking to the server you think.
