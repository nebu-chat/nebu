defmodule Nebu.Web.ArmScriptTest do
  @moduledoc """
  ATDD static acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC5.6 / D9 (oracle m5), amended
  by story `consent-arming-hardening` (G3-5, D2 / AC4):
  `Nebu.Web.ArmScript.script/0` is the ONE shared, generic arming script of the SSO confirmation page AND the OAuth
  consent page. It is button-name neutral: the live-region messages take the name from the armed element's own text
  (`textContent`, trimmed, fallback "This button"), so no message names "Continue". Rules pinned here (the browser
  behaviour itself is the e2e `@legacy-sso-confirm` / `@oauth-consent` suites):

    * plain ES5, no network API, no DOM injection, never clicks or submits for the user;
    * generic: addresses the button through `data-arm` and the hint through `data-arm-hint` (no page-specific id);
    * armed only >= 600 ms after load AND after real interaction that is NOT on the button: a pointer move of
      >= 4 px (mouse / pen), a key press, a wheel event (a scroll alone does NOT arm, review cycle 2), a focusin elsewhere, a `touchstart` / touch `pointerdown` elsewhere;
    * mouse / pen (G3-5): an activation after arming is accepted only if a `pointermove` with non-zero movement (pointerType mouse or
      pen) on the button happened AFTER the arming moment, otherwise `preventDefault()` on the click;
    * touch and keyboard (`click` with `detail == 0`) activations are accepted once armed.
  """
  use ExUnit.Case, async: true

  defp script, do: apply(Nebu.Web.ArmScript, :script, [])

  test "Nebu.Web.ArmScript.script/0 exists, returns a non-empty binary and is deterministic (the CSP hash is computed from it)" do
    assert {:module, Nebu.Web.ArmScript} = Code.ensure_loaded(Nebu.Web.ArmScript)
    assert function_exported?(Nebu.Web.ArmScript, :script, 0)
    s = script()
    assert is_binary(s) and byte_size(s) > 200
    assert script() == s
  end

  test "script/0 has a @doc" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Nebu.Web.ArmScript)

    doc =
      Enum.find_value(docs, fn
        {{:function, :script, 0}, _, _, %{"en" => d}, _} -> d
        _ -> nil
      end)

    assert is_binary(doc) and doc != ""
  end

  test "the script is ASCII only and can never end the inline <script> element" do
    s = script()
    assert String.valid?(s)
    assert s |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128)), "ASCII only (the CSP hash is over the served bytes)"
    refute s =~ ~r/<\/script/i
    refute s =~ "<!--"
    refute s =~ ~r{//|/\*}, "the pinned script carries no comments (they would change the hash for nothing)"
  end

  test "plain ES5: no arrow functions, let / const, classes, template literals, async / await, spread, optional chaining" do
    s = script()
    refute s =~ "=>", "no arrow functions"
    refute s =~ ~r/\b(let|const|class|async|await|yield|import|export)\b/
    refute s =~ "`", "no template literals"
    refute s =~ "..."
    refute s =~ "?.", "no optional chaining"
    refute s =~ "??", "no nullish coalescing"
    refute s =~ ~r/\bfor\s*\([^)]*\bof\b/
    refute s =~ ~r/\bPromise\b|\bSymbol\b|\bMap\(|\bSet\(/
  end

  test "no network API and no DOM injection: it only toggles the button and the hint" do
    s = script()

    for forbidden <- ~w(fetch XMLHttpRequest WebSocket sendBeacon EventSource eval Function innerHTML outerHTML insertAdjacent createElement appendChild document.write document.cookie localStorage sessionStorage postMessage importScripts) do
      refute s =~ forbidden, "#{forbidden} must not appear in the arming script"
    end

    refute s =~ ~r/\blocation\b/, "no navigation"
    refute s =~ ~r/\.(submit|requestSubmit|click)\s*\(/, "the script never clicks or submits for the user"
    refute s =~ ~r/setAttribute\(\s*["']action|\.action\s*=|\.src\s*=|\.href\s*=/
  end

  test "generic selectors: the element is found through data-arm and the hint through data-arm-hint, no page-specific id" do
    s = script()
    assert s =~ "data-arm"
    assert s =~ "data-arm-hint"
    refute s =~ ~r/getElementById|#continue|#allow|id=["']?(continue|allow)/
    refute s =~ ~r/["'](continue|allow|deny|cancel)["']/i
  end

  test "the 600 ms dwell and the 4 px movement threshold are constants of the script" do
    s = script()
    assert s =~ "600"
    assert s =~ ~r/\b4\b/, "a pointer move of 4 px or more arms (a stationary pointer under a double click does not)"
  end

  test "interaction that arms: pointer move (mouse / pen), key press, wheel, and touch events that are not on the button (NOT scroll)" do
    s = script()
    for ev <- ~w(pointermove keydown wheel touchstart pointerdown), do: assert(s =~ ev, "event #{ev} must be handled")
    refute s =~ "scroll", "review cycle 2 (LOW-2): a scroll (an opener can fragment-navigate a COOP-less popup) never arms"
    assert s =~ "pointerType"
    assert s =~ ~r/touch/
    assert s =~ ~r/mouse/ and s =~ ~r/pen/
  end

  test "G3-5 / LOW-2: after arming a mouse / pen activation needs a pointermove with NON-ZERO movement over the button AFTER the arming moment" do
    s = script()
    refute s =~ "pointerenter", "pointerenter also fires on a layout / scroll change under a parked pointer"
    assert s =~ ~r/clientX!==lx\|\|[^;]*clientY!==ly/, "the movement is compared with the previous pointer position"
    assert s =~ "entered=true"
    assert s =~ "preventDefault", "an activation without the travel is cancelled"
    assert s =~ "click"
    assert s =~ ~r/detail/, "a keyboard activation (click with detail 0) is accepted once armed"
  end

  test "UX B1: the button is rendered aria-disabled (focusable, announced) and armed by flipping aria-disabled; no `disabled` property" do
    s = script()
    assert s =~ "aria-disabled"
    refute s =~ ~r/\.disabled\s*=/, "the page renders aria-disabled=\"true\", the script never touches the disabled property"
    assert s =~ "preventDefault", "a click while the button is not armed is cancelled"
    assert s =~ ~r/hidden|style\.display|classList/, "the hint element is hidden once armed"
  end

  test "UX B1/B2: the polite live region [data-arm-status] is filled with the button-name neutral messages (text only, textContent)" do
    s = script()
    assert s =~ "data-arm-status"
    assert s =~ ~S{" is now available."}
    assert s =~ ~S{" is not available yet."}
    assert s =~ ~S{"Move the pointer off and back onto "}
    assert s =~ ~S{", then click."}
    assert s =~ ~S{"Move the focus off and back onto "}
    assert s =~ ~S{", then press Enter."}
    refute s =~ ~r/innerHTML|insertAdjacent|createElement/, "text only: textContent of the existing element"
  end

  test "D2 / AC4: the button name comes from the armed element's own text (textContent, trimmed, fallback \"This button\")" do
    s = script()
    assert s =~ ~S{(b.textContent||"")}, "the name is read from the armed element, not hard-coded"
    assert s =~ ~S{.replace(/^\s+|\s+$/g,"")}, "leading / trailing white space of the label is trimmed"
    assert s =~ ~S{"This button"}, "fallback when the element has no text"

    assert s =~ ~S{(b.textContent||"").replace(/^\s+|\s+$/g,"")||"This button"},
           "the whole name expression: read, trim, fall back (an empty or blank label falls back)"

    refute s =~ ~r/\.(innerHTML|innerText)\b/, "the name goes only into the live region through textContent"
    refute s =~ "Continue", "no message names a button that may not exist on the page (the consent page has Allow)"
    refute s =~ "Allow", "the script names no page-specific button"
  end

  test "D2 / AC4: every blocked or armed message is built from the name, in the same wording as before (the SSO texts stay byte-identical)" do
    s = script()
    for tail <- [~S{" is now available."}, ~S{" is not available yet."}, ~S{", then click."}, ~S{", then press Enter."}] do
      assert s =~ tail
    end

    # the name variable is concatenated in front of / inside the messages (not a literal button name)
    assert s =~ ~r/\w+\+" is now available\."/
    assert s =~ ~r/\w+\+" is not available yet\."/
    assert s =~ ~r/"Move the pointer off and back onto "\+\w+\+", then click\."/
    assert s =~ ~r/"Move the focus off and back onto "\+\w+\+", then press Enter\."/
  end

  test "UX B1: a focusin on an element other than the button also arms (>= 600 ms after load)" do
    s = script()
    assert s =~ "focusin"
  end

  test "SEC #4: a keyboard activation is accepted only after the focus moved onto the button AFTER arming (a focusin on it)" do
    s = script()
    assert s =~ "focusin"
    assert s =~ ~r/detail/, "keyboard activation = click with detail 0"
    # the button itself listens to focusin (the armed-focus signal), besides the document-level arming listener
    assert length(Regex.scan(~r/focusin/, s)) >= 2, "one focusin arms (elsewhere), one records the focus on the button after arming"
  end

  test "LOW-2: a hashchange resets the armed state (an opener can fragment-navigate the popup) and restarts the dwell" do
    s = script()
    assert s =~ "hashchange"
    assert s =~ ~r/hashchange.{0,200}armed=false/s
    assert s =~ ~r/hashchange.{0,300}aria-disabled","true"/s, "the button is aria-disabled again"
    assert s =~ ~r/gen/, "a pending arming timer of the old generation never arms the reset button"
  end

  test "review cycle 1 UX N2: arming while the button already has the focus announces how to move back onto it" do
    s = script()
    assert s =~ "document.activeElement===b"
    assert s =~ ~S{" is now available. Press Shift+Tab, then Tab to move back onto it."}
    assert s =~ ~r/\w+\+" is now available\."/, "the plain message stays for the other case"
  end

  test "review cycle 1 UX N3: arming removes the hint id from aria-describedby, a hashchange reset restores it" do
    s = script()
    assert s =~ ~S{getAttribute("aria-describedby")}
    assert s =~ ~S{removeAttribute("aria-describedby")}
    assert s =~ ~r/hashchange.{0,500}aria-disabled","true".{0,200}dsc\(true\)/s, "restored on the reset"
    assert s =~ ~r/h\.hidden=true\}dsc\(false\)/, "removed on arming, together with hiding the hint"
    refute s =~ ~r/["']arm-hint["']/, "the hint id is read from the hint element, never hard-coded"
  end

  test "review cycle 1 UX N8: the live region is cleared before every message and when the pointer or focus reaches the armed element" do
    s = script()
    assert s =~ ~S|function say(m){if(st){st.textContent="";st.textContent=m}}|
    assert s =~ ~r/if\(armed&&moved\)\{if\(!entered\)\{say\(""\)\}entered=true\}/
    assert s =~ ~r/if\(armed\)\{if\(!focused\)\{say\(""\)\}focused=true\}/
  end

  test "Kassandra INFO #2: a focusin on the armed element before arming neither arms nor counts as the focus after arming (#allow fragment)" do
    s = script()
    assert s =~ ~r/document\.addEventListener\("focusin",function\(e\)\{if\(!\(e\.target&&b\.contains\(e\.target\)\)\)\{act\(\)\}\}/
    assert s =~ ~r/b\.addEventListener\("focusin",function\(\)\{if\(armed\)/
    assert s =~ ~r/function arm\(\)\{if\(armed\)\{return\}armed=true;entered=false;focused=false;/
  end
end
