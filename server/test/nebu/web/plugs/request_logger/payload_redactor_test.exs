defmodule Nebu.Web.Plugs.RequestLogger.PayloadRedactorTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/matrix-payload-debug-logging`.

  Story: docs/stories/enhanced-logging/matrix-payload-debug-logging.md

  Unit-level tests for `Nebu.Web.Plugs.RequestLogger.PayloadRedactor` — the
  two-category redaction layer (AC4-AC10):

    1. Credentials/secrets (password, access_token, refresh_token, Authorization
       header, UIAA auth.token/auth.session, ?access_token= query param) →
       "***REDACTED***"
    2. Chat message content (content.body and equivalent user-generated content
       across ALL Matrix event types) → "***MESSAGE_CONTENT***"

  MUST FAIL right now: `Nebu.Web.Plugs.RequestLogger.PayloadRedactor` does not
  exist yet — every test below raises `UndefinedFunctionError` /
  `Protocol.UndefinedError`-style failures at call time, which is the expected
  red-phase state (AC10: the module is new, no implementation exists).

  Pure unit tests — no Plug, no HTTP, no DB (AC9/AC10: redaction is isolated and
  testable without a full plug/HTTP request). Run in the default `mix test`
  profile (no `:integration` tag needed).
  """
  use ExUnit.Case, async: true

  alias Nebu.Web.Plugs.RequestLogger.PayloadRedactor

  @redacted "***REDACTED***"
  @msg "***MESSAGE_CONTENT***"

  # ══════════════════════════════════════════════════════════════════════════
  # AC4/AC5 — Credential redaction (Category 1), recursive
  # ══════════════════════════════════════════════════════════════════════════

  describe "credential redaction (AC4/AC5)" do
    test "top-level password, access_token, refresh_token are redacted" do
      payload = %{
        "password" => "secret123",
        "access_token" => "syt_alice_abc123",
        "refresh_token" => "syt_alice_refresh_xyz",
        "user_id" => "@alice:localhost"
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["password"] == @redacted
      assert redacted["access_token"] == @redacted
      assert redacted["refresh_token"] == @redacted
      # Non-credential fields must survive untouched.
      assert redacted["user_id"] == "@alice:localhost"
    end

    test "credential redaction is recursive — nested inside an auth object" do
      payload = %{
        "auth" => %{
          "password" => "secret123",
          "access_token" => "syt_alice_abc123"
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["auth"]["password"] == @redacted
      assert redacted["auth"]["access_token"] == @redacted
    end

    test "credential redaction reaches arbitrary nesting depth" do
      payload = %{
        "a" => %{"b" => %{"c" => %{"d" => %{"password" => "deep-secret"}}}}
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["a"]["b"]["c"]["d"]["password"] == @redacted
    end

    test "top-level new_password is redacted (POST /_matrix/client/v3/account/password, Oracle MUST)" do
      # This endpoint carries the CURRENT password under `password` (already
      # covered above) and the NEW plaintext password under a distinct
      # `new_password` key — both are credentials.
      payload = %{
        "auth" => %{"type" => "m.login.password", "password" => "current-secret"},
        "new_password" => "brand-new-secret-password",
        "logout_devices" => true
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["new_password"] == @redacted
      assert redacted["auth"]["password"] == @redacted
      # Non-credential metadata survives untouched.
      assert redacted["logout_devices"] == true

      encoded = Jason.encode!(redacted)
      refute String.contains?(encoded, "brand-new-secret-password")
    end

    test "new_password nested at arbitrary depth is also redacted (Oracle MUST)" do
      payload = %{"a" => %{"b" => %{"new_password" => "deeply-nested-new-secret"}}}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["a"]["b"]["new_password"] == @redacted
    end

    test "UIAA generic auth object fields token and session are redacted (Oracle spec)" do
      # Matrix User-Interactive Auth API: the generic `auth` object carries a
      # `session` id and, for some stages, a bearer-like `token` — both are
      # credential-shaped and must be redacted, not just `password`.
      payload = %{
        "auth" => %{
          "type" => "m.login.password",
          "session" => "uiaa-session-id-123",
          "token" => "uiaa-stage-token-abc",
          "password" => "secret123"
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["auth"]["session"] == @redacted
      assert redacted["auth"]["token"] == @redacted
      assert redacted["auth"]["password"] == @redacted
      # `type` is UIAA metadata, not a credential — must survive.
      assert redacted["auth"]["type"] == "m.login.password"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4/AC5 — Authorization header redaction
  # ══════════════════════════════════════════════════════════════════════════

  describe "Authorization header redaction (AC4/AC5)" do
    test "the entire Authorization header value is redacted" do
      headers = %{"authorization" => "Bearer syt_alice_abc123"}

      redacted = PayloadRedactor.redact_payload(headers)

      assert redacted["authorization"] == @redacted
    end

    test "Authorization header key matching is case-insensitive (Oracle spec)" do
      for key <- ["Authorization", "AUTHORIZATION", "authorization", "AuThOrIzAtIoN"] do
        headers = %{key => "Bearer syt_alice_abc123"}
        redacted = PayloadRedactor.redact_payload(headers)

        assert redacted[key] == @redacted,
               "expected header key #{inspect(key)} to be redacted regardless of case"
      end
    end

    test "deprecated ?access_token= query-param style is redacted (Oracle spec)" do
      # Matrix spec (deprecated but still-supported client behaviour): some
      # clients pass the access token as a URL query parameter instead of an
      # Authorization header. Whatever representation the redactor is handed
      # (e.g. a decoded query-params map merged into the payload under
      # "access_token", or a raw query string) must not leak the token.
      payload = %{"query_params" => %{"access_token" => "syt_alice_from_url_abc123"}}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["query_params"]["access_token"] == @redacted
    end

    test "a raw query string containing access_token= is redacted (Oracle spec, string input)" do
      query_string = "access_token=syt_alice_from_url_abc123&since=s123"

      redacted = PayloadRedactor.redact_payload(query_string)

      refute String.contains?(redacted, "syt_alice_from_url_abc123"),
             "raw access_token value must not survive redaction of a query string"
    end

    test "a raw query string containing filename= is redacted (upload ?filename= may be personal data)" do
      for qs <- ["filename=Anna-Schmidt-Kuendigung.pdf&x=1", "x=1&filename=Anna%20Schmidt.pdf"] do
        redacted = PayloadRedactor.redact_payload(qs)

        refute String.contains?(redacted, "Schmidt"), "filename value leaked: #{inspect(redacted)}"
        assert String.contains?(redacted, "x=1")
      end
    end
  end

  describe "filename query param with percent-encoded NAME (review MIN-1)" do
    test "encoded key variants are masked; plain/encoded values, multi-params" do
      for qs <- [
            "fil%65name=Anna-Schmidt.pdf",
            "x=1&fil%65name=Anna-Schmidt.pdf&y=2",
            "?%66ilename=Anna-Schmidt.pdf",
            "filename=Anna%20Schmidt.pdf&y=2",
            "fil%65name=Anna%20Schmidt.pdf",
            "x=1&filename=Anna-Schmidt.pdf&fil%65name=Bob-Schmidt.pdf"
          ] do
        redacted = PayloadRedactor.redact_payload(qs)
        refute String.contains?(redacted, "Schmidt"), "leaked: #{inspect(redacted)}"
      end

      redacted = PayloadRedactor.redact_payload("x=1&fil%65name=Anna-Schmidt.pdf&y=2")
      assert redacted =~ "x=1"
      assert redacted =~ "y=2"
    end

    test "x-filename is masked (substring pass) and unrelated encoded keys are untouched" do
      refute PayloadRedactor.redact_payload("x-filename=Anna-Schmidt.pdf") =~ "Schmidt"
      assert PayloadRedactor.redact_payload("na%6De=keepme&z=1") == "na%6De=keepme&z=1"
    end

    test "invalid percent-encoding does not crash" do
      assert is_binary(PayloadRedactor.redact_payload("bad%ZZkey=v&fil%65name=Anna-Schmidt.pdf"))
      refute PayloadRedactor.redact_payload("bad%ZZkey=v&fil%65name=Anna-Schmidt.pdf") =~ "Schmidt"
      assert PayloadRedactor.redact_payload("a%=b&%=c") == "a%=b&%=c"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6/AC7 — Message content redaction (Category 2), any event type, any depth
  # ══════════════════════════════════════════════════════════════════════════

  describe "message content redaction (AC6/AC7)" do
    test "m.room.message content.body is redacted, msgtype survives" do
      payload = %{
        "type" => "m.room.message",
        "content" => %{
          "body" => "Hello, this is a private message",
          "msgtype" => "m.text"
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["content"]["body"] == @msg
      assert redacted["content"]["msgtype"] == "m.text"
    end

    test "message content redaction reaches events nested at any depth (sync-shaped payload)" do
      payload = %{
        "rooms" => %{
          "join" => %{
            "!abc123:localhost" => %{
              "timeline" => %{
                "events" => [
                  %{
                    "type" => "m.room.message",
                    "content" => %{
                      "body" => "Hello, this is a private message",
                      "msgtype" => "m.text"
                    }
                  }
                ]
              }
            }
          }
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      event =
        redacted["rooms"]["join"]["!abc123:localhost"]["timeline"]["events"] |> List.first()

      assert event["content"]["body"] == @msg
      assert event["content"]["msgtype"] == "m.text"
      # Structure is preserved — no fields deleted, only masked.
      assert event["type"] == "m.room.message"
    end

    test "multiple event types in one payload — m.room.name, m.room.topic, custom types" do
      payload = %{
        "events" => [
          %{
            "type" => "m.room.message",
            "content" => %{"body" => "secret text", "msgtype" => "m.text"}
          },
          %{"type" => "m.room.name", "content" => %{"name" => "My Private Room Name"}},
          %{"type" => "m.room.topic", "content" => %{"topic" => "Confidential topic text"}},
          %{
            "type" => "com.example.custom_event",
            "content" => %{"custom_field" => "user-typed custom payload"}
          }
        ]
      }

      redacted = PayloadRedactor.redact_payload(payload)
      [msg_ev, name_ev, topic_ev, custom_ev] = redacted["events"]

      assert msg_ev["content"]["body"] == @msg
      assert msg_ev["content"]["msgtype"] == "m.text"

      assert name_ev["content"]["name"] == @msg
      assert topic_ev["content"]["topic"] == @msg
      assert custom_ev["content"]["custom_field"] == @msg
    end

    test "m.room.encrypted plaintext content fields are redacted, metadata fields survive" do
      # The ciphertext itself is opaque (already encrypted), but any plaintext
      # field alongside it inside `content` is user-influenced and must still be
      # treated per the "not a system/metadata field" rule (AC7). Metadata such
      # as algorithm/sender_key/device_id/session_id are structural, not
      # user-generated text, and must survive.
      payload = %{
        "type" => "m.room.encrypted",
        "content" => %{
          "algorithm" => "m.megolm.v1.aes-sha2",
          "ciphertext" => "AwgAEnACgAYMPmMLm...opaque-base64...",
          "sender_key" => "senderkeybase64",
          "device_id" => "DEVICEID1",
          "session_id" => "sessionidbase64"
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["content"]["algorithm"] == "m.megolm.v1.aes-sha2"
      assert redacted["content"]["sender_key"] == "senderkeybase64"
      assert redacted["content"]["device_id"] == "DEVICEID1"
      assert redacted["content"]["session_id"] == "sessionidbase64"
    end

    test "metadata fields msgtype, url, format, formatted_body-adjacent info remain unredacted" do
      payload = %{
        "type" => "m.room.message",
        "content" => %{
          "body" => "check this file",
          "msgtype" => "m.file",
          "url" => "mxc://localhost/abc123",
          "format" => "org.matrix.custom.html"
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["content"]["body"] == @msg
      assert redacted["content"]["msgtype"] == "m.file"
      assert redacted["content"]["url"] == "mxc://localhost/abc123"
      assert redacted["content"]["format"] == "org.matrix.custom.html"
    end

    test "nested arrays of events (sync timeline.events) — every element is redacted" do
      make_event = fn text ->
        %{"type" => "m.room.message", "content" => %{"body" => text, "msgtype" => "m.text"}}
      end

      payload = %{
        "timeline" => %{
          "events" => [
            make_event.("first secret"),
            make_event.("second secret"),
            make_event.("third secret")
          ]
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      bodies = Enum.map(redacted["timeline"]["events"], & &1["content"]["body"])
      assert bodies == [@msg, @msg, @msg]
    end

    test "unsigned.prev_content (state-event previous content) is redacted, same as content (code-review m2)" do
      # A Matrix state event (e.g. m.room.topic/m.room.name) carries the
      # PREVIOUS content object under `unsigned.prev_content` when the state
      # is replaced. This is the same "user-generated content" leak class as
      # `content` itself (AC7), reached via a different key path.
      payload = %{
        "type" => "m.room.topic",
        "content" => %{"topic" => "New confidential topic"},
        "unsigned" => %{
          "prev_content" => %{"topic" => "Old confidential topic"},
          "age" => 1234
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["content"]["topic"] == @msg
      assert redacted["unsigned"]["prev_content"]["topic"] == @msg
      # Structural metadata outside prev_content survives untouched.
      assert redacted["unsigned"]["age"] == 1234

      encoded = Jason.encode!(redacted)
      refute String.contains?(encoded, "Old confidential topic")
      refute String.contains?(encoded, "New confidential topic")
    end

    test "nested arrays of events (/messages chunk) — every element is redacted" do
      make_event = fn text ->
        %{"type" => "m.room.message", "content" => %{"body" => text, "msgtype" => "m.text"}}
      end

      payload = %{
        "chunk" => [make_event.("alpha"), make_event.("beta")],
        "start" => "t1-1",
        "end" => "t1-2"
      }

      redacted = PayloadRedactor.redact_payload(payload)

      bodies = Enum.map(redacted["chunk"], & &1["content"]["body"])
      assert bodies == [@msg, @msg]
      # Non-content pagination metadata is untouched.
      assert redacted["start"] == "t1-1"
      assert redacted["end"] == "t1-2"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Security review 2026-07-05 (Kassandra SEC gate, cycle 5) — F1/F2/F3/F4
  #
  # F1 (CRITICAL): the Matrix write path (`send`/`setState`) puts event
  # content at the TOP LEVEL of the request body, with NO `content` wrapper
  # at all. The old structural "only redact inside a `content` key" detection
  # never fires for these payloads, so `body`/`topic`/`name`/etc. leak
  # verbatim. F2/F3 (HIGH): even on the wrapped read path, the metadata
  # allowlist over-shadows genuinely user-generated `m.relates_to.key` and
  # `reason`. F4 (MEDIUM): `client_secret`/`id_access_token` missing from the
  # credential key sets.
  # ══════════════════════════════════════════════════════════════════════════

  describe "F1 (CRITICAL) — top-level content with no `content` wrapper (write path)" do
    test "a top-level body field (send-event-shaped request body, no content wrapper) is redacted" do
      # PUT /rooms/{roomId}/send/{eventType}/{txnId} sends the event content as
      # the RAW top-level request body — there is no {"content": {...}} wrapper.
      payload = %{"body" => "secret message text", "msgtype" => "m.text"}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["body"] == @msg
      assert redacted["msgtype"] == "m.text"
    end

    test "a top-level formatted_body field (no content wrapper) is redacted" do
      payload = %{
        "body" => "plain secret",
        "formatted_body" => "<b>plain secret</b>",
        "format" => "org.matrix.custom.html",
        "msgtype" => "m.text"
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["body"] == @msg
      assert redacted["formatted_body"] == @msg
      assert redacted["format"] == "org.matrix.custom.html"
      assert redacted["msgtype"] == "m.text"
    end

    test "a top-level topic field (PUT .../state/m.room.topic/, no content wrapper) is redacted" do
      payload = %{"topic" => "Confidential quarterly numbers"}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["topic"] == @msg
    end

    test "a top-level name field (PUT .../state/m.room.name/, no content wrapper) is redacted" do
      payload = %{"name" => "Secret Project Room"}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["name"] == @msg
    end

    test "a top-level displayname field (PUT profile/{userId}/displayname, no content wrapper) is redacted" do
      payload = %{"displayname" => "Alice Realname Leak"}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["displayname"] == @msg
    end

    test "a top-level filename field (no content wrapper) is redacted" do
      payload = %{"filename" => "confidential-contract.pdf", "msgtype" => "m.file"}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["filename"] == @msg
      assert redacted["msgtype"] == "m.file"
    end
  end

  describe "F2 (HIGH) — m.relates_to.key (reaction text) survives the metadata allowlist" do
    test "content.m.relates_to.key is redacted while rel_type/event_id survive" do
      payload = %{
        "type" => "m.reaction",
        "content" => %{
          "m.relates_to" => %{
            "rel_type" => "m.annotation",
            "event_id" => "$abc123:localhost",
            "key" => "\u{1F44D} distinctive-reaction-text"
          }
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)
      relates_to = redacted["content"]["m.relates_to"]

      assert relates_to["key"] == @msg
      assert relates_to["rel_type"] == "m.annotation"
      assert relates_to["event_id"] == "$abc123:localhost"

      encoded = Jason.encode!(redacted)
      refute String.contains?(encoded, "distinctive-reaction-text")
    end

    test "m.relates_to.key is redacted even without a content wrapper (any depth)" do
      payload = %{
        "m.relates_to" => %{"rel_type" => "m.annotation", "key" => "top-level-reaction"}
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["m.relates_to"]["key"] == @msg
      assert redacted["m.relates_to"]["rel_type"] == "m.annotation"
    end
  end

  describe "F3 (HIGH) — content.reason (kick/ban/redaction free text) survives the metadata allowlist" do
    test "content.reason on an m.room.member event is redacted" do
      payload = %{
        "type" => "m.room.member",
        "content" => %{
          "membership" => "leave",
          "reason" => "distinctive-moderator-typed-reason-text"
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["content"]["reason"] == @msg
      # membership is genuine structural metadata and must survive.
      assert redacted["content"]["membership"] == "leave"

      encoded = Jason.encode!(redacted)
      refute String.contains?(encoded, "distinctive-moderator-typed-reason-text")
    end
  end

  describe "F4 (MEDIUM) — client_secret / id_access_token missing from credential key sets" do
    test "top-level client_secret is redacted" do
      payload = %{"client_secret" => "3pid-request-token-secret", "email" => "a@b.example"}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["client_secret"] == @redacted
      assert redacted["email"] == "a@b.example"
    end

    test "top-level id_access_token is redacted" do
      payload = %{
        "id_access_token" => "identity-server-bearer-token",
        "id_server" => "example.org"
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["id_access_token"] == @redacted
      assert redacted["id_server"] == "example.org"
    end

    test "client_secret and id_access_token nested at arbitrary depth are redacted" do
      payload = %{
        "threepidCreds" => %{
          "client_secret" => "nested-secret",
          "id_access_token" => "nested-token"
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["threepidCreds"]["client_secret"] == @redacted
      assert redacted["threepidCreds"]["id_access_token"] == @redacted
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Security review 2026-07-05 (Kassandra SEC gate, cycle 5 RE-VERIFY) — F1-R
  #
  # F1-R (HIGH, residual of F1): cycle 5 closed the COMMON write-path content
  # fields via a FIXED name list (`@always_content_keys`), but any content
  # field NOT on that list still leaked on the write path, because
  # `redact_payload/1` always seeded the top-level recursion with
  # `in_content? = false` — the "non-metadata inside content ⇒ content"
  # catch-all never fired without a `content` wrapper. Matrix's event schema
  # is open/extensible (custom/vendor fields, `m.location.geo_uri`, poll
  # text, `m.room.encrypted.ciphertext`), so a fixed list can never be
  # exhaustive. Fix: a new `redact_payload/2` with `in_content?: true` seeds
  # the top-level recursion as though already inside a `content` object, so
  # write-path callers (RequestLogger, for send/state routes) get the SAME
  # "any non-metadata key ⇒ content" catch-all the read path already gets
  # via its `content` wrapper.
  # ══════════════════════════════════════════════════════════════════════════

  describe "F1-R (HIGH, cycle 6) — redact_payload/2 in_content?: true" do
    test "m.location.geo_uri (plaintext GPS coordinates) is masked when in_content?: true, even though it is not in the fixed field-name list" do
      # PUT /rooms/{roomId}/send/m.room.message/{txnId} with an m.location
      # event sends this shape as the RAW top-level request body.
      payload = %{
        "msgtype" => "m.location",
        "body" => "My current location",
        "geo_uri" => "geo:52.5200,13.4050"
      }

      redacted = PayloadRedactor.redact_payload(payload, in_content?: true)

      assert redacted["geo_uri"] == @msg
      assert redacted["body"] == @msg
      # msgtype is structural metadata and must survive.
      assert redacted["msgtype"] == "m.location"
    end

    test "an arbitrary custom/vendor event field is masked when in_content?: true, even though it is not in the fixed field-name list" do
      # A custom/vendor event type's top-level write-path body, e.g.
      # PUT /rooms/{roomId}/send/com.example.custom_event/{txnId}.
      payload = %{"custom_field" => "user-typed custom payload"}

      redacted = PayloadRedactor.redact_payload(payload, in_content?: true)

      assert redacted["custom_field"] == @msg
    end

    test "m.room.encrypted.ciphertext is masked when in_content?: true (F1-R.a, low-severity but closed by the same fix)" do
      payload = %{
        "algorithm" => "m.megolm.v1.aes-sha2",
        "ciphertext" => "AwgAEnACgAYMPmMLm...opaque-base64...",
        "sender_key" => "senderkeybase64",
        "device_id" => "DEVICEID1",
        "session_id" => "sessionidbase64"
      }

      redacted = PayloadRedactor.redact_payload(payload, in_content?: true)

      assert redacted["ciphertext"] == @msg
      # Structural crypto metadata still survives.
      assert redacted["algorithm"] == "m.megolm.v1.aes-sha2"
      assert redacted["sender_key"] == "senderkeybase64"
      assert redacted["device_id"] == "DEVICEID1"
      assert redacted["session_id"] == "sessionidbase64"
    end

    test "credentials are still redacted at the top level when in_content?: true (Category 1 unaffected)" do
      payload = %{"access_token" => "syt_alice_abc123", "custom_field" => "some text"}

      redacted = PayloadRedactor.redact_payload(payload, in_content?: true)

      assert redacted["access_token"] == @redacted
      assert redacted["custom_field"] == @msg
    end

    test "without the option (default redact_payload/1), a top-level non-fixed content field is NOT masked" do
      # This is the pre-existing, still-correct behaviour of the default
      # entry point: NOT every top-level map is a Matrix event content
      # object (e.g. a /sync response envelope), so `redact_payload/1` must
      # stay conservative by default. Only route-aware callers that KNOW the
      # body is a raw content object (RequestLogger, for send/state write
      # paths) opt into `in_content?: true`.
      payload = %{"geo_uri" => "geo:52.5200,13.4050"}

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["geo_uri"] == "geo:52.5200,13.4050"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4-AC7 — Combined redaction, both categories in one payload
  # ══════════════════════════════════════════════════════════════════════════

  describe "combined redaction — both categories in one payload" do
    test "credentials and message content are both redacted in a single nested payload" do
      payload = %{
        "auth" => %{"password" => "secret123", "access_token" => "syt_abc"},
        "rooms" => %{
          "join" => %{
            "!room:localhost" => %{
              "timeline" => %{
                "events" => [
                  %{
                    "type" => "m.room.message",
                    "content" => %{"body" => "private message body", "msgtype" => "m.text"}
                  }
                ]
              }
            }
          }
        }
      }

      redacted = PayloadRedactor.redact_payload(payload)

      assert redacted["auth"]["password"] == @redacted
      assert redacted["auth"]["access_token"] == @redacted

      event =
        redacted["rooms"]["join"]["!room:localhost"]["timeline"]["events"] |> List.first()

      assert event["content"]["body"] == @msg

      encoded = Jason.encode!(redacted)
      refute String.contains?(encoded, "secret123")
      refute String.contains?(encoded, "syt_abc")
      refute String.contains?(encoded, "private message body")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC9/AC10 — Redaction layer isolation / testability
  # ══════════════════════════════════════════════════════════════════════════

  describe "redaction layer isolation (AC9/AC10)" do
    test "PayloadRedactor.redact_payload/1 is callable with only a map — no plug/conn/HTTP required" do
      # This test's mere existence (and the fact it needs no Plug.Conn, no
      # Plug.Test, no router, no DB) proves AC10: the redaction logic is
      # independent of the plug infrastructure.
      assert %{"password" => @redacted} = PayloadRedactor.redact_payload(%{"password" => "x"})
    end

    test "redact_payload/1 accepts a plain string and returns a string unchanged when no secrets present" do
      assert PayloadRedactor.redact_payload("hello world") == "hello world"
    end

    test "redact_payload/1 accepts a map and returns a map" do
      assert is_map(PayloadRedactor.redact_payload(%{"a" => 1}))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Oracle spec edge cases — empty/nil/non-JSON/malformed bodies, idempotency
  # ══════════════════════════════════════════════════════════════════════════

  describe "edge cases (Oracle spec)" do
    test "nil body returns nil unchanged, no crash" do
      assert PayloadRedactor.redact_payload(nil) == nil
    end

    test "empty map returns empty map unchanged" do
      assert PayloadRedactor.redact_payload(%{}) == %{}
    end

    test "empty string returns empty string unchanged" do
      assert PayloadRedactor.redact_payload("") == ""
    end

    test "binary (non-JSON, e.g. media upload bytes) is returned unchanged, not parsed, no crash" do
      binary_blob = <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00>>

      result = PayloadRedactor.redact_payload(binary_blob)

      assert result == binary_blob
    end

    test "form-encoded body string: not parsed as JSON, but the refresh_token value IS redacted" do
      form_body = "grant_type=refresh_token&refresh_token=some-value-here"

      result = PayloadRedactor.redact_payload(form_body)

      # Whatever the redactor does with an opaque non-JSON string, it must not
      # crash, and must not silently fabricate JSON structure from it.
      assert is_binary(result)
      # code-review m5: strengthened beyond a type-only check. This is a real
      # OAuth-style refresh-token-exchange body — `redact_query_style/3`
      # recognises the `refresh_token=` key=value pattern even without
      # structurally parsing the string, so the actual secret value must be
      # absent from the result, not merely "some binary came back".
      refute String.contains?(result, "some-value-here")
      assert String.contains?(result, "***REDACTED***")
    end

    test "malformed JSON string is not parsed as structured data, but the body value IS redacted" do
      malformed = "{\"type\": \"m.room.message\", \"content\": {\"body\": \"leaked secret\""

      result = PayloadRedactor.redact_payload(malformed)

      # The function must not raise trying to parse this, and must not return a
      # map (since it could not have been legitimately parsed).
      refute is_map(result)
      # code-review m5: strengthened beyond a type-only check. Even though
      # this string is never `Jason.decode`d (AC6/AC7's "message content must
      # never appear in logs, even in malformed/edge-case input" LAW still
      # applies) — `redact_json_string_style/3` recognises the `"body":
      # "..."` quoted-key pattern and masks it without ever treating the
      # string as structured data.
      refute String.contains?(result, "leaked secret")
      assert String.contains?(result, "***MESSAGE_CONTENT***")
    end

    test "redaction is idempotent — redacting twice yields identical output to redacting once" do
      payload = %{
        "password" => "secret123",
        "auth" => %{"access_token" => "syt_abc"},
        "content" => %{"body" => "hello", "msgtype" => "m.text"}
      }

      once = PayloadRedactor.redact_payload(payload)
      twice = PayloadRedactor.redact_payload(once)

      assert once == twice
    end

    test "media binary bodies are never JSON-parsed or logged as text (Oracle spec)" do
      # A raw multipart/binary upload body must pass through as an opaque binary
      # (or an explicit non-textual marker) — never attempted-decoded as JSON,
      # and never surfacing raw bytes as if they were loggable text content.
      png_like = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5>>

      result = PayloadRedactor.redact_payload(png_like)

      assert result == png_like
    end
  end
end
