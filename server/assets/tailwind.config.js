/** @type {import('tailwindcss').Config} */
// Nebu Admin UI design system (Tailwind + DaisyUI).
// Restores the original "Obsidian" dark theme (UX-DR1) + typography scale (UX-DR2)
// that the Go admin UI shipped, now driving the Phoenix LiveView admin templates.
// The DaisyUI theme is named "nebu" to match `<html data-theme="nebu">` in
// Nebu.Admin.Layouts. Colour values are WCAG-AA tuned (contrast ratios in comments).
module.exports = {
  // Scan the LiveView admin templates (~H sigils in .ex) for utility/component classes.
  content: ["../lib/nebu/**/*.{ex,heex,eex}"],
  plugins: [require("daisyui")],
  daisyui: {
    themes: [
      {
        nebu: {
          "primary":           "#f97316", // buttons, active nav
          "primary-content":   "#1c1917", // dark on orange — 5.98:1 WCAG AA
          "secondary":         "#374151",
          "secondary-content": "#f9fafb",
          "accent":            "#f59e0b",
          "accent-content":    "#1f2937",
          "neutral":           "#374151",
          "neutral-content":   "#9ca3af",
          "base-100":          "#111827", // page background
          "base-200":          "#1f2937", // cards, panels, sidebar
          "base-300":          "#374151", // hover, overlays, borders
          "base-content":      "#f9fafb", // primary text
          "success":           "#22c55e",
          "success-content":   "#052e16",
          "warning":           "#f59e0b",
          "warning-content":   "#431407",
          "error":             "#ef4444",
          "error-content":     "#000000", // black on red — 5.9:1 WCAG AA
          "info":              "#6b7280",
          "info-content":      "#f9fafb",
        },
      },
    ],
    darkTheme: "nebu",
    logs: false,
  },
  theme: {
    extend: {
      colors: {
        "primary-hover":   "#ea580c",
        "primary-subtle":  "#431407",
        "text-secondary":  "#9ca3af",
        "text-disabled":   "#4b5563",
        "status-ok-bg":    "#052e16",
        "status-warn-bg":  "#431407",
        "status-error-bg": "#450a0a",
        // trace-map-leitstand UX gate V5: text-on-status-error-bg pairing
        // (the dummy's own choice) — #fca5a5 on #450a0a = 8.51:1 WCAG AA;
        // the plain error token (#ef4444) only reaches 4.29:1 there.
        "status-error-text": "#fca5a5",
        "base-400":        "#0d1117",
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "sans-serif"],
        mono: ["JetBrains Mono", "monospace"],
      },
      fontSize: {
        display: ["2.25rem", { fontWeight: "700", lineHeight: "1.2", letterSpacing: "-0.02em" }],
        heading: ["1.5rem", { fontWeight: "600", lineHeight: "1.2", letterSpacing: "-0.02em" }],
        body: ["1rem", { fontWeight: "400", lineHeight: "1.6" }],
        caption: ["0.75rem", { fontWeight: "400", lineHeight: "1.5", letterSpacing: "0.08em" }],
        mono: ["0.875rem", { fontWeight: "400", lineHeight: "1.5" }],
      },
    },
  },
};
