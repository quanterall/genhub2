// GenHub2's page: uploads, jobs, results, live events (the gateway's API, gh_web).
"use strict";
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]));
let selected = location.hash ? decodeURIComponent(location.hash.slice(1)) : null;

let me = null;   // {user, role} of this session
let viewer = {enabled: false, viruses: []};   // the structure viewer (gh_viewer), if the site has one

// every changing request carries the gateway's header (protection against requests from other sites); a 401 means
// the session ended, so the login form comes back
async function api(path, opts = {}) {
  const method = (opts.method || "GET").toUpperCase();
  const headers = Object.assign({}, opts.headers, method === "GET" ? {} : {"x-genhub2": "1"});
  const r = await fetch(path, Object.assign({}, opts, {headers, credentials: "same-origin"}));
  const body = await r.json().catch(() => ({}));
  if (r.status === 401 && path !== "/api/login") showLogin();
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}

function showLogin() {
  me = null;
  $("#app").hidden = true; $("#login").hidden = false;
  $("#who").hidden = true; $("#logout").hidden = true; $("#live").hidden = true;
}

// the page for the session's role: researchers see monitoring; analysts the lab's analyses; admins also users and
// the audit log
async function start() {
  try { me = await api("/api/me"); } catch (e) { showLogin(); return; }
  $("#login").hidden = true; $("#app").hidden = false;
  viewer = await api("/api/viewer").catch(() => viewer);
  $("#beacon").hidden = false;
  $("#who").textContent = `${me.user} (${me.role})`; $("#who").hidden = false; $("#logout").hidden = false;
  const lab = me.role === "admin" || me.role === "analyst";
  document.querySelectorAll(".lab").forEach((el) => { el.hidden = !lab || el.id === "detail"; });
  $("#admin").hidden = me.role !== "admin";
  if (lab) { $("#live").hidden = false; await refresh(); connect(); } else { await monitor(); }
  if (me.role === "admin") await admin();
  $("#datasets").hidden = false; $("#ds-new").hidden = me.role !== "admin";
  await datasets();
  $("#trends").hidden = false; $("#t-admin").hidden = me.role !== "admin";
  await trends();
  $("#account").hidden = false;
  await account();
}

async function account() {
  const ss = await api("/api/me/sessions");
  $("#me-sessions").innerHTML = ss.map((x) => `<li>since ${new Date(x.started).toLocaleString()}, last used
    ${new Date(x.last_used).toLocaleString()}${x.current ? " <b>(this one)</b>" : ""}</li>`).join("");
  $("#me-end").hidden = ss.length < 2;
}

$("#me-end").addEventListener("click", async () => {
  try { await api("/api/me/sessions/end-others", {method: "POST"}); $("#me-msg").textContent = "Your other sessions are ended."; }
  catch (e) { $("#me-msg").textContent = "Failed: " + e.message; }
  await account();
});

$("#me-pw").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    await api("/api/me/password", {method: "POST", headers: {"content-type": "application/json"},
      body: JSON.stringify({password: $("#me-old").value, code: $("#me-code").value.trim(), new_password: $("#me-new").value})});
    $("#me-msg").textContent = "Password changed; your other sessions are ended.";
  } catch (e) { $("#me-msg").textContent = "Failed: " + e.message; }
  $("#me-old").value = ""; $("#me-code").value = ""; $("#me-new").value = "";
  await account();
});

let agg = null;   // this site's aggregates, for the region filter

async function trends() {
  agg = await api("/api/aggregates");
  const regions = [...new Set(agg.totals.map((t) => t.region))].sort();
  const keep = $("#t-region").value;
  $("#t-region").innerHTML = `<option value="">all</option>` + regions.map((r) => `<option>${esc(r)}</option>`).join("");
  $("#t-region").value = regions.includes(keep) ? keep : "";
  drawTrends();
  $("#t-uncounted").textContent = agg.not_counted ? `${agg.not_counted} sequences without a region or collection date are not counted.` : "";
  const a = await api("/api/aggregates/alerts");
  $("#t-sites").textContent = `Sites in the merge: ${a.sites.join(", ")}; latest week ${a.latest_week ?? "none"}.`;
  $("#t-alerts").innerHTML = a.alerts.length ? a.alerts.map((x) => `<li>${x.type === "new_lineage"
      ? `new lineage <b>${esc(x.lineage)}</b> in ${esc(x.week)}: ${x.n} sequences (${esc(x.regions.join(", "))})` +
        ((x.mutations || []).length ? `, bringing ${x.mutations.length} rising mutations (${esc(x.mutations.slice(0, 5).map((m) => m.mutation.split(":")[1]).join(", "))}${x.mutations.length > 5 ? ", ..." : ""})` : "")
      : `<b>${esc(x.mutation)}</b> rising in ${esc(x.week)}: ${Math.round(x.share * 100)}% of sequences, baseline ${Math.round(x.baseline * 100)}% (${x.n})`}</li>`).join("")
    : `<li class="hint">None.</li>`;
  if (me.role === "admin") {
    const st = await api("/api/settings");
    $("#s-share").value = st.alert_thresholds.min_share; $("#s-ratio").value = st.alert_thresholds.ratio;
    $("#s-n").value = st.alert_thresholds.min_n; $("#s-weeks").value = st.alert_thresholds.baseline_weeks;
    $("#s-mqtt").checked = st.notify.mqtt;
  }
}

