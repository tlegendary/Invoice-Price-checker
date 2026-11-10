/* App Store edition start-up: checks the Apple subscription, shows the paywall if needed, then starts the app. */
(() => {
  // ---- set these to match App Store Connect ----
  const PRODUCTS = { yearly: "ipc_yearly", monthly: "ipc_monthlyy" };
  const PRIVACY_URL = window.__PRIVACY_URL || "https://example.com/privacy";
  const TERMS_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/";
  const SUPPORT = "r93.hamad@gmail.com";
  // ----------------------------------------------
  window.__GATED = true;
  const $ = s => document.querySelector(s);
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const get = (k, d) => { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch(e){ return d; } };
  const set = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch(e){} };
  const Cap = window.Capacitor;
  const native = !!(Cap && Cap.isNativePlatform && Cap.isNativePlatform());
  const IAP = native ? (Cap.registerPlugin ? Cap.registerPlugin("NativePurchases") : Cap.Plugins.NativePurchases) : null;
  window.__IAP = IAP;
  const tmo = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), ms))]);
  async function loadProducts(){
    if(!IAP) return;
    try {
      const r = await tmo(IAP.getProducts({ productIdentifiers: Object.values(PRODUCTS), productType: "subs" }), 10000);
      for(const p of (r.products || [])) products[p.identifier] = p;
      window.__STORE_STATUS = (r.products || []).length + " of 2 plans returned by the App Store" + ((r.products || []).length ? " (" + r.products.map(p => p.identifier).join(", ") + ")" : "");
    } catch(e){ window.__STORE_STATUS = "App Store error: " + (e && e.message || e); }
  }
  let products = {}, busy = false, started = false;

  // ---- free version: watch 1 rewarded ad = 1 scan ----
  const AD_REWARDED = window.__AD_REWARDED || "ca-app-pub-3940256099942544/1712485313"; // Google test unit until real IDs are set
  const AD_TESTING = !window.__AD_REWARDED || !!window.__ADS_TEST;  // test ads while TestFlight testing, real ads in the release build
  const AdMob = native ? ((Cap.registerPlugin && Cap.registerPlugin("AdMob")) || (Cap.Plugins && Cap.Plugins.AdMob) || null) : null;
  let adsInit = null, adReady = false, adLoading = null;
  const adLog = m => { try { window.__ADS.status = m; console.log("[ads] " + m); } catch(e){} };
  const errMsg = e => (e && (e.message || e.errorMessage || e.code)) ? String(e.message || e.errorMessage || e.code) : String(e || "unknown");
  function initAds(){
    if(!AdMob) return Promise.resolve(false);
    if(!adsInit) adsInit = (async () => {
      try {
        await tmo(AdMob.initialize({ initializeForTesting: AD_TESTING }), 15000);
        adLog("ads started" + (AD_TESTING ? " (test ads)" : ""));
        try {
          const ci = await tmo(AdMob.requestConsentInfo(), 8000);
          if(ci && ci.status === "REQUIRED" && ci.isConsentFormAvailable) await AdMob.showConsentForm();
          const ci2 = await tmo(AdMob.requestConsentInfo(), 8000).catch(() => ci);
          window.__ADS.privacyRequired = !!(ci2 && ci2.privacyOptionsRequirementStatus === "REQUIRED");
        } catch(e){}
        preloadAd();
        return true;
      } catch(e){ adLog("couldn't start ads: " + errMsg(e)); adsInit = null; return false; }
    })();
    return adsInit;
  }
  function preloadAd(){
    if(!AdMob || adReady) return Promise.resolve(adReady);
    if(adLoading) return adLoading;
    adLog("loading ad…");
    const once = () => tmo(AdMob.prepareRewardVideoAd({ adId: AD_REWARDED, isTesting: AD_TESTING }), 45000);
    adLoading = once()
      .catch(e => /time ?out|network|internet|connection/i.test(errMsg(e)) ? (adLog("slow network – trying again…"), new Promise(r => setTimeout(r, 1500)).then(once)) : Promise.reject(e))   // one automatic retry on a slow network
      .then(() => { adReady = true; adLog("ad ready"); return true; })
      .catch(e => { adReady = false; adLog("no ad: " + errMsg(e)); return false; })
      .finally(() => { adLoading = null; });
    return adLoading;
  }
  window.__ADS = {
    status: AdMob ? "not started" : (native ? "ad plugin missing from this build" : "browser preview"),
    credits: () => +get("ic.credits", 0) || 0,
    use(n){ const c = window.__ADS.credits(); n = Math.min(n || 1, c); set("ic.credits", c - n); return n; },
    watching: null,
    privacyRequired: false,
    async privacyOptions(){ if(!AdMob) throw new Error("not available"); await initAds(); return AdMob.showPrivacyOptionsForm(); },
    // a scan is ONLY given when Google confirms the ad was watched (onRewardedVideoAdReward)
    // resolves { ok, reason, free?, closed? }
    watch(){
      if(window.__ADS.watching) return window.__ADS.watching;
      return window.__ADS.watching = new Promise(async res => {
        const hs = []; let earned = false, fin = false;
        const done = (ok, reason, shown) => {
          if(fin) return; fin = true; window.__ADS.watching = null; hs.forEach(h => { try { h.remove(); } catch(e){} }); setTimeout(preloadAd, 500);
          res({ ok, closed: !!shown && !ok, reason: reason || window.__ADS.status });
        };
        if(!AdMob){
          if(!native){ set("ic.credits", window.__ADS.credits() + 1); return done(true); }
          return done(false, "ad plugin missing from this build");
        }
        try {
          if(!(await tmo(initAds(), 30000))) return done(false);
          if(!adReady && !(await preloadAd())) return done(false);
          hs.push(await AdMob.addListener("onRewardedVideoAdReward", () => { if(!earned){ earned = true; set("ic.credits", window.__ADS.credits() + 1); } }));
          hs.push(await AdMob.addListener("onRewardedVideoAdDismissed", () => done(earned, earned ? "" : "ad closed before the end", true)));
          hs.push(await AdMob.addListener("onRewardedVideoAdFailedToShow", e => done(earned, "ad couldn't show: " + errMsg(e))));
          adReady = false; adLog("showing ad");
          AdMob.showRewardVideoAd().then(() => setTimeout(() => done(earned), 20000)).catch(e => done(earned, "ad couldn't show: " + errMsg(e)));
        } catch(e){ done(false, errMsg(e)); }
      });
    }
  };
  // ---- scan packs (consumable in-app purchases) ----
  const PACKS = { ipc_scans_3: 3, ipc_scans_10: 10, ipc_scans_30: 30 };
  const PACK_PREVIEW = { ipc_scans_3: "£0.99", ipc_scans_10: "£2.99", ipc_scans_30: "£6.99" };
  let packProducts = {};
  async function loadPacks(){
    if(!IAP) return;
    try {
      const r = await tmo(IAP.getProducts({ productIdentifiers: Object.keys(PACKS), productType: "inapp" }), 10000);
      for(const p of (r.products || [])) packProducts[p.identifier] = p;
    } catch(e){}
  }
  // adds the scans for a purchase exactly once (remembers transaction IDs)
  function creditPack(t){
    const n = t && PACKS[t.productIdentifier]; if(!n) return 0;
    const id = String(t.transactionId || t.id || t.originalTransactionId || "");
    const seen = get("ic.txns", []);
    if(id && seen.includes(id)) return 0;
    set("ic.credits", window.__ADS.credits() + n);
    if(id){ seen.push(id); set("ic.txns", seen.slice(-300)); }
    return n;
  }
  window.__PACKS = {
    list(){ return Object.keys(PACKS).map(id => ({ id, n: PACKS[id], price: packProducts[id] ? packProducts[id].priceString : (native ? null : PACK_PREVIEW[id]) })).filter(p => p.price); },
    reload: loadPacks,
    async buy(id){
      if(!PACKS[id]) return { ok: false };
      if(!IAP){ if(!native){ set("ic.credits", window.__ADS.credits() + PACKS[id]); return { ok: true, n: PACKS[id] }; } return { ok: false, reason: "not available" }; }
      try {
        const t = await IAP.purchaseProduct({ productIdentifier: id, productType: "inapp", quantity: 1 });
        creditPack(t);
        return { ok: true, n: PACKS[id] };
      } catch(e){ const m = errMsg(e); return { ok: false, cancelled: /cancel/i.test(m), reason: m }; }
    }
  };

  // the paywall is a pop-up over the app with a ✕ – closing it goes back to the app (or to the free version on first open)
  window.__showPaywall = () => { if(window.__buying) return; window.__upgrading = true; started = false; paywall(); };
  function closePaywall(animate){
    const d = $("#pw"), b = $("#pwBg"); if(!d) return;
    const done = () => { d.remove(); if(b) b.remove(); document.documentElement.classList.remove("modal-open"); };
    if(animate){ d.classList.add("out"); if(b) b.classList.add("out"); setTimeout(done, 240); } else done();
  }
  function paywallX(){
    if(busy) return;
    if(window.__upgrading && window.__appRan){ window.__upgrading = false; started = true; return closePaywall(true); }
    set("ic.free", true); closePaywall(true); setTimeout(() => start({ product: "Free (with ads)", free: true, expires: null }), 120);
  }

  function start(sub){
    if(started) return; started = true;
    if(window.__appRan){ if(sub && !sub.free){ set("ic.free", false); try { localStorage.removeItem("ic.forceFree"); } catch(e){} } closePaywall(); location.reload(); return; }
    closePaywall();
    window.__SUB_INFO = sub;
    if(sub && sub.free) initAds();
    const go = () => window.__startApp ? window.__startApp() : setTimeout(go, 30);
    $("#main").innerHTML = ""; go();
  }
  async function entitlement(){
    if(!IAP) return null;
    const { purchases } = await IAP.getPurchases({ onlyCurrentEntitlements: true });
    const ids = Object.values(PRODUCTS);
    const p = (purchases || []).find(t => ids.includes(t.productIdentifier) && t.isActive !== false &&
      (!t.expirationDate || new Date(t.expirationDate).getTime() > Date.now()));
    if(!p) return null;
    const info = { product: p.productIdentifier === PRODUCTS.yearly ? "Yearly" : "Monthly", expires: p.expirationDate || null, trial: !!p.isTrialPeriod || p.offerType === "introductory" };
    set("ic.sub", info);
    return info;
  }
  const periodText = id => id === PRODUCTS.yearly ? "year" : "month";
  function trialText(p){
    const ip = p && p.introductoryPrice;
    if(!ip || p.introEligibility === 1) return "";
    const sp = ip.subscriptionPeriod || {}, n = (sp.numberOfUnits || 1) * (ip.numberOfPeriods || 1);
    const unit = ["day","week","month","year"][sp.unit] || "day";
    return ip.price === 0 ? `${n}-${unit} free trial` : "";
  }
  function paywall(msg){
    const y = products[PRODUCTS.yearly], m = products[PRODUCTS.monthly];
    const trial = trialText(y) || trialText(m);
    let sel = get("ic.plan", "yearly");
    if(native && (y || m) && !(sel === "yearly" ? y : m)) sel = y ? "yearly" : "monthly";   // only offer plans the App Store returned
    const showPlan = key => !native || !(y || m) || (key === "yearly" ? y : m);
    const plan = (key, p, best) => {
      const t = trialText(p);
      return `<button class="plan ${sel === key ? "on" : ""}" data-plan="${key}">
        ${best ? `<span class="best">Best value</span>` : ""}
        <div style="font-weight:750;font-size:16px">${key === "yearly" ? "Yearly" : "Monthly"}</div>
        <div style="font-size:20px;font-weight:800;margin-top:2px">${p ? esc(p.priceString) : "—"}<span class="small mut" style="font-weight:600"> /${key === "yearly" ? "year" : "month"}</span></div>
        ${key === "yearly" && p && m ? `<div class="small" style="color:var(--grn);font-weight:650">${esc(p.currencySymbol || "£")}${(p.price/12).toFixed(2)} a month${m.price > 0 && p.price < m.price * 12 ? ` · <span style="background:var(--grn);color:#fff;border-radius:999px;padding:1px 8px;font-size:12px">Save ${Math.round((1 - p.price / (m.price * 12)) * 100)}%</span>` : ""}</div>` : ""}
        ${t ? `<div class="small mut">${t}, then ${p ? esc(p.priceString) : ""}</div>` : ""}
      </button>`;
    };
    const chosen = sel === "yearly" ? y : m;
    const noPrices = native && !y && !m;
    let pw = $("#pw");
    if(!pw){
      const bg = document.createElement("div"); bg.id = "pwBg"; bg.className = "sheetbg"; bg.onclick = paywallX;
      pw = document.createElement("div"); pw.id = "pw"; pw.className = "card bsheet pwsheet"; pw.setAttribute("role", "dialog"); pw.setAttribute("aria-modal", "true");
      document.body.appendChild(bg); document.body.appendChild(pw);
      document.documentElement.classList.add("modal-open");
      let y0 = null, dy = 0;     // swipe down to close
      pw.addEventListener("touchstart", e => { y0 = pw.scrollTop > 0 ? null : e.touches[0].clientY; dy = 0; }, { passive: true });
      pw.addEventListener("touchmove", e => { if(y0 === null) return; dy = e.touches[0].clientY - y0; if(dy > 0){ pw.classList.add("drag"); pw.style.transform = `translateY(${dy}px)`; } }, { passive: true });
      pw.addEventListener("touchend", () => { if(y0 === null) return; y0 = null; pw.classList.remove("drag"); pw.style.transform = ""; if(dy > 120) paywallX(); }, { passive: true });
    }
    const keepTop = pw.scrollTop;
    pw.innerHTML = `<style>
      #pw{top:calc(env(safe-area-inset-top) + 12px);max-height:none}
      #pw.out{transform:translateY(105%)}
      .pack{position:relative;border:2px solid var(--line);background:var(--card);color:var(--ink);border-radius:14px;padding:14px 6px 10px;font:inherit;display:flex;flex-direction:column;align-items:center;gap:2px;transition:transform .12s,border-color .2s}
      .pack:active{transform:scale(.96);border-color:var(--acc)}.pack b{font-size:15px;white-space:nowrap}@media (max-width:350px){.pack b{font-size:13px}.pack span{font-size:12.5px}}.pack span{font-size:14px;color:var(--mut)}
      .pack .tag{position:absolute;top:-9px;left:50%;transform:translateX(-50%);background:var(--gold,#c99a3a);color:#1d1606;font-size:10.5px;font-weight:800;padding:2px 7px;border-radius:999px;white-space:nowrap}
      .plan{display:block;width:100%;text-align:left;border:2px solid var(--line);background:var(--card);color:var(--ink);border-radius:16px;padding:14px 16px;margin:8px 0;position:relative;font:inherit;transition:border-color .2s,transform .12s}
      .plan.on{border-color:var(--p2);box-shadow:0 0 0 4px var(--accs)}.plan:active{transform:scale(.98)}
      .best{position:absolute;top:-10px;right:14px;background:linear-gradient(135deg,#b8862b,#d9ad55);color:#1d1405;font-size:11px;font-weight:800;padding:3px 9px;border-radius:20px}
      .feat{list-style:none;padding:0;margin:12px 0}.feat li{padding:6px 0 6px 30px;position:relative}
      .feat li:before{content:"✓";position:absolute;left:4px;top:5px;width:20px;height:20px;border-radius:50%;background:var(--accs);color:var(--grn);font-weight:800;font-size:12px;display:grid;place-items:center}
      .legal{font-size:11.5px;color:var(--mut);line-height:1.45;margin-top:14px}.legal a{color:var(--acc)}
    </style>
    <div>
      <div class="grab"></div><button type="button" class="sheetx" id="pwX" aria-label="Close">✕</button>
      <div style="text-align:center;margin:4px 0 6px"><div style="font-size:24px;font-weight:800;letter-spacing:-.02em">${trial ? "Start your " + esc(trial) : "Unlock ChargeCheck"}</div>
      <div class="mut" style="margin-top:4px">Stop paying more than your agreed prices.</div></div>
      <ul class="feat">
        <li>Scan photo or PDF invoices – read on your phone, works offline</li>
        <li>Every invoice double-checked before you see the result</li>
        <li>See exactly how much each supplier overcharged you</li>
        <li>Ready-made credit requests, reports for every shop</li>
      </ul>
      ${showPlan("yearly") ? plan("yearly", y, true) : ""}${showPlan("monthly") ? plan("monthly", m, false) : ""}
      ${msg ? `<div class="err">${esc(msg)}</div>` : ""}
      ${noPrices ? `<div class="warn" style="margin-top:10px">Couldn't load prices from the App Store. Check your internet connection.${window.__STORE_STATUS ? `<div class="small" style="margin-top:4px;opacity:.8">Details: ${window.__STORE_STATUS}</div>` : ""}<div style="margin-top:6px"><button class="btn sm" id="retryPrices">↻ Try again</button></div></div>` : ""}
      <button class="btn pri big" style="margin-top:10px" id="buyBtn" ${!chosen ? "disabled" : ""}>${busy ? "Please wait…" : trialText(chosen) ? "Start free trial" : "Subscribe"}</button>
      <div class="row" style="justify-content:center;margin-top:6px"><button class="btn sm ghost" id="restoreBtn">Restore purchases</button></div>
      <div class="legal">${chosen && trialText(chosen) ? `${esc(trialText(chosen))}, then ${esc(chosen.priceString)} per ${periodText(chosen.identifier)}. ` : chosen ? `${esc(chosen.priceString)} per ${periodText(chosen.identifier)}. ` : ""}Payment is charged to your Apple ID when you confirm${trial ? " (after the free trial ends)" : ""}. Your subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel any time in your App Store account settings.
        <br><a href="${TERMS_URL}" target="_blank" rel="noopener">Terms of Use</a> · <a href="${PRIVACY_URL}" target="_blank" rel="noopener">Privacy Policy</a> · Help: ${SUPPORT}</div>
      ${window.__PACKS.list().length ? `<div style="margin-top:16px;padding-top:14px;border-top:1px solid var(--line)">
        <div style="font-weight:750;text-align:center">Or buy scans – no subscription, no ads</div>
        <div style="display:grid;grid-template-columns:repeat(${window.__PACKS.list().length},1fr);gap:8px;margin-top:10px">
          ${window.__PACKS.list().map(p => `<button class="pack" data-pack="${p.id}" ${busy ? "disabled" : ""}>${p.n === 10 ? `<span class="tag">Popular</span>` : p.n === 30 ? `<span class="tag">Best price</span>` : ""}<b>${p.n} scans</b><span>${esc(p.price)}</span></button>`).join("")}
        </div>
        <div class="small mut" style="margin-top:8px;text-align:center">One-time purchase. Scans don't expire and are kept on this iPhone – keep a backup (Settings) so they aren't lost if you delete the app.</div>
      </div>` : ""}
      <div style="text-align:center;margin-top:16px;padding-top:14px;border-top:1px solid var(--line)">
        <div class="small mut" style="margin-bottom:8px">Not ready to pay?</div>
        <button class="btn" id="freeBtn" style="width:100%">${window.__upgrading ? "Back to the free version" : "Use free – watch 1 short ad per scan"}</button>
      </div>
      ${native && window.__TEST_BUILD ? `<div class="warn" style="margin-top:12px">Test build – for your own testing only.<br><button class="btn sm" id="previewBtn" style="margin-top:6px">Open the app (test mode)</button></div>` : ""}
      ${native ? "" : `<div class="warn" style="margin-top:12px">Preview outside the iPhone app – purchases only work in the App Store version.<br><button class="btn sm" id="previewBtn" style="margin-top:6px">Open the app (preview)</button></div>`}
    </div>`;
    pw.scrollTop = keepTop;
    $("#pwX").onclick = paywallX;
    const rp = $("#retryPrices"); if(rp) rp.onclick = async () => { rp.disabled = true; rp.textContent = "Loading…"; await loadProducts(); paywall(); };
    document.querySelectorAll(".plan").forEach(b => b.onclick = () => { set("ic.plan", b.dataset.plan); paywall(); });
    $("#buyBtn").onclick = buy;
    document.querySelectorAll("[data-pack]").forEach(b => b.onclick = async () => {
      if(busy) return; busy = true; window.__buying = true; paywall();
      const r = await window.__PACKS.buy(b.dataset.pack); busy = false; setTimeout(() => { window.__buying = false; }, 400);
      if(r.ok){ set("ic.free", true);
        if(window.__upgrading && window.__appRan){ window.__upgrading = false; started = true; closePaywall(true); if(window.__onPackCredited) window.__onPackCredited(r.n); return; }
        return start({ product: "Free (with ads)", free: true, expires: null }); }
      paywall(r.cancelled ? "" : "The purchase didn't go through. Please try again.");
    });
    $("#restoreBtn").onclick = restore;
    $("#freeBtn").onclick = paywallX;
    const pv = $("#previewBtn"); if(pv) pv.onclick = () => start({ product: window.__TEST_BUILD && native ? "Test mode" : "Preview", expires: null });
  }
  async function buy(){
    if(busy || !IAP) return;
    let id = get("ic.plan", "yearly") === "yearly" ? PRODUCTS.yearly : PRODUCTS.monthly;
    if(!products[id]){ const other = id === PRODUCTS.yearly ? PRODUCTS.monthly : PRODUCTS.yearly; if(products[other]) id = other; }   // same plan the screen shows
    busy = true; paywall();
    try {
      await IAP.purchaseProduct({ productIdentifier: id, productType: "subs", quantity: 1 });
      const e = await entitlement();
      busy = false;
      if(e) return start(e);
      paywall("The purchase didn't complete. Please try again.");
    } catch(err){
      busy = false;
      const m = String(err && (err.message || err)).toLowerCase();
      paywall(/cancel/.test(m) ? "" : "The purchase didn't go through. Please try again.");
    }
  }
  async function restore(){
    if(busy || !IAP) return;
    busy = true; paywall();
    try { await IAP.restorePurchases(); const e = await entitlement(); busy = false; if(e) return start(e); paywall("No active subscription was found for this Apple ID."); }
    catch(err){ busy = false; paywall("Couldn't restore right now. Check your connection and try again."); }
  }
  (async () => {
    try {
      if(IAP){
        try { IAP.addListener("transactionUpdated", async t => { try {
          if(t && PACKS[t.productIdentifier]){ const n = creditPack(t); if(n && window.__onPackCredited) window.__onPackCredited(n); return; }
          const e2 = await entitlement(); if(e2) start(e2);
        } catch(e){} }); } catch(e){}
        await Promise.all([loadProducts(), loadPacks()]);
        if(window.__TEST_BUILD && get("ic.forceFree", false)) return start({ product: "Free (with ads)", free: true, expires: null });
        const e = await tmo(entitlement(), 10000);
        if(e) return start(e);
        if(get("ic.free", false)) return start({ product: "Free (with ads)", free: true, expires: null });
      } else {
        // outside the iPhone app (preview only)
        products = {
          [PRODUCTS.yearly]: { identifier: PRODUCTS.yearly, priceString: "£89.99", price: 89.99, currencySymbol: "£", introductoryPrice: { price: 0, numberOfPeriods: 1, subscriptionPeriod: { numberOfUnits: 7, unit: 0 } } },
          [PRODUCTS.monthly]: { identifier: PRODUCTS.monthly, priceString: "£8.99", price: 8.99, currencySymbol: "£", introductoryPrice: { price: 0, numberOfPeriods: 1, subscriptionPeriod: { numberOfUnits: 7, unit: 0 } } }
        };
      }
    } catch(e){
      // offline or StoreKit busy: use the last confirmed subscription until it ends
      const c = get("ic.sub", null);
      if(c && (!c.expires || new Date(c.expires).getTime() > Date.now())) return start(c);
      if(get("ic.free", false)) return start({ product: "Free (with ads)", free: true, expires: null });
    }
    if(get("ic.free", false)) return start({ product: "Free (with ads)", free: true, expires: null });
    paywall();
  })();
})();
