# CadNexa ↔ loglinkr integration contract

This documents the **exact** message/URL contract that loglinkr's NPD Feasibility
module already implements, so the matching code can be added to the CadNexa app
(`cadnexa.com/app.html` and the `/cadnexa` embed). loglinkr is the **fixed side** —
do not change it to fit CadNexa; implement the CadNexa side to satisfy what is
described here.

All loglinkr references below point at `app.html` in this repo
(component `NpdFeasibility…` / `CadNexaHandoff`, around lines 21745–22040).

There are **two independent handoff paths**. CadNexa should support both.

---

## Path 1 — Popup "Auto-Balloon" tool (new tab)

### What loglinkr sends
When the engineer taps **🎯 Balloon**, loglinkr opens a new tab (handle kept, no
`noopener`, so `window.opener` is live):

```
https://cadnexa.com/app.html?tool=autoBalloon
    &fileUrl=<https URL of the stored customer drawing>
    &fileName=<original file name>
    &returnTo=<loglinkr origin, e.g. https://app.loglinkr.com>
    &projectId=<loglinkr project UUID>
    &projectCode=<human project code, may be empty>
```

### What CadNexa must do on load (HOOK A — new)
In `app.html` boot, read the query string. If `tool === 'autoBalloon'`:

1. If `fileUrl` is present, fetch it and load it into the 2D drafter
   (same code path as a normal "open 2D drawing"), using `fileName` for the title.
2. Auto-run the ballooning routine once the drawing is loaded.
3. Remember `returnTo` and `projectId` for the export step below.

### HOOK A (recommended) — self-contained loader, no internal function names

Paste this once near the end of CadNexa `app.html` (before `</body>`). It fetches
the drawing and feeds it into the existing **"Drop drawing here"** upload box by
setting the file `<input>` and firing a synthetic drop — so it works without
knowing CadNexa's internal loader names. Verified against the tool UI
("Drop drawing here · PDF · JPG · PNG" + "✨ Auto-detect dimensions").

```js
<script>
(function loglinkrAutoBalloon () {
  var q = new URLSearchParams(location.search);
  if (q.get('tool') !== 'autoBalloon') return;
  var fileUrl  = q.get('fileUrl'); if (!fileUrl) return;
  var fileName = q.get('fileName') || 'drawing.pdf';

  // Keep return context so exports can post back to loglinkr (see HOOK B).
  window.__cnxReturn = { returnTo: q.get('returnTo') || '', projectId: q.get('projectId') || '', opener: window.opener || null };

  function deliver (file) {
    var input = document.querySelector('input[type=file]');
    if (input) {                                   // react-dropzone hidden input
      var dt = new DataTransfer(); dt.items.add(file);
      input.files = dt.files;
      input.dispatchEvent(new Event('change', { bubbles: true }));
    }
    // also simulate a real drop in case the zone is drop-only
    try {
      var zone = document.querySelector('[data-dropzone],.dropzone') || document.body;
      var dt2 = new DataTransfer(); dt2.items.add(file);
      ['dragenter','dragover','drop'].forEach(function (t) {
        var ev = new DragEvent(t, { bubbles: true, cancelable: true });
        Object.defineProperty(ev, 'dataTransfer', { value: dt2 });
        zone.dispatchEvent(ev);
      });
    } catch (_) {}
  }

  function go (tries) {
    tries = tries || 0;
    if (!document.querySelector('input[type=file]') && tries < 40) { return setTimeout(function(){ go(tries+1); }, 250); }
    fetch(fileUrl).then(function (r) { return r.blob(); }).then(function (b) {
      var lower = fileName.toLowerCase();
      var type = b.type || (lower.endsWith('.pdf') ? 'application/pdf' : 'image/' + lower.split('.').pop());
      deliver(new File([b], fileName, { type: type }));
      // Optional: auto-click "Auto-detect dimensions" once the file is in.
      // setTimeout(function(){ var btn=[].find.call(document.querySelectorAll('button'),function(x){return /Auto-detect dimensions/i.test(x.textContent);}); if(btn) btn.click(); }, 1200);
    }).catch(function (e) { console.warn('[autoBalloon] fetch failed', e); });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function(){ go(); });
  else go();
})();
</script>
```

> Note: the drawing's `fileUrl` is a public Supabase URL on loglinkr's storage —
> a cross-origin `fetch` from cadnexa.com works as long as that bucket allows
> public GET (it does today). If a CORS error appears, allow `cadnexa.com` on
> the storage bucket.

### HOOK A (alternative) — wire to CadNexa's own loader (if you prefer)

```js
// --- HOOK A: loglinkr Auto-Balloon deep link -------------------------------
(function initLoglinkrAutoBalloon () {
  const q = new URLSearchParams(location.search);
  if (q.get('tool') !== 'autoBalloon') return;

  window.__cnxReturn = {

  window.__cnxReturn = {
    returnTo:  q.get('returnTo')  || '',          // loglinkr origin to post back to
    projectId: q.get('projectId') || '',
    opener:    window.opener || null,
  };

  const fileUrl  = q.get('fileUrl');
  const fileName = q.get('fileName') || 'drawing';
  if (!fileUrl) return;

  // Fetch the stored drawing and load it into the 2D drafter, then balloon.
  fetch(fileUrl)
    .then(r => r.blob())
    .then(blob => {
      const file = new File([blob], fileName, { type: blob.type });
      // >>> call CadNexa's existing "load a 2D drawing" entry point here <<<
      //     e.g. loadDrawingFile(file)  — wire to the real function name.
      return loadDrawingFile(file);
    })
    .then(() => {
      // >>> call CadNexa's existing "auto-balloon current drawing" routine <<<
      //     e.g. autoBalloonCurrentDrawing()
      if (typeof autoBalloonCurrentDrawing === 'function') autoBalloonCurrentDrawing();
    })
    .catch(err => console.warn('[autoBalloon] load failed', err));
})();
```