// weeks as rows, the most counted lineages as columns, for the chosen region
function drawTrends() {
  const r = $("#t-region").value;
  const rows = agg.lineages.filter((x) => !r || x.region === r);
  const byLin = {};
  rows.forEach((x) => { byLin[x.lineage] = (byLin[x.lineage] || 0) + x.n; });
  const lins = Object.keys(byLin).sort((a, b) => byLin[b] - byLin[a] || a.localeCompare(b)).slice(0, 8);
  const weeks = [...new Set(rows.map((x) => x.week))].sort();
  const n = (w, l) => rows.filter((x) => x.week === w && x.lineage === l).reduce((s, x) => s + x.n, 0);
  const total = (w) => agg.totals.filter((t) => t.week === w && (!r || t.region === r)).reduce((s, t) => s + t.n, 0);
  $("#t-table thead").innerHTML = `<tr><th>Week</th>${lins.map((l) => `<th>${esc(l)}</th>`).join("")}<th>All sequences</th></tr>`;
  $("#t-table tbody").innerHTML = weeks.length ? weeks.map((w) => `<tr><td>${esc(w)}</td>${lins.map((l) => `<td>${n(w, l) || ""}</td>`).join("")}
    <td>${total(w)}</td></tr>`).join("") : `<tr><td class="hint">No counted sequences yet.</td></tr>`;
}
$("#t-region").addEventListener("change", drawTrends);

$("#t-settings").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    await api("/api/settings", {method: "PUT", headers: {"content-type": "application/json"}, body: JSON.stringify({
      alert_thresholds: {min_share: parseFloat($("#s-share").value), ratio: parseFloat($("#s-ratio").value),
                         min_n: parseInt($("#s-n").value, 10), baseline_weeks: parseInt($("#s-weeks").value, 10)},
      notify: {mqtt: $("#s-mqtt").checked}})});
    $("#t-msg").textContent = "Saved.";
    await trends();
  } catch (e) { $("#t-msg").textContent = "Failed: " + e.message; }
});

$("#t-export").addEventListener("click", async () => {
  try {
    const a = await api("/api/aggregates");
    delete a.not_counted;
    const url = URL.createObjectURL(new Blob([JSON.stringify(a)], {type: "application/json"}));
    const link = Object.assign(document.createElement("a"), {href: url, download: `aggregates-${a.site}-${new Date().toISOString().slice(0, 10)}.json`});
    document.body.append(link); link.click(); link.remove(); URL.revokeObjectURL(url);
    $("#t-msg").textContent = "Downloaded: counts only, no sequences or sample names.";
  } catch (e) { $("#t-msg").textContent = "Failed: " + e.message; }
});

// Beacon (gh_beacon): a 1-based mutation name (A23403G) as Beacon v2's 0-based start
$("#b-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const q = new URLSearchParams();
  const mut = $("#b-mut").value.trim().toUpperCase(), lin = $("#b-lin").value.trim();
  const m = mut.match(/^([ACGT])([0-9]+)([ACGT])$/);
  if (mut && !m) { $("#b-result").innerHTML = `<li class="hint">A mutation looks like A23403G.</li>`; return; }
  if (m) { q.set("referenceName", $("#b-ref").value.trim()); q.set("start", String(Number(m[2]) - 1));
           q.set("referenceBases", m[1]); q.set("alternateBases", m[3]); }
  if (lin) q.set("filters", "lineage:" + lin);
  if (me.role !== "researcher") q.set("requestedGranularity", "count");
  try {
    const r = await api("/beacon/g_variants?" + q.toString());
    const sets = r.response.resultSets;
    $("#b-result").innerHTML = `<li><b>${r.responseSummary.exists ? "Yes" : "No"}</b>${r.responseSummary.numTotalResults !== undefined
        ? `: ${r.responseSummary.numTotalResults} genomes` : ""}</li>` +
      sets.filter((x) => x.exists).map((x) => `<li>dataset <code>${esc(x.id)}</code>${x.resultsCount !== undefined ? `: ${x.resultsCount}` : ""}</li>`).join("");
  } catch (e) { $("#b-result").innerHTML = `<li>${esc(e.message)}</li>`; }
});

