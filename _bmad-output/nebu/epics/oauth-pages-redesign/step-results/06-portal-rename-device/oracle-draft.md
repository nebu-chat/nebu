# Oracle context (script draft from Matrix spec v1.18 api.json)

## GET /_matrix/client/v3/devices — List registered devices for the current user
- (matched from the shorthand `GET /devices` — verify it is the intended endpoint)
- Auth: required (access token) · Rate-limited: no
- Responses: 200 Device information

## PUT /_matrix/client/v3/devices/{deviceId} — Create or update a device
- (matched from the shorthand `PUT /devices/{id}` — verify it is the intended endpoint)
- Auth: required (access token) · Rate-limited: no
- Required params: deviceId(path)
- Body required fields: none
- Body optional: display_name
- Responses: 200 The device was successfully updated. | 201 The device was successfully created by the application service. | 404 The current user has no device with the given ID.
- MUST: The ability to create new devices is only available to application services: regular clients may only update existing devices.
- MUST: When a new device was created, the homeserver MUST return a 201 HTTP status code.
- MUST: It MUST return a 200 HTTP status code if a device was updated.
