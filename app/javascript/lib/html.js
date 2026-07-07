// html — tiny helpers for the bits we render client-side as innerHTML strings
// (command palette rows, JSON viewers). Keep these pure and dependency-free.

// escapeHtml — escape the 5 HTML-significant characters so dynamic/user text is
// safe to interpolate into an innerHTML string (mirrors Rails' ERB escaping).
export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c])
}