$("#t-import").addEventListener("change", async () => {
  const f = $("#t-import").files[0];
  if (!f) return;
  try {
    const r = await api("/api/aggregates", {method: "POST", headers: {"content-type": "application/json"}, body: await f.text()});
    $("#t-msg").textContent = `Imported the aggregates of ${r.site}.`;
    await trends();
  } catch (e) { $("#t-msg").textContent = "Failed: " + e.message; }
  $("#t-import").value = "";
});

async function datasets() {
  const {datasets: ds, duo} = await api("/api/datasets");
  if (!$("#ds-consent").options.length)
    $("#ds-consent").innerHTML = Object.entries(duo).sort().map(([c, l]) => `<option value="${esc(c)}">${esc(c)} ${esc(l)}</option>`).join("");
  const from = (m) => `${esc(m.source)}: ${m.genomes} genomes` + (m.countries.length ? `, ${esc(m.countries.join(", "))}` : "")
    + (m.regions.length ? ` (${esc(m.regions.join(", "))})` : "")
    + (m.collection_weeks.length ? `<br>collected ${esc(m.collection_weeks[0])}${m.collection_weeks[1] !== m.collection_weeks[0] ? " to " + esc(m.collection_weeks[1]) : ""}` : "");
  $("#ds-list tbody").innerHTML = ds.map((d) => `<tr><td><b>${esc(d.title)}</b><br><code>${esc(d.id)}</code></td><td>${from(d.metadata)}</td>
    <td>${d.consent.map((c) => `${esc(c.code)} ${esc(c.label)}`).join("<br>")}</td><td>${esc(d.state)}</td>
    <td>${d.state === "approved" ? d.files.map((f) => `<a href="/ga4gh/drs/v1/objects/${esc(f.id)}/data">${esc(f.name)}</a>`).join("<br>") : ""}</td>
    <td>${me.role === "admin" && d.state === "approved" ? `<button class="small" data-withdraw="${esc(d.id)}">Withdraw</button>` : ""}</td></tr>`).join("");
  document.querySelectorAll("[data-withdraw]").forEach((b) => b.addEventListener("click", async () => {
    if (!confirm(`Withdraw ${b.dataset.withdraw}? It is no longer served.`)) return;
    try { await api(`/api/datasets/${encodeURIComponent(b.dataset.withdraw)}/withdraw`, {method: "POST"}); }
    catch (e) { $("#ds-msg").textContent = "Failed: " + e.message; }
    await datasets();
  }));
}

$("#ds-new").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const jobs = await chosenJobs();
    const consent = [...$("#ds-consent").selectedOptions].map((o) => o.value);
    if (!consent.length) throw new Error("choose at least one consent code");
    const d = await api("/api/datasets", {method: "POST", headers: {"content-type": "application/json"},
      body: JSON.stringify({title: $("#ds-title").value.trim(), description: $("#ds-desc").value.trim(), consent, jobs})});
    $("#ds-msg").textContent = `Shared ${d.id}: ${d.jobs} analyses.`;
    await datasets();
  } catch (e) {
    $("#ds-msg").textContent = "Failed: " + e.message;
  }
});

$("#login-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  $("#l-msg").textContent = "";
  try {
    await api("/api/login", {method: "POST", headers: {"content-type": "application/json"},
      body: JSON.stringify({user: $("#l-user").value.trim(), password: $("#l-pw").value, code: $("#l-code").value.trim()})});
    $("#l-pw").value = ""; $("#l-code").value = "";
    await start();
  } catch (e) {
    $("#l-msg").textContent = e.message;
  }
});

$("#logout").addEventListener("click", async () => {
  try { await api("/api/logout", {method: "POST"}); } finally { location.reload(); }
});

