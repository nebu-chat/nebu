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

    var liveSocket = new LiveSocket("/admin/live", Socket, {
      params: { _csrf_token: csrfToken },
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