> The only two project-specific bits to wire are the real function names for
> **load a 2D drawing** and **auto-balloon the current drawing**.

### What CadNexa must post back (HOOK B — at each export call site)
loglinkr listens on `window` for `message` events of type `CNX_RESULT` and files
the payload against the project automatically (see `app.html` ~21838–21854):

```js
// loglinkr's receiver (already live — for reference only):
if (!d || d.type !== 'CNX_RESULT') return;
if (d.projectId && d.projectId !== p.id) return;
const kind = d.kind === 'fai_report' ? 'fai_report' : 'balloon_drawing';
// uses d.dataUrl (base64 data: URL) OR d.url (https), plus d.name, d.contentType
```

So wherever CadNexa **exports the ballooned drawing PDF** and **exports the FAI
report PDF**, also call this helper (in addition to / instead of the download):

```js
// --- HOOK B: post an export back to loglinkr -------------------------------
function postResultToLoglinkr (kind, blobOrDataUrl, name, contentType) {
  const ctx = window.__cnxReturn;
  if (!ctx || !ctx.opener) return;            // not launched from loglinkr → no-op

  const send = (payload) => {
    try { ctx.opener.postMessage(payload, ctx.returnTo || '*'); } catch (_) {}
  };
  const base = {
    type: 'CNX_RESULT',
    kind: kind === 'fai_report' ? 'fai_report' : 'balloon_drawing',
    name: name || (kind + '.pdf'),
    contentType: contentType || 'application/pdf',
    projectId: ctx.projectId || undefined,
  };

  if (typeof blobOrDataUrl === 'string') {     // already a data: URL
    send({ ...base, dataUrl: blobOrDataUrl });
  } else {                                     // a Blob/File → convert to data URL
    const fr = new FileReader();
    fr.onload = () => send({ ...base, dataUrl: fr.result });
    fr.readAsDataURL(blobOrDataUrl);
  }
}

// Call sites (wire to the real export code):
//   ballooned drawing PDF exported:
//     postResultToLoglinkr('balloon_drawing', pdfBlob, 'ballooned.pdf', 'application/pdf');
//   FAI report PDF exported:
//     postResultToLoglinkr('fai_report', faiBlob, 'fai-report.pdf', 'application/pdf');
```

Result: the moment CadNexa exports, the file lands on the loglinkr project with
**zero manual upload**. (loglinkr keeps the one-tap manual attach as a fallback,
so partial wiring is safe.)

---

## Path 2 — Iframe embed (already half-wired on the loglinkr side)

loglinkr's `CadNexaHandoff` (and the `CadNexaEmbed` 3D tab) load CadNexa in an
iframe at:

```
/cadnexa?embed=1&plant=<name>&plant_id=<id>&user=<full name>&email=<email>[&cxauto=balloon]
```

The iframe contract loglinkr already speaks (see `app.html` ~21993–22020):

| CadNexa → parent (post to `window.parent`) | loglinkr → CadNexa (reply) |
|---|---|
| `{ type:'CADNEXA_REQUEST_SHARED_FILE' }` | `{ type:'CADNEXA_SHARED_FILE', file }` — a real `File`, structured-cloned |
| `{ type:'CNX_REQUEST_AUTH' }` | `{ type:'CNX_AUTH', capabilities:{view3d,drawing2d,balloonTool,faiReport,bom,estimator,rfq:true}, effectivePlan:'bundle', isDemoMode:false, isAnonymous:false }` |

CadNexa side requirements for this path:

1. On boot inside an iframe (`window.self !== window.top`): suppress the landing
   screen / analytics chrome (loglinkr relies on this — see comment ~25505).
2. Post `CADNEXA_REQUEST_SHARED_FILE` to `window.parent` (poll until answered),
   and load the returned `file` into the viewer/drafter.
3. Post `CNX_REQUEST_AUTH`; when `CNX_AUTH` arrives, unlock the listed
   capabilities (full engineering toolset — loglinkr and CadNexa ship as one
   bundle, so embedded plant users are **not** the locked guest view).
4. If `cxauto=balloon`, auto-open the 2D drafter and balloon once the model loads.

---

## Quick test checklist
- [ ] `app.html?tool=autoBalloon&fileUrl=…&returnTo=…&projectId=…` loads the drawing and balloons it automatically.
- [ ] Exporting the ballooned PDF posts `CNX_RESULT` (kind `balloon_drawing`) to `window.opener`; it appears on the loglinkr project unprompted.
- [ ] Exporting the FAI report posts `CNX_RESULT` (kind `fai_report`); it appears on the loglinkr project.
- [ ] Embedded `/cadnexa?embed=1&cxauto=balloon` requests the shared file + auth, loads it, and balloons.
- [ ] Launched standalone (no `tool`/no `opener`): everything behaves normally, no post-backs.
