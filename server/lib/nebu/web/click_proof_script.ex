defmodule Nebu.Web.ClickProofScript do
  @moduledoc """
  The ONE shared "click proof" script (story `safari-fetch-metadata-compat`, decisions D1 / D5). Safari / WebKit never sends
  `Sec-Fetch-User`, the header that tells the server a user activation caused a form navigation. The strict forms (OAuth client
  approve / reject / revoke / bulk removal, the legacy SSO trust lists, the OAuth switch, the claim and role mapping, the OIDC scopes and refresh mode forms, the `/account` reset approval) therefore carry a hidden
  field `<input type="hidden" name="_click_proof" value="" data-click-proof>`; this script sets it to `1` when the browser
  reports a TRUSTED click (`event.isTrusted === true`: a mouse / touch / keyboard activation of a submit control, which includes
  the implicit submit of Enter in a text field; `button.click()`, `dispatchEvent(new MouseEvent("click"))` and `form.submit()`
  are not trusted) and drops it again 2 s later and on `pageshow` (back-forward cache). `Nebu.OAuth.BrowserPost` accepts the
  field ONLY for WebKit user agents and only together with strictly correct `Sec-Fetch-Site` / `-Mode` / `-Dest`.

  It is a usability-level equivalent, not a stronger one: a script that runs in the page can set the field itself, exactly the
  accepted SO7 residual (ADR-033). Chromium and Gecko keep the unchanged rule (`Sec-Fetch-User: ?1` is required there).

  Embedding: the admin pages load the byte-identical copy from `priv/static/assets/app.js` (CSP `script-src 'self'`, a test pins
  the equality); the `/account` reset page embeds `script/0` inline and pins it in its CSP by `csp_hash/0`. Plain ES5, ASCII, NO
  comments (they would change the hash for nothing: the explanation lives here), no network, it never clicks or submits.
  """

  @script Enum.join(
            [
              ~S'(function(){var q="input[data-click-proof]";',
              ~S'function mark(f){var p=f&&f.querySelector?f.querySelector(q):null;if(!p){return}p.value="1";setTimeout(function(){p.value=""},2000)}',
              ~S'function clear(){var l=document.querySelectorAll(q),i;for(i=0;i<l.length;i++){l[i].value=""}}',
              ~S'document.addEventListener("click",function(e){if(e.isTrusted!==true){return}var t=e.target;if(!t||typeof t.closest!=="function"){return}',
              ~S'var b=t.closest("button,input");if(b&&b.type==="submit"){mark(b.form)}},true);',
              ~S'document.addEventListener("keydown",function(e){if(e.isTrusted!==true||e.key!=="Enter"){return}var t=e.target;if(t&&t.tagName==="INPUT"&&t.type!=="checkbox"&&t.type!=="radio"){mark(t.form)}},true);',
              ~S'window.addEventListener("pageshow",clear)})();'
            ],
            "\n"
          )

  @doc "The exact bytes a page embeds between `<script>` and `</script>` (and `app.js` carries): deterministic."
  @spec script() :: String.t()
  def script, do: @script

  @doc "The CSP source expression that pins `script/0`: `'sha256-<base64>'` (with the quotes)."
  @spec csp_hash() :: String.t()
  def csp_hash, do: "'sha256-" <> Base.encode64(:crypto.hash(:sha256, @script)) <> "'"
end
