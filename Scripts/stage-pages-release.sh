#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

app_name="Simple Playback"
build_root="${BUILD_ROOT:-build/distribution}"
pages_dir="${PAGES_DIR:-docs}"
version="${1:-}"

if [[ -z "$version" ]]; then
  dmg_candidates=("${build_root}"/Simple\ Playback-*.dmg(N))
  if [[ ${#dmg_candidates[@]} -ne 1 ]]; then
    echo "usage: $0 <version>" >&2
    echo "Could not infer a single release DMG from ${build_root}." >&2
    exit 64
  fi
  dmg_name="${dmg_candidates[1]:t}"
  version="${dmg_name#Simple Playback-}"
  version="${version%.dmg}"
fi

dmg_source="${build_root}/${app_name}-${version}.dmg"
zip_source="${build_root}/appcast/${app_name}-${version}.zip"
appcast_source="${build_root}/appcast/appcast.xml"
icon_source="${repo_root}/Simple Playback/Support/AppIcon.icon/Assets/PlayTriangle.png"

for required_file in "$dmg_source" "$zip_source" "$appcast_source" "$icon_source"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 66
  fi
done

mkdir -p "$pages_dir"
touch "${pages_dir}/.nojekyll"

cp "$dmg_source" "${pages_dir}/${app_name}-${version}.dmg"
cp "$zip_source" "${pages_dir}/${app_name}-${version}.zip"
cp "$appcast_source" "${pages_dir}/appcast.xml"
cp "$icon_source" "${pages_dir}/icon.png"

shasum -a 256 \
  "${pages_dir}/${app_name}-${version}.dmg" \
  "${pages_dir}/${app_name}-${version}.zip" \
  > "${pages_dir}/checksums.txt"

dmg_size="$(du -h "${pages_dir}/${app_name}-${version}.dmg" | awk '{print $1}')"
zip_size="$(du -h "${pages_dir}/${app_name}-${version}.zip" | awk '{print $1}')"
dmg_sha="$(shasum -a 256 "${pages_dir}/${app_name}-${version}.dmg" | awk '{print $1}')"
release_date="$(stat -f "%Sm" -t "%B %e, %Y" "${pages_dir}/${app_name}-${version}.dmg")"

cat > "${pages_dir}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Simple Playback ${version}</title>
  <meta name="description" content="Download Simple Playback for macOS.">
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f5f7f8;
      --ink: #17191c;
      --muted: #606873;
      --line: #d8dde3;
      --panel: #ffffff;
      --accent: #0f766e;
      --accent-hover: #115e59;
      --shadow: 0 18px 45px rgba(14, 20, 28, 0.12);
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #111315;
        --ink: #f3f5f7;
        --muted: #a9b0ba;
        --line: #2c3238;
        --panel: #191d21;
        --accent: #2dd4bf;
        --accent-hover: #5eead4;
        --shadow: 0 18px 45px rgba(0, 0, 0, 0.32);
      }
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--ink);
      letter-spacing: 0;
    }

    main {
      width: min(980px, calc(100vw - 32px));
      margin: 0 auto;
      padding: 56px 0 48px;
    }

    .release {
      display: grid;
      grid-template-columns: minmax(0, 1.2fr) minmax(280px, 0.8fr);
      gap: 28px;
      align-items: start;
    }

    .brand {
      display: flex;
      gap: 18px;
      align-items: center;
      margin-bottom: 28px;
    }

    .brand img {
      width: 92px;
      height: 92px;
      border-radius: 22px;
      box-shadow: var(--shadow);
    }

    h1 {
      margin: 0;
      font-size: clamp(2.2rem, 7vw, 4.2rem);
      line-height: 0.96;
      font-weight: 750;
    }

    .subtitle {
      margin: 18px 0 0;
      max-width: 620px;
      font-size: 1.12rem;
      line-height: 1.55;
      color: var(--muted);
    }

    .download-panel {
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      padding: 22px;
      box-shadow: var(--shadow);
    }

    .version {
      display: flex;
      justify-content: space-between;
      gap: 16px;
      padding-bottom: 16px;
      border-bottom: 1px solid var(--line);
      font-size: 0.95rem;
      color: var(--muted);
    }

    .download-button {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 48px;
      margin-top: 18px;
      border-radius: 8px;
      background: var(--accent);
      color: #ffffff;
      text-decoration: none;
      font-weight: 700;
    }

    .download-button:hover { background: var(--accent-hover); }

    .meta {
      display: grid;
      gap: 12px;
      margin-top: 18px;
      color: var(--muted);
      font-size: 0.92rem;
      line-height: 1.45;
    }

    .hash {
      overflow-wrap: anywhere;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 0.82rem;
    }

    .links {
      display: flex;
      flex-wrap: wrap;
      gap: 14px;
      margin-top: 20px;
    }

    .links a {
      color: var(--accent);
      text-decoration: none;
      font-weight: 650;
    }

    .links a:hover { text-decoration: underline; }

    .notes {
      margin-top: 44px;
      padding-top: 24px;
      border-top: 1px solid var(--line);
    }

    h2 {
      margin: 0 0 12px;
      font-size: 1.1rem;
    }

    ul {
      margin: 0;
      padding-left: 20px;
      color: var(--muted);
      line-height: 1.7;
    }

    @media (max-width: 760px) {
      main { padding-top: 32px; }
      .release { grid-template-columns: 1fr; }
      .brand { align-items: flex-start; }
      .brand img { width: 74px; height: 74px; border-radius: 18px; }
    }
  </style>
</head>
<body>
  <main>
    <section class="release" aria-label="Simple Playback release">
      <div>
        <div class="brand">
          <img src="icon.png" alt="Simple Playback app icon">
          <h1>Simple Playback</h1>
        </div>
        <p class="subtitle">A macOS playback app for still images and videos with software preview, media takes, crossfades, and DeckLink output.</p>
        <div class="notes">
          <h2>Release Notes</h2>
          <ul>
            <li>Initial signed and notarized macOS distribution build.</li>
            <li>Sparkle update feed is enabled for future releases.</li>
            <li>Requires macOS 26.0 or later.</li>
          </ul>
        </div>
      </div>

      <aside class="download-panel" aria-label="Download">
        <div class="version">
          <span>Version ${version}</span>
          <span>${release_date}</span>
        </div>
        <a class="download-button" href="Simple%20Playback-${version}.dmg">Download for macOS</a>
        <div class="meta">
          <div>DMG size: ${dmg_size}</div>
          <div>Update zip: ${zip_size}</div>
          <div>SHA-256</div>
          <div class="hash">${dmg_sha}</div>
        </div>
        <div class="links">
          <a href="appcast.xml">Appcast</a>
          <a href="checksums.txt">Checksums</a>
          <a href="Simple%20Playback-${version}.zip">Sparkle zip</a>
        </div>
      </aside>
    </section>
  </main>
</body>
</html>
EOF

cat <<EOF
Staged GitHub Pages release files in ${pages_dir}:
  ${app_name}-${version}.dmg
  ${app_name}-${version}.zip
  appcast.xml
  checksums.txt
  icon.png
  index.html
EOF
