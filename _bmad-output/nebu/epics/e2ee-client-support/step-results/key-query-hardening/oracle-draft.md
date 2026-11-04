# Oracle context (script draft from Matrix spec v1.18 api.json)

## POST /_matrix/client/v3/keys/query — Download device identity keys.
- (matched from the shorthand `POST /keys/query` — verify it is the intended endpoint)
- Auth: required (access token) · Rate-limited: no
- Body required fields: device_keys:object
- Body optional: timeout
- Responses: 200 The device information

## POST /_matrix/client/v3/keys/signatures/upload — Upload cross-signing signatures.
- (matched from the shorthand `POST /keys/signatures/upload` — verify it is the intended endpoint)
- Auth: required (access token) · Rate-limited: no
- Body required fields: none
- Responses: 200 [M_INVALID_SIGNATURE] The provided signatures were processed.
- MUST: The signed JSON object must match the key previously uploaded or retrieved for the given key ID, with the exception of the `signatures` property, which contains the new signature(s) to add.

## Error codes named in the story
- M_INVALID_SIGNATURE  → every one needs a test with its HTTP status (see responses above)
