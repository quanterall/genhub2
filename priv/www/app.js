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
}

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
  const reads = document.querySelector('input[name="kind"]:checked').value === "reads";
  $("#reads-in").hidden = !reads;
  $("#genome-in").hidden = reads;
}));

$("#go").addEventListener("click", async () => {
  const kind = document.querySelector('input[name="kind"]:checked').value;
  const files = kind === "genome" ? [$("#g1").files[0]] : [$("#r1").files[0], $("#r2").files[0]];
  if (files.some((f) => !f)) { $("#msg").textContent = "Choose the file" + (kind === "reads" ? "s" : "") + " first."; return; }
  $("#go").disabled = true;
  try {
    const inputs = [];
    for (const f of files) {
      $("#msg").textContent = `Uploading ${f.name}...`;
      inputs.push((await api("/api/uploads", {method: "POST", body: f})).hash);
    }
    const {id} = await api("/api/jobs", {method: "POST", headers: {"content-type": "application/json"},
                                         body: JSON.stringify({kind, inputs})});
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
    if (topic === "genhub/alerts") {
      if ($("#alerts .hint")) $("#alerts").innerHTML = "";
      const a = document.createElement("li");
      a.textContent = `${new Date().toLocaleString()}: first ${message.type === "new_pango" ? "lineage" : "species"} ` +
        `${message.pango || message.species} at this site (${message.job})`;
      $("#alerts").prepend(a);
    }
  };
}

start();