async function admin() {
  const st = me.storage;
  $("#a-storage").textContent = !st ? "" : st.check === "off" ? "Storage: the encryption check is off."
    : "Storage: " + st.directories.map((d) => `${d.directory} ${d.result === "encrypted" ? "is on an encrypted volume"
        : d.result === "unencrypted" ? "is NOT on an encrypted volume" : "could not be checked"}`).join("; ") +
      (st.directories.every((d) => d.result === "encrypted") ? "." : ` (setting: ${st.check}).`);
  const users = await api("/api/users");
  $("#a-users tbody").innerHTML = users.sort((a, b) => a.name.localeCompare(b.name)).map((u) => `<tr>
    <td>${esc(u.name)}</td><td>${esc(u.role)}</td>
    <td>${u.disabled ? "disabled" : u.locked ? "locked" : "active"}</td><td>${new Date(u.created).toLocaleDateString()}</td>
    <td>${u.disabled || u.name === me.user ? "" : `<button class="small" data-disable="${esc(u.name)}">Disable</button>
      <button class="small" data-reset="${esc(u.name)}">Reset</button>`}</td></tr>`).join("");
  document.querySelectorAll("[data-reset]").forEach((b) => b.addEventListener("click", async () => {
    const pw = prompt(`New password for ${b.dataset.reset} (12 characters or more). Their sessions end, and they get a new one-time secret.`);
    if (!pw) return;
    try {
      const u = await api(`/api/users/${encodeURIComponent(b.dataset.reset)}/reset`, {method: "POST",
        headers: {"content-type": "application/json"}, body: JSON.stringify({password: pw})});
      $("#a-secret").innerHTML = `<b>${esc(u.user)}</b> reset: give them their new password, and this secret for an
        authenticator app now; it is not shown again.<br>Secret: <code>${esc(u.totp_secret)}</code><br>Or as a link:
        <code>${esc(u.totp_uri)}</code>`;
      $("#a-secret").hidden = false;
    } catch (e) { $("#a-msg").textContent = "Failed: " + e.message; }
    await admin();
  }));
  document.querySelectorAll("[data-disable]").forEach((b) => b.addEventListener("click", async () => {
    if (!confirm(`Disable ${b.dataset.disable}? Their sessions end now.`)) return;
    try { await api(`/api/users/${encodeURIComponent(b.dataset.disable)}/disable`, {method: "POST"}); }
    catch (e) { $("#a-msg").textContent = "Failed: " + e.message; }
    await admin();
  }));
  const v = await api("/api/audit/verify");
  $("#a-verify").textContent = v.whole ? `The chain of ${v.records} records is whole.`
    : `The chain is broken at record ${v.broken_at}.`;
  const log = await api("/api/audit?from=1&limit=10000");
  $("#a-audit tbody").innerHTML = log.slice(-200).reverse().map((r) => `<tr><td>${r.seq}</td>
    <td>${new Date(r.time).toLocaleString()}</td><td>${esc(r.actor)}</td><td>${esc(r.action)}</td>
    <td><code>${esc(r.object)}</code></td><td>${esc(r.outcome)}</td></tr>`).join("");
}

$("#a-new").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  $("#a-msg").textContent = ""; $("#a-secret").hidden = true;
  try {
    const u = await api("/api/users", {method: "POST", headers: {"content-type": "application/json"},
      body: JSON.stringify({user: $("#a-name").value.trim(), role: $("#a-role").value, password: $("#a-pw").value})});
    $("#a-pw").value = "";
    // shown this once: the new user adds it to an authenticator app
    $("#a-secret").innerHTML = `<b>${esc(u.user)}</b>: add this to an authenticator app now; it is not shown again.<br>
      Secret: <code>${esc(u.totp_secret)}</code><br>Or as a link: <code>${esc(u.totp_uri)}</code>`;
    $("#a-secret").hidden = false;
    await admin();
  } catch (e) {
    $("#a-msg").textContent = "Failed: " + e.message;
  }
});

document.querySelectorAll('input[name="kind"]').forEach((el) => el.addEventListener("change", () => {
  const k = document.querySelector('input[name="kind"]:checked').value;
  $("#reads-in").hidden = k !== "reads";
  $("#genome-in").hidden = k !== "genome";
  $("#manual-in").hidden = k !== "manual";
}));

