const fs = require('fs');
const src = fs.readFileSync('/home/claude/app/index.html', 'utf8');
const line = re => { const m = src.match(re); if(!m) throw new Error('missing ' + re); return m[0]; };
const between = (a, b) => { const i = src.indexOf(a), j = src.indexOf(b, i); if(i < 0 || j < 0) throw new Error('missing block ' + a); return src.slice(i, j); };
const fn = name => { const i = src.indexOf('function ' + name + '('); let d = 0; for(let k = src.indexOf('{', i); k < src.length; k++){ if(src[k] === '{') d++; else if(src[k] === '}'){ d--; if(!d) return src.slice(i, k + 1); } } };
global.S = { baseline: [], history: [], invoices: [], cfg: { tol: 0.01 } };
const code = [line(/const r2 = [^\n]*\n/), line(/const num = [^\n]*\n/), line(/const STOP[^\n]*\n/), line(/const norm[^\n]*\n/), line(/const toks[^\n]*\n/), line(/function tokEq[^\n]*\n/),
  between('/* ---------- parsing ---------- */', '/* ---------- invoices ---------- */'), fn('visionRows'),
  ';Object.assign(global,{norm,toks,tokEq,r2,num,parseLine,parseInvoice,cleanDesc,consensusDesc,mergeReads,visionRows,knownSuppliers,cleanSupplier,knownWords});'].join('\n');
eval(code);

// seeded random
let seed = 20261110; const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
const pick = a => a[Math.floor(rnd() * a.length)];
const chance = p => rnd() < p;

const names = ["Fresh Halal Fillet 110-130 9kg","Medium Inner Fillet","1600gm Fresh Halal Chicken","Fresh Prime Wing","Discovery Tortilla Wrap 10\"","Panini Sesame Nigella 130g",
  "Meadow Vale Breaded Nuggets","Steak Breaded","Americana 4.5\" Seed Burger Bun 4x12","Pepsi Can 24x330ml","Original Breading","Suprano Cheese R74","Palmax Fat 12.5kg","Cheff Real Mayo 10L",
  "Lion Very Hot Chilli Sauce 2x2.27L","KTC Vegetable Oil Tin 20L","Quarter Pounder 48x4oz","Ketchup 2x4.5L","Chicken Popcorn 3kg","Bravo Pizza Flour 16kg","16 Inch Colour Pizza Boxes","Wipe Up Tissue 10x500"];
const norm0 = s => global.norm(s);
S.baseline = names.map((n, i) => ({ id: 'i' + i, name: n, price: 10 + i, supplier: i % 3 ? 'Sample Foods Ltd' : 'Bakery Direct', aliases: [norm0(n)] }));

const raw = JSON.parse(fs.readFileSync('/home/claude/rawtexts.json', 'utf8'));
// real rows the old reader produced from invoice photos: keep item-like rows only (no header / address lines)
const realRows = [];
for(const t of raw) for(const L of t.split('\n')){ const s = L.trim(); if(/\d[.,]\d{2}/.test(s) && /[A-Za-z]{3}/.test(s) && !/road|birmingham|mosley|motorway|trading|unit 0|tel|vat reg|bank|sort|account|www|@|gold|apex|pex/i.test(s)) realRows.push(s.replace(/\s{3,}/g, '   ')); }

