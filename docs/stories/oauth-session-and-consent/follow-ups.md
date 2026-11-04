# Follow-ups of epic oauth-session-and-consent

- Redact device names in the debug request logger (the `GET /devices` response body shows them at debug level).
- Thread client_name through authenticate/redeem to avoid the second client SELECT (`DeviceName.for_client/2` re-reads the approved client).
- Confusable/mixed-script warning on approve_confirm (homoglyph client names such as a Cyrillic "Element").

## Security review notes (Kassandra, oauth-device-default-display-name, LOW)

- Invisible letters (U+3164, U+FFA0, U+115F, U+1160, U+2800, U+034F, variation selectors) and combining marks without a base letter are now handled in `Nebu.OAuth.DeviceName` (a base without a visible character falls back to `OAuth client`).
- Homoglyph / impersonation client names (for example a Cyrillic "Element") are an accepted residual risk: only the `client_name` of an approved client is used, an admin reviews it at approval, and the device suffix is always added by the server.