// a typed or pasted sequence as a FASTA file: a FASTA record as is, otherwise the letters under the given name. The
// gateway's validation (gh_validate) checks the letters and turns RNA's U into T.
function manualFasta() {
  const text = $("#m-seq").value.trim();
  if (!text) return null;
  if (text.startsWith(">")) return new Blob([text + "\n"], {type: "text/plain"});
  const name = $("#m-name").value.trim() || "sequence-1";
  const seq = text.replace(/\s+/g, "").toUpperCase();
  const rna = document.querySelector('input[name="moltype"]:checked').value === "rna";
  if (!rna && seq.includes("U")) throw new Error("U in a DNA sequence: choose RNA, or check the sequence");
  if (rna && seq.includes("T")) throw new Error("T in an RNA sequence: choose DNA, or check the sequence");
  return new Blob([`>${name}\n${seq}\n`], {type: "text/plain"});
}

// the sample metadata typed in, if any
function metadata() {
  const m = {};
  if ($("#u-region").value.trim()) m.region = $("#u-region").value.trim().toUpperCase();
  if ($("#u-date").value) m.collection_date = $("#u-date").value;
  return m;
}

$("#go").addEventListener("click", async () => {
  const choice = document.querySelector('input[name="kind"]:checked').value;
  const kind = choice === "reads" ? "reads" : "genome";
  let files;
  try {
    files = choice === "genome" ? [$("#g1").files[0]] : choice === "reads" ? [$("#r1").files[0], $("#r2").files[0]]
      : [manualFasta()];
  } catch (e) { $("#msg").textContent = e.message; return; }
  if (files.some((f) => !f)) {
    $("#msg").textContent = choice === "manual" ? "Type or paste a sequence first."
      : "Choose the file" + (choice === "reads" ? "s" : "") + " first.";
    return;
  }
  $("#go").disabled = true;
  try {
    const inputs = [];
    for (const f of files) {
      $("#msg").textContent = `Uploading ${f.name || "the sequence"}...`;
      inputs.push((await api("/api/uploads", {method: "POST", body: f})).hash);
    }
    const {id} = await api("/api/jobs", {method: "POST", headers: {"content-type": "application/json"},
                                         body: JSON.stringify({kind, inputs, metadata: metadata()})});
    $("#msg").textContent = `Started ${id}.`;
    selected = id; history.replaceState(null, "", "#" + id);
    await refresh();
  } catch (e) {
    $("#msg").textContent = "Failed: " + e.message;
  } finally {
    $("#go").disabled = false;
  }
});

// replicates apply to neighbour-joining only
function boot() {
  const n = Math.max(0, Math.min(1000, parseInt($("#t-boot").value, 10) || 0));
  return $("#t-method").value === "nj" ? n : 0;
}
$("#t-method").addEventListener("change", () => { $("#t-boot").disabled = $("#t-method").value !== "nj"; });

$("#j-all").addEventListener("change", async () => {
  ticked.clear();
  if ($("#j-all").checked)
    (await api("/api/jobs")).filter((j) => j.state === "done" && j.kind !== "tree").forEach((j) => ticked.add(j.id));
  await refresh();
});

$("#t-go").addEventListener("click", async () => {
  $("#t-go").disabled = true;
  try {
    const jobs = await chosenJobs();
    const r = await api("/api/trees", {method: "POST", headers: {"content-type": "application/json"},
                                       body: JSON.stringify({jobs, method: $("#t-method").value, bootstrap: boot()})});
    $("#t-msg").textContent = `Started ${r.id}: ${jobs.length} analyses against ${r.reference}.`;
    selected = r.id; history.replaceState(null, "", "#" + r.id);
    await refresh();
  } catch (e) {
    $("#t-msg").textContent = "Failed: " + e.message;
  } finally {
    $("#t-go").disabled = false;
  }
});

async function monitor() {
  const s = await api("/api/summary");
  const rows = (xs) => xs.map((x) => `<tr><td>${esc(x.name)}</td><td>${x.count}</td>
    <td>${new Date(x.first_seen).toLocaleDateString()}</td></tr>`).join("");
  $("#m-lin tbody").innerHTML = rows(s.lineages);
  $("#m-sp tbody").innerHTML = rows(s.species);
}

const ticked = new Set();   // analyses chosen for a tree or a dataset

// the ticked finished analyses, or all finished ones when none is ticked
async function chosenJobs() {
  const done = (await api("/api/jobs")).filter((j) => j.state === "done" && j.kind !== "tree").map((j) => j.id);
  const t = done.filter((id) => ticked.has(id));
  return t.length ? t : done;
}

