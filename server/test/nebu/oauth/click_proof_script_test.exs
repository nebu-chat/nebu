defmodule Nebu.OAuth.ClickProofScriptTest do
  @moduledoc """
  Unit / static tests (no database) for story `safari-fetch-metadata-compat`, AC4 / AC5 (decisions D1, D5): the shared click-proof
  script `Nebu.Web.ClickProofScript` that fills the hidden `_click_proof` field on a TRUSTED click (or Enter in a text field) of a form
  with such a field, the byte-identical copy in the admin `app.js` (CSP `script-src 'self'`), and the hygiene rules of the script
  (plain ES5, ASCII, no comments, no network, never submits or clicks). The behaviour is exercised in `node` against a stub DOM when
  `node` is installed (skipped otherwise: the isolated CI image has none; the real-browser run is a manual verification).
  """
  use ExUnit.Case, async: true

  @mod Nebu.Web.ClickProofScript
  @app_js Path.expand("../../../priv/static/assets/app.js", __DIR__)
  @node System.find_executable("node")

  defp script, do: apply(@mod, :script, [])

  test "the module exists and the script is deterministic, non-empty, ASCII, plain ES5 (no arrow functions, let/const, template strings)" do
    assert {:module, _} = Code.ensure_loaded(@mod)
    s = script()
    assert is_binary(s) and byte_size(s) > 100 and byte_size(s) < 1500, "small: a lot of script is a lot of attack surface (#{byte_size(s)} bytes)"
    assert s == script()
    assert String.printable?(s) and s == for(<<c <- s>>, c < 128 or c == ?\n, into: "", do: <<c>>), "ASCII only"
    refute s =~ "=>"
    refute s =~ ~r/\b(let|const|class|async|await)\b/
    refute s =~ "`"
    refute s =~ ~r/<\/script/i, "a closing tag would end the inline script"
    refute s =~ "<!--"
    refute s =~ "\r", "an HTML parser normalizes CRLF: the CSP hash would silently break"
    refute s =~ "?.", "no optional chaining (ES2020)"
    refute s =~ "??"
    refute s =~ "..."
  end

  test "no comments, no network, no navigation, no submit / click of its own, no DOM injection, no storage, no eval" do
    s = script()
    refute s =~ "//", "a comment would change the hash for nothing"
    refute s =~ "/*"

    for forbidden <- ~w(fetch XMLHttpRequest WebSocket sendBeacon .submit( .click( requestSubmit dispatchEvent innerHTML outerHTML insertAdjacent createElement appendChild eval Function( localStorage sessionStorage document.cookie location),
        do: refute(s =~ forbidden, "the script must not use #{forbidden}")
  end

  test "it reads the trusted flag, listens in the capture phase, names the data attribute the forms carry and clears on pageshow" do
    s = script()
    assert s =~ "isTrusted"
    assert s =~ "data-click-proof"
    assert s =~ "pageshow"
    assert s =~ "setTimeout"
    assert s =~ ~s("click")
    assert s =~ ~s("keydown")
  end

  test "the admin app.js (script-src 'self', no inline script) carries the same bytes, and the admin layout loads app.js" do
    js = File.read!(@app_js)
    assert js =~ script(), "app.js must contain Nebu.Web.ClickProofScript.script/0 byte for byte"
    assert length(String.split(js, script())) == 2, "exactly once"
    layouts = File.read!(Path.expand("../../../lib/nebu/admin/layouts.ex", __DIR__))
    assert layouts =~ "/admin/static/assets/app.js"
  end

  test "the hash a CSP pins is the SHA-256 of exactly these bytes (helper)" do
    assert apply(@mod, :csp_hash, []) == "'sha256-" <> Base.encode64(:crypto.hash(:sha256, script())) <> "'"
  end

  @harness ~S"""
  var handlers = {doc: {}, win: {}};
  var timers = [];
  global.setTimeout = function (fn, ms) { timers.push({fn: fn, ms: ms}); return timers.length; };
  var proof = {value: ""};
  var other = {value: ""};
  function form(field) { return {querySelector: function (sel) { return sel === "input[data-click-proof]" ? field : null; }}; }
  var withProof = form(proof), without = form(null);
  global.document = {
    addEventListener: function (t, f, c) { (handlers.doc[t] = handlers.doc[t] || []).push({f: f, c: c}); },
    querySelectorAll: function (sel) { return sel === "input[data-click-proof]" ? [proof, other] : []; }
  };
  global.window = {addEventListener: function (t, f) { (handlers.win[t] = handlers.win[t] || []).push(f); }};
  new Function(process.env.SCRIPT)();
  function fire(type, ev) { (handlers.doc[type] || []).forEach(function (h) { h.f(ev); }); }
  function btn(type, f) { return {type: type, form: f}; }
  function on(b) { return {closest: function () { return b; }}; }
  function reset() { proof.value = ""; timers = []; }
  var out = {};
  fire("click", {isTrusted: true, target: on(btn("submit", withProof))});
  out.trusted = proof.value; out.timerMs = timers.map(function (t) { return t.ms; });
  timers.forEach(function (t) { t.fn(); }); out.afterTimer = proof.value; reset();
  fire("click", {isTrusted: false, target: on(btn("submit", withProof))}); out.untrusted = proof.value; reset();
  fire("click", {target: on(btn("submit", withProof))}); out.noFlag = proof.value; reset();
  fire("click", {isTrusted: "true", target: on(btn("submit", withProof))}); out.stringFlag = proof.value; reset();
  fire("click", {isTrusted: true, target: on(btn("button", withProof))}); out.typeButton = proof.value; reset();
  fire("click", {isTrusted: true, target: on(btn("submit", without))}); out.formWithoutField = proof.value; reset();
  fire("click", {isTrusted: true, target: on(btn("submit", null))}); out.noForm = proof.value; reset();
  fire("click", {isTrusted: true, target: {}}); out.noClosest = proof.value; reset();
  fire("click", {isTrusted: true, target: null}); out.nullTarget = proof.value; reset();
  fire("click", {isTrusted: true, target: {closest: function () { return null; }}}); out.noButton = proof.value; reset();
  fire("keydown", {isTrusted: true, key: "Enter", target: {tagName: "INPUT", form: withProof}}); out.enter = proof.value; reset();
  fire("keydown", {isTrusted: false, key: "Enter", target: {tagName: "INPUT", form: withProof}}); out.enterUntrusted = proof.value; reset();
  fire("keydown", {isTrusted: true, key: "a", target: {tagName: "INPUT", form: withProof}}); out.otherKey = proof.value; reset();
  fire("keydown", {isTrusted: true, key: "Enter", target: {tagName: "TEXTAREA", form: withProof}}); out.textarea = proof.value; reset();
  fire("keydown", {isTrusted: true, key: "Enter", target: {tagName: "INPUT", type: "checkbox", form: withProof}}); out.checkbox = proof.value; reset();
  fire("keydown", {isTrusted: true, key: "Enter", target: {tagName: "INPUT", type: "text", form: withProof}}); out.textInput = proof.value; reset();
  proof.value = "1"; other.value = "1";
  (handlers.win.pageshow || []).forEach(function (f) { f({}); });
  out.pageshow = [proof.value, other.value];
  out.captureClick = (handlers.doc.click || []).length > 0 && handlers.doc.click.every(function (h) { return h.c === true; });
  out.captureKeydown = (handlers.doc.keydown || []).length > 0 && handlers.doc.keydown.every(function (h) { return h.c === true; });
  console.log(JSON.stringify(out));
  """

  describe "behaviour against a stub DOM (needs node)" do
    @describetag skip: if(@node, do: nil, else: "node is not installed")

    setup do
      {out, 0} = System.cmd(@node || "node", ["-e", @harness], env: [{"SCRIPT", script()}], stderr_to_stdout: true)
      {:ok, out: Jason.decode!(out |> String.trim() |> String.split("\n") |> List.last())}
    end

    test "a trusted click on a submit control of a form with the field sets it to 1; the value is dropped again after a short time", %{out: out} do
      assert out["trusted"] == "1"
      assert out["timerMs"] == [2000]
      assert out["afterTimer"] == ""
    end

    test "an untrusted click (button.click(), dispatchEvent), a missing or non-boolean flag, a type=button control: no proof", %{out: out} do
      for key <- ~w(untrusted noFlag stringFlag typeButton), do: assert(out[key] == "", key)
    end

    test "a form without the field, no form, no closest(), no target, no button: nothing happens, nothing throws", %{out: out} do
      for key <- ~w(formWithoutField noForm noClosest nullTarget noButton), do: assert(out[key] == "", key)
    end

    test "a trusted Enter in a text field (implicit submission) sets it; an untrusted one, another key, a textarea do not", %{out: out} do
      assert out["enter"] == "1"
      assert out["textInput"] == "1"
      for key <- ~w(enterUntrusted otherKey textarea checkbox), do: assert(out[key] == "", key)
    end

    test "pageshow (back-forward cache restore) clears every field; both listeners run in the capture phase", %{out: out} do
      assert out["pageshow"] == ["", ""]
      assert out["captureClick"] == true and out["captureKeydown"] == true
    end
  end

  describe "the strict forms carry the field (static check of the templates)" do
    @lib Path.expand("../../../lib/nebu", __DIR__)

    for {file, count} <- [
          {"admin/templates/oauth_registrations/approve_confirm.html.heex", 1},
          {"admin/templates/oauth_registrations/index.html.heex", 1},
          {"admin/templates/oauth_registrations/bulk_preview.html.heex", 1},
          {"admin/templates/oauth_clients/revoke_confirm.html.heex", 1},
          {"admin/templates/config/index.html.heex", 5},
          {"admin/templates/claim_mapping/index.html.heex", 1},
          {"admin/templates/role_mapping/index.html.heex", 1},
          {"oauth/account_templates/reset.html.eex", 1}
        ] do
      test "#{file}: #{count} hidden field(s) _click_proof with data-click-proof" do
        src = File.read!(Path.join(@lib, unquote(file)))
        hits = Regex.scan(~r/<input[^>]*name="_click_proof"[^>]*>/, src)
        assert length(hits) == unquote(count), "#{length(hits)} hits"
        for [tag] <- hits, do: assert(tag =~ "data-click-proof" and tag =~ ~s(type="hidden"))
      end
    end

    test "no other template has the field (only the forms behind the strict level)" do
      with_field =
        for f <- Path.wildcard(Path.join(@lib, "**/*.{heex,eex}")), File.read!(f) =~ "_click_proof", do: Path.relative_to(f, @lib)

      assert Enum.sort(with_field) ==
               Enum.sort([
                 "admin/templates/oauth_registrations/approve_confirm.html.heex",
                 "admin/templates/oauth_registrations/index.html.heex",
                 "admin/templates/oauth_registrations/bulk_preview.html.heex",
                 "admin/templates/oauth_clients/revoke_confirm.html.heex",
                 "admin/templates/config/index.html.heex",
                 "admin/templates/claim_mapping/index.html.heex",
                 "admin/templates/role_mapping/index.html.heex",
                 "oauth/account_templates/reset.html.eex",
                 # story admin-forms-gate-sweep: every other admin form post is behind the strict level too
                 "admin/templates/users/show.html.heex",
                 "admin/templates/rooms/new.html.heex",
                 "admin/templates/rooms/index.html.heex",
                 "admin/templates/rooms/show.html.heex",
                 "admin/templates/spaces/index.html.heex",
                 "admin/templates/spaces/show.html.heex",
                 "admin/templates/logs_config/index.html.heex",
                 "admin/templates/media_settings/index.html.heex"
               ])
    end
  end
end
