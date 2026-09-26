#!/bin/bash
# Render plain-text release notes into the HTML sidecar Sparkle embeds.
#
#   scripts/render_notes_html.sh <notes.txt> <out.html>
#
# Restricted input format: "New:"/"Fixes:" style headings (a line ending in a
# colon), "- " bullets, and plain paragraphs. make_appcast.sh writes the output
# beside the archive under the archive's base name, and
# `generate_appcast --embed-release-notes` places it inside the item's
# <description> CDATA.
#
# Split out of make_appcast.sh so the escaping can be exercised on its own
# (`--self-test`); make_appcast.sh deletes its work directory on exit, which
# left the rendered bytes unobservable.
#
# `>` is escaped as well as `&` and `<`. HTML does not need it, but the output
# lands inside CDATA, where a raw `]]>` ends the section. Whether
# generate_appcast splits such a sequence when it embeds the sidecar is
# unverified; escaping `>` removes the question. Two historical notes
# contained `>` (v1.3.0, v1.16.0) and would now render `&gt;`, which displays
# the same; items already in appcast.xml are preserved verbatim by
# generate_appcast and are not re-rendered.
set -euo pipefail

render() {
  awk '
    function esc(t) { gsub(/&/, "\\&amp;", t); gsub(/</, "\\&lt;", t); gsub(/>/, "\\&gt;", t); return t }
    /^- / {
      if (!inlist) { print "<ul>"; inlist = 1 }
      print "<li>" esc(substr($0, 3)) "</li>"
      next
    }
    {
      if (inlist) { print "</ul>"; inlist = 0 }
      if ($0 ~ /^[[:space:]]*$/) next
      t = esc($0)
      if (t ~ /:[[:space:]]*$/) print "<b>" t "</b>"
      else print "<p>" t "</p>"
    }
    END { if (inlist) print "</ul>" }
  ' "$1"
}

if [[ "${1:-}" == "--self-test" ]]; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  # `&lt;` in the source guards the awk-replacement regression where `&` in a
  # gsub replacement expanded to the match and turned `&lt;` into `<lt;`.
  printf '%s\n' 'Fixes:' '- a < b && c > d' '- literal &lt; stays escaped' \
    'Ends ]]> early' > "$work/in.txt"
  cat > "$work/want.html" <<'EOF'
<b>Fixes:</b>
<ul>
<li>a &lt; b &amp;&amp; c &gt; d</li>
<li>literal &amp;lt; stays escaped</li>
</ul>
<p>Ends ]]&gt; early</p>
EOF
  render "$work/in.txt" > "$work/got.html"
  if ! diff -u "$work/want.html" "$work/got.html"; then
    echo "render_notes_html self-test: FAIL" >&2
    exit 1
  fi
  echo "render_notes_html self-test: ok"
  exit 0
fi

render "$1" > "$2"
