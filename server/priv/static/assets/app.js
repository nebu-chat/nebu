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

  function boot() {
    if (!window.Phoenix || !window.LiveView) {
      // Vendored client not present (e.g. a stripped deploy) — the static render
      // still works; only the live DOM-diff upgrade is unavailable.
      return;
    }

    var Socket = window.Phoenix.Socket;
    var LiveSocket = window.LiveView.LiveSocket;

    var meta = document.querySelector("meta[name='csrf-token']");
    var csrfToken = meta ? meta.getAttribute("content") : null;

    // admin-add-user-autocomplete: ARIA-combobox keyboard navigation for the add-user
    // typeahead (rooms + spaces share this hook). The suggestion options are server-
    // rendered <li role="option" data-role="user-suggestion">; this hook only manages
    // the keyboard interaction + aria-activedescendant on the client. Selecting pushes
    // the existing "select_user_suggestion" event so the server fills the field.
    var Hooks = {
      UserCombobox: {
        mounted() {
          this.activeIndex = -1;
          this.input = this.el;
          this.onKeydown = this.handleKeydown.bind(this);
          this.input.addEventListener("keydown", this.onKeydown);
        },
        updated() {
          // Re-render may replace the listbox; reset the active option highlight.
          this.activeIndex = -1;
          this.input.removeAttribute("aria-activedescendant");
        },
        destroyed() {
          this.input.removeEventListener("keydown", this.onKeydown);
        },
        options() {
          var listId = this.input.getAttribute("aria-controls");
          var list = listId ? document.getElementById(listId) : null;
          return list ? Array.prototype.slice.call(list.querySelectorAll('[role="option"]')) : [];
        },
        highlight(opts, idx) {
          opts.forEach(function (o, i) {
            o.setAttribute("aria-selected", i === idx ? "true" : "false");
            if (i === idx) {
              o.classList.add("bg-base-300");
              o.scrollIntoView({ block: "nearest" });
            } else {
              o.classList.remove("bg-base-300");
            }
          });
          if (idx >= 0 && opts[idx]) {
            this.input.setAttribute("aria-activedescendant", opts[idx].id);
          } else {
            this.input.removeAttribute("aria-activedescendant");
          }
        },
        handleKeydown(e) {
          var opts = this.options();
          if (e.key === "ArrowDown") {
            if (opts.length === 0) return;
            e.preventDefault();
            this.activeIndex = (this.activeIndex + 1) % opts.length;
            this.highlight(opts, this.activeIndex);
          } else if (e.key === "ArrowUp") {
            if (opts.length === 0) return;
            e.preventDefault();
            this.activeIndex = (this.activeIndex - 1 + opts.length) % opts.length;
            this.highlight(opts, this.activeIndex);
          } else if (e.key === "Enter") {
            if (this.activeIndex >= 0 && opts[this.activeIndex]) {
              // Pick the highlighted suggestion (do NOT submit the form yet).
              e.preventDefault();
              opts[this.activeIndex].click();
            }
            // Otherwise let Enter submit the form (free-text submit is unchanged).
          } else if (e.key === "Escape") {
            if (opts.length > 0) {
              e.preventDefault();
              this.pushEvent("dismiss_user_suggestions", {});
            }
          }
        },
      },
    };

    var liveSocket = new LiveSocket("/admin/live", Socket, {
      params: { _csrf_token: csrfToken },
      hooks: Hooks,
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
