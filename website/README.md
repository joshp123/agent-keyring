# Agent Keyring Website (`agent-keyring.jjpcodes.com`)

Static landing page, comparison page, and AI-agent Markdown mirrors for Agent Keyring.

## Hosting

Static hosting, CDN, TLS certificate and DNS are managed in the separate OpenTofu infrastructure repo for `jjpcodes.com`.

`appcast.xml` (the signed Sparkle 2 feed for the Mac app) is uploaded to the root of the static site bucket by `script/publish_release.sh` and served at `https://keyring.opentrawl.sh/appcast.xml`. When syncing `website/` to S3 with `--delete`, always pass `--exclude "appcast.xml"` so the live update feed is preserved.

## Files

- `index.html`: the landing page. Hero film (what the agent says, and the device you answer on), the three rules, how passwords are protected, a short comparison, the TestFlight beta link.
- `security/index.html`, `compare/index.html`: the security page and the full comparison.
- `styles.css`: light and dark themes for all three pages.
- `city.js`: the dithered pixel city behind every page. On the home page it also shows where the agent runs and where you are for the scene the film is playing.
- `app.js`: theme toggle, the mascot, the film's clock and scenes, the copy-prompt buttons.
- `assets/hardware/`: Apple's product bezels for Apple Watch and iPhone, and the Touch ID glyph. The screens inside them are HTML that follows the SwiftUI views in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/` and `AgentKeyringWatch/RequestView.swift`; change those and this must follow.
- `index.md`, `security.md`, `security/index.md`, `compare.md`, `compare/index.md`, `llms.txt`, `llms-full.txt`: Markdown copies for LLMs and coding agents. Keep them in step with the HTML.
- `robots.txt`, `sitemap.xml`: allow rules for search and AI retrieval bots.

`/?scene=2&at=4500` opens the home page with the film held still at that scene (0 to 3) and time in milliseconds, for checking a frame.

## Local preview

Serve `website/` with any static file server that sends `text/markdown; charset=utf-8` for `.md` files and `text/plain; charset=utf-8` for `llms.txt` / `llms-full.txt`.

## Launch indexing checklist (AEO / GEO)

1. Verify `https://agent-keyring.jjpcodes.com/sitemap.xml`, `/robots.txt`, `/llms.txt`, `/index.md`, and `/compare.md` return HTTP 200 with `text/markdown; charset=utf-8` (or `text/plain`) for `.md` / `.txt`.
2. Submit sitemap in Google Search Console (Gemini + AI Overviews).
3. Submit sitemap in Bing Webmaster Tools and ping IndexNow on updates (ChatGPT Search + Copilot).
4. Submit URLs at `https://search.brave.com/submit-url` (Claude Search).