async function refresh() {
  const jobs = await api("/api/jobs");
  const pick = (j) => j.state === "done" && j.kind !== "tree";
  $("#jobs tbody").innerHTML = jobs.map((j) => `<tr data-id="${esc(j.id)}" class="${j.id === selected ? "sel" : ""}">
    <td>${pick(j) ? `<input type="checkbox" data-tick="${esc(j.id)}" ${ticked.has(j.id) ? "checked" : ""} aria-label="tick ${esc(j.id)}">` : ""}</td>
    <td><code>${esc(j.id)}</code></td><td>${esc(j.kind)}</td><td class="state-${esc(j.state)}">${esc(j.state)}</td>
    <td>${new Date(j.created).toLocaleString()}</td></tr>`).join("");
  $("#j-count").textContent = ticked.size ? `${ticked.size} ticked.` : "";
  document.querySelectorAll("[data-tick]").forEach((c) => {
    c.addEventListener("click", (ev) => ev.stopPropagation());
    c.addEventListener("change", () => { c.checked ? ticked.add(c.dataset.tick) : ticked.delete(c.dataset.tick);
      $("#j-count").textContent = ticked.size ? `${ticked.size} ticked.` : ""; });
  });
  document.querySelectorAll("#jobs tbody tr").forEach((tr) => tr.addEventListener("click", () => {
    selected = tr.dataset.id; history.replaceState(null, "", "#" + selected); refresh();
  }));
  if (selected) await show(selected);
  await monitor();
}

// the tree drawn inline, so it can be zoomed, moved, searched and its genomes clicked (leaves are named job/genome)
let treeShown = null, tv = null;
async function showTree(id, url) {
  const r = await fetch(url, {credentials: "same-origin"});
  $("#d-tree").innerHTML = await r.text();
  treeShown = id;
  const svg = $("#d-tree svg");
  const [, , w, h] = svg.getAttribute("viewBox").split(" ").map(Number);
  tv = {x: 0, y: 0, w, h, W: w, H: h};
  svg.removeAttribute("width"); svg.removeAttribute("height");
  svg.style.width = "100%"; svg.style.height = Math.min(h, 640) + "px";
  const apply = () => svg.setAttribute("viewBox", `${tv.x} ${tv.y} ${tv.w} ${tv.h}`);
  const zoom = (f, cx = tv.x + tv.w / 2, cy = tv.y + tv.h / 2) => {
    const w2 = Math.min(tv.W, Math.max(tv.W / 50, tv.w * f)), h2 = tv.h * (w2 / tv.w);
    tv.x = cx - (cx - tv.x) * (w2 / tv.w); tv.y = cy - (cy - tv.y) * (h2 / tv.h); tv.w = w2; tv.h = h2; apply();
  };
  $("#tz-in").onclick = () => zoom(0.7); $("#tz-out").onclick = () => zoom(1 / 0.7);
  $("#tz-fit").onclick = () => { tv = {...tv, x: 0, y: 0, w: tv.W, h: tv.H}; apply(); };
  svg.addEventListener("wheel", (ev) => {
    ev.preventDefault();
    const p = svg.getBoundingClientRect();
    zoom(ev.deltaY < 0 ? 0.8 : 1.25, tv.x + (ev.clientX - p.left) / p.width * tv.w, tv.y + (ev.clientY - p.top) / p.height * tv.h);
  }, {passive: false});
  let drag = null;
  svg.addEventListener("pointerdown", (ev) => { if (ev.target.classList.contains("leaf")) return; drag = {x: ev.clientX, y: ev.clientY, vx: tv.x, vy: tv.y}; svg.setPointerCapture(ev.pointerId); });
  svg.addEventListener("pointermove", (ev) => {
    if (!drag) return;
    const p = svg.getBoundingClientRect();
    tv.x = drag.vx - (ev.clientX - drag.x) / p.width * tv.w; tv.y = drag.vy - (ev.clientY - drag.y) / p.height * tv.h; apply();
  });
  svg.addEventListener("pointerup", () => { drag = null; });
  svg.querySelectorAll("text.leaf").forEach((t) => {
    const job = t.textContent.split("/")[0];
    if (job.startsWith("job-")) {
      t.style.cursor = "pointer";
      t.addEventListener("click", () => { selected = job; history.replaceState(null, "", "#" + job); treeShown = null; refresh(); });
    }
  });
  $("#tz-find").value = ""; $("#tz-hits").textContent = "";
}

