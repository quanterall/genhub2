// GenHub2's page: uploads, jobs, results, live events (the gateway's API, gh_web).
"use strict";
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]));
let selected = null;

async function api(path, opts) {
  const r = await fetch(path, opts);
  const body = await r.json();
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}

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

async function refresh() {
  const jobs = await api("/api/jobs");
  $("#jobs tbody").innerHTML = jobs.map((j) => `<tr data-id="${esc(j.id)}" class="${j.id === selected ? "sel" : ""}">
    <td><code>${esc(j.id)}</code></td><td>${esc(j.kind)}</td><td class="state-${esc(j.state)}">${esc(j.state)}</td>
    <td>${new Date(j.created).toLocaleString()}</td></tr>`).join("");
  document.querySelectorAll("#jobs tbody tr").forEach((tr) => tr.addEventListener("click", () => {
    selected = tr.dataset.id; refresh();
  }));
  if (selected) await show(selected);
}

async function show(id) {
  const j = await api("/api/jobs/" + encodeURIComponent(id));
  const res = (step) => (j.steps[step] ? j.steps[step].results : []);
  $("#detail").hidden = false;
  $("#d-title").textContent = `${j.id}: ${j.kind}, ${j.state}` + (j.error ? ` (${j.error})` : "");
  $("#d-steps").innerHTML = j.order.map((s) => `<span class="step ${j.steps[s] ? "done" : ""}">${esc(s)}${
    j.steps[s] ? " " + j.steps[s].seconds.toFixed(2) + " s" : ""}</span>`).join("");
  const calls = res("classify").flat();
  $("#d-class tbody").innerHTML = calls.map((q) => {
    const c = q.call || {};
    const near = (q.hits || []).slice(0, 3).map((h) => `${esc(h.ref)} ${esc(h.organism)} (${h.ani.toFixed(3)})`).join("<br>");
    return `<tr><td>${esc(q.query)}</td><td>${esc(c.species || "-")}</td><td>${esc(c.family || "-")}</td>
      <td>${c.ani != null ? c.ani.toFixed(3) : "-"}</td><td class="conf-${esc(c.confidence)}">${esc(c.confidence)}</td>
      <td>${near}</td></tr>`;
  }).join("");
  const lin = res("lineage").flat();
  $("#d-lineage-wrap").hidden = lin.length === 0;
  $("#d-lineage tbody").innerHTML = lin.map((l) => `<tr><td>${esc(l.query)}</td><td>${esc(l.pango)}</td>
    <td>${esc(l.clade)}</td><td>${esc(l.qc)}</td></tr>`).join("");
  $("#d-mut tbody").innerHTML = res("mutations").flat().map((m) => m.aligned ? `<tr><td>${esc(m.query)}</td>
    <td>${esc(m.reference)}</td><td>${m.substitutions.length}</td><td>${m.insertions.length}</td>
    <td>${m.deletions.length}</td><td>${m.missing}</td></tr>` : `<tr><td>${esc(m.query)}</td><td colspan="5">not aligned</td></tr>`).join("");
  const cons = res("consensus")[0];
  $("#d-cons-wrap").hidden = !cons;
  if (cons) {
    const d = res("dehost")[0];
    $("#d-cons").innerHTML = `${d ? `${d.pairs_kept} of ${d.pairs_in} read pairs kept after removing human reads. ` : ""}
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
  };
}

refresh();
connect();
