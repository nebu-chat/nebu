defmodule Nebu.Web.ArmScript do
  @moduledoc """
  The ONE shared, generic "arming" script of the browser decision pages (story
  `legacy-sso-redirect-confirmation`, G3-3, D9 / oracle m5), used by the SSO confirmation page and, since story
  `consent-arming-hardening` (G3-5), by the OAuth consent page. Shared infrastructure: it names no domain module,
  so every page that has a decision button that must not be hit by an unintended click can embed the
  byte-identical script and pin it in its CSP by SHA-256 (`script-src 'sha256-<base64 of script/0>'`, no
  `'unsafe-inline'`).

  Against "double clickjacking" (an attacker page opens a window that lands on the decision page behind the
  victim's second click of a double click) the script arms the single element marked `data-arm` only when ALL of
  this holds. The element is rendered `aria-disabled="true"` (focusable and announced, never the `disabled`
  property: a screen-reader touch-exploration user must be able to reach it and hear why it is not available) and
  the script never touches `.disabled`; the element marked `data-arm-hint` explains it (visible by default, hidden
  on arming) and the polite live region `data-arm-status` announces "<name> is now available." / why a click
  was blocked (it is cleared when the pointer or the focus reaches the armed element, and the sentence says how to
  re-enter when the element already had the focus at the moment it armed). Arming also removes the hint's id from the
  element's `aria-describedby` (restored on a `hashchange` reset). The button name `<name>` is the armed element's own trimmed `textContent` (fallback "This button"),
  so the same script serves the SSO confirmation page ("Continue") and the OAuth consent page ("Allow"):

    * at least 600 ms passed since the script ran, AND
    * the user really interacted with the page, NOT on the armed element itself: a pointer move of at least 4 px
      (mouse / pen), a key press, a wheel event, a `focusin` on another element, or - touch devices emit no
      `pointermove` without contact - a `touchstart` / a `pointerdown` of type touch whose target is not the armed
      element.

  Before arming the element may also carry a `form` attribute that points at no form (a page can render it so that
  the button does nothing without JavaScript); arming removes it, so with JavaScript off the button stays inert.

  A `scroll` event does NOT arm (review cycle 2, LOW-2: the popup carries no COOP, so an opener can fragment-navigate
  it, e.g. `#continue`, and scroll the page without any user interaction). A `hashchange` resets the element to the
  unarmed state and restarts the dwell.

  Mouse / pen (G3-5 class): after arming, an activation (`click`) of the element is accepted only when a
  `pointermove` of type mouse or pen over it with NON-ZERO movement happened AFTER the arming moment (a layout or
  scroll change makes the browser fire synthetic moves with unchanged coordinates, and `pointerenter` fires on
  such a change, so neither can satisfy it); otherwise the script calls `preventDefault()` on the click (the pointer
  must visibly travel onto the button after it became active, which a double-click lure that parks the pointer on
  the spot cannot provide). A touch tap is accepted once armed
  (touch has no hover; the arming touch had to land elsewhere). A keyboard activation (`click` with `detail == 0`,
  Enter / Space on the focused button) is accepted only when the focus moved onto the element AFTER the arming
  moment (a `focusin` on it, security review SEC #4: a "Tab, Tab, Enter" lure cannot hit it blind); otherwise the
  click is cancelled and the live region says so.

  Plain ES5, ASCII only, no network, no DOM injection, it never clicks or submits for the user, and it carries
  NO comments (they would change the hash for nothing: the explanation lives in this module). The server never
  trusts the button state: the arming is a usability barrier, not an authorization.
  """

  @script Enum.join(
            [
              ~S'(function(){var b=document.querySelector("[data-arm]");if(!b){return}',
              ~S'var h=document.querySelector("[data-arm-hint]");var st=document.querySelector("[data-arm-status]");var f0=b.getAttribute("form");var n=(b.textContent||"").replace(/^\s+|\s+$/g,"")||"This button";var d0=b.getAttribute("aria-describedby");var hid=h?h.id:"";',
              ~S'var t0=Date.now(),gen=0,fx=null,fy=null,lx=null,ly=null,pending=false,armed=false,entered=false,focused=false,last="";',
              ~S'function say(m){if(st){st.textContent="";st.textContent=m}}',
              ~S'function dsc(r){if(d0===null||!hid){return}if(r){b.setAttribute("aria-describedby",d0);return}',
              ~S'var k=d0.split(" ").filter(function(x){return x&&x!==hid}).join(" ");if(k){b.setAttribute("aria-describedby",k)}else{b.removeAttribute("aria-describedby")}}',
              ~S'function inside(e){if(e.target&&b.contains(e.target)){return true}',
              ~S'var p=e.touches&&e.touches[0]?e.touches[0]:(e.changedTouches&&e.changedTouches[0]?e.changedTouches[0]:e);',
              ~S'var r=b.getBoundingClientRect();',
              ~S'return typeof p.clientX==="number"&&p.clientX>=r.left&&p.clientX<=r.right&&p.clientY>=r.top&&p.clientY<=r.bottom}',
              ~S'function arm(){if(armed){return}armed=true;entered=false;focused=false;',
              ~S'b.setAttribute("aria-disabled","false");b.removeAttribute("form");',
              ~S'if(h){h.hidden=true}dsc(false);',
              ~S'say(document.activeElement===b?n+" is now available. Press Shift+Tab, then Tab to move back onto it.":n+" is now available.")}',
              ~S'function act(){if(armed||pending){return}pending=true;var g=gen;',
              ~S'setTimeout(function(){if(g===gen){arm()}},Math.max(0,600-(Date.now()-t0)))}',
              ~S'window.addEventListener("hashchange",function(){gen=gen+1;armed=false;pending=false;entered=false;focused=false;t0=Date.now();',
              ~S'b.setAttribute("aria-disabled","true");if(f0!==null){b.setAttribute("form",f0)}dsc(true);',
              ~S'if(h){h.hidden=false}say("")});',
              ~S'document.addEventListener("pointermove",function(e){if(e.pointerType!=="mouse"&&e.pointerType!=="pen"){return}',
              ~S'var moved=lx!==null&&(e.clientX!==lx||e.clientY!==ly);lx=e.clientX;ly=e.clientY;',
              ~S'if(fx===null){fx=e.clientX;fy=e.clientY;return}',
              ~S'if(inside(e)){if(armed&&moved){if(!entered){say("")}entered=true}return}',
              ~S'if(Math.abs(e.clientX-fx)+Math.abs(e.clientY-fy)>=4){act()}},true);',
              ~S'document.addEventListener("keydown",act,true);',
              ~S'document.addEventListener("wheel",act,true);',
              ~S'document.addEventListener("focusin",function(e){if(!(e.target&&b.contains(e.target))){act()}},true);',
              ~S'document.addEventListener("touchstart",function(e){if(!inside(e)){act()}},true);',
              ~S'document.addEventListener("pointerdown",function(e){if(e.pointerType==="touch"&&!inside(e)){act()}},true);',
              ~S'b.addEventListener("focusin",function(){if(armed){if(!focused){say("")}focused=true}});',
              ~S'b.addEventListener("pointerdown",function(e){last=e.pointerType||""},true);',
              ~S'b.addEventListener("click",function(e){',
              ~S'if(!armed){e.preventDefault();say(n+" is not available yet.");return}',
              ~S'if(e.detail===0){if(!focused){e.preventDefault();say("Move the focus off and back onto "+n+", then press Enter.")}return}',
              ~S'if(last==="touch"){return}',
              ~S'if(!entered){e.preventDefault();say("Move the pointer off and back onto "+n+", then click.")}},true)})();'
            ],
            "\n"
          )

  @doc """
  The inline script (see the moduledoc): the exact bytes a page embeds between `<script>` and `</script>`, and
  the bytes its CSP hashes. Deterministic.
  """
  @spec script() :: String.t()
  def script, do: @script
end
