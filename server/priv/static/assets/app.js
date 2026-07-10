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

  // admin-sidebar-nesting: expand/collapse for the nested sidebar nav sections
  // ("Logs", "Configuration" — Nebu.Admin.Layouts.nav_item/1 parent mode).
  //
  // The admin CSP is `script-src 'self'` (no 'unsafe-inline'), and the sidebar
  // renders on BOTH dead controller pages (no LiveView socket — a `phx-click`
  // would never fire) and LiveView pages, so the toggle lives here as a single
  // DELEGATED document-level click listener (survives LiveView DOM patches;
  // nothing to re-wire after morphdom). A native <button> fires `click` for
  // mouse, Space, and Enter alike, so this one listener is fully
  // keyboard-operable (story AC9).
  //
  // Toggling flips three things the server rendered (expanded by default —
  // story Dev Notes Q3; collapse state intentionally does NOT persist across
  // navigations, Q1):
  //   - aria-expanded on the <button data-nav-toggle> (screen readers)
  //   - the boolean `hidden` attribute on the aria-controls'd child <ul>
  //     (children stay in the DOM — AC10; the <ul> carries no display utility
  //     class, so the UA's `[hidden] { display: none }` actually applies —
  //     see the trace-map-hierarchy cycle-1 flex-beats-hidden bug)
  //   - the chevron's `rotate-90` class (visual open/closed state — AC13)
  function wireNavSectionToggles() {
    document.addEventListener("click", function (event) {
      var target = event.target;
      if (!target || typeof target.closest !== "function") return;
      var button = target.closest("button[data-nav-toggle]");
      if (!button) return;

      var nowExpanded = button.getAttribute("aria-expanded") !== "true";
      button.setAttribute("aria-expanded", nowExpanded ? "true" : "false");

      var listId = button.getAttribute("aria-controls");
      var list = listId ? document.getElementById(listId) : null;
      if (list) {
        if (nowExpanded) {
          list.removeAttribute("hidden");
        } else {
          list.setAttribute("hidden", "hidden");
        }
      }

      var icon = button.querySelector('[data-testid="nav-toggle-icon"]');
      if (icon) icon.classList.toggle("rotate-90", nowExpanded);
    });
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

  // enhanced-logging/admin-logs-monitoring-view (AC1/AC3/AC4): the Trace Map's
  // filter-toggle bubbles are CLIENT-SIDE ONLY (no server round-trip per click —
  // AC3). The admin CSP (`script-src 'self'`, no `unsafe-inline`) rules out an
  // inline `<script>` tag in the LogsLive template, so — exactly like
  // `wireConfirmForms`/`wireUserAutocomplete` above — this lives here instead.
  //
  // Each bubble's `phx-click` is bound to `Phoenix.LiveView.JS.dispatch(...)`
  // (server/lib/nebu/admin/logs_live.ex), which fires a plain, bubbling
  // CustomEvent on the clicked element and does NOT push anything to the
  // LiveView server. This delegated listener on `document` toggles the
  // bubble's own `aria-pressed` attribute, then recomputes which
  // `[data-testid="request-row"]` rows and `[data-testid="filter-chip"]` chips
  // should be visible — AND logic across dimensions (endpoint/level/source),
  // OR logic for multiple active values within the SAME dimension.
  function activeTraceMapFilters() {
    var filters = {};
    var bubbles = document.querySelectorAll(
      '[data-testid="trace-map-bubble"][aria-pressed="true"]',
    );
    Array.prototype.forEach.call(bubbles, function (bubble) {
      var dimension = bubble.dataset.bubbleDimension;
      var value = bubble.dataset.bubbleValue;
      if (!dimension) return;
      filters[dimension] = filters[dimension] || [];
      filters[dimension].push(value);
    });
    return filters;
  }

  function traceMapRowMatches(row, filters) {
    for (var dimension in filters) {
      if (!Object.prototype.hasOwnProperty.call(filters, dimension)) continue;
      var activeValues = filters[dimension];
      if (!activeValues || activeValues.length === 0) continue;

      var rowValues;
      if (dimension === "endpoint") {
        rowValues = [row.dataset.endpoint || ""];
      } else if (dimension === "level") {
        rowValues = [row.dataset.highestLevel || ""];
      } else if (dimension === "source") {
        rowValues = (row.dataset.sources || "").split(" ");
      } else {
        rowValues = [];
      }

      var matchesThisDimension = activeValues.some(function (v) {
        return rowValues.indexOf(v) !== -1;
      });
      if (!matchesThisDimension) return false;
    }
    return true;
  }

  function applyTraceMapFilters() {
    var filters = activeTraceMapFilters();

    var rows = document.querySelectorAll('[data-testid="request-row"]');
    Array.prototype.forEach.call(rows, function (row) {
      row.style.display = traceMapRowMatches(row, filters) ? "" : "none";
    });

    var chips = document.querySelectorAll('[data-testid="filter-chip"]');
    Array.prototype.forEach.call(chips, function (chip) {
      var dimension = chip.dataset.chipDimension;
      var value = chip.dataset.chipValue;
      var isActive = !!(filters[dimension] && filters[dimension].indexOf(value) !== -1);
      chip.style.display = isActive ? "" : "none";
    });
  }

  // V2 fix (UX/accessibility gate, BLOCKING): the bubble's active/filled
  // visual state (AC1: "Clicking a bubble activates it (filled/highlighted),
  // clicking again deactivates (dimmed/outline)") was never actually applied
  // client-side — only `aria-pressed` toggled, not the `btn-active`/
  // `btn-outline` classes `trace_map_bubble.ex`'s own `class` computation
  // defines server-side for `active: true`/`active: false`. This mirrors
  // that EXACT class logic (`server/lib/nebu/admin/logs_live/trace_map_bubble.ex`):
  //   active && not off  -> "btn-active" (and NOT "btn-outline")
  //   not active || off  -> "btn-outline" (and NOT "btn-active")
  // "off" bubbles never reach here with `pressed: true` (the click handler
  // below returns early for them), so they always stay in the "btn-outline"
  // branch, matching the server-rendered default.
  function setBubbleActiveClasses(bubble, pressed) {
    if (pressed) {
      bubble.classList.add("btn-active");
      bubble.classList.remove("btn-outline");
    } else {
      bubble.classList.remove("btn-active");
      bubble.classList.add("btn-outline");
    }
  }

  // Bug fix (trace-map-filter-reset-bugfix, AC3): reflects the CURRENT
  // aria-pressed state of every Trace Map bubble into the page's own URL
  // query string (`?endpoint=...&level=...&source=...`), via
  // `history.pushState` — entirely client-side, no LiveView round trip
  // (keeps AC2's "no perceptible click lag" property; see `bubble_js/2`'s
  // own comment in `logs_live.ex` for why this could not be done via
  // `Phoenix.LiveView.JS.patch/2` + `handle_params/3` instead).
  //
  // dev-story cycle 1, code-review MAJOR finding M1: ALL active values per
  // dimension are encoded now, comma-joined (e.g. `?level=error,warning`),
  // not just the first one — `logs_live.ex`'s `@active_filters` now
  // mirrors this file's own OR-within-a-dimension semantics
  // (`activeTraceMapFilters`/`traceMapRowMatches`, already multi-select
  // since the original admin-logs-monitoring-view story) exactly, list for
  // list, instead of collapsing to a single scalar. Comma-joining (not
  // repeated bare params like `?level=error&level=warning`) was chosen
  // because `Plug.Conn.Query.decode/1` — the server's own query-string
  // parser — documents "if a value is given more than once, the LAST
  // value takes precedence"; a repeated bare param would silently DROP
  // every value but the last one on the server side, defeating the whole
  // point of this fix.
  function syncTraceMapUrlFromBubbles() {
    // V8 fix (real-browser verification): the entry the page ORIGINALLY
    // loaded on carries a history `state` object LiveView itself seeded
    // BEFORE our very first click (shape: `{type: "patch", id:
    // <this-view's-own-phx-id>, position: 0}` — see
    // `phoenix_live_view.cjs.js`'s `historyPatch`/initial state setup).
    // Navigating "back" to THAT exact entry later makes LiveView's own
    // "popstate" listener see `navType === "patch" && id === this.main.id`
    // and attempt `this.main.pushLinkPatch(...)` — a REAL server round trip
    // requiring `handle_params/3`, the exact mechanism this fix cannot use
    // (see `bubble_js/2`'s comment in `logs_live.ex`) — which silently does
    // nothing observable (no error, no re-render) rather than falling back
    // to a full re-mount. Neutralizing that ONE, pre-existing entry's state
    // (replacing it with a plain marker, once, before our first push) makes
    // a later "back" to it fall through to LiveView's OTHER, DOES-work
    // branch (`replaceMain`, a full disconnect+remount that correctly reads
    // the target URL's query params fresh — exactly `mount/3`'s own
    // params-driven `@active_filters` seeding this story's fix already
    // relies on for the "shareable URL" case).
    if (!window.__nebuHistoryNeutralized) {
      window.__nebuHistoryNeutralized = true;
      window.history.replaceState(
        { nebuTraceMapFilters: true },
        "",
        window.location.pathname + window.location.search + window.location.hash,
      );
    }

    var filters = activeTraceMapFilters();
    var parts = [];
    ["endpoint", "level", "source"].forEach(function (dimension) {
      var values = filters[dimension];
      if (values && values.length > 0) {
        var encoded = values.map(encodeURIComponent).join(",");
        parts.push(dimension + "=" + encoded);
      }
    });

    var query = parts.length > 0 ? "?" + parts.join("&") : "";
    var newUrl = window.location.pathname + query + window.location.hash;
    if (newUrl !== window.location.pathname + window.location.search + window.location.hash) {
      window.history.pushState({ nebuTraceMapFilters: true }, "", newUrl);
      syncLiveSocketHref(newUrl);
    }
  }

  // V7 fix (real-browser verification against the actual running dev stack —
  // caught a SECOND, distinct variant of the original bug, not covered by
  // any unit test): this admin UI's LiveSocket is configured with a FORCED
  // `ThrottledLongPoll` transport (see this file's own `boot()`, `new
  // LiveSocket("/admin/live", Socket, { transport: ThrottledLongPoll, ... })`)
  // — NOT a WebSocket-with-longpoll-fallback. Long-polling periodically
  // re-joins its underlying Phoenix Channel (confirmed empirically: a fresh
  // `mount:` diff appears in the browser console a few seconds after every
  // connect, with no user action). Phoenix.LiveView's OWN channel-join
  // payload builder reads `view.href` (cached on the View instance, NOT
  // re-read from `window.location.href` on every join — see
  // `deps/phoenix_live_view/priv/static/phoenix_live_view.cjs.js`'s `View`
  // class: `this.channel = this.liveSocket.channel(topic, () => ({ url:
  // this.href && this.expandURL(this.href), ... }))`). That cached `href` is
  // set ONCE at initial page load (`view.setHref(this.getHref())`) and is
  // ONLY ever updated again through LiveView's OWN internal push-patch flow
  // (`commitPendingLink`) — which requires a real `handle_params/3` server
  // round trip, the exact mechanism this story's Dev Notes evaluated FIRST
  // and rejected (see `bubble_js/2`'s comment in `logs_live.ex`). A bare
    // `history.pushState` (this file's `syncTraceMapUrlFromBubbles`, above)
  // updates the BROWSER's address bar just fine, but never touches this
  // cached `view.href` — so the NEXT long-poll rejoin sent the STALE,
  // pre-click URL as its join `url:` param, `mount/3` re-derived an EMPTY
  // `@active_filters` from it, and the filter silently reset — a NEW
  // variant of the EXACT bug this story exists to fix, invisible to
  // `Phoenix.LiveViewTest` (no real transport, no rejoin) and only caught by
  // testing against the real, running dev stack as instructed.
  //
  // Fix: directly keep the LiveSocket's and the main View's own internal
  // `href` caches in sync with our own URL updates. `window.liveSocket` is
  // already exposed globally by this file's `boot()`. These are marked
  // `@internal` in Phoenix LiveView's own source (no public API exists for
  // "tell the client the URL changed without a server round trip") — a
  // deliberate, narrowly-scoped, defensively-guarded use of an internal
  // field, chosen after confirming (via the real dependency's source, not
  // guesswork) that no supported alternative achieves a purely client-side
  // URL sync.
  function syncLiveSocketHref(newUrl) {
    var socket = window.liveSocket;
    if (!socket) return;

    var absoluteHref = window.location.origin + newUrl;
    if (typeof socket.href === "string") {
      socket.href = absoluteHref;
    }
    if (socket.main && typeof socket.main.setHref === "function") {
      socket.main.setHref(absoluteHref);
    }

    // V8 fix (real-browser verification): `LiveSocket` ALSO caches
    // `currentLocation` (separately from `href`, above) — its OWN "popstate"
    // listener (bound once, at boot, alongside ours) short-circuits as a
    // total no-op whenever `registerNewLocation(window.location)` reports
    // "unchanged" by comparing `window.location` against THIS cached value.
    // Since our raw `pushState` never touches it, `currentLocation` stayed
    // frozen at whatever the page's TRUE first load was — so navigating
    // "back" to that exact original URL (a very common case: click once,
    // then go back) was wrongly seen as "the URL didn't change", and
    // LiveView's own fallback re-mount (`replaceMain`, its documented
    // answer for a non-"patch" popstate) never ran at all, leaving the
    // stale, still-pressed bubble on screen. Calling the same
    // `registerNewLocation` method LiveView's own code calls after every
    // one of ITS OWN navigations keeps this cache honest too.
    if (typeof socket.registerNewLocation === "function") {
      socket.registerNewLocation(window.location);
    }
  }

  // Companion to `syncTraceMapUrlFromBubbles` — re-derives EVERY bubble's
  // aria-pressed/class state FROM the page's current URL query string
  // (AC3's browser back/forward requirement). Used both by the
  // `popstate` listener below (back/forward navigation) and safe to call
  // at any time since it fully recomputes state rather than toggling.
  //
  // dev-story cycle 1, code-review MAJOR finding M1: a dimension's query
  // param is a comma-joined list of values (see `syncTraceMapUrlFromBubbles`
  // above) — a bubble is pressed if its OWN value appears ANYWHERE in that
  // list, not only if it equals the whole (previously single-valued)
  // param string.
  function applyTraceMapFiltersFromUrl() {
    var search = window.location.search || "";
    var params = new URLSearchParams(search);

    var bubbles = document.querySelectorAll('[data-testid="trace-map-bubble"]');
    Array.prototype.forEach.call(bubbles, function (bubble) {
      var dimension = bubble.dataset.bubbleDimension;
      var value = bubble.dataset.bubbleValue;
      if (!dimension) return;

      var urlValues = (params.get(dimension) || "").split(",").filter(function (v) {
        return v !== "";
      });
      var pressed = bubble.dataset.bubbleOff !== "true" && urlValues.indexOf(value) !== -1;
      bubble.setAttribute("aria-pressed", pressed ? "true" : "false");
      setBubbleActiveClasses(bubble, pressed);
    });

    applyTraceMapFilters();
  }

  // Bug fix (trace-map-filter-reset-bugfix, AC3 popstate-sync fix,
  // code-review finding): `applyTraceMapFiltersFromUrl`, above, only ever
  // updates the DOM (aria-pressed/CSS classes/row visibility) — it never
  // told the SERVER that a back/forward navigation changed which filters
  // are active. `logs_live.ex`'s `@active_filters` assign (the actual
  // source of truth every bubble re-renders `active:` from, per
  // `toggle_filter`/`remove_filter` above) stayed stale after a "back",
  // so the NEXT server-triggered re-render (e.g. a new log entry bumping
  // an unrelated bubble's count) silently re-asserted the STALE
  // pre-navigation filter state over the just-restored, correct DOM/URL
  // state — reintroducing this story's exact bug via the back/forward
  // path instead of a plain click.
  //
  // Called from the `popstate` listener below, right after
  // `applyTraceMapFiltersFromUrl` has re-derived the DOM: reads the SAME
  // now-current URL query params and pushes them to the server as a
  // `handle_event("sync_filters", %{"filters" => %{...}}, socket)` round
  // trip that replaces `@active_filters` wholesale (see that clause's own
  // comment in `logs_live.ex` for why "wholesale replace", not a
  // per-dimension toggle).
  //
  // Uses `liveSocket.main.pushEvent(...)` directly rather than a
  // `phx-click`/`JS.push` command list (as every OTHER filter interaction
  // in this file does): there is no clicked element here — this is a
  // synthetic, popstate-driven update — and no public LiveView JS API
  // exists to push a plain event without either a bound element or a
  // `phx-hook`. `View.pushEvent(type, el, targetCtx, phxEvent, meta, opts,
  // onReply)` is exactly what `Phoenix.LiveView.JS.push/2` itself calls
  // under the hood for a real click (see
  // `deps/phoenix_live_view/assets/js/phoenix_live_view/js.js`'s
  // `exec_push`) — this is the same `@internal`-but-stable-shaped surface
  // `syncLiveSocketHref`, above, already uses and justifies for the
  // identical reason (no supported alternative achieves a purely
  // client-side-triggered server update).
  //
  // dev-story cycle 1, code-review MAJOR finding M2 (real crash bug): this
  // function is invoked from a WINDOW-level `popstate` listener bound ONCE
  // at boot (see `wireTraceMapFilters` below), unconditionally, regardless
  // of which LiveView happens to be currently mounted. `DashboardLive`/
  // `AuditLogLive` share the same `live_session :admin` as `LogsLive` but
  // define no `handle_event/3` clause at all (Phoenix LiveView injects no
  // default handler) — landing on `/admin/logs` (binding this listener at
  // boot), live-navigating to `/admin/dashboard`, then pressing browser
  // Back used to push `sync_filters` into whatever LiveView was mounted,
  // crashing it with `UndefinedFunctionError`. Fixed by requiring the
  // dedicated `#trace-map-sync-anchor` marker (see `logs_live.ex`'s
  // `render/1`) to be present in the DOM before pushing anything at all —
  // that marker only exists while `LogsLive` (the one LiveView that
  // actually owns the Trace Map / `handle_event("sync_filters", ...)`) is
  // mounted, so a `popstate` firing while a sibling LiveView is mounted
  // instead is now a safe no-op.
  //
  // dev-story cycle 1, code-review MINOR finding (blast radius): the SAME
  // marker element also replaces `document.body` as the `pushEvent`
  // target — `document.body` set a PAGE-WIDE `data-phx-ref-lock` during
  // the round trip (blocking LiveView patches to the WHOLE page, not just
  // the Trace Map, e.g. the `new-entries-banner` aria-live region), while
  // this tiny, dedicated, hidden element confines the lock to itself.
  //
  // dev-story cycle 1, code-review MAJOR finding M1: sends the FULL list
  // of active values per dimension (mirrors `syncTraceMapUrlFromBubbles`'s
  // own comma-joined URL encoding, split back into an array here), not a
  // single scalar — `logs_live.ex`'s `handle_event("sync_filters", ...)`
  // now stores real lists per dimension, matching this file's own
  // multi-select-within-a-dimension semantics.
  function pushFilterSyncToServer() {
    var socket = window.liveSocket;
    var anchor = document.getElementById("trace-map-sync-anchor");
    if (!socket || !socket.main || typeof socket.main.pushEvent !== "function" || !anchor) {
      return;
    }

    var params = new URLSearchParams(window.location.search || "");
    var filters = {};
    ["endpoint", "level", "source"].forEach(function (dimension) {
      var raw = params.get(dimension) || "";
      filters[dimension] = raw
        ? raw.split(",").filter(function (v) {
            return v !== "";
          })
        : [];
    });

    socket.main.pushEvent("click", anchor, null, "sync_filters", null, {
      value: { filters: filters },
    });
  }

  function wireTraceMapFilters() {
    if (window.__nebuTraceMapWired) return;
    window.__nebuTraceMapWired = true;

    document.addEventListener("nebu:trace-bubble-click", function (event) {
      var bubble = event.target;
      if (!bubble || !bubble.dataset) return;

      // AC2: clicking an "off" (uncollected) bubble never activates a filter —
      // it represents a structural absence, not a toggleable dimension value.
      if (bubble.dataset.bubbleOff === "true") return;

      var pressed = bubble.getAttribute("aria-pressed") === "true";
      var nowPressed = !pressed;
      bubble.setAttribute("aria-pressed", nowPressed ? "true" : "false");
      setBubbleActiveClasses(bubble, nowPressed);
      applyTraceMapFilters();
      syncTraceMapUrlFromBubbles();
    });

    // The active-filter chip row's own "×" remove control (AC4) — a DISTINCT
    // interaction from re-clicking the bubble, but it must deactivate the
    // SAME bubble so both stay in lockstep.
    document.addEventListener("nebu:trace-chip-remove", function (event) {
      var button = event.target;
      if (!button || !button.dataset) return;

      var dimension = button.dataset.chipDimension;
      var value = button.dataset.chipValue;
      if (dimension && value) {
        var selector =
          '[data-testid="trace-map-bubble"][data-bubble-dimension="' +
          dimension +
          '"][data-bubble-value="' +
          value +
          '"]';
        var bubble = document.querySelector(selector);
        if (bubble) {
          bubble.setAttribute("aria-pressed", "false");
          setBubbleActiveClasses(bubble, false);
        }
      }

      applyTraceMapFilters();
      syncTraceMapUrlFromBubbles();
    });

    // AC8: copy the full chronological thread to the clipboard for support hand-off.
    document.addEventListener("nebu:copy-thread", function (event) {
      var button = event.target;
      var text = button && button.dataset ? button.dataset.copyText : "";
      if (text && navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(function () {
          // Best-effort — clipboard permissions can be denied by the browser;
          // no user-visible error surface exists for this secondary action.
        });
      }
    });

    // Bug fix (trace-map-filter-reset-bugfix, AC3): browser back/forward
    // navigation fires `popstate` (NOT a page reload, since
    // `syncTraceMapUrlFromBubbles` only ever uses `pushState`) — re-derive
    // every bubble's pressed state from the now-current URL and reapply
    // row/chip visibility to match.
    window.addEventListener("popstate", function () {
      applyTraceMapFiltersFromUrl();
      pushFilterSyncToServer();
    });

    // Run once at load so any server-rendered "off" state / initial counts are
    // reflected immediately, even before the first click.
    applyTraceMapFilters();

    wireTraceMapRowObserver();
  }

  // V6 fix (UX re-verification pass, cycle 3): `applyTraceMapFilters()` was only
  // ever re-run on a bubble click, a chip-remove click, and once at boot — never
  // when the `#request-rows` stream container itself gained new children. AC9/
  // AC11 stream new/updated rows in via `Phoenix.LiveView.stream_insert/4` (see
  // `logs_live.ex`'s `upsert_row/2`) entirely independently of any click, so a
  // row that streams in while a filter is active rendered fully visible —
  // silently bypassing the active filter (AC3 says filters apply to "the
  // already-loaded/streaming rows in the browser"; that's the "streaming" half
  // this was missing).
  //
  // M1 fix (bug-fix cycle 5, code-review MAJOR finding): the cycle-3 fix above
  // only wired this observer directly onto `document.getElementById("request-rows")`
  // AND ONLY IF that element already existed at the moment `wireTraceMapFilters()`
  // ran (once, from `boot()`, on `DOMContentLoaded`). `router.ex` places
  // `DashboardLive`/`AuditLogLive`/`LogsLive` all inside the SAME `live_session
  // :admin` block, and `layouts.ex`'s sidebar uses `<.link navigate="...">`
  // between them — Phoenix LiveView "live navigation" between LiveViews in the
  // same live_session does NOT reload the page, so `DOMContentLoaded` never
  // fires again and `#request-rows` (which only exists on `/admin/logs`) was
  // never present yet for any tab whose initial full page load landed on
  // Dashboard or AuditLog first (the common case). The observer was then
  // permanently never wired for that tab, even after navigating into
  // `/admin/logs` — silently reintroducing the cycle-3 bug for the normal
  // navigation path.
  //
  // Fixed by observing `document.body` (present at boot, exactly like
  // `wireDetailPanelFocus`'s (V4) own `document.body` observer just below —
  // that function already established this precedent for the identical "this
  // container doesn't necessarily exist yet, and/or LiveView live-navigation
  // never re-fires DOMContentLoaded" problem) instead of the by-id
  // `#request-rows` container directly. This makes the wiring:
  //   - container-existence-agnostic: no early-return if `#request-rows`
  //     isn't in the DOM yet at boot time.
  //   - live-navigation-agnostic: `#request-rows` appearing in the DOM
  //     *because the operator just live-navigated into `/admin/logs`* is
  //     itself a `childList` mutation on `document.body`'s subtree, so it is
  //     observed identically to any other row/tier-migration mutation — no
  //     separate LiveSocket/`phx:navigate` lifecycle hook is needed.
  //
  // `applyTraceMapFilters()` is idempotent (it recomputes visibility for every
  // row from scratch on every call, and no-ops when `[data-testid="request-row"]`
  // / `[data-testid="trace-map-bubble"]` simply don't exist yet, e.g. while on
  // Dashboard/AuditLog) so simply re-running it on ANY body-subtree mutation
  // with added nodes is safe and correct. This covers ALL of the following
  // identically, with no special-casing:
  //   - live-navigating into `/admin/logs` for the first time in a tab
  //     (`#request-rows` and its initial rows appear as a body-subtree
  //     mutation)
  //   - a genuinely new `request_id` -> `stream_insert/4` appends a new node
  //     (a `childList` mutation with an added node)
  //   - an existing row whose severity tier changed -> `stream_delete_by_dom_id/3`
  //     followed by `stream_insert/4` at the new index, which removes the old
  //     DOM node (wiping its previously-applied `display:none`) and inserts a
  //     FRESH one in its place (also a `childList` mutation with an added node)
  function wireTraceMapRowObserver() {
    if (window.__nebuTraceMapRowObserverWired) return;
    window.__nebuTraceMapRowObserverWired = true;

    var observer = new MutationObserver(function (mutations) {
      var rowsChanged = mutations.some(function (mutation) {
        return mutation.addedNodes && mutation.addedNodes.length > 0;
      });
      if (rowsChanged) applyTraceMapFilters();
    });

    observer.observe(document.body, { childList: true, subtree: true });
  }

  // V4 fix (UX/accessibility gate, BLOCKING — WCAG 2.4.3): `detail_panel.ex`'s
  // `role="dialog"` had no focus management at all — opening it never moved
  // focus in, and closing it never returned focus to the row that opened it,
  // silently stranding a keyboard/screen-reader user's focus wherever it
  // happened to be (often on a now-detached/hidden element). This uses a
  // single `MutationObserver` on `document.body` (LiveView patches the DOM
  // via morphdom, not by replacing this file's own listeners, so one
  // observer set up once at boot survives every subsequent live update) to
  // detect the panel appearing/disappearing:
  //   - appears  -> focus moves to its first interactive control (the
  //     "Copy thread" button)
  //   - disappears -> focus returns to the request-row `<button>` that most
  //     recently opened a panel (tracked via a delegated click listener,
  //     since `data-testid="request-row"` is the only server-rendered hook
  //     identifying "what was clicked to open this")
  //
  // NOTE (documented per the fix brief): this does NOT implement a full
  // Tab/Shift+Tab focus TRAP. See detail_panel.ex's moduledoc for the
  // rationale — only focus-in-on-open and focus-return-on-close are done.
  var detailPanelFocusState = { open: false, trigger: null };

  function wireDetailPanelFocus() {
    if (window.__nebuDetailPanelFocusWired) return;
    window.__nebuDetailPanelFocusWired = true;

    document.addEventListener("click", function (event) {
      var trigger =
        event.target &&
        typeof event.target.closest === "function" &&
        event.target.closest('[data-testid="request-row"]');
      if (trigger) detailPanelFocusState.trigger = trigger;
    });

    var observer = new MutationObserver(function () {
      var panel = document.querySelector('[data-testid="detail-panel"]');

      if (panel && !detailPanelFocusState.open) {
        detailPanelFocusState.open = true;
        var focusTarget =
          panel.querySelector('[data-testid="copy-thread-button"]') ||
          panel.querySelector("button");
        if (focusTarget) focusTarget.focus();
      } else if (!panel && detailPanelFocusState.open) {
        detailPanelFocusState.open = false;
        var trigger = detailPanelFocusState.trigger;
        detailPanelFocusState.trigger = null;
        if (trigger && document.body.contains(trigger)) trigger.focus();
      }
    });

    observer.observe(document.body, { childList: true, subtree: true });
  }

  // V5(b) fix (UX/accessibility gate, BLOCKING): AC10 ("if the user has
  // scrolled down... new rows arrive silently... with an optional 'resume
  // live updates' button") had a real `handle_event("pause_live_updates",
  // ...)` clause server-side but nothing anywhere ever triggered it — the
  // pause path was dead code. The actual admin-page scroll container is
  // `#main-content` (`Nebu.Admin.Layouts.root/1`'s `<main
  // id="main-content" class="... overflow-auto ...">`), NOT
  // `#request-rows` (which has no `overflow`/`max-height` of its own and
  // therefore never itself scrolls). Once the operator scrolls that
  // container away from the top, this clicks the hidden, real
  // `phx-click="pause_live_updates"` button LogsLive renders
  // (`[data-testid="pause-live-updates-trigger"]`) — a genuine DOM click on
  // an element carrying `phx-click` is exactly what LiveView's own
  // click-delegation listens for, so this reuses the EXISTING server
  // `handle_event` clause rather than inventing a parallel client-only pause
  // mechanism. (AC8 already pauses server-side directly when a detail row is
  // opened — see `handle_event("open_detail", ...)` in logs_live.ex — no JS
  // needed for that half of the trigger.) The "Resume live updates" button
  // was already wired to a real `phx-click="resume_live_updates"`; clicking
  // it here just resets this file's own "already triggered" guard so a
  // later scroll-away can re-trigger the pause.
  function wireLiveUpdatesPause() {
    if (window.__nebuLiveUpdatesPauseWired) return;
    window.__nebuLiveUpdatesPauseWired = true;

    var pauseTriggered = false;

    document.addEventListener(
      "scroll",
      function (event) {
        var container = event.target;
        if (!container || container.id !== "main-content") return;
        if (pauseTriggered || container.scrollTop <= 0) return;

        var pauseButton = document.querySelector(
          '[data-testid="pause-live-updates-trigger"]',
        );
        if (!pauseButton) return;

        pauseTriggered = true;
        pauseButton.click();
      },
      true,
    );

    document.addEventListener("click", function (event) {
      var resumeButton =
        event.target &&
        typeof event.target.closest === "function" &&
        event.target.closest('button[phx-click="resume_live_updates"]');
      if (resumeButton) pauseTriggered = false;
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

  // enhanced-logging/war-room-dedicated-page (amendment 4): ticks the
  // topbar recording pill's mm:ss elapsed clock every second, purely
  // client-side from its own `data-started-at` (unix seconds) — mirrors
  // `traceMapTickWarRoomClock`'s identical mechanism for the Trace Map
  // page's own war-room banner, but wired as its OWN small hook (rather
  // than depending on the TraceMapLeitstand hook, which only mounts on the
  // /admin/logs/trace-map page) since `Nebu.Admin.Layouts` renders the pill
  // on every admin page. CSP: no inline JS, a plain interval reading a
  // data attribute.
  var WarRoomPill = {
    mounted: function () {
      this.tick();
      this.timer = setInterval(this.tick.bind(this), 1000);
    },
    updated: function () {
      this.tick();
    },
    destroyed: function () {
      if (this.timer) clearInterval(this.timer);
    },
    tick: function () {
      var clock = this.el.querySelector('[data-testid="topbar-war-room-pill-clock"]');
      if (!clock) return;
      var startedAt = parseInt(this.el.getAttribute("data-started-at"), 10);
      if (!startedAt) return;

      var total = Math.max(0, Math.floor(Date.now() / 1000) - startedAt);
      var minutes = Math.floor(total / 60);
      var seconds = total % 60;
      var pad = function (n) {
        return String(n).padStart(2, "0");
      };
      clock.textContent = pad(minutes) + ":" + pad(seconds);
    },
  };

  // enhanced-logging/admin-logs-retention-settings (AC7/AC8/AC11): the
  // /admin/logs/config page is a plain (dead) controller render — no
  // LiveView socket exists there — so the reused-for-visual-styling bubble
  // buttons' interactivity (click-to-toggle a level, reveal/hide its inline
  // retention fields, show/hide the DEBUG excessive-logging warning) is
  // implemented entirely here, following the exact same delegated-listener,
  // CSP-safe pattern as `wireConfirmForms`/`wireUserAutocomplete` above (the
  // admin CSP is `script-src 'self'`, no `unsafe-inline` — no inline
  // `onclick=` is possible on that page either).
  //
  // Data-attribute contract (see design-decisions.md #4c and
  // test-review-findings.md — pinned down for the Playwright e2e suite,
  // `e2e/features/admin/logs-config.feature`):
  //   - Bubble: [data-testid="trace-map-bubble"][data-bubble-dimension="level"][data-bubble-value="info"|"debug"]
  //     (WARN/ERROR bubbles are non-interactive <div>s with no click handler)
  //   - Retention fields container: [data-testid="retention-fields"][data-bubble-value="info"|"debug"],
  //     containing input[name="info_days"|"debug_days"] and
  //     input[name="info_max_entries"|"debug_max_entries"]
  //   - DEBUG warning: [data-testid="debug-warning"]
  //   - Hidden enabled-state input: [data-testid="info-enabled-input"|"debug-enabled-input"]
  //
  // AC8: the FIRST time a level is toggled ON in this page's lifetime (i.e.
  // the retention-fields node does not already exist for it — it was
  // server-rendered absent because the level was off on load), the newly
  // created fields are pre-populated with the sensible defaults (7 days /
  // 1000 max entries). Toggling off then back on again within the SAME page
  // load reuses whatever the operator already typed (the node is hidden,
  // not destroyed, once created) — only a genuinely fresh page load can
  // reset back to "no node yet".
  var LOGS_CONFIG_DEFAULT_DAYS = "7";
  var LOGS_CONFIG_DEFAULT_MAX_ENTRIES = "1000";

  var DEBUG_WARNING_TEXT =
    "⚠️ DEBUG logging captures HTTP request/response payloads, including full " +
    "message content (redacted per policy, but even redacted payloads are large). This " +
    "endpoint is called continuously by every connected client. Enabling unbounded " +
    "collection could rapidly fill the database. Consider using War Room mode (see " +
    "settings below) for a bounded time/count capture instead of leaving DEBUG on " +
    "indefinitely.";

  function logsConfigBubble(level) {
    return document.querySelector(
      '[data-testid="trace-map-bubble"][data-bubble-dimension="level"][data-bubble-value="' +
        level +
        '"]',
    );
  }

  function logsConfigRetentionFields(level) {
    return document.querySelector(
      '[data-testid="retention-fields"][data-bubble-value="' + level + '"]',
    );
  }

  function buildRetentionFields(level) {
    var container = document.createElement("div");
    container.id = level + "-retention-fields";
    container.setAttribute("data-testid", "retention-fields");
    container.setAttribute("data-bubble-value", level);
    container.className = "mb-4 flex flex-wrap gap-4 items-end";

    container.appendChild(
      buildRetentionLabel(
        "Retention: days",
        level + "_days",
        LOGS_CONFIG_DEFAULT_DAYS,
        "0",
        "90",
        level.toUpperCase() + " retention days",
      ),
    );
    container.appendChild(
      buildRetentionLabel(
        "Retention: max entries",
        level + "_max_entries",
        LOGS_CONFIG_DEFAULT_MAX_ENTRIES,
        "0",
        "10000",
        level.toUpperCase() + " retention max entries",
      ),
    );

    return container;
  }

  function buildRetentionLabel(labelText, name, value, min, max, ariaLabel) {
    var label = document.createElement("label");
    label.className = "form-control";

    var span = document.createElement("span");
    span.className = "label-text";
    span.textContent = labelText;
    label.appendChild(span);

    var input = document.createElement("input");
    input.type = "number";
    input.name = name;
    input.value = value;
    input.placeholder = "Leave blank for no limit";
    input.setAttribute("aria-label", ariaLabel);
    input.min = min;
    input.max = max;
    input.className = "input input-bordered input-sm";
    label.appendChild(input);

    return label;
  }

  // UX-gate advisory fix: role="status" (not "alert") — contextual
  // guidance, not an urgent/interrupting error condition. Matches the
  // server-rendered template and the codebase's own convention (role="alert"
  // reserved for actual error flashes).
  function buildDebugWarning() {
    var container = document.createElement("div");
    container.id = "debug-warning";
    container.setAttribute("data-testid", "debug-warning");
    container.className = "alert alert-warning mb-4 max-w-2xl";
    container.setAttribute("role", "status");

    var p = document.createElement("p");
    p.textContent = DEBUG_WARNING_TEXT;
    container.appendChild(p);

    return container;
  }

  // UX-gate blocking fix: also toggles `aria-expanded` (paired with the
  // `aria-controls` attribute already present on the button in the
  // server-rendered HTML) so assistive tech has an explicit, standard
  // signal that this button expands/collapses a controlled region — not
  // just a bare pressed-state change.
  function setLogsConfigBubblePressed(bubble, pressed) {
    bubble.setAttribute("aria-pressed", pressed ? "true" : "false");
    bubble.setAttribute("aria-expanded", pressed ? "true" : "false");
    if (pressed) {
      bubble.classList.add("btn-active");
    } else {
      bubble.classList.remove("btn-active");
    }
  }

  function toggleLogsConfigLevel(level) {
    var bubble = logsConfigBubble(level);
    if (!bubble) return;

    var hiddenInput = document.querySelector(
      '[data-testid="' + level + '-enabled-input"]',
    );

    var wasPressed = bubble.getAttribute("aria-pressed") === "true";
    var nowPressed = !wasPressed;

    setLogsConfigBubblePressed(bubble, nowPressed);
    if (hiddenInput) hiddenInput.value = nowPressed ? "true" : "false";

    var fields = logsConfigRetentionFields(level);

    // UX-gate blocking fix: insert newly-created nodes INSIDE the
    // always-present `aria-live="polite"` wrapper the server template
    // renders for this level (`#<level>-retention-live`) — not merely
    // "afterend" of the hidden input — so a screen reader actually
    // announces the mutation (a live region only fires for changes to
    // content already inside it, not for the wrapper itself appearing).
    var liveRegion = document.getElementById(level + "-retention-live");

    if (nowPressed) {
      if (!fields) {
        fields = buildRetentionFields(level);
        if (liveRegion) {
          liveRegion.appendChild(fields);
        } else {
          // Defensive fallback if the live-region wrapper is ever missing
          // (should not happen with the current template) — still mirrors
          // the server-rendered position, just without the live-region
          // announcement benefit.
          (hiddenInput || bubble).insertAdjacentElement("afterend", fields);
        }
      } else {
        fields.style.display = "";
      }
    } else if (fields) {
      fields.style.display = "none";
    }

    if (level === "debug") {
      var warning = document.querySelector('[data-testid="debug-warning"]');
      if (nowPressed) {
        if (!warning) {
          warning = buildDebugWarning();
          if (liveRegion) {
            liveRegion.appendChild(warning);
          } else {
            fields.insertAdjacentElement("afterend", warning);
          }
        } else {
          warning.style.display = "";
        }
      } else if (warning) {
        warning.style.display = "none";
      }
    }
  }

  function wireLogsConfigToggles() {
    if (window.__nebuLogsConfigWired) return;
    window.__nebuLogsConfigWired = true;

    document.addEventListener(
      "click",
      function (event) {
        var bubble = event.target.closest
          ? event.target.closest(
              '[data-testid="trace-map-bubble"][data-bubble-dimension="level"]',
            )
          : null;
        if (!bubble) return;
        // WARN/ERROR bubbles are non-interactive <div>s (AC6) — nothing to
        // wire for them; only INFO/DEBUG are real <button>s here.
        if (bubble.tagName.toLowerCase() !== "button") return;

        var level = bubble.getAttribute("data-bubble-value");
        if (level !== "info" && level !== "debug") return;

        toggleLogsConfigLevel(level);
      },
      true,
    );
  }

  // enhanced-logging/war-room-mode (AC7/AC8): both warning blocks are
  // ALWAYS present in the server-rendered War Room start form
  // (`style="display:none"` by default — see
  // Nebu.Admin.LogsLive.WarRoomPanel's moduledoc), toggled here based on
  // the scope <select>'s current value. Mirrors wireLogsConfigToggles()'s
  // exact CSP-`script-src 'self'`-compliant pattern (no inline <script>).
  function wireWarRoomPanel() {
    if (window.__nebuWarRoomWired) return;
    window.__nebuWarRoomWired = true;

    document.addEventListener("change", function (event) {
      var select = event.target.closest
        ? event.target.closest(
            '[data-testid="war-room-start-form"] select[name="scope"]',
          )
        : null;
      if (!select) return;

      var warningAll = document.querySelector('[data-testid="war-room-warning-all"]');
      var warningSync = document.querySelector('[data-testid="war-room-warning-sync"]');

      // code-review MINOR-1 (war-room-mode, cycle 1): the default/empty ""
      // select value (the "-- select scope --" placeholder option) is the
      // SAME null-scope case as an explicit "all" per AC7/AC3 (Dev Notes:
      // "NULL, treated as 'all'") — the broadest, most dangerous case
      // (collecting everything). Treat "" identically to "all" here so an
      // operator who never touches the dropdown still sees the warning
      // once they interact with the form at all.
      if (select.value === "all" || select.value === "") {
        if (warningAll) warningAll.style.display = "";
        if (warningSync) warningSync.style.display = "none";
      } else if (select.value === "/_matrix/client/v3/sync") {
        if (warningAll) warningAll.style.display = "none";
        if (warningSync) warningSync.style.display = "";
      } else {
        if (warningAll) warningAll.style.display = "none";
        if (warningSync) warningSync.style.display = "none";
      }
    });
  }

  // enhanced-logging/trace-map-leitstand (AC7/AC9/AC10/AC11): all client-only
  // behavior for the /admin/logs/trace-map Leitstand page, wired as a single
  // phx-hook on the page's root element (CSP is `script-src 'self'` — no
  // inline JS anywhere; every listener below is added via addEventListener
  // from this external file):
  //   - Enter/Space keyboard activation for the SVG map nodes (AC10 — an SVG
  //     <g role="button" tabindex="0"> has NO native keyboard activation, so
  //     keydown is translated into the same bubbling click phx-click handles)
  //   - tooltip show/hide/positioning on hover + focus (AC7 — content comes
  //     from the server-rendered data-tooltip-* attributes; positioned to
  //     stay inside the map area; hides on click/Escape/blur/mouse-out)
  //   - stream-panel resizer (AC9 — pointer drag with capture, ArrowUp/Down
  //     ±32px, Home=minimize / End=maximize the stream per the e2e contract
  //     in logs-trace-map.feature Scenario 9, dblclick resets to 218px,
  //     clamped 64px … column-height−140px)
  //   - stream autoscroll (new lines pin to the bottom unless the operator
  //     is hovering/focusing the stream — AC9's "autoscroll pauses" rule)
  //   - war-room banner elapsed clock (AC6 — ticks the server-rendered
  //     mm:ss text every second from data-started-at)
  //   - decorative status-transition pings (AC11 — elements are created
  //     here, but the animation itself is pure CSS @keyframes; skipped
  //     entirely under prefers-reduced-motion)
  var TRACE_MAP_DEFAULT_STREAM_H = 218;
  var TRACE_MAP_RESIZE_STEP = 32;
  var TRACE_MAP_MIN_STREAM_H = 64;
  var SVG_NS = "http://www.w3.org/2000/svg";

  // enhanced-logging/trace-map-zoom-pan (AC1-AC9): map-app-style zoom/pan.
  // Zoom is a scalar (1.0 = default/fit, 4.0 = max); pan is tracked as an
  // offset (panX, panY) added to the server-rendered viewBox's own top-left
  // corner — at zoom=1.0 the clamp below collapses pan to exactly (0, 0),
  // which is what makes "minimum zoom shows the full viewBox without being
  // forced to pan" (AC3) fall out of the formula for free, and is also why
  // resetZoomPan (zoom=1.0, panX=0, panY=0) always reproduces the EXACT
  // server-rendered default viewBox byte-for-byte (AC4/AC9).
  var TRACE_MAP_MIN_ZOOM = 1.0;
  var TRACE_MAP_MAX_ZOOM = 4.0;
  var TRACE_MAP_ZOOM_STEP = 0.1;
  var TRACE_MAP_PAN_STEP = 32;
  var TRACE_MAP_VIEWBOX_X = -780;
  var TRACE_MAP_VIEWBOX_Y = -650;
  var TRACE_MAP_VIEWBOX_W = 1560;
  var TRACE_MAP_VIEWBOX_H = 1300;

  function traceMapClampZoom(zoom) {
    return Math.max(TRACE_MAP_MIN_ZOOM, Math.min(TRACE_MAP_MAX_ZOOM, zoom));
  }

  // AC3: pan is clamped so the map can never be panned so far the whole
  // layout leaves the viewport — px ∈ [0, 1560 - 1560/zoom],
  // py ∈ [0, 1300 - 1300/zoom] against the server's own viewBox dimensions.
  function traceMapClampPan(zoom, panX, panY) {
    var maxPanX = TRACE_MAP_VIEWBOX_W - TRACE_MAP_VIEWBOX_W / zoom;
    var maxPanY = TRACE_MAP_VIEWBOX_H - TRACE_MAP_VIEWBOX_H / zoom;
    return {
      x: Math.max(0, Math.min(maxPanX, panX)),
      y: Math.max(0, Math.min(maxPanY, panY)),
    };
  }

  function traceMapViewBoxString(zoom, panX, panY) {
    var w = TRACE_MAP_VIEWBOX_W / zoom;
    var h = TRACE_MAP_VIEWBOX_H / zoom;
    var x = TRACE_MAP_VIEWBOX_X + panX;
    var y = TRACE_MAP_VIEWBOX_Y + panY;
    return x + " " + y + " " + w + " " + h;
  }

  var TraceMapLeitstand = {
    mounted: function () {
      var self = this;
      this.nodeStatusCache = traceMapReadStatuses(this.el);

      // Readiness marker for the Playwright suite (logs-trace-map.steps.ts's
      // awaitLeitstandReady): every LiveView-backed interaction on this page
      // (phx-click, Enter/Space activation, resizer, tooltip) only works once
      // the LiveSocket has connected and this hook has mounted -- the admin UI
      // uses a throttled LONGPOLL transport, so that happens a few seconds
      // after first paint. A window property (not a DOM attribute) so
      // LiveView's DOM patching can never sweep it away.
      window.__nebuTraceMapHookReady = true;

      // ── AC10: Enter/Space activates the focused SVG node ──────────────
      this.onNodeKeydown = function (event) {
        if (event.key !== "Enter" && event.key !== " " && event.key !== "Spacebar") return;
        var node = event.target.closest
          ? event.target.closest('[data-testid="trace-map-node"]')
          : null;
        if (!node) return;
        event.preventDefault();
        traceMapHideTooltip(self.el);
        node.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      };
      this.el.addEventListener("keydown", this.onNodeKeydown);

      // ── AC7: tooltip on hover + focus ──────────────────────────────────
      this.onPointerOver = function (event) {
        var node = event.target.closest
          ? event.target.closest('[data-testid="trace-map-node"]')
          : null;
        if (node) traceMapShowTooltip(self.el, node);
      };
      this.onPointerOut = function (event) {
        var node = event.target.closest
          ? event.target.closest('[data-testid="trace-map-node"]')
          : null;
        if (node) traceMapHideTooltip(self.el);
      };
      this.onFocusIn = function (event) {
        var node = event.target.closest
          ? event.target.closest('[data-testid="trace-map-node"]')
          : null;
        if (node) traceMapShowTooltip(self.el, node);
      };
      this.onFocusOut = function (event) {
        var node = event.target.closest
          ? event.target.closest('[data-testid="trace-map-node"]')
          : null;
        if (node) traceMapHideTooltip(self.el);
      };
      // AC7: "tooltip hides on click"; Escape hides it too (keyboard parity).
      this.onClick = function (event) {
        var node = event.target.closest
          ? event.target.closest('[data-testid="trace-map-node"]')
          : null;
        if (node) traceMapHideTooltip(self.el);
      };
      this.onEscape = function (event) {
        if (event.key === "Escape") traceMapHideTooltip(self.el);
      };
      this.el.addEventListener("pointerover", this.onPointerOver);
      this.el.addEventListener("pointerout", this.onPointerOut);
      this.el.addEventListener("focusin", this.onFocusIn);
      this.el.addEventListener("focusout", this.onFocusOut);
      this.el.addEventListener("click", this.onClick);
      document.addEventListener("keydown", this.onEscape);

      // ── AC9: resizer ───────────────────────────────────────────────────
      var resizer = this.el.querySelector('[data-testid="trace-map-resizer"]');
      var stream = this.el.querySelector('[data-testid="trace-map-stream"]');
      var column = this.el.querySelector("#trace-map-left");
      this.dragStart = null;

      function setStreamHeight(height) {
        var max = column ? column.offsetHeight - 140 : TRACE_MAP_DEFAULT_STREAM_H;
        if (max < TRACE_MAP_MIN_STREAM_H) max = TRACE_MAP_MIN_STREAM_H;
        var clamped = Math.max(TRACE_MAP_MIN_STREAM_H, Math.min(max, height));
        stream.style.height = clamped + "px";
        // 2026-07-09 resize-persistence fix: remember the user's chosen
        // height on the hook instance so `updated()` can reassert it after
        // every LiveView patch (see that callback for why this is needed —
        // the server never renders a height style, so morphdom's attribute
        // sync silently strips the client-set one on the next re-render).
        self.streamHeight = clamped;
        // UX gate V4 (ARIA window-splitter): a focusable role="separator"
        // must expose aria-valuenow — screen-reader users pressing
        // ArrowUp/Down/Home/End otherwise get zero position feedback. The
        // value is the stream's share of its allowed range, as a percentage.
        if (resizer) {
          resizer.setAttribute("aria-valuenow", String(Math.round((clamped / max) * 100)));
        }
      }

      if (resizer && stream) {
        this.onResizerPointerDown = function (event) {
          self.dragStart = { y: event.clientY, h: stream.offsetHeight };
          if (resizer.setPointerCapture) resizer.setPointerCapture(event.pointerId);
        };
        this.onResizerPointerMove = function (event) {
          if (!self.dragStart) return;
          // Drag UP grows the stream, drag DOWN shrinks it (2026-07-09
          // direction fix) — the resizer bar itself is what moves under the
          // pointer, and moving it down means "give the space above (the
          // map) more room," matching the standard split-pane convention
          // (VS Code, browser devtools, etc). The inverse of the original
          // implementation, which the design owner found backwards live.
          setStreamHeight(self.dragStart.h - (event.clientY - self.dragStart.y));
        };
        this.onResizerPointerUp = function () {
          self.dragStart = null;
        };
        this.onResizerDblClick = function () {
          setStreamHeight(TRACE_MAP_DEFAULT_STREAM_H);
        };
        this.onResizerKeydown = function (event) {
          // Keyboard contract per logs-trace-map.feature Scenario 9
          // (2026-07-09 direction fix, kept consistent with the drag fix
          // above): ArrowUp grows the stream, ArrowDown shrinks it,
          // Home minimizes the stream, End maximizes it.
          if (event.key === "ArrowUp") {
            event.preventDefault();
            setStreamHeight(stream.offsetHeight + TRACE_MAP_RESIZE_STEP);
          } else if (event.key === "ArrowDown") {
            event.preventDefault();
            setStreamHeight(stream.offsetHeight - TRACE_MAP_RESIZE_STEP);
          } else if (event.key === "Home") {
            event.preventDefault();
            setStreamHeight(TRACE_MAP_MIN_STREAM_H);
          } else if (event.key === "End") {
            event.preventDefault();
            setStreamHeight(999999);
          }
        };
        // UX gate V4: compute the exact initial aria-valuenow (the server
        // renders an approximation — it cannot know the column height).
        setStreamHeight(stream.offsetHeight);
        resizer.addEventListener("pointerdown", this.onResizerPointerDown);
        resizer.addEventListener("pointermove", this.onResizerPointerMove);
        resizer.addEventListener("pointerup", this.onResizerPointerUp);
        resizer.addEventListener("pointercancel", this.onResizerPointerUp);
        resizer.addEventListener("dblclick", this.onResizerDblClick);
        resizer.addEventListener("keydown", this.onResizerKeydown);
      }

      // ── enhanced-logging/trace-map-zoom-pan: map-app-style zoom/pan ─────
      //
      // Client-owned state on the hook instance (self.zoom/panX/panY),
      // reasserted into the SVG's viewBox on every `updated()` — EXACTLY the
      // `self.streamHeight` / `updated()` pattern above (the server never
      // renders a live viewBox, so morphdom would otherwise silently reset
      // it on the next patch — see `updated()` below).
      var mapSvg = this.el.querySelector('[data-testid="trace-map-svg"]');
      this.zoom = TRACE_MAP_MIN_ZOOM;
      this.panX = 0;
      this.panY = 0;
      this.panDrag = null;

      this.applyZoomPan = function () {
        var svgEl = self.el.querySelector('[data-testid="trace-map-svg"]');
        if (!svgEl) return;
        svgEl.setAttribute("viewBox", traceMapViewBoxString(self.zoom, self.panX, self.panY));
      };

      function setZoomPan(zoom, panX, panY) {
        var clampedZoom = traceMapClampZoom(zoom);
        var clampedPan = traceMapClampPan(clampedZoom, panX, panY);
        self.zoom = clampedZoom;
        self.panX = clampedPan.x;
        self.panY = clampedPan.y;
        self.applyZoomPan();
      }

      // AC1: converts a screen/client coordinate into the SVG's OWN user
      // coordinate space via the real DOM CTM — the same point stays under
      // the cursor after the zoom below, regardless of letterboxing from
      // `preserveAspectRatio="xMidYMid meet"`.
      function svgPointFromClient(clientX, clientY) {
        if (!mapSvg || !mapSvg.createSVGPoint) return { x: 0, y: 0 };
        var ctm = mapSvg.getScreenCTM();
        if (!ctm) return { x: 0, y: 0 };
        var pt = mapSvg.createSVGPoint();
        pt.x = clientX;
        pt.y = clientY;
        var transformed = pt.matrixTransform(ctm.inverse());
        return { x: transformed.x, y: transformed.y };
      }

      // AC1: zooms to `newZoom` while keeping `point` (in SVG user space)
      // fixed on screen — the standard "cursor-centered zoom" map-app
      // formula: shrink/grow the viewBox around `point`, not around the
      // viewBox's own coordinate origin. Used ONLY by wheel zoom (AC1 is
      // explicit that cursor-centering is a wheel-zoom requirement).
      function zoomAt(point, newZoom) {
        var vw = TRACE_MAP_VIEWBOX_W / self.zoom;
        var vh = TRACE_MAP_VIEWBOX_H / self.zoom;
        var vx = TRACE_MAP_VIEWBOX_X + self.panX;
        var vy = TRACE_MAP_VIEWBOX_Y + self.panY;
        var clampedZoom = traceMapClampZoom(newZoom);
        var newVw = TRACE_MAP_VIEWBOX_W / clampedZoom;
        var newVh = TRACE_MAP_VIEWBOX_H / clampedZoom;
        var newVx = point.x - (point.x - vx) * (newVw / vw);
        var newVy = point.y - (point.y - vy) * (newVh / vh);
        setZoomPan(clampedZoom, newVx - TRACE_MAP_VIEWBOX_X, newVy - TRACE_MAP_VIEWBOX_Y);
      }

      // Keyboard/button zoom has no cursor to center on — anchor-based
      // instead: only the zoom level changes, panX/panY are left exactly as
      // they are (then re-clamped against the NEW zoom's bounds, which is a
      // no-op whenever pan was already within the new, tighter/looser
      // range). This is deliberately NOT "zoom around the current viewport
      // center" — centering would shift panX/panY away from 0 even when the
      // operator never touched pan (0 -> nonzero drift purely from
      // symmetric zoom-in/zoom-out), which breaks the reasonable and tested
      // expectation that panning right then left by the same amount returns
      // to the exact pre-pan viewBox after a pure keyboard-zoom sequence.
      function zoomByStep(delta) {
        setZoomPan(self.zoom + delta, self.panX, self.panY);
      }

      function panByStep(dx, dy) {
        setZoomPan(self.zoom, self.panX + dx, self.panY + dy);
      }

      function resetZoomPan() {
        setZoomPan(TRACE_MAP_MIN_ZOOM, 0, 0);
      }

      if (mapSvg) {
        // AC1/AC8: cursor-centered wheel zoom; preventDefault (only while
        // over the map) so the page never scrolls/zooms underneath it.
        this.onMapWheel = function (event) {
          event.preventDefault();
          var direction = event.deltaY < 0 ? 1 : -1;
          zoomAt(svgPointFromClient(event.clientX, event.clientY), self.zoom + direction * TRACE_MAP_ZOOM_STEP);
        };
        mapSvg.addEventListener("wheel", this.onMapWheel, { passive: false });

        // AC2: click-and-drag pan on empty map background. Node click/hover/
        // tooltip interactions are untouched: a pointerdown that lands ON a
        // node (via the same `.closest('[data-testid="trace-map-node"]')`
        // delegation the rest of this hook already uses) flags this WHOLE
        // gesture as "never pan" by simply never starting `self.panDrag` —
        // not a pixel-distance threshold, so a long, intentional drag
        // started on a node still does not pan (Dev Notes' own contract).
        // The node's native click still fires exactly as before this story,
        // since nothing here calls preventDefault/stopPropagation/
        // setPointerCapture for that case.
        this.onMapPointerDown = function (event) {
          var node = event.target.closest
            ? event.target.closest('[data-testid="trace-map-node"]')
            : null;
          if (node) {
            self.panDrag = null;
            return;
          }
          var ctm = mapSvg.getScreenCTM();
          self.panDrag = {
            clientX: event.clientX,
            clientY: event.clientY,
            panX: self.panX,
            panY: self.panY,
            // SVG user-units per screen pixel, fixed for the whole drag
            // gesture (zoom never changes mid-pan) — robust against
            // `meet`-letterboxing, unlike a plain rect-width/viewBox-width
            // ratio would be.
            scaleX: ctm && ctm.a ? 1 / ctm.a : 1,
            scaleY: ctm && ctm.d ? 1 / ctm.d : 1,
          };
          if (mapSvg.setPointerCapture) mapSvg.setPointerCapture(event.pointerId);
        };
        this.onMapPointerMove = function (event) {
          if (!self.panDrag) return;
          var dx = (event.clientX - self.panDrag.clientX) * self.panDrag.scaleX;
          var dy = (event.clientY - self.panDrag.clientY) * self.panDrag.scaleY;
          // Dragging right/down moves the CONTENT right/down on screen,
          // i.e. the viewBox's own top-left corner moves left/up.
          setZoomPan(self.zoom, self.panDrag.panX - dx, self.panDrag.panY - dy);
        };
        this.onMapPointerUp = function () {
          self.panDrag = null;
        };
        mapSvg.addEventListener("pointerdown", this.onMapPointerDown);
        mapSvg.addEventListener("pointermove", this.onMapPointerMove);
        mapSvg.addEventListener("pointerup", this.onMapPointerUp);
        mapSvg.addEventListener("pointercancel", this.onMapPointerUp);

        // AC5: keyboard zoom/pan on the map surface itself (tabindex="0").
        // Scoped to `event.target === mapSvg` so it never fires from a
        // bubbled keydown originating on a focused node/resizer/button —
        // Tab/Enter/Space node activation and the resizer's own Arrow-key
        // resize stay completely unaffected (AC5's own regression clause).
        this.onMapKeydown = function (event) {
          if (event.target !== mapSvg) return;
          switch (event.key) {
            case "+":
            case "=":
            case "PageUp":
              event.preventDefault();
              zoomByStep(TRACE_MAP_ZOOM_STEP);
              return;
            case "-":
            case "_":
            case "PageDown":
              event.preventDefault();
              zoomByStep(-TRACE_MAP_ZOOM_STEP);
              return;
            case "ArrowUp":
              event.preventDefault();
              panByStep(0, -TRACE_MAP_PAN_STEP);
              return;
            case "ArrowDown":
              event.preventDefault();
              panByStep(0, TRACE_MAP_PAN_STEP);
              return;
            case "ArrowLeft":
              event.preventDefault();
              panByStep(-TRACE_MAP_PAN_STEP, 0);
              return;
            case "ArrowRight":
              event.preventDefault();
              panByStep(TRACE_MAP_PAN_STEP, 0);
              return;
            default:
              return;
          }
        };
        mapSvg.addEventListener("keydown", this.onMapKeydown);
      }

      // AC1/AC4: on-screen zoom controls — client-only, no phx-click (AC7/
      // AC9), wired here exactly like the resizer's own buttons/handles.
      var zoomInBtn = this.el.querySelector('[data-testid="trace-map-zoom-in"]');
      var zoomOutBtn = this.el.querySelector('[data-testid="trace-map-zoom-out"]');
      var zoomResetBtn = this.el.querySelector('[data-testid="trace-map-zoom-reset"]');
      if (zoomInBtn) {
        this.onZoomInClick = function () {
          zoomByStep(TRACE_MAP_ZOOM_STEP);
        };
        zoomInBtn.addEventListener("click", this.onZoomInClick);
      }
      if (zoomOutBtn) {
        this.onZoomOutClick = function () {
          zoomByStep(-TRACE_MAP_ZOOM_STEP);
        };
        zoomOutBtn.addEventListener("click", this.onZoomOutClick);
      }
      if (zoomResetBtn) {
        this.onZoomResetClick = function () {
          resetZoomPan();
        };
        zoomResetBtn.addEventListener("click", this.onZoomResetClick);
      }

      // UX gate finding 2: discoverable on-screen pan buttons — a
      // dependable screen-reader-accessible pan path (role="group" +
      // tabindex="0" on the SVG does not reliably put NVDA/JAWS into
      // "focus mode", so the SVG's own arrow-key handler cannot be relied
      // on for AT users). Same client-only wiring pattern as the zoom
      // buttons above; reuses the EXACT same panByStep/TRACE_MAP_PAN_STEP
      // the keyboard arrow keys use, so button and keyboard panning behave
      // identically.
      var panUpBtn = this.el.querySelector('[data-testid="trace-map-pan-up"]');
      var panDownBtn = this.el.querySelector('[data-testid="trace-map-pan-down"]');
      var panLeftBtn = this.el.querySelector('[data-testid="trace-map-pan-left"]');
      var panRightBtn = this.el.querySelector('[data-testid="trace-map-pan-right"]');
      if (panUpBtn) {
        this.onPanUpClick = function () {
          panByStep(0, -TRACE_MAP_PAN_STEP);
        };
        panUpBtn.addEventListener("click", this.onPanUpClick);
      }
      if (panDownBtn) {
        this.onPanDownClick = function () {
          panByStep(0, TRACE_MAP_PAN_STEP);
        };
        panDownBtn.addEventListener("click", this.onPanDownClick);
      }
      if (panLeftBtn) {
        this.onPanLeftClick = function () {
          panByStep(-TRACE_MAP_PAN_STEP, 0);
        };
        panLeftBtn.addEventListener("click", this.onPanLeftClick);
      }
      if (panRightBtn) {
        this.onPanRightClick = function () {
          panByStep(TRACE_MAP_PAN_STEP, 0);
        };
        panRightBtn.addEventListener("click", this.onPanRightClick);
      }

      // ── AC6: war-room elapsed clock ────────────────────────────────────
      // enhanced-logging/trace-map-node-controls (AC5/AC6): the SAME
      // interval also ticks every temporary-capture countdown (node +
      // inspector) purely client-side from data-expires-at (unix seconds)
      // — "no server tick needed; the expiry time is set once, client
      // updates every 1 s via JS hook" (spec §5). The server still
      // re-evaluates captures on its own 1 s tick for the actual
      // auto-revert/expiry STATE transition (that part cannot be
      // client-only); this is purely the visual mm:ss smoothing between
      // server pushes.
      this.clockTimer = setInterval(function () {
        traceMapTickWarRoomClock(self.el);
        traceMapTickCountdowns(self.el);
      }, 1000);

      traceMapScrollStream(this.el);
    },

    updated: function () {
      // Decorative pings on ok→warn/error transitions (pure CSS animation;
      // skipped under prefers-reduced-motion).
      var fresh = traceMapReadStatuses(this.el);
      if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        traceMapSpawnPings(this.el, this.nodeStatusCache, fresh);
      }
      this.nodeStatusCache = fresh;
      traceMapScrollStream(this.el);

      // 2026-07-09 resize-persistence fix: the server never renders a
      // height style on the stream panel (it's entirely client-owned via
      // the resizer), so every LiveView patch — the 1s status tick, a new
      // log line arriving — morphdom-syncs its attributes back to the
      // server's (style-less) version, silently discarding a live resize.
      // Reassert the user's last chosen height right after every patch,
      // in the same tick, so the reset is never visible.
      if (this.streamHeight != null) {
        var streamEl = this.el.querySelector('[data-testid="trace-map-stream"]');
        if (streamEl) streamEl.style.height = this.streamHeight + "px";
      }

      // enhanced-logging/trace-map-zoom-pan (AC6): the EXACT same
      // reassertion pattern as `this.streamHeight` above — the server only
      // ever renders the DEFAULT viewBox (AC9: zoom/pan is never part of
      // server state), so every LiveView patch (status tick, new log line,
      // node status change) would otherwise morphdom-sync the viewBox
      // attribute back to that default, silently discarding the operator's
      // live zoom/pan. Reassert it right after every patch, in the same
      // tick, so the reset is never visible.
      if (this.zoom != null && this.applyZoomPan) {
        this.applyZoomPan();
      }
    },

    destroyed: function () {
      window.__nebuTraceMapHookReady = false;
      if (this.clockTimer) clearInterval(this.clockTimer);
      if (this.onEscape) document.removeEventListener("keydown", this.onEscape);
      // Listeners on this.el itself die with the element — no manual cleanup
      // needed for those.
    },
  };

  function traceMapReadStatuses(root) {
    var statuses = {};
    root.querySelectorAll('[data-testid="trace-map-node"]').forEach(function (node) {
      statuses[node.getAttribute("data-node-key")] = node.getAttribute("data-node-status");
    });
    return statuses;
  }

  function traceMapSpawnPings(root, previous, fresh) {
    var pingLayer = root.querySelector("#trace-map-pings");
    if (!pingLayer) return;

    root.querySelectorAll('[data-testid="trace-map-node"]').forEach(function (node) {
      var key = node.getAttribute("data-node-key");
      var status = fresh[key];
      var before = previous[key];
      if (status === before) return;
      if (status !== "warn" && status !== "error") return;
      if (pingLayer.childElementCount > 24) return;

      var core = node.querySelector('[data-testid="trace-map-node-core"]');
      var wrap = document.createElementNS(SVG_NS, "g");
      wrap.setAttribute("transform", node.getAttribute("transform") || "");
      var ring = document.createElementNS(SVG_NS, "circle");
      ring.setAttribute("class", "tm-ping tm-ping--" + status);
      ring.setAttribute("r", core ? core.getAttribute("r") : "24");
      wrap.appendChild(ring);
      pingLayer.appendChild(wrap);
      setTimeout(function () {
        wrap.remove();
      }, 750);
    });
  }

  // AC7: tooltip content is rebuilt from the node's server-rendered
  // data-tooltip-* attributes using textContent only (no innerHTML with
  // attribute-derived values).
  function traceMapShowTooltip(root, node) {
    var tooltip = root.querySelector('[data-testid="trace-map-tooltip"]');
    var wrap = root.querySelector("#trace-map-map-wrap");
    if (!tooltip || !wrap) return;

    tooltip.textContent = "";

    var rows = [
      ["tm-tooltip-name", node.getAttribute("data-tooltip-name")],
      ["tm-tooltip-route", node.getAttribute("data-tooltip-route")],
      ["tm-tooltip-status", "Status: " + (node.getAttribute("data-tooltip-status") || "")],
      ["tm-tooltip-counts", node.getAttribute("data-tooltip-counts")],
      ["tm-tooltip-cta", node.getAttribute("data-tooltip-cta")],
    ];
    rows.forEach(function (row) {
      if (!row[1]) return;
      var div = document.createElement("div");
      div.className = row[0];
      div.textContent = row[1];
      tooltip.appendChild(div);
    });

    tooltip.hidden = false;

    // Position next to the node, flipped/clamped so it never leaves the map.
    var nodeRect = node.getBoundingClientRect();
    var wrapRect = wrap.getBoundingClientRect();
    var x = nodeRect.right - wrapRect.left + 12;
    var y = nodeRect.top - wrapRect.top;
    if (x + 240 > wrapRect.width) x = nodeRect.left - wrapRect.left - 252;
    if (x < 0) x = 8;
    var tooltipHeight = tooltip.offsetHeight || 150;
    if (y + tooltipHeight > wrapRect.height) y = wrapRect.height - tooltipHeight - 8;
    if (y < 0) y = 8;
    tooltip.style.left = x + "px";
    tooltip.style.top = y + "px";
  }

  function traceMapHideTooltip(root) {
    var tooltip = root.querySelector('[data-testid="trace-map-tooltip"]');
    if (tooltip) tooltip.hidden = true;
  }

  function traceMapTickWarRoomClock(root) {
    var elapsedEl = root.querySelector('[data-testid="trace-map-war-room-elapsed"]');
    if (!elapsedEl) return;
    var startedAt = parseInt(elapsedEl.getAttribute("data-started-at"), 10);
    if (!startedAt) return;

    var total = Math.max(0, Math.floor(Date.now() / 1000) - startedAt);
    var hours = Math.floor(total / 3600);
    var minutes = Math.floor((total % 3600) / 60);
    var seconds = total % 60;
    var pad = function (n) {
      return String(n).padStart(2, "0");
    };
    elapsedEl.textContent =
      hours > 0
        ? pad(hours) + ":" + pad(minutes) + ":" + pad(seconds)
        : pad(minutes) + ":" + pad(seconds);
  }

  // enhanced-logging/trace-map-node-controls (AC5/AC6): ticks every
  // temporary-capture countdown element (the node's own + the inspector's
  // duplicate) from its own data-expires-at (unix seconds) — no per-element
  // bookkeeping needed since this just re-reads the DOM attribute every
  // second; newly-rendered countdown elements (a fresh capture enabled) are
  // picked up automatically on the very next tick via the live
  // querySelectorAll, and an element that disappears (capture ended/expired,
  // server patched it away) is simply no longer in the NodeList.
  function traceMapTickCountdowns(root) {
    var now = Math.floor(Date.now() / 1000);
    root.querySelectorAll("[data-expires-at]").forEach(function (el) {
      var expiresAt = parseInt(el.getAttribute("data-expires-at"), 10);
      if (!expiresAt) return;
      var remaining = Math.max(0, expiresAt - now);
      var minutes = Math.floor(remaining / 60);
      var seconds = remaining % 60;
      var pad = function (n) {
        return String(n).padStart(2, "0");
      };
      el.textContent = pad(minutes) + ":" + pad(seconds);
    });
  }

  // AC9: autoscroll pauses while the operator hovers or focuses the stream.
  function traceMapScrollStream(root) {
    var body = root.querySelector("#trace-map-stream-body");
    if (!body) return;
    if (body.matches(":hover")) return;
    if (body.contains(document.activeElement)) return;
    body.scrollTop = body.scrollHeight;
  }

  function boot() {
    wireConfirmForms();
    wireNavSectionToggles();
    wireUserAutocomplete();
    wireTraceMapFilters();
    wireDetailPanelFocus();
    wireLiveUpdatesPause();
    wireLogsConfigToggles();
    wireWarRoomPanel();

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
      hooks: {
        SessionKeepalive: SessionKeepalive,
        TraceMapLeitstand: TraceMapLeitstand,
        WarRoomPill: WarRoomPill,
      },
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