const words = ["FRESH","HALAL","FILLET","110-130","9KG","9G","MEDUIM","INNER","1600GM","CHICKEN","PRIME","WING","WINGS","TORTILLA","WRAP","10'","PANINI","SESAME","130g","NUGGETS","BREDED","STEAK","BREADED","AMERICANA","A4.5","SEED","BURGER","BUN","4X12","PEPSI","CAN","24X330","ML","ORIGINAL","BREADING","SUPRANO","CHEESE","R74","PALMAX","FAT","12.50","CHEFF","REAL","MAYO","10L","LION","VERY","HOT","CHILLI","SAUCE","2X2.27","L","KTC","VEGETABLE","OIL","TIN","20","Itrs","ltrs","QUATER","POUNDER","48X40Z","48X4oz","KETCH","UP","2X4.5LT","POPCORN","3KG","PIZZA","FLOUR","16KG","BOXES","16","INCH","COLOUR","WIPE","TISSU","10X500","10XS00","HP10","Mayonnaise","Chips","7mm","(9mm)","4x2.5kg","Coca","Cola","24x330ml","Fries","Buns","Salt","Bag"];
const junk = ["|","—","-","(A","A715)","Q","VA","Vis","L","Z","S","T","ee","rr","Vrt","\\","9","32","™","[1","O","_","~","'","“","”",")","{","AANA","000","Th","R","=","/","£"];
const codes = ["123456","AB12345","FD-1029","00412","P/1203"];
const money = v => v.toFixed(2);
function corruptNum(s){
  const r = rnd();
  if(r < 0.08) return s.replace('.', ',');
  if(r < 0.14) return s.replace('.', '');
  if(r < 0.19) return s.replace(/0/g, 'O');
  if(r < 0.23) return s.replace(/1/, 'l');
  if(r < 0.27) return s.replace(/5/, 'S');
  if(r < 0.31) return '£' + s;
  if(r < 0.34) return s + ')';
  if(r < 0.36) return '.' + s.split('.')[1];
  return s;
}
function fuzzLine(){
  const parts = [];
  if(chance(0.12)) parts.push(pick(junk));
  const qty = pick([1,1,1,2,2,3,4,5,6,7,10,12,24]);
  const qr = rnd();
  if(qr < 0.55) parts.push(corruptNum(money(qty))); else if(qr < 0.75) parts.push(String(qty)); else if(qr < 0.82) parts.push(String(qty * 100)); else if(qr < 0.88) parts.push(pick(junk));
  if(chance(0.12)) parts.push(pick(codes));
  if(chance(0.06)) parts.push(money(qty));
  const n = 1 + Math.floor(rnd() * 5);
  for(let i = 0; i < n; i++){ parts.push(chance(0.75) ? pick(words) : pick(words).toLowerCase()); if(chance(0.07)) parts.push(pick(junk)); }
  if(chance(0.2)) parts.push(pick(junk));
  const unit = pick([6.99, 8.29, 9.99, 10.99, 14.99, 15, 19.99, 21.99, 22.99, 24.99, 26.99, 27.99, 41.99, 47.99, 49.99, 50.99, 0.85, 105.5]);
  const net = Math.round(qty * unit * 100) / 100;
  const nr = rnd();
  if(nr < 0.72){ parts.push(corruptNum(money(unit))); if(chance(0.1)) parts.push(pick(junk)); parts.push(corruptNum(money(chance(0.08) ? net + 1 : net))); }
  else if(nr < 0.82){ parts.push(corruptNum(money(unit))); }
  else if(nr < 0.9){ parts.push(corruptNum(money(net))); }
  else if(nr < 0.95){ parts.push(money(unit), money(0), money(net)); }
  if(chance(0.35)) parts.push(pick(["0.00","20.00","5.00","0,00","O.OO", money(Math.round(net * 20) / 100)]));
  if(chance(0.2)) parts.push(pick(junk));
  if(chance(0.05)) parts.push(pick(junk), pick(junk));
  if(chance(0.03)) parts.push("11.00","12.00","13.00","14.00");
  return parts.join(chance(0.3) ? "   " : " ");
}
const pl = p => p ? { qty: p.qty, desc: p.desc, raw: p.raw, unit: p.unit, vat: p.vat, warn: p.warn } : null;
const ml = p => Object.assign(pl(p), { reads: p.reads || 0, disagree: !!p.disagree, onlyB: !!p.onlyB, altQty: p.alt ? p.alt.qty : null, altUnit: p.alt ? p.alt.unit : null });
const inv = P => ({ supplier: P.supplier, invNo: P.invNo, date: P.date, printedNet: P.printedNet == null ? null : P.printedNet, printedTotal: P.printedTotal == null ? null : P.printedTotal, lines: P.lines.map(ml) });

const lineInputs = [...realRows];
for(let i = 0; i < 700; i++) lineInputs.push(fuzzLine());
lineInputs.push("", "x", "2.00 CHICKEN", "TOTAL NET AMOUNT 546.73", "  3.00   FRESH PRIME WING   15.99   47.97   0.00  ", "1 2.00 ORIGINAL BREADING 19.99 39.98", "QUATER POUNDER 48X40Z va VIS L Q 24.99 49.98");
const lines = lineInputs.map(s => ({ in: s, out: pl(parseLine(s)) }));

const cleanInputs = ["Quater Pounder 48x40z Va Vis L Q","123456 Chicken Wings 10kg Z","Burger Buns 4x12 S","Vegetable Oil 20 L","Hot Dog Bun","Mayonnaise 10L | V","AB12345 Fries 9mm 4x2.5kg ee","Chicken l Wings Vrt","Coca Cola Can 24x330ml T",
  "QUATER POUNDER 48X4oz A A715)","3 CHEFF REAL MAYO 10L 10.99 000 AANA","WAPE UP TISSU 10XS00","HP10 BURGER BOXES","PALMAX FAT 12.50","Fries (9mm)","KTC VEGETABLE OIL TIN 20 Itrs","[1 2.00 ORIGINAL BREADING","SUPRANO CHEESE R74 (VA","", "A", "2.00 2.00 X"];
for(let i = 0; i < 250; i++){ const n = 1 + Math.floor(rnd() * 6), p = []; for(let k = 0; k < n; k++) p.push(chance(0.7) ? pick(words) : chance(0.5) ? pick(junk) : pick(codes.concat(["2.00","10.99","7"]))); cleanInputs.push(p.join(" ")); }
const clean = cleanInputs.map(s => ({ in: s, out: cleanDesc(s) }));