$("#tz-find").addEventListener("input", () => {
  const q = $("#tz-find").value.trim().toLowerCase();
  const leaves = [...document.querySelectorAll("#d-tree text.leaf")];
  leaves.forEach((t) => t.classList.toggle("hit", !!q && t.textContent.toLowerCase().includes(q)));
  const hits = leaves.filter((t) => t.classList.contains("hit"));
  $("#tz-hits").textContent = q ? `${hits.length} of ${leaves.length} genomes` : "";
  if (hits[0] && tv) { const b = hits[0].getBBox(); tv.x = Math.max(0, b.x - tv.w / 4); tv.y = Math.max(0, b.y - tv.h / 2);
    $("#d-tree svg").setAttribute("viewBox", `${tv.x} ${tv.y} ${tv.w} ${tv.h}`); }
});

async function show(id) {
  const j = await api("/api/jobs/" + encodeURIComponent(id));
  const res = (step) => (j.steps[step] ? j.steps[step].results : []);
  $("#detail").hidden = false;
  $("#d-title").textContent = `${j.id}: ${j.kind}, ${j.state}` + (j.state === "failed" && j.error ? ` (${j.error})` : "");
  const base = "/api/jobs/" + encodeURIComponent(j.id) + "/";
  const isTree = j.kind === "tree";
  const exp = isTree ? ["tree.svg", "tree.nwk", "job.json"] : ["report.csv", "report.pdf", "job.json"];
  $("#d-exports").innerHTML = j.state === "done"
    ? "Export: " + exp.map((e) => `<a href="${base}${e}" target="_blank" rel="noopener">${e}</a>`).join("") : "";
  $("#d-tree-wrap").hidden = !(isTree && j.state === "done");
  if (isTree && j.state === "done" && treeShown !== j.id) await showTree(j.id, base + "tree.svg");
  $("#d-results").hidden = isTree;
  $("#d-steps").innerHTML = j.order.map((s) => `<span class="step ${j.steps[s] ? "done" : ""}">${esc(s)}${
    j.steps[s] ? " " + j.steps[s].seconds.toFixed(2) + " s" : ""}</span>`).join("");
  const calls = res("classify").flat();
  const prot = Object.fromEntries(res("protein").flat().filter((p) => p.call.confidence !== "unclassified").map((p) => [p.query, p.call]));
  $("#d-class tbody").innerHTML = calls.map((q) => {
    const p = prot[q.query];
    const c = p ? {species: p.species, family: p.family, ani: p.aa_identity, confidence: p.confidence, method: "protein (aa identity)"}
                : {...(q.call || {}), method: "MinHash (ANI)"};
    const near = (q.hits || []).slice(0, 3).map((h) => `${esc(h.ref)} ${esc(h.organism)} (${h.ani.toFixed(3)})`).join("<br>");
    return `<tr><td>${esc(q.query)}</td><td>${esc(c.species || "-")}</td><td>${esc(c.family || "-")}</td>
      <td>${c.ani != null ? c.ani.toFixed(3) : "-"}</td><td class="conf-${esc(c.confidence)}">${esc(c.confidence)}</td>
      <td>${esc(c.method)}</td><td>${near}</td></tr>`;
  }).join("");
  const place = res("place").flat();
  $("#d-place-wrap").hidden = place.length === 0;
  $("#d-place tbody").innerHTML = place.map((p) => `<tr><td>${esc(p.query)}</td><td>${esc(p.clade)}</td>
    <td>${p.parsimony ?? ""}</td><td>${p.placements ?? ""}</td></tr>`).join("");
  const lin = res("lineage").flat();
  $("#d-lineage-wrap").hidden = lin.length === 0;
  const species = Object.fromEntries(res("classify").flat().map((c) => [c.query, (c.call || {}).species]));
  const aa = (l) => [...(l.aa_substitutions || []), ...(l.aa_deletions || [])];
  const viewable = (l) => viewer.enabled && viewer.viruses.includes(species[l.query]) && aa(l).length;
  $("#d-lineage tbody").innerHTML = lin.map((l) => `<tr><td>${esc(l.query)}</td><td>${esc(l.pango)}</td>
    <td>${esc(l.clade)}</td><td>${esc(l.qc)}</td>
    <td>${aa(l).length ? `<details><summary>${aa(l).length}</summary><code>${esc(aa(l).join(", "))}</code></details>` : ""}</td>
    <td>${aa(l).length ? `${viewable(l) ? `<button class="small" data-view="${esc(l.query)}">Open</button> ` : ""}
      <button class="small" data-copy="${esc(aa(l).join(", "))}">Copy changes</button>` : ""}</td></tr>`).join("");
  $("#d-viewer-note").hidden = !lin.some(viewable);
  // RSV-B's structures have no antibody at site Zero (TechUPGRADE, 20 November 2026): said before anyone looks
  $("#d-rsvb-note").hidden = !lin.some((l) => viewable(l) && /rsv[\/_-]b/i.test(l.dataset || ""));
  document.querySelectorAll("[data-view]").forEach((b) => b.addEventListener("click", async () => {
    // a signed link, valid for 10 minutes, carrying the changes but no sample or job names (gh_viewer)
    try {
      const v = await api(`/api/jobs/${encodeURIComponent(j.id)}/structure-view?query=${encodeURIComponent(b.dataset.view)}`);
      window.open(v.url, "_blank", "noopener");
    } catch (e) { alert("The structure view failed: " + e.message); }
  }));
  document.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = "Copied"; }
    catch (e) { prompt("Copy the changes:", b.dataset.copy); }
  }));
  $("#d-mut tbody").innerHTML = res("mutations").flat().map((m) => m.aligned ? `<tr><td>${esc(m.query)}</td>
    <td>${esc(m.reference)}</td><td>${m.substitutions.length}</td><td>${m.insertions.length}</td>
    <td>${m.deletions.length}</td><td>${m.missing}</td>
    <td>${m.substitutions.length + m.insertions.length + m.deletions.length ? `<details><summary>show</summary><code>${esc(
      [...m.substitutions.map(([p, r, a]) => r + p + a), ...m.insertions.map(([p, sq]) => `ins${p}${sq}`),
       ...m.deletions.map(([p, n]) => `del${p}-${p + n - 1}`)].join(", "))}</code></details>` : ""}</td></tr>`
    : `<tr><td>${esc(m.query)}</td><td colspan="6">not aligned</td></tr>`).join("");
  const kr = res("kraken")[0];
  $("#d-kraken-wrap").hidden = !kr;
  if (kr) $("#d-kraken tbody").innerHTML = kr.species.map((s) => `<tr><td>${esc(s.name)}</td><td>${s.reads}</td>
    <td>${(s.share * 100).toFixed(1)}%</td></tr>`).join("");
  const cons = res("consensus")[0];
  $("#d-cons-wrap").hidden = !cons;
  if (cons) {
    const d = res("dehost")[0];
    $("#d-cons").innerHTML = `${d ? `${d.pairs_kept} of ${d.pairs_in} read pairs kept after removing human reads (${esc(d.method)}). ` : ""}
      ${cons.primers_trimmed ? "Primers trimmed (iVar). " : ""}
      Against ${esc(cons.reference)}: ${(cons.breadth * 100).toFixed(1)}% covered, mean depth ${cons.mean_depth.toFixed(0)}.
      <a href="/api/files/${esc(cons.genome)}">Consensus genome (FASTA)</a>`;
  }
  $("#d-know").innerHTML = res("knowledge").flatMap((k) => k.links).map((l) =>
    `<li><a href="${esc(l.url)}" target="_blank" rel="noopener">${esc(l.title)}</a></li>`).join("");
  $("#d-prov").textContent = JSON.stringify(Object.fromEntries(Object.entries(j.steps).map(([s, v]) => [s, v.provenance])), null, 1);
}

function connect() {
  const ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
  ws.onopen = () => { $("#live").textContent = "live"; $("#live").classList.add("on"); };
  ws.onclose = () => { $("#live").textContent = "reconnecting"; $("#live").classList.remove("on"); setTimeout(connect, 2000); };
  ws.onmessage = (ev) => {
    const {topic, message} = JSON.parse(ev.data);
    const li = document.createElement("li");
    li.textContent = `${new Date().toLocaleTimeString()} ${topic} ${JSON.stringify(message).slice(0, 200)}`;
    $("#events").prepend(li);
    if (topic === "genhub/tasks/status") refresh();
    if (topic === "genhub/alerts" && message.source === "merged") trends();
    else if (topic === "genhub/alerts") {
      if ($("#alerts .hint")) $("#alerts").innerHTML = "";
      const a = document.createElement("li");
      a.textContent = `${new Date().toLocaleString()}: first ${message.type === "new_pango" ? "lineage" : "species"} ` +
        `${message.pango || message.species} at this site (${message.job})`;
      $("#alerts").prepend(a);
    }
  };
}

start();
