# Oracle context (script draft from Matrix spec v1.18 api.json)

## PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId} — Send a message event to the given room.
- (matched from the shorthand `PUT /rooms/{id}/send/m.room.encrypted/{txn}` — verify it is the intended endpoint)
- Auth: required (access token) · Rate-limited: no
- Required params: roomId(path), eventType(path), txnId(path)
- Body required fields: none
- Responses: 200 An ID for the sent event. | 400 [M_DUPLICATE_ANNOTATION, M_UNKNOWN] The request is invalid. A [standard error response](https://spec.matri
- MUST: Homeservers MUST allow clients to send `m.room.redaction` events with this endpoint for all room versions.
- MUST: In rooms with a version older than 11 they MUST move the `redacts` property inside the `content` to the top level of the event.

## PUT /_matrix/client/v3/sendToDevice/{eventType}/{txnId} — Send an event to a given set of devices.
- (matched from the shorthand `PUT /sendToDevice/{type}/{txn}` — verify it is the intended endpoint)
- Auth: required (access token) · Rate-limited: no
- Required params: eventType(path), txnId(path)
- Body required fields: messages:object
- Responses: 200 The message was successfully sent.

## POST /_matrix/client/v3/keys/device_signing/upload — Upload cross-signing keys.
- (matched from the shorthand `POST /keys/device_signing/upload` — verify it is the intended endpoint)
- Auth: required (access token) · Rate-limited: no
- Body required fields: none
- Body optional: auth, master_key, self_signing_key, user_signing_key
- Responses: 200 The provided keys were successfully uploaded. | 400 [M_INVALID_SIGNATURE, M_MISSING_PARAM] The input was invalid in some way. This can include one of the followi | 403 [M_FORBIDDEN] The public key of one of the keys is the same as one of the user\'s de
- MUST: User-Interactive Authentication MUST be performed for regular clients, except in these cases: - there is no existing master signing key uploaded to the homeserver, OR - there is an existing master signing key and it exac
- MUST: If there are any additional keys provided in the request (self-signing key, user-signing key) they MUST also match the existing keys stored on the server.

## Error codes named in the story
- M_FORBIDDEN, M_INVALID_PARAM  → every one needs a test with its HTTP status (see responses above)

## Event types named in the story (not covered by api.json — look up in client-server-api/index.html)
- m.key.verification.request, m.room.encrypted, m.room.encryption, m.room.message, m.room_key.withheld, m.secret.request, m.secret.send
