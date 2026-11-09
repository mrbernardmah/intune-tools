# Remediation Builder

Describe a problem in plain English and get a ready-to-import **Intune Remediation** pair
(detection + remediation PowerShell), already linted and virtually tested by Claude.

## How it works

1. **Generate** – Claude writes `detection.ps1` and `remediation.ps1` following Intune's rules
   (exit 0 = compliant, exit 1 = fix needed, read-only detection, idempotent remediation, one status line
   under 2048 characters, no interactive input) plus 4-6 test scenarios.
2. **Static checks** – deterministic rules (no AI) flag interactive prompts, missing exit codes, detection that
   changes state, destructive deletes, disabled security controls, hard-coded secrets, remote code execution,
   reboots, and scripts over the 200 KB limit.
3. **Virtual test** – a second Claude pass mentally executes both scripts line by line against every scenario
   (compliant, fixable, feature missing, failure), including the post-remediation re-check Intune performs.
4. **Auto-fix loop** – failures and lint errors are fed back to Claude, up to the number of rounds you choose,
   then re-tested. A "pass" from the AI is overridden if the static checks still find errors.

> **The virtual test is a simulation, not execution.** Claude reasons about what the scripts would do; nothing
> runs on a real device. Read the code and pilot on a small device group before assigning widely.

## Use it

Open `index.html` locally, or host it with GitHub Pages (see below). Paste your Anthropic API key,
describe the detection and fix, click **Generate and test**, then copy or download the two `.ps1` files.

In the Intune admin center: **Devices > Scripts and remediations > Remediations > Create**, upload the
detection and remediation scripts, and use the recommended run context and 64-bit setting shown with the result.

### Privacy and key handling

- The page is static. Requests go from your browser straight to `api.anthropic.com`; there is no backend.
- The key is kept in memory unless you tick **Remember in this browser** (stored in `localStorage`).
  Use a key with a spend limit, and do not use this on a shared machine with remembering enabled.
- Do not paste tenant secrets or real user data into the request. Your description is sent to Claude.

### Host on GitHub Pages

The workflow in `.github/workflows/pages.yml` publishes this folder. One-time setup: in the repo go to
**Settings > Pages > Build and deployment > Source** and choose **GitHub Actions**. After the next push to `main`
the builder is live at `https://mrbernardmah.github.io/intune-tools/`.

### Standalone file

`node remediation-builder/build.js` writes `remediation-builder/dist/index.html`: one self-contained file with the
logic inlined. You can open it from disk or drop it on any static host. It also writes `dist/sitemap.xml`.
`dist/` is committed and a test fails if it falls out of date, so rebuild after editing `index.html` or `builder.js`.

### Get it found on Google

The page already has a title, description, canonical URL, Open Graph tags, structured data and real text content
for crawlers. Google only indexes a site once it has found it, and nothing can force or guarantee that, so do this
once after Pages is live:

1. Open [Google Search Console](https://search.google.com/search-console) and add a **URL prefix** property for
   `https://mrbernardmah.github.io/intune-tools/`.
2. Verify ownership with the **HTML tag** method: paste the `<meta name="google-site-verification" ...>` tag Google
   gives you into the `<head>` of `index.html`, then run the build and push.
3. Use **URL Inspection** on the page and click **Request indexing**, and submit `sitemap.xml` under **Sitemaps**.
4. Expect days to weeks before it appears in results. Links from your repo README and other pages help.

GitHub project sites cannot serve a root `robots.txt`, which is fine here because crawling is allowed by default.
If you move to your own domain, update the canonical URL in `index.html` and rebuild.

## Develop

No dependencies and no build step. Run the tests with Node 18+:

```
node --test remediation-builder/test/*.test.js
```

The tests cover JSON extraction, bundle validation, every lint rule, the API request shape, and the full
generate / test / fix pipeline against a mocked Claude API.
