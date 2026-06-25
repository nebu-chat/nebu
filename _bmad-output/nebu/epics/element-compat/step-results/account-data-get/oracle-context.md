## Spec Context: GET/PUT /user/{userId}/account_data/{type} (Matrix CS v1.18)

### PUT /_matrix/client/v3/user/{userId}/account_data/{type}
- Spec: stores arbitrary JSON content as account data for the given type
- Server MUST accept any JSON body and return `200 {}`
- Requires auth: Yes (OidcPlug enforced)
- Rate-limited: Yes

### GET /_matrix/client/v3/user/{userId}/account_data/{type}
- Spec: returns the account data for the given type
- 200: the stored JSON body (raw, not re-encoded)
- 404: `{"errcode": "M_NOT_FOUND", "error": "..."}` if not found (spec-valid)
- Requires auth: Yes

### User isolation
- Spec: each user's account data is independent
- Server MUST NOT allow user A to read/write user B's account data
- The {userId} in the path must match the authenticated user (IDOR guard)

### Spec note on storage
- Spec does not mandate persistence across restarts — clients are responsible for
  re-uploading account data after a fresh login if the server loses data
- ETS (volatile) store is spec-acceptable for an MVP stub

### Secret storage key types
- `m.secret_storage.default_key`: stores the ID of the default secret storage key
- `m.secret_storage.key.{keyId}`: stores the key description
- Element Web reads these back after PUT to continue cross-signing setup
- A 404 on GET breaks the setup flow — must return the stored value
