/* Frosty Irie ordering client.
 * - Menu comes from menu.json (same file the APIs price against).
 * - Orders go to the first healthy API in FROSTY_CONFIG.apis (AWS, then Azure).
 * - If every API is down, the order still reaches the kitchen through WhatsApp.
 * All DOM is built with textContent; menu data is never injected as HTML.
 */
(() => {
  "use strict";
  const CFG = window.FROSTY_CONFIG || { apis: [], whatsapp: "50689185528", requestTimeoutMs: 8000 };
  const $ = (s, r = document) => r.querySelector(s);
  const el = (tag, props = {}, ...kids) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === "class") n.className = v;
      else if (k === "text") n.textContent = v;
      else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
      else if (v !== undefined && v !== null && v !== false) n.setAttribute(k, v);
    }
    kids.flat().forEach(c => c != null && n.append(c));
    return n;
  };
  const fmt = n => "₡" + Math.round(n).toLocaleString("en-US");

  let MENU = null;
  let activeCat = null;
  let orderType = "pickup";
  const cart = new Map();              // key "id|size" -> {item, size, qty}
  const chosenSize = new Map();        // item id -> size

  // ---------- time helpers (Costa Rica, no DST) ----------
  function localHHMM() {
    return new Intl.DateTimeFormat("en-GB", { timeZone: MENU.store.timezone, hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date());
  }
  function isHappyHour() {
    const hh = MENU.pricing.happyHour; if (!hh) return false;
    const t = localHHMM(); return t >= hh.start && t < hh.end;
  }
  function unitPrice(item, size) {
    let p = item.prices[size];
    const hh = MENU.pricing.happyHour;
    if (hh && isHappyHour() && item.category === hh.category) p = Math.min(p, hh.price);
    return p;
  }

  // ---------- menu ----------
  async function loadMenu() {
    try {
      const r = await fetch("menu.json", { cache: "no-cache" });
      if (!r.ok) throw new Error(r.status);
      MENU = await r.json();
    } catch (e) {
      $("#menuStatus").textContent = "We couldn't load the menu. Message us on WhatsApp and we'll take your order.";
      return;
    }
    $("#menuStatus").textContent = "Tap a size, add to your order, and choose delivery, pickup or your beach spot.";
    $("#hoursLabel").textContent = `${MENU.store.hours.open}–${MENU.store.hours.close}`;
    $("#hhBanner").hidden = !isHappyHour();
    renderTabs(); selectCat(MENU.categories[0].id); renderOrderTypes();
  }

  function renderTabs() {
    const tabs = $("#tabs"); tabs.textContent = "";
    MENU.categories.forEach(c => tabs.append(el("button", {
      class: "tab", role: "tab", "aria-selected": "false", "data-cat": c.id, onclick: () => selectCat(c.id)
    }, `${c.emoji} ${c.label}`)));
  }

  function selectCat(id) {
    activeCat = id;
    document.querySelectorAll(".tab").forEach(t => t.setAttribute("aria-selected", String(t.dataset.cat === id)));
    const cat = MENU.categories.find(c => c.id === id);
    $("#catBlurb").textContent = cat ? cat.blurb : "";
    renderGrid();
  }

  function renderGrid() {
    const grid = $("#grid"); grid.textContent = "";
    MENU.items.filter(i => i.category === activeCat).forEach(item => grid.append(card(item)));
  }

  function card(item) {
    const sizes = Object.keys(item.prices);
    if (!chosenSize.has(item.id)) chosenSize.set(item.id, sizes[0]);
    const size = chosenSize.get(item.id);
    const base = item.prices[size], now = unitPrice(item, size);
    const priceEl = el("span", { class: "price" });
    if (now < base) priceEl.append(el("s", { text: fmt(base) }));
    priceEl.append(fmt(now));

    const sizeRow = sizes.length > 1 ? el("div", { class: "sizes", role: "group", "aria-label": `Size for ${item.name}` },
      sizes.map(s => el("button", {
        class: "size", type: "button", "aria-pressed": String(s === size),
        title: MENU.sizes[s]?.detail || "",
        onclick: () => { chosenSize.set(item.id, s); renderGrid(); }
      }, `${MENU.sizes[s]?.label || s} ${fmt(item.prices[s])}`))) : null;

    return el("article", { class: "card" },
      el("div", { class: "card-top" },
        el("div", { class: "card-emoji", "aria-hidden": "true" }, item.emoji),
        el("div", {}, el("h3", { text: item.name }), item.badge ? el("span", { class: "tag", text: item.badge }) : null)),
      el("p", { text: item.desc }),
      sizeRow,
      el("div", { class: "card-foot" }, priceEl,
        el("button", { class: "add", type: "button", onclick: () => add(item, chosenSize.get(item.id)),
          "aria-label": `Add ${item.name} to order` }, "+ Add")));
  }

  // ---------- cart ----------
  function add(item, size) {
    const key = `${item.id}|${size}`;
    const line = cart.get(key) || { item, size, qty: 0 };
    line.qty = Math.min(20, line.qty + 1); cart.set(key, line);
    renderCart(); toast(`${item.emoji} ${item.name} added`);
  }
  function changeQty(key, d) {
    const line = cart.get(key); if (!line) return;
    line.qty += d; if (line.qty <= 0) cart.delete(key);
    renderCart();
  }
  function totals() {
    const p = MENU.pricing;
    const subtotal = [...cart.values()].reduce((s, l) => s + unitPrice(l.item, l.size) * l.qty, 0);
    const service = p.serviceAppliesTo.includes(orderType) ? Math.round(subtotal * p.serviceRate) : 0;
    const iva = Math.round(subtotal * p.ivaRate);
    const delivery = orderType === "delivery" ? p.deliveryFee : 0;
    return { subtotal, service, iva, delivery, total: subtotal + service + iva + delivery };
  }
  function renderCart() {
    const n = [...cart.values()].reduce((s, l) => s + l.qty, 0);
    const badge = $("#cartCount"); badge.textContent = n; badge.hidden = n === 0;
    const list = $("#cartLines"); list.textContent = "";
    $("#cartEmpty").hidden = n > 0; $("#checkout").hidden = n === 0;
    for (const [key, l] of cart) {
      const sizeLabel = l.size === "single" ? "" : MENU.sizes[l.size]?.label;
      list.append(el("li", { class: "line" },
        el("span", { class: "e", "aria-hidden": "true" }, l.item.emoji),
        el("div", {}, el("strong", { text: l.item.name }),
          el("small", { text: [sizeLabel, fmt(unitPrice(l.item, l.size))].filter(Boolean).join(" · ") })),
        el("div", { class: "qty" },
          el("button", { type: "button", "aria-label": "One less", onclick: () => changeQty(key, -1) }, "−"),
          el("span", { text: String(l.qty) }),
          el("button", { type: "button", "aria-label": "One more", onclick: () => changeQty(key, 1) }, "+"))));
    }
    const t = totals(), dl = $("#totals"); dl.textContent = "";
    const row = (a, b, cls) => dl.append(el("div", { class: cls }, el("dt", { text: a }), el("dd", { text: b })));
    row("Subtotal", fmt(t.subtotal));
    if (t.service) row("Service (10%)", fmt(t.service));
    row("IVA (13%)", fmt(t.iva));
    if (t.delivery) row("Delivery", fmt(t.delivery));
    row("Total", fmt(t.total), "grand");
  }
  function renderOrderTypes() {
    const fs = $("#orderTypes");
    MENU.orderTypes.forEach(o => fs.append(el("label", {},
      el("input", { type: "radio", name: "orderType", value: o.id, checked: o.id === orderType,
        onchange: () => { orderType = o.id; syncFields(); renderCart(); } }),
      `${o.emoji} ${o.label}`)));
    syncFields();
  }
  function syncFields() {
    document.querySelectorAll(".field[data-for]").forEach(f => { f.hidden = f.dataset.for !== orderType; });
  }

  // ---------- drawer ----------
  function openCart() { $("#cart").classList.add("open"); $("#cart").setAttribute("aria-hidden", "false"); $("#scrim").hidden = false; $("#cartBtn").setAttribute("aria-expanded", "true"); $("#closeCart").focus(); }
  function closeCart() { $("#cart").classList.remove("open"); $("#cart").setAttribute("aria-hidden", "true"); $("#scrim").hidden = true; $("#cartBtn").setAttribute("aria-expanded", "false"); }

  // ---------- submit ----------
  async function postWithFailover(body) {
    for (const base of CFG.apis || []) {
      const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), CFG.requestTimeoutMs || 8000);
      try {
        const r = await fetch(base.replace(/\/$/, "") + "/orders", {
          method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: ctl.signal
        });
        const data = await r.json().catch(() => ({}));
        if (r.status >= 400 && r.status < 500) return { error: data.error || "Please check your order." };
        if (r.ok) return { data, via: base };
      } catch (_) { /* network error or timeout: try the next cloud */ }
      finally { clearTimeout(timer); }
    }
    return { offline: true };
  }

  function waUrl(text) { return `https://wa.me/${CFG.whatsapp || MENU.store.whatsapp}?text=${encodeURIComponent(text)}`; }

  function offlineText(body, t) {
    const rows = [...cart.values()].map(l => `• ${l.qty}× ${l.item.name}${l.size === "single" ? "" : " (" + l.size + ")"}`);
    const where = body.address || body.table;
    return [`🍕 *Frosty Irie order* (sent by WhatsApp)`, ...rows, `Estimated total: ${fmt(t.total)}`,
      `${body.orderType}${where ? " · " + where : ""}`, `👤 ${body.name}`].join("\n");
  }

  async function submit(e) {
    e.preventDefault();
    const f = e.target, err = $("#formError"); err.textContent = "";
    const fd = new FormData(f);
    const body = {
      orderType, name: fd.get("name")?.trim(), phone: fd.get("phone")?.trim(), notes: fd.get("notes")?.trim(),
      address: fd.get("address")?.trim(), table: fd.get("table")?.trim(), website: fd.get("website"),
      consent: fd.get("consent") === "on",
      items: [...cart.values()].map(l => ({ id: l.item.id, size: l.size, qty: l.qty }))
    };
    if (!body.name) return (err.textContent = "Please tell us your name.");
    if (!/^\+?[0-9 ()-]{8,20}$/.test(body.phone || "")) return (err.textContent = "Please enter a valid phone number.");
    if (orderType === "delivery" && !body.address) return (err.textContent = "Where should we deliver?");
    if (orderType === "beach" && !body.table) return (err.textContent = "Which table or beach spot are you at?");
    if (!body.consent) return (err.textContent = "Please accept the privacy notice so we can prepare your order.");

    const btn = $("#placeOrder"); btn.disabled = true; btn.textContent = "Sending…";
    const t = totals();
    const res = await postWithFailover(body);
    btn.disabled = false; btn.textContent = "Place order";
    if (res.error) { err.textContent = res.error; return; }

    if (res.data) {
      $("#confirmIcon").textContent = "✅";
      $("#confirmTitle").textContent = "Order received!";
      $("#confirmId").textContent = `Order ${res.data.orderId}`;
      $("#confirmMsg").textContent = `Total ${fmt(res.data.total)}. Tap below to send it to our kitchen on WhatsApp so we can confirm the wait time.`;
      $("#confirmWa").href = waUrl(res.data.whatsappText);
    } else {
      $("#confirmIcon").textContent = "📲";
      $("#confirmTitle").textContent = "Send it on WhatsApp";
      $("#confirmId").textContent = "";
      $("#confirmMsg").textContent = "Our online ordering is taking a break, but the kitchen is open. Tap below to send your order on WhatsApp.";
      $("#confirmWa").href = waUrl(offlineText(body, t));
    }
    closeCart(); $("#confirm").hidden = false; $("#confirmWa").focus();
    if (res.data) { cart.clear(); f.reset(); renderCart(); }
  }

  let toastTimer;
  function toast(msg) { const t = $("#toast"); t.textContent = msg; t.classList.add("show"); clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove("show"), 1800); }

  // ---------- wire up ----------
  document.addEventListener("DOMContentLoaded", () => {
    const wa = waUrl("Hi Frosty Irie! 🌴");
    $("#heroWa").href = wa; $("#waLink").href = wa;
    $("#year").textContent = new Date().getFullYear();
    $("#servedBy").textContent = `Served from ${CFG.servedBy || "the cloud"}`;
    $("#cartBtn").addEventListener("click", openCart);
    $("#closeCart").addEventListener("click", closeCart);
    $("#scrim").addEventListener("click", closeCart);
    document.addEventListener("keydown", e => { if (e.key === "Escape") { closeCart(); $("#confirm").hidden = true; } });
    $("#checkout").addEventListener("submit", submit);
    $("#confirmClose").addEventListener("click", () => { $("#confirm").hidden = true; });
    loadMenu();
  });
})();
