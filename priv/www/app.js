// GenHub2's page: uploads, jobs, results, live events (the gateway's API, gh_web).
"use strict";
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]));
let selected = location.hash ? decodeURIComponent(location.hash.slice(1)) : null;

let me = null;   // {user, role} of this session

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
}

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
      ? `new lineage <b>${esc(x.lineage)}</b> in ${esc(x.week)}: ${x.n} sequences (${esc(x.regions.join(", "))})`
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
  $("#ds-list tbody").innerHTML = ds.map((d) => `<tr><td><b>${esc(d.title)}</b><br><code>${esc(d.id)}</code></td>
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
    const jobs = (await api("/api/jobs")).filter((j) => j.state === "done" && j.kind !== "tree").map((j) => j.id);
    const d = await api("/api/datasets", {method: "POST", headers: {"content-type": "application/json"},
      body: JSON.stringify({title: $("#ds-title").value.trim(), consent: [$("#ds-consent").value], jobs})});
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
    <td>${u.disabled || u.name === me.user ? "" : `<button class="small" data-disable="${esc(u.name)}">Disable</button>`}</td></tr>`).join("");
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
    selected = id;
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

$("#t-go").addEventListener("click", async () => {
  $("#t-go").disabled = true;
  try {
    const jobs = (await api("/api/jobs")).filter((j) => j.state === "done" && j.kind !== "tree").map((j) => j.id);
    const r = await api("/api/trees", {method: "POST", headers: {"content-type": "application/json"},
                                       body: JSON.stringify({jobs, method: $("#t-method").value, bootstrap: boot()})});
    $("#t-msg").textContent = `Started ${r.id}: ${jobs.length} analyses against ${r.reference}.`;
    selected = r.id;
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

async function refresh() {
  const jobs = await api("/api/jobs");
  $("#jobs tbody").innerHTML = jobs.map((j) => `<tr data-id="${esc(j.id)}" class="${j.id === selected ? "sel" : ""}">
    <td><code>${esc(j.id)}</code></td><td>${esc(j.kind)}</td><td class="state-${esc(j.state)}">${esc(j.state)}</td>
    <td>${new Date(j.created).toLocaleString()}</td></tr>`).join("");
  document.querySelectorAll("#jobs tbody tr").forEach((tr) => tr.addEventListener("click", () => {
    selected = tr.dataset.id; history.replaceState(null, "", "#" + selected); refresh();
  }));
  if (selected) await show(selected);
  await monitor();
}

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
  if (isTree && j.state === "done") $("#d-tree").src = base + "tree.svg";
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
  $("#d-lineage tbody").innerHTML = lin.map((l) => `<tr><td>${esc(l.query)}</td><td>${esc(l.pango)}</td>
    <td>${esc(l.clade)}</td><td>${esc(l.qc)}</td></tr>`).join("");
  $("#d-mut tbody").innerHTML = res("mutations").flat().map((m) => m.aligned ? `<tr><td>${esc(m.query)}</td>
    <td>${esc(m.reference)}</td><td>${m.substitutions.length}</td><td>${m.insertions.length}</td>
    <td>${m.deletions.length}</td><td>${m.missing}</td></tr>` : `<tr><td>${esc(m.query)}</td><td colspan="5">not aligned</td></tr>`).join("");
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
