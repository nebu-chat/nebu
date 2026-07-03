// admin-ui-migration: LiveView client bootstrap for the Nebu Admin UI.
//
// No npm/esbuild build step. We load the vendored UMD builds of phoenix and
// phoenix_live_view (copied from deps/ at build time) which expose the `Phoenix`
// and `LiveView` globals, then wire a LiveSocket on /admin/live. The CSRF token is
// read from the <meta name="csrf-token"> emitted by the root layout.
//
// These three <script> tags are emitted by NebuHttp.Admin.Layouts.root/1:
//   /admin/static/assets/phoenix.min.js          → window.Phoenix
//   /admin/static/assets/phoenix_live_view.min.js → window.LiveView
//   /admin/static/assets/app.js                   → this file (defer)
(function () {
  "use strict";

  // device-revoke-confirm: CSP-compliant confirmation for destructive admin actions.
  //
  // The admin CSP is `script-src 'self'` with NO 'unsafe-inline', so inline
  // `onsubmit="return confirm(...)"` handlers are blocked by the browser and never
  // fire. The per-user device page (a dead controller render — no LiveView socket)
  // therefore cannot rely on either an inline handler OR Phoenix `data-confirm`.
  //
  // This single delegated `submit` listener (loaded from this external file, which IS
  // allowed by `script-src 'self'`) intercepts any `[data-confirm]` form submit and
  // requires the operator to confirm before the destructive POST proceeds. It fires for
  // BOTH click-to-submit and keyboard (Enter) submit, so it is keyboard-operable, and
  // it works with or without LiveView present — hence it is wired BEFORE the LiveView
  // bootstrap guard below.
  function wireConfirmForms() {
    document.addEventListener(
      "submit",
      function (event) {
        var form = event.target;
        if (!form || typeof form.matches !== "function") return;
        if (!form.matches("form[data-confirm]")) return;
        var message = form.getAttribute("data-confirm");
        if (!message) return;
        if (!window.confirm(message)) {
          event.preventDefault();
        }
      },
      // Capture phase so the confirmation runs before any other submit handler.
      true,
    );
  }

  // admin-add-user-autocomplete: CSP-safe fetch typeahead for the room/space add-member
  // field. The admin CSP is `script-src 'self'` (no 'unsafe-inline') but same-origin
  // fetch IS allowed, and these pages are dead controller renders (no LiveView socket).
  // This widget therefore lives entirely in this external file:
  //   - debounced GET /admin/users/search?q=… (>=2 chars; below that it clears)
  //   - renders <ul role="listbox"> <li role="option" data-role="user-suggestion"
  //     data-user-id="…"> options; user_id is set via textContent (XSS-safe — never
  //     innerHTML), so a crafted display value cannot inject markup
  //   - click / Enter / ArrowUp / ArrowDown / Escape are keyboard-operable
  //   - selecting an option fills the input and closes the listbox (free-text submit
  //     remains unchanged when no option is picked)
  var AUTOCOMPLETE_MIN_CHARS = 2;
  var AUTOCOMPLETE_DEBOUNCE_MS = 150;

  function wireUserAutocomplete() {
    var inputs = document.querySelectorAll('[data-field="add-member-user-id"][role="combobox"]');
    Array.prototype.forEach.call(inputs, function (input) {
      if (input.getAttribute("data-autocomplete-wired") === "true") return;
      input.setAttribute("data-autocomplete-wired", "true");
      setupAutocomplete(input);
    });
  }

  function setupAutocomplete(input) {
    var container =
      input.parentElement &&
      input.parentElement.querySelector('[data-role="user-suggestions"]');
    if (!container) return;

    var listboxId = container.getAttribute("data-listbox-id") || "user-suggestions-listbox";
    var debounceTimer = null;
    var requestSeq = 0;
    var activeIndex = -1;
    var currentList = null;

    function clearList() {
      container.textContent = "";
      currentList = null;
      activeIndex = -1;
      input.setAttribute("aria-expanded", "false");
      input.removeAttribute("aria-activedescendant");
    }

    function options() {
      return currentList
        ? Array.prototype.slice.call(currentList.querySelectorAll('[role="option"]'))
        : [];
    }

    function highlight(idx) {
      var opts = options();
      opts.forEach(function (o, i) {
        if (i === idx) {
          o.setAttribute("aria-selected", "true");
          o.classList.add("bg-base-300");
          o.scrollIntoView({ block: "nearest" });
        } else {
          o.setAttribute("aria-selected", "false");
          o.classList.remove("bg-base-300");
        }
      });
      activeIndex = idx;
      if (idx >= 0 && opts[idx]) {
        input.setAttribute("aria-activedescendant", opts[idx].id);
      } else {
        input.removeAttribute("aria-activedescendant");
      }
    }

    function select(userId) {
      input.value = userId;
      clearList();
      input.focus();
    }

    function render(users, query) {
      container.textContent = "";
      activeIndex = -1;

      var ul = document.createElement("ul");
      ul.id = listboxId;
      ul.setAttribute("role", "listbox");
      ul.className =
        "menu bg-base-100 border border-base-300 rounded-box shadow w-full max-h-60 overflow-auto";

      if (users.length === 0) {
        // Empty-state marker — the query was long enough but matched nobody. Rendered
        // so the (server-confirmed) no-match state is observable, not a race.
        var empty = document.createElement("li");
        empty.setAttribute("data-role", "no-user-suggestions");
        empty.className = "px-3 py-2 text-base-content/60 text-sm";
        empty.textContent = "No matching users";
        ul.appendChild(empty);
      } else {
        users.forEach(function (u, i) {
          var li = document.createElement("li");
          li.id = listboxId + "-opt-" + i;
          li.setAttribute("role", "option");
          li.setAttribute("data-role", "user-suggestion");
          li.setAttribute("data-user-id", u.user_id);
          li.setAttribute("aria-selected", "false");
          li.className = "px-3 py-2 cursor-pointer hover:bg-base-200 font-mono text-sm";
          // textContent only — never innerHTML. A crafted user_id renders as inert text.
          li.textContent = u.user_id;
          li.addEventListener("mousedown", function (e) {
            // mousedown (not click) so the input's blur does not close the listbox first.
            e.preventDefault();
            select(u.user_id);
          });
          ul.appendChild(li);
        });
      }

      container.appendChild(ul);
      currentList = ul;
      input.setAttribute("aria-expanded", "true");
    }

    function fetchSuggestions(query) {
      var seq = ++requestSeq;
      // No custom Accept header: the admin :browser pipeline negotiates `html` from the
      // default `*/*`; the controller's json/2 sets application/json on the response.
      fetch(
        "/admin/users/search?q=" + encodeURIComponent(query),
        { credentials: "same-origin" },
      )
        .then(function (resp) {
          return resp.ok ? resp.json() : { users: [] };
        })
        .then(function (data) {
          if (seq !== requestSeq) return; // stale response — a newer query superseded it
          render((data && data.users) || [], query);
        })
        .catch(function () {
          if (seq !== requestSeq) return;
          clearList();
        });
    }

    input.addEventListener("input", function () {
      var query = input.value.trim();
      if (debounceTimer) clearTimeout(debounceTimer);
      if (query.length < AUTOCOMPLETE_MIN_CHARS) {
        clearList();
        return;
      }
      debounceTimer = setTimeout(function () {
        fetchSuggestions(query);
      }, AUTOCOMPLETE_DEBOUNCE_MS);
    });

    input.addEventListener("keydown", function (e) {
      var opts = options();
      if (e.key === "ArrowDown") {
        if (opts.length === 0) return;
        e.preventDefault();
        highlight((activeIndex + 1) % opts.length);
      } else if (e.key === "ArrowUp") {
        if (opts.length === 0) return;
        e.preventDefault();
        highlight((activeIndex - 1 + opts.length) % opts.length);
      } else if (e.key === "Enter") {
        if (activeIndex >= 0 && opts[activeIndex]) {
          e.preventDefault();
          select(opts[activeIndex].getAttribute("data-user-id"));
        }
        // else: let Enter submit the form (free-text path unchanged)
      } else if (e.key === "Escape") {
        if (currentList) {
          e.preventDefault();
          clearList();
        }
      }
    });

    // Close the listbox when focus leaves the widget (delayed so option mousedown wins).
    input.addEventListener("blur", function () {
      setTimeout(clearList, 100);
    });
  }

  // admin-liveview-session-refresh (AC3): the silent OIDC refresh in
  // Nebu.Admin.Auth.fetch_current_user/2 only runs on a genuine HTTP round-trip
  // through the :browser pipeline — it never re-fires for an operator who stays on
  // an open admin LiveView (Dashboard/AuditLog) with no new HTTP request, so a
  // Keycloak-class IdP's short id_token lifetime force-logs-out the operator even
  // with a valid stored OIDC refresh token. Rather than inventing a new
  // WebSocket-reachable refresh mechanism, this hook periodically fires an
  // invisible `GET /admin/keepalive` (well inside the existing 120s pre-expiry
  // window) while any admin LiveView with this hook mounted is on screen — that
  // request goes through the normal :browser pipeline, so fetch_current_user/2's
  // EXISTING silent-refresh leg runs unmodified. No response payload is read; the
  // side effect (refreshing the underlying HTTP session) is all that matters.
  var KEEPALIVE_INTERVAL_MS = 60 * 1000;

  var SessionKeepalive = {
    mounted: function () {
      this.timer = setInterval(sendKeepalive, KEEPALIVE_INTERVAL_MS);
    },
    destroyed: function () {
      if (this.timer) clearInterval(this.timer);
    },
  };

  function sendKeepalive() {
    fetch("/admin/keepalive", {
      method: "GET",
      credentials: "same-origin",
      cache: "no-store",
    }).catch(function () {
      // Best-effort heartbeat: a transient network error just means this cycle's
      // refresh attempt is skipped — the next interval tick tries again, and the
      // operator's normal HTTP navigation remains an independent refresh trigger.
    });
  }

  function boot() {
    wireConfirmForms();
    wireUserAutocomplete();

    if (!window.Phoenix || !window.LiveView) {
      // Vendored client not present (e.g. a stripped deploy) — the static render
      // still works; only the live DOM-diff upgrade is unavailable.
      return;
    }

    var Socket = window.Phoenix.Socket;
    var LongPoll = window.Phoenix.LongPoll;
    var LiveSocket = window.LiveView.LiveSocket;

    var meta = document.querySelector("meta[name='csrf-token']");
    var csrfToken = meta ? meta.getAttribute("content") : null;

    // Throttle re-polls to avoid hammering the server when WebSocket is unavailable.
    // Default Phoenix LongPoll polls again immediately after each response; 1 500 ms
    // is enough to feel responsive while staying friendly to the server and proxies.
    class ThrottledLongPoll extends LongPoll {
      poll() {
        setTimeout(() => super.poll(), 1500);
      }
    }

    // NOTE: the add-user typeahead is NOT a LiveView hook — it is the CSP-safe fetch
    // widget wired in `wireUserAutocomplete()` above (the admin add-member pages are
    // dead controller renders with no LiveView socket).
    var liveSocket = new LiveSocket("/admin/live", Socket, {
      transport: ThrottledLongPoll,
      params: { _csrf_token: csrfToken },
      hooks: { SessionKeepalive: SessionKeepalive },
    });

    liveSocket.connect();
    window.liveSocket = liveSocket;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
