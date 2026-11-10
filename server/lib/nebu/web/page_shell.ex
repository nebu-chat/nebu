defmodule Nebu.Web.PageShell do
  @moduledoc """
  The ONE page frame of the standalone Nebu pages (story oauth-pages-redesign/02, design
  `ux-oauth-pages-redesign-2026-11-05/DESIGN.md` section 4): doctype, `<html lang>`, the inline
  hexagon-N logo, the Obsidian tokens (dark by default, light via `prefers-color-scheme`) and ONE
  inline `<style>` block holding the notice / button / details styles of every page.

  CSP: the SHA-256 of that one style block is computed at compile time and is the only
  `style-src` source (`csp/0`); everything else stays `'none'`. No external resource, no webfont
  (font stack `Inter, system-ui, ...` falls back to system fonts), no script, no `style=`
  attribute, no `<img>` (the logo is an inline SVG).

  `render/2` takes already-safe HTML for `:content`; every dynamic value must go through `esc/1`
  first. The page language comes from `Nebu.Web.Locale`, the texts from `Nebu.Web.PageText`.
  """

  @css Enum.join(
         [
           ":root{color-scheme:dark light;--bg:#111827;--card:#1f2937;--border:#374151;--text:#f9fafb;--muted:#9ca3af;" <>
             "--primary:#f97316;--on-primary:#1c1917;--accent:#fb923c;--outline:#9ca3af;" <>
             "--warn-bg:#451a03;--warn-border:#f59e0b;--warn-text:#fde68a;" <>
             "--err-bg:#450a0a;--err-border:#ef4444;--err-text:#fca5a5;--focus:#f9fafb;" <>
             "--ok-bg:#052e16;--ok-border:#22c55e;--ok-text:#bbf7d0;--info-bg:#172554;--info-border:#60a5fa;--info-text:#bfdbfe}",
           "@media (prefers-color-scheme:light){:root{--bg:#f3f4f6;--card:#ffffff;--border:#d1d5db;--text:#111827;--muted:#4b5563;" <>
             "--accent:#c2410c;--outline:#6b7280;--warn-bg:#fffbeb;--warn-border:#b45309;--warn-text:#78350f;" <>
             "--err-bg:#fef2f2;--err-border:#b91c1c;--err-text:#7f1d1d;--focus:#111827;" <>
             "--ok-bg:#f0fdf4;--ok-border:#15803d;--ok-text:#14532d;--info-bg:#eff6ff;--info-border:#1d4ed8;--info-text:#1e3a8a}}",
           "*,*::before,*::after{box-sizing:border-box}",
           "body{margin:0;padding:1.5rem 1rem;background:var(--bg);color:var(--text);" <>
             "font-family:Inter,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;font-size:1rem;line-height:1.6}",
           ".shell{max-width:30rem;margin:0 auto}",
           ".brand{display:flex;align-items:center;gap:.6rem;margin:0 0 1rem;font-size:1.1rem;font-weight:600}",
           ".logo{width:32px;height:32px;flex:none;color:var(--accent)}",
           ".logo polygon,.logo path{fill:none;stroke:currentColor;stroke-width:2;stroke-linejoin:round;stroke-linecap:round}",
           "main{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:1.5rem 1.25rem}",
           "h1{margin:.5rem 0 .75rem;font-size:1.5rem;font-weight:600;letter-spacing:-.02em;line-height:1.25;overflow-wrap:anywhere}",
           "p{margin:0 0 1rem;overflow-wrap:anywhere}",
           ".muted{color:var(--muted);font-size:.9rem}",
           ".host{font-weight:600;overflow-wrap:anywhere}",
           ".status{display:block;width:32px;height:32px;fill:none;stroke:var(--err-border);stroke-width:2;stroke-linecap:round}",
           "details{margin:1rem 0 0;padding-top:.5rem;border-top:1px solid var(--border)}",
           "summary{display:list-item;padding:.65rem 0;min-height:44px;color:var(--accent);cursor:pointer}",
           "details ul{margin:.25rem 0 0;padding-left:1.25rem}",
           "li{margin:.35rem 0;overflow-wrap:anywhere}",
           ".notice{margin:0 0 1rem;padding:.75rem 1rem;border:1px solid;border-radius:8px;overflow-wrap:anywhere}",
           ".notice.warn{background:var(--warn-bg);border-color:var(--warn-border);color:var(--warn-text)}",
           ".notice.error{background:var(--err-bg);border-color:var(--err-border);color:var(--err-text)}",
           ".btn{display:inline-flex;align-items:center;justify-content:center;min-height:44px;padding:0 1.25rem;" <>
             "border:1px solid var(--outline);border-radius:8px;background:transparent;color:var(--text);" <>
             "font:inherit;font-weight:600;text-decoration:none;cursor:pointer}",
           ".btn.primary{background:var(--primary);border-color:var(--primary);color:var(--on-primary)}",
           ":focus-visible{outline:3px solid var(--focus);outline-offset:2px}",
           # consent page (story oauth-pages-redesign/03): notice with icon, app block, permission line, actions, field, details list
           ".notice.icon{display:flex;gap:.6rem;align-items:flex-start;border-width:2px}",
           ".notice.icon svg{flex:none;width:20px;height:20px;margin-top:.15rem}",
           ".notice.icon p{margin:0}",
           ".app{display:flex;align-items:center;gap:.75rem;background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:.75rem 1rem;margin:0 0 1rem}",
           ".app>div{min-width:0}",
           ".app .name{display:block;font-weight:600;font-size:1.1rem;overflow-wrap:anywhere}",
           ".app .claim{display:block;color:var(--muted);font-size:.8rem}",
           ".perm{display:flex;gap:.6rem;align-items:flex-start;margin:0 0 1rem}",
           ".perm svg{flex:none;width:20px;height:20px;margin-top:.2rem}",
           ".perm p{margin:0}",
           ".devname{margin:0 0 1rem}",
           ".actions{display:flex;flex-wrap:wrap;gap:.75rem;margin-top:1.25rem}",
           ".actions .btn{flex:1 1 9rem;min-height:48px}",
           ".btn.secondary{border-width:2px}",
           ".btn[aria-disabled=true]{opacity:.55;cursor:not-allowed}",
           ".hint{margin:.75rem 0 0}",
           ".fine{margin:1rem 0 0;color:var(--muted);font-size:.85rem}",
           ".field{margin:0 0 .5rem}",
           ".field label{display:block;font-weight:600;margin-bottom:.35rem}",
           ".field input{width:100%;min-height:48px;padding:.6rem .8rem;border-radius:8px;border:2px solid var(--outline);background:var(--bg);color:var(--text);font:inherit}",
           ".field p{margin:.35rem 0 0}",
           "dl{margin:.25rem 0 0}dt{color:var(--muted);font-size:.8rem;margin-top:.75rem}dd{margin:0;overflow-wrap:anywhere}",
           "code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.95em;overflow-wrap:anywhere}",
           ".sr-only{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0,0,0,0);clip-path:inset(50%);white-space:nowrap;border:0}",
           # account portal (story oauth-pages-redesign/05): wide shell, who line, nav, tiles, cards, success / info notices, danger button
           "a{color:var(--accent)}",
           ".shell.wide{max-width:44rem}",
           ".who{margin:0 0 1rem;color:var(--muted);font-size:.9rem}",
           "nav.portal ul{list-style:none;display:flex;flex-wrap:wrap;gap:.25rem;margin:0 0 1rem;padding:.25rem;background:var(--card);border:1px solid var(--border);border-radius:10px}",
           "nav.portal li{margin:0}",
           "nav.portal a{display:flex;align-items:center;min-height:44px;padding:0 .9rem;border-radius:8px;color:var(--text);text-decoration:none;font-weight:500}",
           "nav.portal a[aria-current=page]{background:var(--primary);color:var(--on-primary);font-weight:600}",
           ".tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(11rem,1fr));gap:.75rem;margin:0 0 1rem}",
           ".tile{display:block;background:var(--bg);border:1px solid var(--border);border-radius:12px;padding:1rem 1.25rem;color:var(--text);text-decoration:none}",
           ".tile b{display:block;font-size:1.05rem}.tile span{display:block;color:var(--muted);font-size:.9rem}",
           "ul.cards{list-style:none;margin:0;padding:0;display:grid;gap:.75rem}",
           ".card{background:var(--bg);border:1px solid var(--border);border-radius:12px;padding:1rem 1.25rem;margin:0}",
           "section.card{margin:0 0 .75rem}",
           ".card .top{display:flex;flex-wrap:wrap;align-items:flex-start;justify-content:space-between;gap:.75rem}",
           ".card .top>div{min-width:0;flex:1 1 12rem}",
           ".card h2{margin:0;font-size:1.05rem;font-weight:600;overflow-wrap:anywhere}",
           ".card .meta{margin:.1rem 0 0;color:var(--muted);font-size:.9rem}",
           ".card details{margin-top:.5rem}",
           ".card dl{display:grid;grid-template-columns:max-content 1fr;gap:.25rem 1rem;font-size:.9rem}",
           ".card dt{margin:0}",
           ".card .actions{margin-top:.75rem}",
           ".actions form{flex:1 1 9rem;margin:0}.actions form .btn{width:100%}",
           ".btn.danger{border:2px solid var(--err-border);color:var(--err-text)}",
           ".notice.success{background:var(--ok-bg);border-color:var(--ok-border);color:var(--ok-text)}",
           ".notice.info{background:var(--info-bg);border-color:var(--info-border);color:var(--info-text)}",
           ".foot{margin-top:1.5rem;padding-top:1rem;border-top:1px solid var(--border)}.foot form{margin:0}",
           "@media (forced-colors:active){main,.notice,.btn,.app,.card,.tile{border:1px solid CanvasText}nav.portal a[aria-current=page]{border:3px solid Highlight}}"
         ],
         "\n"
       )

  # One source for both policies: prefix (default + style hash) and suffix (base-uri, form-action, frame-ancestors).
  @csp_prefix "default-src 'none'; style-src 'sha256-#{Base.encode64(:crypto.hash(:sha256, @css))}'; "
  @csp_suffix "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  @csp @csp_prefix <> @csp_suffix

  @logo ~s(<svg class="logo" viewBox="0 0 32 32" width="32" height="32" aria-hidden="true" focusable="false">) <>
          ~s(<polygon points="16,2 28,9 28,23 16,30 4,23 4,9"/><path d="M11 22V10l10 12V10"/></svg>)

  @status_icon ~s(<svg class="status" viewBox="0 0 24 24" width="32" height="32" aria-hidden="true" focusable="false">) <>
                 ~s(<circle cx="12" cy="12" r="10"/><path d="M12 7v6M12 16.5v.5"/></svg>)

  @doc "The one shared stylesheet (the content of the page's single inline `<style>`)."
  @spec css() :: String.t()
  def css, do: @css

  @doc "The `Content-Security-Policy` value of every shell page: the one style hash, everything else `'none'`."
  @spec csp() :: String.t()
  def csp, do: @csp

  @doc """
  The `Content-Security-Policy` of a shell page that carries ONE pinned inline script (`script` = the exact text between
  `<script>` and `</script>`): like `csp/0` plus `script-src 'sha256-<script>'`, nothing else allowed.
  """
  @spec csp_with_script(String.t()) :: String.t()
  def csp_with_script(script) when is_binary(script) do
    @csp_prefix <> "script-src 'sha256-#{Base.encode64(:crypto.hash(:sha256, script))}'; " <> @csp_suffix
  end

  @doc "The inline hexagon-N logo (decorative SVG)."
  @spec logo() :: String.t()
  def logo, do: @logo

  @doc "A decorative status icon (exclamation in a circle) for error pages."
  @spec status_icon() :: String.t()
  def status_icon, do: @status_icon

  @doc "HTML-escapes plain text (catalog texts and every request-derived value)."
  @spec esc(term()) :: String.t()
  def esc(text), do: text |> to_string() |> Plug.HTML.html_escape()

  @doc """
  Renders a full page. Options: `:title` (plain text, escaped here), `:main_attrs` (already-safe
  attribute string for `<main>`, e.g. the `data-page` / `data-error` hooks) and `:content`
  (already-safe HTML inside `<main>`). Optional `:script` (the ONE pinned inline script of a decision
  page, e.g. `Nebu.Web.ArmScript.script/0`; its own CSP is built by that page): rendered after `<main>`.
  Optional `:wide` (the 44 rem portal shell instead of the 30 rem decision card) and `:before_main` (already-safe HTML between the
  brand header and `<main>`, e.g. the portal's "signed in as" line and navigation).
  """
  @spec render(Nebu.Web.Locale.t(), keyword()) :: String.t()
  def render(lang, opts) when lang in [:en, :de] do
    title = esc(Keyword.fetch!(opts, :title))
    main_attrs = Keyword.fetch!(opts, :main_attrs)
    content = Keyword.fetch!(opts, :content)
    script = if js = Keyword.get(opts, :script), do: "<script>#{js}</script>\n", else: ""
    shell_class = if Keyword.get(opts, :wide, false), do: "shell wide", else: "shell"
    before_main = if html = Keyword.get(opts, :before_main), do: html <> "\n", else: ""

    """
    <!doctype html>
    <html lang="#{lang}">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="dark light">
      <title>#{title}</title>
      <style>#{@css}</style>
    </head>
    <body>
    <div class="#{shell_class}">
    <header class="brand">#{@logo}<span>Nebu</span></header>
    #{before_main}<main #{main_attrs}>
    #{content}
    </main>
    </div>
    #{script}</body>
    </html>
    """
  end
end