const consensus = [];
for(let i = 0; i < 150; i++){ const n = 2 + Math.floor(rnd() * 4), base = []; for(let k = 0; k < n; k++) base.push(pick(words));
  const mut = () => { const a = base.slice(); if(chance(0.4)) a.unshift(pick(junk.concat(words))); if(chance(0.4)) a.push(pick(junk.concat(words))); if(chance(0.2)) a.splice(Math.floor(rnd() * a.length), 1); return a.join(" ") || "X"; };
  const a = mut(), b = mut(); consensus.push({ a, b, out: consensusDesc(a, b) }); }

function invoiceText(rows, opts){
  const net = opts.net;
  return ["Sample Foods Ltd", "12 Example Street", "Invoice No   " + opts.no, "Invoice Date  " + opts.date, "Quantity  Description  Unit Price  Net Amount  VAT", ...rows,
    opts.noTotal ? "" : "Total Net Amount   " + money(net), "Invoice Total  " + money(net + 3.2)].join("\n");
}
function cleanRows(k){ const rows = []; let net = 0; for(let i = 0; i < k; i++){ const q = pick([1,2,3,5,7]), u = pick([6.99,14.99,24.99,41.99,49.99,8.29]); const nm = pick(names).toUpperCase();
  rows.push(`${money(q)}   ${nm}   ${money(u)}   ${money(q * u)}   ${chance(0.2) ? "20.00" : "0.00"}`); net += Math.round(q * u * 100) / 100; } return { rows, net }; }
const perturb = rows => rows.map(r => { let t = r.split(/\s+/); if(chance(0.25)) t.splice(1 + Math.floor(rnd() * (t.length - 1)), 0, pick(junk)); if(chance(0.15)) t[t.length - 2] = corruptNum(t[t.length - 2]); if(chance(0.1)) t[0] = pick(["l.00","7.00","2,00"]); if(chance(0.08)) t.pop(); return t.join("  "); }).filter(() => !chance(0.06));
const invoices = [], merges = [];
for(let i = 0; i < 40; i++){
  const { rows, net } = cleanRows(3 + Math.floor(rnd() * 8));
  const opts = { no: 80000 + i, date: "0" + (1 + i % 9) + "/11/2026", net: chance(0.15) ? net + 5 : net, noTotal: chance(0.1) };
  const a = invoiceText(chance(0.5) ? perturb(rows) : rows, opts), b = invoiceText(perturb(rows), opts);
  invoices.push({ text: a, out: inv(parseInvoice(a)) });
  const A = parseInvoice(a), B = parseInvoice(b);
  merges.push({ a, b, known: knownSuppliers(), out: inv(mergeReads(A, B)) });
}
// real rows in a synthetic invoice
{ const a = invoiceText(realRows.slice(0, 14), { no: 82044, date: "06/11/2026", net: 546.73 }); invoices.push({ text: a, out: inv(parseInvoice(a)) }); }

const rows = [];
for(let i = 0; i < 25; i++){
  const ang = (rnd() - 0.5) * (i % 5 === 0 ? 1.0 : 0.12), items = [], nrow = 3 + Math.floor(rnd() * 8);
  for(let r = 0; r < nrow; r++){ const y = 100 + r * 40 + (rnd() - 0.5) * 6; let x = 30;
    const cols = [money(pick([1,2,3])), pick(names).toUpperCase(), money(14.99), money(29.98)];
    for(const t of cols){ const w = t.length * 11, h = 18 + rnd() * 4, cx = x + w / 2, cy = y + (rnd() - 0.5) * 5;
      items.push({ t: chance(0.05) ? " " : t, c: chance(0.08) ? 0.2 : 0.5 + rnd() * 0.5, x: cx * Math.cos(ang) - cy * Math.sin(ang), y: cx * Math.sin(ang) + cy * Math.cos(ang), w, h: chance(0.03) ? 0 : h, a: ang + (rnd() - 0.5) * 0.01 }); x += w + 40 + rnd() * 30; } }
  for(let k = items.length - 1; k > 0; k--){ const j = Math.floor(rnd() * (k + 1)); [items[k], items[j]] = [items[j], items[k]]; }
  rows.push({ items, out: visionRows(items) });
}
const norm = global.norm;
const out = { names, known: [...knownWords()], lines, clean, consensus, invoices, merges, rows };
fs.writeFileSync('parser.json', JSON.stringify(out));
const ok = lines.filter(l => l.out).length;
console.log('real rows', realRows.length, '| lines', lines.length, 'parsed', ok, '| clean', clean.length, '| consensus', consensus.length, '| invoices', invoices.length, '| merges', merges.length, '| rows', rows.length, '| bytes', fs.statSync('parser.json').size);
console.log(realRows.slice(0, 6).join('\n'));
