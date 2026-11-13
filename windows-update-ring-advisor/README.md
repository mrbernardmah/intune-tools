# Windows Update Ring Advisor

A single-file, offline HTML tool that recommends *Update rings for Windows 10 and later* settings in Intune.

Pick a ring, region, release cycle and compliance target (Microsoft "Current", Essential Eight ML1–ML3). Enter your current ring settings to see what differs, how long devices stay unpatched, and whether you meet your target. Export the recommended settings as a checklist or Graph JSON (beta).

## Use

Open `index.html` in any browser, put it on a file share, or host it internally. It needs no internet connection and no install. Only the source links on the page need a connection. Your current-ring entries are saved in the browser's local storage.
