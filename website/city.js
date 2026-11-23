/*
 * The page background: a pixel city drawn in ordered dither with live 120fps spotlighting.
 * Architecture for full native refresh rate, ultra-low CPU, and ~4 MB memory:
 *   1. Static dimmed neighbourhood cached once per layout/scroll/scene on a viewport canvas.
 *   2. Quarter-res (~96 KB) GPU-upscaled dimming veil & spotlight canvas, redrawn only while moving.
 *   3. Foreground actor & signal-wire canvas updated at native rAF using dirty-rect putImageData.
 */
(function () {
  'use strict';

  const fgCanvas = document.getElementById('city');
  const main = document.getElementById('main');
  const stageEl = document.getElementById('film-stage');
  if (!fgCanvas || !main) return;

  // Create the cached background layer and tiny quarter-res scrim layer directly beneath #city
  const bgCanvas = document.createElement('canvas');
  bgCanvas.className = 'city-canvas city-bg';
  bgCanvas.setAttribute('aria-hidden', 'true');
  const scrimCanvas = document.createElement('canvas');
  scrimCanvas.className = 'city-scrim';
  scrimCanvas.setAttribute('aria-hidden', 'true');
  fgCanvas.parentNode.insertBefore(bgCanvas, fgCanvas);
  fgCanvas.parentNode.insertBefore(scrimCanvas, fgCanvas);

  const chatEl = document.getElementById('film-chat');
  const deviceEl = document.getElementById('film-device');
  const stripEl = document.getElementById('city-strip');
  const heroEl = document.querySelector('.hero');
  const tagAgent = document.getElementById('tag-agent');
  const tagYou = document.getElementById('tag-you');

  const bgCtx = bgCanvas.getContext('2d', { alpha: true });
  const scrimCtx = scrimCanvas.getContext('2d', { alpha: true });
  const fgCtx = fgCanvas.getContext('2d', { alpha: true });
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');

  const CELL = 2;
  const SCRIM_DIV = 4; // Quarter resolution (~200x120 = 96 KB) upscaled smoothly by the GPU
  const FLANK_MIN = 1160;
  const BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map(function (v) { return v * 16 + 8; });

  const P = {
    DIM: 1, LINE: 2, WARM: 3, CYAN: 4, MAG: 5, GREEN: 6, RED: 7, WHITE: 8, SKIN: 9,
    INK: 10, ROAD: 11, TREE: 12, BLUE: 13, WOOD: 14, HAIR: 15, DENIM: 16, BRIGHT: 17
  };

  const THEMES = {
    dark: {
      1: [96, 138, 255, 0.56], 2: [176, 202, 255, 1], 3: [255, 214, 120, 1], 4: [76, 232, 255, 1],
      5: [255, 98, 214, 1], 6: [52, 228, 128, 1], 7: [255, 92, 82, 1], 8: [248, 250, 255, 1],
      9: [246, 198, 160, 1], 10: [12, 19, 44, 1], 11: [134, 156, 224, 0.42], 12: [64, 224, 136, 0.62],
      13: [96, 148, 255, 1], 14: [204, 144, 86, 1], 15: [158, 106, 70, 1], 16: [68, 96, 208, 1],
      17: [118, 160, 255, 0.96]
    },
    light: {
      1: [47, 98, 245, 0.36], 2: [18, 56, 186, 1], 3: [242, 156, 18, 1], 4: [8, 148, 188, 1],
      5: [208, 50, 170, 1], 6: [20, 156, 68, 1], 7: [222, 46, 40, 1], 8: [255, 255, 255, 1],
      9: [228, 170, 126, 1], 10: [22, 36, 84, 1], 11: [20, 60, 160, 0.24], 12: [22, 136, 64, 0.56],
      13: [34, 90, 245, 1], 14: [172, 118, 62, 1], 15: [74, 46, 34, 1], 16: [34, 52, 122, 1],
      17: [42, 94, 245, 0.86]
    }
  };

  const DIM_THEMES = {
    dark: {
      1: [76, 96, 158, 0.26], 2: [94, 116, 178, 0.34], 3: [170, 154, 118, 0.28], 4: [84, 138, 170, 0.28],
      5: [148, 92, 148, 0.26], 6: [74, 142, 112, 0.26], 7: [152, 86, 86, 0.26], 8: [140, 156, 198, 0.28],
      9: [148, 134, 126, 0.30], 10: [16, 24, 52, 0.45], 11: [90, 108, 162, 0.20], 12: [72, 134, 106, 0.26],
      13: [86, 112, 182, 0.32], 14: [128, 110, 96, 0.28], 15: [106, 92, 88, 0.28], 16: [76, 94, 156, 0.30],
      17: [88, 110, 176, 0.30]
    },
    light: {
      1: [82, 104, 156, 0.22], 2: [74, 96, 148, 0.30], 3: [164, 142, 108, 0.24], 4: [76, 124, 148, 0.24],
      5: [144, 96, 142, 0.22], 6: [72, 124, 98, 0.24], 7: [156, 88, 90, 0.24], 8: [168, 180, 206, 0.28],
      9: [152, 136, 124, 0.28], 10: [64, 80, 120, 0.32], 11: [76, 96, 148, 0.14], 12: [74, 122, 98, 0.24],
      13: [78, 104, 164, 0.28], 14: [134, 116, 100, 0.26], 15: [94, 86, 86, 0.28], 16: [74, 90, 136, 0.28],
      17: [84, 106, 160, 0.26]
    }
  };

  const CH = {
    H: P.HAIR, S: P.SKIN, K: P.INK, B: P.BLUE, D: P.DENIM, W: P.WHITE, G: P.LINE,
    C: P.CYAN, Y: P.WARM, O: P.WOOD, R: P.RED, N: P.GREEN, M: P.MAG
  };

  const SPRITES = {
    loo: [
      '......HHHH.......',
      '.....HHHHHH......',
      '.....HHSSSS......',
      '.....HSSKSS......',
      '.....SSSSSS......',
      '......SSSS.......',
      '.....BBBBB.......',
      'WW..BBBBBBB......',
      'WW..BBBBBBB..CK..',
      'WW..BBBBBBBSSCK..',
      'WW..BBBBBB...CK..',
      'WW..DDDDDDDDD....',
      'WW..DDDDDDDDDD...',
      'WWWWWWWWWW.DDD...',
      'WWWWWWWWWW.DDD...',
      '.WWWWWWWW..DDD...',
      '..WWWWWW...DDD...',
      '...WWWW....SSS...',
      '..WWWWWW...KKKK..'
    ],
    desk: [
      '......HHHH................',
      '.....HHHHHH...............',
      '.....HHSSSS...............',
      '.....HSSKSS.......GGGGGGG.',
      '.....SSSSSS.......GCCCCCG.',
      '......SSSS........GCCCCCG.',
      '.....BBBBB........GCCCCCG.',
      '.G..BBBBBBB.......GCCCCCG.',
      '.G..BBBBBBBSSSS...GGGGGGG.',
      '.G..BBBBBBB...SS....GG....',
      '.G..BBBBBB....GGGGGGGGGGG.',
      '.G..DDDDDDDD.OOOOOOOOOOOOO',
      '.GGGGGGGGGDD.O...........O',
      '....G....GDD.O...........O',
      '....G....GDD.O...........O',
      '....G....GSS.O...........O',
      '...GG...GGKKKO...........O'
    ],
    cat: [
      'W...W...',
      'WWWWW..W',
      'WWWWWWWW',
      '.WWWWWW.'
    ],
    car: [
      '..GGGGG...',
      '.GCCGCCG..',
      'GGGGGGGGGY',
      'GGGGGGGGGG',
      '.KK...KK..'
    ],
    pin: [
      '.BBBBBBB.',
      'BBBBBBBBB',
      'BWBBBBBBB',
      'BBWBBBBBB',
      'BWBBWWWBB',
      'BBBBBBBBB',
      '.BBBBBBB.',
      '...BBB...',
      '....B....'
    ]
  };

  let theme = document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
  let pal = new Uint32Array(18);
  let palDim = new Uint32Array(18);

  let W = 0, VH = 0, SW = 0, SH = 0, docH = 0;
  let den = null, col = null;
  let bgImg = null, bg32 = null;
  let fgImg = null, fg32 = null;

  let offY = 0, lastOffY = -99999;
  let vy0 = 0, vy1 = 0;
  let bgDirty = true;
  let scrimDirty = true;

  // Track separate left-flank and right-flank dirty boxes so the wide centre column costs 0 CPU
  let dL = [0, 0, 0, 0], dR = [0, 0, 0, 0];
  let pL = [0, 0, 0, 0], pR = [0, 0, 0, 0];
  let trackDirty = false;

  let L = null;
  let ground = [];
  let staticItems = [];
  let dynamicItems = [];
  let scene = { agent: 'home', you: 'bike', status: 'ask', speaking: false };
  let statusAt = 0;
  let clock = 0;
  let spotA = null;
  let spotU = null;

  let D = 1;

  function buildPal(src, dst) {
    dst[0] = 0;
    for (let i = 1; i < 18; i++) {
      const c = src[i];
      dst[i] = ((Math.round(c[3] * 255) << 24) | (c[2] << 16) | (c[1] << 8) | c[0]) >>> 0;
    }
  }

  function setPalette() {
    buildPal(THEMES[theme], pal);
    buildPal(DIM_THEMES[theme], palDim);
    bgDirty = true;
    scrimDirty = true;
  }

  function mulberry(seed) {
    let a = seed >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function hash(a, b, c) {
    let h = (a * 374761393 + b * 668265263 + c * 2147483647) | 0;
    h = (h ^ (h >>> 13)) * 1274126177;
    return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
  }

  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }

  function expandBox(box, x0, y0, x1, y1) {
    if (x0 < box[0]) box[0] = x0;
    if (y0 < box[1]) box[1] = y0;
    if (x1 > box[2]) box[2] = x1;
    if (y1 > box[3]) box[3] = y1;
  }

  function expandDirty(x0, y0, x1, y1) {
    if (!trackDirty) return;
    const mid = L ? L.cx : (W >> 1);
    if (x1 <= mid) {
      expandBox(dL, x0, y0, x1, y1);
    } else if (x0 >= mid) {
      expandBox(dR, x0, y0, x1, y1);
    } else {
      expandBox(dL, x0, y0, mid, y1);
      expandBox(dR, mid, y0, x1, y1);
    }
  }

  // ---- Raster (writes into shared den/col scratch buffer for either bg or fg pass) ----
  let S = 1, PX = 0, PY = 0;

  function scaled(m, s, fn, t, density) {
    const prevD = D;
    D = density === undefined ? 1 : density;
    S = s; PX = Math.round(m.x); PY = Math.round(m.y);
    fn(m, t);
    S = 1;
    D = prevD;
  }

  function rect(x, y, w, h, c, d) {
    if (S !== 1) { x = PX + (x - PX) * S; y = PY + (y - PY) * S; w *= S; h *= S; }
    const x0 = Math.max(0, Math.round(x)), x1 = Math.min(W, Math.round(x + w));
    const y0 = Math.max(vy0, Math.round(y)), y1 = Math.min(vy1, Math.round(y + h));
    if (x0 >= x1 || y0 >= y1) return;
    const vyA = y0 - offY, vyB = y1 - offY;
    expandDirty(x0, vyA, x1, vyB);
    const dv = c === 0 ? 0 : Math.min(255, Math.round(d * D));
    for (let vy = vyA; vy < vyB; vy++) {
      const o = vy * W;
      for (let xx = x0; xx < x1; xx++) { den[o + xx] = dv; col[o + xx] = c; }
    }
  }

  function px(x, y, c, d) {
    x = Math.round(x); y = Math.round(y);
    const val = d === undefined ? 255 : d;
    if (S !== 1) { rect(x, y, 1, 1, c, val); return; }
    if (x < 0 || x >= W || y < vy0 || y >= vy1) return;
    const vy = y - offY;
    expandDirty(x, vy, x + 1, vy + 1);
    const i = vy * W + x;
    den[i] = c === 0 ? 0 : Math.min(255, Math.round(val * D));
    col[i] = c;
  }

  function line(x0, y0, x1, y1, c, d) {
    x0 = Math.round(x0); y0 = Math.round(y0); x1 = Math.round(x1); y1 = Math.round(y1);
    const dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0);
    const sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    let err = dx + dy;
    for (let n = 0; n < 2000; n++) {
      px(x0, y0, c, d);
      if (x0 === x1 && y0 === y1) break;
      const e2 = 2 * err;
      if (e2 >= dy) { err += dy; x0 += sx; }
      if (e2 <= dx) { err += dx; y0 += sy; }
    }
  }

  function disc(cx, cy, r, c, d) {
    const r2 = r * r + r * 0.6;
    const lim = Math.ceil(r);
    for (let yy = -lim; yy <= lim; yy++) {
      for (let xx = -lim; xx <= lim; xx++) {
        if (xx * xx + yy * yy <= r2) px(cx + xx, cy + yy, c, d);
      }
    }
  }

  function ring(cx, cy, r, c, d) {
    const n = Math.max(14, Math.round(r * 7.5));
    for (let k = 0; k < n; k++) {
      const a = (k / n) * Math.PI * 2;
      px(cx + Math.cos(a) * r, cy + Math.sin(a) * r, c, d);
    }
  }

  function glow(cx, cy, r, c, dmax) {
    if (S !== 1) { cx = PX + (cx - PX) * S; cy = PY + (cy - PY) * S; r *= S; }
    cx = Math.round(cx); cy = Math.round(cy);
    const ri = Math.ceil(r);
    const x0 = Math.max(0, cx - ri), x1 = Math.min(W, cx + ri + 1);
    const y0 = Math.max(vy0, cy - ri), y1 = Math.min(vy1, cy + ri + 1);
    if (x0 >= x1 || y0 >= y1) return;
    expandDirty(x0, y0 - offY, x1, y1 - offY);
    const dm = dmax * D;
    for (let y = y0; y < y1; y++) {
      const dy = y - cy;
      const row = (y - offY) * W;
      for (let x = x0; x < x1; x++) {
        const dx = x - cx;
        const q = 1 - Math.sqrt(dx * dx + dy * dy) / r;
        if (q <= 0) continue;
        const v = dm * q * q;
        const i = row + x;
        if (den[i] < 200 && v > 12 && v > den[i] * 0.7) { den[i] = Math.max(den[i], Math.min(255, Math.round(v))); col[i] = c; }
      }
    }
  }

  function sprite(x, y, rows) {
    x = Math.round(x); y = Math.round(y);
    for (let r = 0; r < rows.length; r++) {
      const row = rows[r];
      for (let k = 0; k < row.length; k++) {
        const ch = row.charCodeAt(k);
        if (ch !== 46) px(x + k, y + r, CH[row[k]], 255);
      }
    }
  }

  // ---- Background City ---------------------------------------------------
  function shell(x, y, w, h, dw, c, roofDen, sideDen) {
    const dh = dw * 2;
    for (let i = 0; i < dw; i++) rect(x + w + i, y - h - 2 * i - 1, 1, h, c, sideDen);
    for (let j = 0; j < dh; j++) rect(x + ((j + 1) >> 1), y - h - 1 - j, w, 1, c, roofDen);
  }

  function drawFiller(b, t) {
    const x = b.x, y = b.y, w = b.w, h = b.h, dw = b.dw, dh = dw * 2;
    shell(x, y, w, h, dw, P.DIM, b.kind === 'house' ? 168 : 132, 42);
    if (b.kind === 'house') {
      for (let j = dw; j < dh; j++) rect(x + ((j + 1) >> 1), y - h - 1 - j, w, 1, P.DIM, 96);
      rect(x + (dw >> 1), y - h - dw, w, 1, P.DIM, 240);
      rect(x + b.chim, y - h - dh - 3, 3, 5, P.DIM, 240);
    } else {
      rect(x + dw, y - h - dh, w, 1, P.DIM, 240);
      rect(x + b.chim, y - h - dw - 3, 5, 3, P.DIM, 240);
      if (b.mast) {
        rect(x + w - 3, y - h - dh - 9, 1, 9, P.DIM, 240);
        px(x + w - 3, y - h - dh - 10, P.RED, 240);
      }
    }
    rect(x, y - h, w, h, P.DIM, 82);
    rect(x, y - h, w, 1, P.DIM, 240);
    const slot = Math.floor(t / 7 + b.seed);
    for (let k = 0; k < b.wins.length; k++) {
      const wn = b.wins[k];
      const lit = hash(b.seed, k, slot + (k % 3)) < 0.58;
      if (lit) rect(x + wn[0], y - h + wn[1], 2, 3, wn[2], 235);
      else rect(x + wn[0], y - h + wn[1], 2, 3, 0, 0);
    }
    if (b.kind === 'shop') {
      rect(x + 3, y - h + 2, w - 6, 1, b.neon, 235);
      rect(x + 2, y - 6, w - 4, 5, 0, 0);
      rect(x + 2, y - 6, w - 4, 5, P.WARM, 115);
    } else {
      rect(x + b.door, y - 5, 3, 5, 0, 0);
    }
  }

  function makeFiller(x, y, wMax, rng) {
    const r = rng();
    const kind = r < 0.5 ? 'house' : (r < 0.86 ? 'block' : 'shop');
    let w, h;
    if (kind === 'house') { w = 16 + Math.floor(rng() * 9); h = 11 + Math.floor(rng() * 5); }
    else if (kind === 'block') { w = 18 + Math.floor(rng() * 12); h = 18 + Math.floor(rng() * 13); }
    else { w = 18 + Math.floor(rng() * 8); h = 11 + Math.floor(rng() * 3); }
    w = Math.min(w, wMax);
    const dw = 4 + Math.floor(rng() * 3);
    const wins = [];
    if (kind === 'block') {
      for (let wy = 4; wy < h - 7; wy += 6) {
        for (let wx = 3; wx < w - 3; wx += 5) wins.push([wx, wy, rng() < 0.16 ? P.CYAN : P.WARM]);
      }
    } else if (kind === 'house') {
      for (let wx = 3; wx < w - 8; wx += 6) wins.push([wx, 3, P.WARM]);
    }
    return {
      y: y, top: y - h - dw * 2 - 12, bot: y + 1,
      x: x, w: w, h: h, dw: dw, kind: kind, wins: wins,
      seed: Math.floor(rng() * 9999), chim: 3 + Math.floor(rng() * Math.max(1, w - 10)),
      door: w - 6, mast: rng() < 0.35, neon: rng() < 0.5 ? P.MAG : P.CYAN,
      draw: drawFiller
    };
  }

  function drawTree(b) {
    rect(b.x, b.y - 3, 1, 3, P.TREE, 240);
    disc(b.x, b.y - 3 - b.r, b.r, P.TREE, 165);
    px(b.x - 1, b.y - 4 - b.r, P.TREE, 240);
    px(b.x, b.y - 5 - b.r, P.TREE, 240);
  }

  function drawLamp(b) {
    rect(b.x, b.y - 8, 1, 8, P.DIM, 235);
    px(b.x, b.y - 9, P.WARM, 240);
    px(b.x + 1, b.y - 9, P.WARM, 240);
    glow(b.x, b.y + 3, 6, P.WARM, 65);
  }

  function drawWalker(b, t) {
    const prevD = D;
    D = 0.45;
    const span = b.x1 - b.x0;
    const x = Math.round(b.x0 + (((t * b.speed + b.phase) % span) + span) % span);
    const step = ((t * 4 + b.phase) | 0) % 2;
    rect(x, b.y - 7, 2, 2, P.DIM, 220);
    rect(x, b.y - 5, 2, 3, P.DIM, 240);
    px(x + step, b.y - 2, P.DIM, 220);
    px(x + 1 - step, b.y - 2, P.DIM, 220);
    D = prevD;
  }

  function drawCar(b, t) {
    const prevD = D;
    D = 0.42;
    const span = b.x1 - b.x0 + 40;
    const x = b.x0 - 20 + ((t * b.speed + b.phase) % span + span) % span;
    rect(x + 2, b.y + 3, 5, 1, P.DIM, 220);
    rect(x + 1, b.y + 4, 8, 2, P.DIM, 220);
    px(x + 9, b.y + 5, P.WARM, 200);
    px(x + 1, b.y + 6, P.DIM, 220);
    px(x + 7, b.y + 6, P.DIM, 220);
    D = prevD;
  }

  // ---- Landmarks ---------------------------------------------------------
  function statusColour() {
    if (scene.status === 'ok') return P.GREEN;
    if (scene.status === 'deny' || scene.status === 'blocked') return P.RED;
    return P.BLUE;
  }

  function statusRGB() {
    if (scene.status === 'ok') return theme === 'light' ? '22, 156, 68' : '52, 228, 128';
    if (scene.status === 'deny' || scene.status === 'blocked') return theme === 'light' ? '220, 48, 42' : '255, 92, 82';
    return theme === 'light' ? '38, 92, 245' : '92, 145, 255';
  }

  function room(x, y, w, h, wallCol, wallDen, borderCol) {
    rect(x, y - h, w, h, wallCol, wallDen);
    const bc = borderCol || P.LINE;
    rect(x, y - h, w, 1, bc, 255);
    rect(x, y - h, 1, h, bc, 255);
    rect(x + w - 1, y - h, 1, h, bc, 255);
    rect(x, y - 1, w, 1, bc, 255);
  }

  function spotlightFrame(x, y, w, h, c, t) {
    const pulse = 200 + Math.round(Math.sin(t * 3.5) * 50);
    const len = 5;
    rect(x - 2, y - h - 2, len, 1, c, pulse);
    rect(x - 2, y - h - 2, 1, len, c, pulse);
    rect(x + w + 2 - len, y - h - 2, len, 1, c, pulse);
    rect(x + w + 1, y - h - 2, 1, len, c, pulse);
    rect(x - 2, y + 1, len, 1, c, pulse);
    rect(x - 2, y + 2 - len, 1, len, c, pulse);
    rect(x + w + 2 - len, y + 1, len, 1, c, pulse);
    rect(x + w + 1, y + 2 - len, 1, len, c, pulse);
  }

  const MARK = {
    home: { w: 50, h: 30, dw: 6, tall: 50 },
    cloud: { w: 38, h: 34, dw: 6, tall: 80 },
    desk: { w: 50, h: 32, dw: 6, tall: 45 },
    toilet: { w: 40, h: 34, dw: 5, tall: 45 }
  };

  function drawHome(m, t) {
    const x = m.x, y = m.y, w = 50, h = 30, hot = scene.agent === 'home';
    const sc = hot ? statusColour() : P.CYAN;
    shell(x, y, w, h, 6, hot ? P.BRIGHT : P.DIM, 176, 64);
    for (let j = 6; j < 12; j++) rect(x + ((j + 1) >> 1), y - h - 1 - j, w, 1, hot ? P.BRIGHT : P.DIM, 104);
    rect(x + 3, y - h - 7, w, 1, hot ? P.BRIGHT : P.DIM, 255);
    rect(x + 36, y - h - 17, 4, 7, hot ? P.BRIGHT : P.DIM, 255);
    for (let k = 0; k < 3; k++) {
      const p = (t * 0.35 + k / 3) % 1;
      px(x + 38 + Math.sin(p * 6 + k) * 2, y - h - 19 - p * 10, P.DIM, 255 * (1 - p));
    }
    room(x, y, w, h, P.WARM, hot ? 56 : 36, hot ? sc : P.LINE);
    rect(x + 4, y - h + 5, 9, 9, P.CYAN, 60);
    rect(x + 4, y - h + 5, 9, 1, P.LINE, 255);
    rect(x + 4, y - h + 13, 9, 1, P.LINE, 255);
    rect(x + 8, y - h + 5, 1, 9, P.LINE, 255);
    rect(x + 15, y - 11, 25, 1, P.WOOD, 255);
    rect(x + 16, y - 10, 1, 9, P.WOOD, 255);
    rect(x + 38, y - 10, 1, 9, P.WOOD, 255);
    rect(x + 17, y - 14, 9, 3, P.WHITE, 255);
    const blink = scene.status === 'blocked' && hot ? ((t * 2.5) | 0) % 2 === 0 : true;
    px(x + 24, y - 13, blink ? sc : P.INK, 255);
    rect(x + 27, y - 24, 12, 10, P.LINE, 255);
    rect(x + 28, y - 23, 10, 8, P.INK, 255);
    rect(x + 32, y - 14, 2, 3, P.LINE, 255);
    for (let k = 0; k < 3; k++) {
      const len = hot && scene.status === 'blocked' ? (k === 0 ? 7 : 0) : 2 + ((t * 2.5 + k * 3) | 0) % 7;
      if (len && blink) rect(x + 29, y - 22 + k * 2, len, 1, sc, 255);
    }
    rect(x + 42, y - 18, 6, 17, P.BRIGHT, 130);
    px(x + 43, y - 9, P.WARM, 255);
    sprite(x + 4, y - 5, SPRITES.cat);
    if (((t * 1.8) | 0) % 2 === 0) px(x + 12, y - 6, P.WHITE, 255);
    glow(x + 9, y - 22, 9, P.WARM, 110);
    if (hot) {
      glow(x + 33, y - 19, 12, sc, 180);
      spotlightFrame(x, y, w, h, sc, t);
    }
  }

  function drawCloud(m, t) {
    const x = m.x, y = m.y, w = 38, h = 34, hot = scene.agent === 'cloud';
    const sc = hot ? statusColour() : P.GREEN;
    shell(x, y, w, h, 6, hot ? P.BRIGHT : P.DIM, 130, 64);
    rect(x + 6, y - h - 12, w, 1, hot ? P.BRIGHT : P.DIM, 255);
    rect(x, y - h, w, h, P.INK, 255);
    rect(x, y - h, w, 1, hot ? sc : P.LINE, 255);
    rect(x, y - h, 1, h, hot ? sc : P.LINE, 255);
    rect(x + w - 1, y - h, 1, h, hot ? sc : P.LINE, 255);
    for (let r = 0; r * 5 + 8 < h; r++) {
      const yy = y - h + 4 + r * 5;
      rect(x + 3, yy, w - 6, 3, P.BRIGHT, 48);
      for (let k = 0; k * 3 + 8 < w; k++) {
        const on = hash(r, k, Math.floor(t * (hot ? 4 : 2) + r)) < 0.65;
        if (on) px(x + 4 + k * 3, yy + 1, (k + r) % 4 === 0 ? P.CYAN : sc, 255);
      }
    }
    rect(x + w - 6, y - h - 28, 1, 16, P.LINE, 255);
    if (((t * 1.8) | 0) % 2 === 0) px(x + w - 6, y - h - 29, P.RED, 255);
    rect(x + 10, y - h - 10, 6, 1, P.LINE, 255);
    rect(x + 12, y - h - 14, 2, 4, P.LINE, 255);
    const cx = x + 16 + Math.sin(t * 0.45) * 3;
    const cy = y - h - 36;
    const cloudCol = theme === 'light' ? P.DIM : P.WHITE;
    disc(cx - 9, cy + 2, 6, cloudCol, 155);
    disc(cx + 9, cy + 2, 6, cloudCol, 155);
    disc(cx, cy - 2, 8, cloudCol, 195);
    disc(cx, cy + 4, 6, cloudCol, 125);
    rect(cx - 14, cy + 7, 29, 1, cloudCol, 240);
    for (let k = 0; k < 5; k++) {
      const p = ((t * (hot ? 1.2 : 0.7) + k / 5) % 1);
      px(cx + (k - 2) * 4, cy + 10 + p * 11, hot ? sc : P.CYAN, 255 * (1 - p * 0.55));
    }
    if (hot) spotlightFrame(x, y, w, h, sc, t);
  }

  function bubble(x, y, c) {
    rect(x - 1, y - 9, 9, 9, c, 255);
    rect(x, y - 8, 7, 7, P.WHITE, 255);
    px(x + 1, y, c, 255);
    rect(x + 3, y - 7, 1, 3, c, 255);
    px(x + 3, y - 3, c, 255);
  }

  function checkBubble(x, y) {
    rect(x - 1, y - 9, 9, 9, P.GREEN, 255);
    px(x + 1, y - 5, P.WHITE, 255);
    px(x + 2, y - 4, P.WHITE, 255);
    px(x + 3, y - 3, P.WHITE, 255);
    px(x + 4, y - 4, P.WHITE, 255);
    px(x + 5, y - 5, P.WHITE, 255);
    px(x + 6, y - 6, P.WHITE, 255);
  }

  function denyBubble(x, y) {
    rect(x - 1, y - 9, 9, 9, P.RED, 255);
    for (let k = 0; k < 5; k++) {
      px(x + 1 + k, y - 7 + k, P.WHITE, 255);
      px(x + 5 - k, y - 7 + k, P.WHITE, 255);
    }
  }

  function reaction(x, y, t) {
    const bob = Math.round(Math.sin(t * 4.2) * 1);
    if (scene.status === 'ask') {
      bubble(x, y + bob, P.BLUE);
      const p = (t * 1.1) % 1;
      ring(x + 3, y - 4 + bob, 5 + p * 7, P.BLUE, 220 * (1 - p));
    } else if (scene.status === 'ok') {
      checkBubble(x, y + bob);
      const age = t - statusAt;
      if (age < 1.8) ring(x + 3, y - 4, 4 + age * 9, P.GREEN, 255 * (1 - age / 1.8));
    } else if (scene.status === 'deny') {
      denyBubble(x, y + bob);
      const age = t - statusAt;
      if (age < 1.8) ring(x + 3, y - 4, 4 + age * 9, P.RED, 255 * (1 - age / 1.8));
    }
  }

  function drawDesk(m, t) {
    const x = m.x, y = m.y, w = 50, h = 32, hot = scene.you === 'desk';
    const sc = hot ? statusColour() : P.CYAN;
    shell(x, y, w, h, 6, hot ? P.BRIGHT : P.DIM, 150, 64);
    rect(x + 6, y - h - 12, w, 1, hot ? P.BRIGHT : P.DIM, 255);
    room(x, y, w, h, P.WARM, hot ? 54 : 32, hot ? sc : P.LINE);
    rect(x + 3, y - h + 5, 8, 9, P.CYAN, 56);
    rect(x + 3, y - h + 5, 8, 1, P.LINE, 255);
    rect(x + 3, y - h + 13, 8, 1, P.LINE, 255);
    rect(x + 38, y - h + 8, 10, 1, P.WOOD, 255);
    rect(x + 39, y - h + 5, 2, 3, P.MAG, 255);
    rect(x + 42, y - h + 4, 2, 4, P.CYAN, 255);
    rect(x + 45, y - h + 6, 2, 2, P.WARM, 255);
    disc(x + 44, y - 8, 2, P.TREE, 255);
    rect(x + 43, y - 5, 3, 4, P.WOOD, 255);
    sprite(x + 9, y - 18, SPRITES.desk);
    const typeStep = ((t * 5) | 0) % 2;
    if (hot) {
      px(x + 23, y - 9 - typeStep, P.SKIN, 255);
      px(x + 24, y - 8 - (1 - typeStep), P.SKIN, 255);
      rect(x + 28, y - 14, 5, 4, P.INK, 255);
      for (let k = 0; k < 3; k++) {
        const len = 1 + ((t * 3 + k * 2) | 0) % 4;
        rect(x + 28, y - 14 + k, len, 1, sc, 255);
      }
      glow(x + 30, y - 12, 10, sc, 175);
      reaction(x + 27, y - 20, t);
      spotlightFrame(x, y, w, h, sc, t);
    } else {
      glow(x + 29, y - 12, 7, P.CYAN, 110);
    }
  }

  function drawToilet(m, t) {
    const x = m.x, y = m.y, w = 40, h = 34, hot = scene.you === 'toilet';
    const sc = hot ? statusColour() : P.CYAN;
    shell(x, y, w, h, 5, hot ? P.BRIGHT : P.DIM, 150, 64);
    rect(x + 5, y - h - 10, w, 1, hot ? P.BRIGHT : P.DIM, 255);
    room(x, y, w, h, P.CYAN, hot ? 42 : 26, hot ? sc : P.LINE);
    for (let gx = 6; gx < w - 1; gx += 6) rect(x + gx, y - h + 1, 1, h - 2, hot ? P.BRIGHT : P.DIM, 54);
    for (let gy = 7; gy < h - 1; gy += 6) rect(x + 1, y - h + gy, w - 2, 1, hot ? P.BRIGHT : P.DIM, 54);
    rect(x + 30, y - h + 5, 6, 6, P.INK, 255);
    px(x + 33, y - h + 7, P.WARM, 255);
    px(x + 34, y - h + 8, P.WARM, 255);
    rect(x + 31, y - 15, 4, 1, P.LINE, 255);
    rect(x + 32, y - 14, 3, 3, P.WHITE, 255);
    px(x + 34, y - 11, P.WHITE, 255);
    sprite(x + 7, y - 20, SPRITES.loo);
    if (hot) {
      const tapStep = ((t * 4) | 0) % 2;
      rect(x + 20, y - 12, 1, 3, sc, 255);
      if (tapStep) px(x + 19, y - 11, P.SKIN, 255);
      glow(x + 20, y - 11, 10, sc, 185);
      if (scene.speaking) {
        // Pixel speech bubble above the person on the toilet so talking is unmistakable
        const bx = x + 19, by = y - 31, bw = 17, bh = 10;
        const bobY = Math.round(Math.sin(t * 7) * 0.6);
        const top = by + bobY;
        rect(bx + 1, top, bw - 2, bh, P.WHITE, 255);
        rect(bx, top + 1, bw, bh - 2, P.WHITE, 255);
        rect(bx + 1, top - 1, bw - 2, 1, P.RED, 255);
        rect(bx + 1, top + bh, bw - 2, 1, P.RED, 255);
        rect(bx - 1, top + 1, 1, bh - 2, P.RED, 255);
        rect(bx + bw, top + 1, 1, bh - 2, P.RED, 255);
        // Speech bubble tail pointing down-left toward mouth
        rect(bx + 2, top + bh, 3, 2, P.WHITE, 255);
        px(bx + 1, top + bh + 1, P.RED, 255);
        px(bx + 2, top + bh + 2, P.RED, 255);
        px(bx + 5, top + bh + 1, P.RED, 255);
        // Animated sound bars inside the bubble
        const s0 = 2 + Math.round((Math.sin(t * 14) + 1) * 1.4);
        const s1 = 2 + Math.round((Math.sin(t * 14 + 1.8) + 1) * 2.1);
        const s2 = 2 + Math.round((Math.sin(t * 14 + 3.6) + 1) * 1.6);
        const s3 = 2 + Math.round((Math.sin(t * 14 + 5.1) + 1) * 1.2);
        const midY = top + 5;
        rect(bx + 3, midY - (s0 >> 1), 2, s0, P.RED, 255);
        rect(bx + 6, midY - (s1 >> 1), 2, s1, P.BLUE, 255);
        rect(bx + 9, midY - (s2 >> 1), 2, s2, P.RED, 255);
        rect(bx + 12, midY - (s3 >> 1), 2, s3, P.BLUE, 255);
        const w1 = ((t * 3.0) % 1);
        ring(x + 16, y - 16, 2 + w1 * 5, P.RED, 190 * (1 - w1));
      } else {
        reaction(x + 22, y - 16, t);
      }
      spotlightFrame(x, y, w, h, sc, t);
    } else {
      glow(x + 19, y - 11, 7, P.CYAN, 110);
    }
  }

  function wheel(cx, cy, a) {
    ring(cx, cy, 5, P.LINE, 255);
    line(cx, cy, cx + Math.cos(a) * 4, cy + Math.sin(a) * 4, P.DIM, 255);
    line(cx, cy, cx - Math.sin(a) * 4, cy + Math.cos(a) * 4, P.DIM, 255);
  }

  function leg(hx, hy, bx, by, a, c) {
    const pxx = bx + Math.cos(a) * 2.6, pyy = by + Math.sin(a) * 2.6;
    const kx = (hx + pxx) / 2 + 2.4, ky = (hy + pyy) / 2 - 1;
    line(hx, hy, kx, ky, c, 255);
    line(kx, ky, pxx, pyy, c, 255);
  }

  function bikeX(t) {
    const b = L.bike;
    const mid = (b.x0 + b.x1) / 2;
    const amp = Math.max(4, Math.min(16, (b.x1 - b.x0) / 2));
    return Math.round(mid + Math.sin(t * 0.72) * amp);
  }

  function bikeBody(m, t) {
    const bob = Math.round(Math.sin(t * 11) * 0.6);
    const x = m.x, y = m.y - 5 + bob, a = t * 6.4;
    const hot = scene.you === 'bike';
    const dashOff = Math.floor(t * 14) % 10;
    for (let dx = -6; dx <= 22; dx += 10) {
      const rx = x + dx - dashOff;
      rect(rx, m.y + 1, 4, 1, hot ? P.BLUE : P.ROAD, hot ? 185 : 110);
    }
    wheel(x, y, a);
    wheel(x + 15, y, a);
    line(x, y, x + 6, y, P.LINE, 255);
    line(x + 6, y, x + 4, y - 8, P.LINE, 255);
    line(x + 4, y - 8, x + 12, y - 8, P.LINE, 255);
    line(x + 6, y, x + 12, y - 8, P.LINE, 255);
    line(x + 12, y - 10, x + 15, y, P.LINE, 255);
    px(x + 13, y - 11, P.LINE, 255);
    rect(x + 2, y - 9, 4, 1, P.INK, 255);
    leg(x + 4, y - 10, x + 6, y, a + Math.PI, P.INK);
    line(x + 4, y - 10, x + 9, y - 16, P.BLUE, 255);
    line(x + 5, y - 10, x + 10, y - 16, P.BLUE, 255);
    line(x + 3, y - 11, x + 8, y - 17, P.BLUE, 255);
    leg(x + 4, y - 10, x + 6, y, a, P.DENIM);
    line(x + 10, y - 15, x + 13, y - 12, P.SKIN, 255);
    disc(x + 11, y - 20, 2, P.SKIN, 255);
    rect(x + 9, y - 23, 5, 2, P.MAG, 255);
    px(x + 14, y - 22, P.MAG, 255);
    const wc = hot && scene.status !== 'idle' && scene.status !== 'blocked' ? statusColour() : P.WHITE;
    px(x + 12, y - 13, wc, 255);
    if (hot && scene.status !== 'idle' && scene.status !== 'blocked') {
      glow(x + 12, y - 13, 6, wc, 220);
    }
    if (hot && scene.status === 'blocked') {
      const p = (t * 0.65) % 1;
      px(x + 17, y - 22 - p * 8, P.RED, 255 * (1 - p));
      px(x + 19, y - 22 - p * 8, P.RED, 255 * (1 - p));
      px(x + 21, y - 22 - p * 8, P.RED, 255 * (1 - p));
    } else if (hot) {
      reaction(x + 16, y - 17, t);
    }
  }

  function drawBike(b, t) {
    scaled({ x: bikeX(t), y: L.bike.y + 11 }, L.bike.s, bikeBody, t, 1);
  }

  function drawYouDot(x, y, t) {
    const c = scene.status === 'blocked' ? P.DIM : statusColour();
    const p = (t * 0.85) % 1;
    ring(x, y, 4 + p * 8, c, 255 * (1 - p));
    disc(x, y, 4.2, P.WHITE, 255);
    disc(x, y, 2.6, c, 255);
  }

  function drawAgentPin(x, y, t) {
    sprite(x - 4, y - 9 + Math.round(Math.sin(t * 2.6)), SPRITES.pin);
  }

  function wire(points, c, dir, t, dashed) {
    let run = 0;
    const lens = [];
    for (let i = 1; i < points.length; i++) {
      const l = Math.abs(points[i][0] - points[i - 1][0]) + Math.abs(points[i][1] - points[i - 1][1]);
      lens.push(l);
      run += l;
    }
    if (run < 4) return;
    const stride = Math.max(20, Math.round(run * 0.38));
    const phase = (t * 48) % stride;
    let acc = 0;
    for (let i = 1; i < points.length; i++) {
      const a = points[i - 1], b = points[i], l = lens[i - 1];
      for (let st = 0; st <= l; st += 1) {
        const q = l ? st / l : 0;
        const x = Math.round(a[0] + (b[0] - a[0]) * q);
        const y = Math.round(a[1] + (b[1] - a[1]) * q);
        const pos = dir >= 0 ? acc + st : run - (acc + st);
        const mod = ((pos - phase) % stride + stride) % stride;
        const isPacket = dir !== 0 && mod < 10;
        if (isPacket) {
          rect(x - 2, y - 2, 5, 5, c, 130);
          rect(x - 1, y - 1, 3, 3, c, 255);
          if (mod < 5) rect(x, y, 2, 2, P.WHITE, 255);
        } else if (!dashed || ((acc + st) & 7) < 5) {
          rect(x - 1, y - 1, 4, 4, c, 70);
          rect(x, y, 2, 2, c, 255);
        }
      }
      acc += l;
    }
    // Crisp directional chevron near the active target end
    if (dir !== 0 && points.length >= 2) {
      const endPt = dir > 0 ? points[points.length - 1] : points[0];
      const prevPt = dir > 0 ? points[points.length - 2] : points[1];
      const dx = Math.sign(endPt[0] - prevPt[0]);
      const dy = Math.sign(endPt[1] - prevPt[1]);
      const ax = endPt[0] - dx * 4;
      const ay = endPt[1] - dy * 4;
      if (dx !== 0) {
        for (let k = 0; k <= 3; k++) {
          rect(ax - dx * k, ay - k, 2, 2, c, 255);
          rect(ax - dx * k, ay + k, 2, 2, c, 255);
        }
      } else if (dy !== 0) {
        for (let k = 0; k <= 3; k++) {
          rect(ax - k, ay - dy * k, 2, 2, c, 255);
          rect(ax + k, ay - dy * k, 2, 2, c, 255);
        }
      }
    }
  }

  function drawPort(x, y, c, t) {
    const p = (t * 1.2) % 1;
    ring(x, y, 4 + p * 6, c, 235 * (1 - p));
    disc(x, y, 4.2, P.WHITE, 255);
    disc(x, y, 2.8, c, 255);
  }

  function anchorOf(name, t) {
    if (name === 'bike') {
      const x = bikeX(t), k = L.bike.s, y = L.bike.y + 11;
      return { cx: x + 9 * k, top: y - 28 * k, left: x - 6 * k, right: x + 21 * k, mid: y - 13 * k, bottom: y + 4, r: 44 * k };
    }
    const m = L.marks[name];
    if (!m) return null;
    const g = MARK[name], k = m.s;
    return {
      cx: m.x + (g.w / 2 + 2) * k, top: m.y - g.tall * k, left: m.x - 2, right: m.x + (g.w + g.dw) * k + 1,
      mid: m.y - Math.round(g.h / 2) * k, bottom: m.y + 6, r: Math.max(g.w, g.h) * 0.96 * k
    };
  }

  function placeTag(el, a, lo, hi, pinTop) {
    if (!el) return;
    if (!a || !el.textContent) { el.style.opacity = '0'; return; }
    const w = el.offsetWidth;
    const x = clamp(a.cx * CELL - w / 2, lo, Math.max(lo, hi - w));
    const y = pinTop === undefined ? Math.max(12, (a.top - 16) * CELL - el.offsetHeight) : pinTop;
    el.style.transform = 'translate(' + Math.round(x) + 'px,' + Math.round(y) + 'px)';
    el.style.opacity = '1';
  }

  function placeTags(t) {
    if (!L || !L.stage) return;
    const sameSpot = scene.agent === scene.you;
    const a = sameSpot ? null : anchorOf(scene.agent, t);
    const u = anchorOf(scene.you, t);
    const docW = W * CELL;
    if (L.mode === 'flank') {
      placeTag(tagAgent, a, 10, L.xl * CELL - 6);
      placeTag(tagYou, u, L.xr * CELL + 6, docW - 10);
    } else if (L.strip) {
      const top = L.strip.t * CELL + 4;
      placeTag(tagAgent, a, 8, docW - 8, top);
      placeTag(tagYou, u, 8, docW - 8, top + (a ? 30 : 0));
    }
  }

  // ---- Layout ------------------------------------------------------------
  function relRect(el, m) {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    return {
      l: Math.round((r.left - m.left) / CELL), t: Math.round((r.top - m.top) / CELL),
      r: Math.round((r.right - m.left) / CELL), b: Math.round((r.bottom - m.top) / CELL)
    };
  }

  function halfAt(y) {
    const q = clamp((y - L.heroBottom + 12) / 24, 0, 1);
    return L.heroHalf + (L.bodyHalf - L.heroHalf) * q;
  }

  function fillSpan(y, x0, x1, rng) {
    let x = x0 + Math.floor(rng() * 4);
    while (x1 - x > 20) {
      const b = makeFiller(x, y, x1 - x - 7, rng);
      if (b.w < 14) break;
      staticItems.push(b);
      x += b.w + b.dw + 2 + Math.floor(rng() * 5);
      if (rng() < 0.4 && x1 - x > 8) {
        staticItems.push({ y: y, top: y - 12, bot: y + 1, x: x + 1, r: 2 + Math.floor(rng() * 2), draw: drawTree });
        x += 6;
      }
    }
  }

  function ensureBuffers(newW, newVH) {
    if (newW === W && newVH === VH && den) return;
    W = newW;
    VH = newVH;
    SW = Math.max(1, Math.ceil(W / SCRIM_DIV));
    SH = Math.max(1, Math.ceil(VH / SCRIM_DIV));

    bgCanvas.width = W;
    bgCanvas.height = VH;
    fgCanvas.width = W;
    fgCanvas.height = VH;
    scrimCanvas.width = SW;
    scrimCanvas.height = SH;

    const len = W * VH;
    den = new Uint8Array(len);
    col = new Uint8Array(len);
    bgImg = bgCtx.createImageData(W, VH);
    bg32 = new Uint32Array(bgImg.data.buffer);
    fgImg = fgCtx.createImageData(W, VH);
    fg32 = new Uint32Array(fgImg.data.buffer);
    pL = [0, 0, 0, 0]; pR = [0, 0, 0, 0];
    bgDirty = true;
    scrimDirty = true;
  }

  function layout() {
    const m = main.getBoundingClientRect();
    const viewW = Math.round(m.width || window.innerWidth);
    const viewH = Math.round(window.innerHeight);
    docH = Math.ceil(Math.round(m.height) / CELL);
    ensureBuffers(Math.ceil(viewW / CELL), Math.ceil(viewH / CELL));

    const stage = relRect(stageEl, m);
    const hero = relRect(heroEl, m);
    const strip = relRect(stripEl, m);
    const wrap = document.querySelector('.band .wrap');
    const wrapRect = relRect(wrap, m);
    const mode = viewW >= FLANK_MIN ? 'flank' : 'strip';
    const cx = Math.round(W / 2);

    L = {
      mode: mode, cx: cx, marks: {}, strip: strip, stage: stage,
      chat: relRect(chatEl, m), device: relRect(deviceEl, m),
      heroBottom: hero ? hero.b : 0,
      heroHalf: stage ? Math.round((stage.r - stage.l) / 2) + 9 : cx,
      bodyHalf: wrapRect ? Math.round((wrapRect.r - wrapRect.l) / 2) + 12 : cx
    };
    L.xl = cx - L.heroHalf;
    L.xr = cx + L.heroHalf;

    ground = [];
    staticItems = [];
    dynamicItems = [];
    const rng = mulberry(20261121);

    const DRAW = { home: drawHome, cloud: drawCloud, desk: drawDesk, toilet: drawToilet };
    const place = function (name, x, y, k, who) {
      L.marks[name] = { x: Math.round(x), y: y, s: k };
      staticItems.push({
        y: y + 0.5, top: y - MARK[name].tall * k - 36, bot: y + 10,
        draw: function (b, t) {
          if (who) return;
          const isHot = (name === 'home' || name === 'cloud') ? scene.agent === name : scene.you === name;
          if (isHot) return;
          scaled(L.marks[name], k, DRAW[name], t, 0.85);
        }
      });
    };

    if (mode === 'flank') {
      const sh = stage ? stage.b - stage.t : 0;
      const k = L.xl >= 116 ? 2 : 1;
      const plan = stage ? [
        { right: false, marks: [['cloud', 0.34], ['home', 0.88]] },
        { right: true, marks: [['desk', 0.22], ['toilet', 0.62]], bike: 0.94 }
      ] : [{ right: false, marks: [] }, { right: true, marks: [] }];
      plan.forEach(function (side, sn) {
        const spanAt = function (y) {
          const half = halfAt(y);
          return side.right ? [Math.round(cx + half) + 5, W - 2] : [2, Math.round(cx - half) - 5];
        };
        const boxes = [];
        side.marks.forEach(function (pair) {
          const name = pair[0], g = MARK[name];
          const y = stage.t + Math.round(sh * pair[1]);
          const sp = spanAt(y), total = (g.w + g.dw) * k;
          const gutter = k === 2 ? 16 : 10;
          const mx = side.right
            ? Math.min(sp[1] - total - 4, sp[0] + gutter)
            : Math.max(sp[0] + 4, sp[1] - total - gutter);
          place(name, mx, y, k, null);
          boxes.push({ l: mx - 6, r: mx + total + 6, t: y - g.tall * k - 8, b: y + 8 });
        });
        if (side.bike) {
          const y = stage.t + Math.round(sh * side.bike);
          const sp = spanAt(y);
          const bikeW = 24 * k;
          const x0 = sp[0] + (k === 2 ? 20 : 12);
          const x1 = Math.max(x0 + 8, Math.min(sp[1] - bikeW - 6, x0 + (k === 2 ? 48 : 28)));
          L.bike = { y: y, x0: x0, x1: x1, s: k };
          ground.push({ y: y, xa: sp[0], xb: sp[1] });
          staticItems.push({
            y: y + 12, top: y - 34 * k, bot: y + 16,
            draw: function (b, t) { if (scene.you !== 'bike') drawBike(b, t); }
          });
          boxes.push({ l: -1, r: W + 1, t: y - 28 * k, b: y + 14 });
        }
        for (let y = 62, n = 0; y < docH - 6; y += 46, n++) {
          const sp = spanAt(y);
          let spans = [sp];
          boxes.forEach(function (bx) {
            if (bx.t > y + 12 || bx.b < y - 38) return;
            const next = [];
            spans.forEach(function (q) {
              if (bx.r <= q[0] || bx.l >= q[1]) { next.push(q); return; }
              if (bx.l - q[0] > 22) next.push([q[0], bx.l]);
              if (q[1] - bx.r > 22) next.push([bx.r, q[1]]);
            });
            spans = next;
          });
          spans.forEach(function (q) {
            ground.push({ y: y, xa: q[0], xb: q[1] });
            fillSpan(y, q[0], q[1], rng);
            for (let x = q[0] + 8 + (n % 3) * 7; x < q[1] - 2; x += 53) {
              staticItems.push({ y: y + 1, top: y - 10, bot: y + 12, x: x, draw: drawLamp });
            }
            if (q[1] - q[0] > 40 && rng() < 0.7) {
              dynamicItems.push({
                y: y + 2, top: y - 8, bot: y + 2, x0: q[0], x1: q[1],
                speed: (rng() < 0.5 ? -1 : 1) * (3 + rng() * 3), phase: rng() * 200,
                c: [P.MAG, P.CYAN, P.WARM, P.WHITE][Math.floor(rng() * 4)], draw: drawWalker
              });
            }
          });
          if (spans.length === 1 && (n + sn) % 3 === 0) {
            dynamicItems.push({
              y: y + 9, top: y + 2, bot: y + 12, x0: sp[0], x1: sp[1],
              speed: 8 + (n % 5) * 2, phase: n * 31, draw: drawCar
            });
          }
        }
      });
    } else if (strip) {
      const y = strip.b - 13;
      ground.push({ y: y, xa: 0, xb: W });
      fillSpan(y - 40, 2, W - 2, rng);
      place('home', 8, y, 1, 'agent');
      place('cloud', 14, y, 1, 'agent');
      place('desk', W - (MARK.desk.w + MARK.desk.dw) * 2 - 10, y, 2, 'you');
      place('toilet', W - (MARK.toilet.w + MARK.toilet.dw) * 2 - 18, y, 2, 'you');
      const bx0 = Math.round(W * 0.52);
      const bx1 = Math.max(bx0 + 16, W - 64);
      L.bike = { y: y, x0: bx0, x1: bx1, s: 2 };
      for (let x = 8; x < W; x += 41) staticItems.push({ y: y + 1, top: y - 10, bot: y + 12, x: x, draw: drawLamp });
    }

    staticItems.sort(function (a, b) { return a.y - b.y; });
    bgDirty = true;
    scrimDirty = true;
  }

  // ---- Pass 1: Static dimmed neighbourhood (ONLY runs on layout/scroll/scene/theme) ----
  function renderBackground(t) {
    bgDirty = false;
    trackDirty = false;
    den.fill(0);
    col.fill(0);
    bg32.fill(0);

    if (vy1 <= vy0) {
      bgCtx.putImageData(bgImg, 0, 0);
      return;
    }

    D = 1;
    for (let i = 0; i < ground.length; i++) {
      const g = ground[i];
      if (g.y + 14 < vy0 || g.y - 2 > vy1) continue;
      rect(g.xa, g.y + 1, g.xb - g.xa, 1, P.ROAD, 135);
      rect(g.xa, g.y + 2, g.xb - g.xa, 10, P.ROAD, 36);
      const yy = g.y + 7;
      if (yy >= vy0 && yy < vy1) {
        const row = (yy - offY) * W;
        for (let x = g.xa; x < g.xb; x++) if ((x & 7) < 3) { den[row + x] = 220; col[row + x] = P.ROAD; }
      }
    }
    for (let i = 0; i < staticItems.length; i++) {
      const b = staticItems[i];
      if (b.bot < vy0 || b.top > vy1) continue;
      b.draw(b, t);
    }

    const flank = L.mode === 'flank';
    for (let gy = vy0; gy < vy1; gy++) {
      const vy = gy - offY;
      const o = vy * W;
      const by = (gy & 3) << 2;
      let xl = 0, xr = 0, mv = 1;
      if (flank) {
        if (L.stage && gy >= L.stage.t + 6 && gy <= L.stage.b - 6) { xl = L.stage.l + 10; xr = L.stage.r - 10; }
        else { const half = halfAt(gy); xl = L.cx - half; xr = L.cx + half; }
        mv = Math.min(1, gy / 10, (docH - gy) / 10);
      } else {
        mv = Math.min(1, (gy - L.strip.t) / 8, (L.strip.b - gy) / 3);
      }
      for (let x = 0; x < W; x++) {
        const i = o + x;
        let d = den[i];
        if (d === 0) continue;
        if (flank && x > xl - 10 && x < xr + 10) {
          const q = x <= xl ? (xl - x) / 10 : (x >= xr ? (x - xr) / 10 : 0);
          d *= q;
        }
        if (mv < 1) d *= mv;
        if (d > BAYER[by + (x & 3)]) bg32[i] = palDim[col[i]];
      }
    }

    bgCtx.putImageData(bgImg, 0, 0);
    // Clear shared scratch buffer once so foreground dirty-rect pass starts clean
    den.fill(0);
    col.fill(0);
  }

  // ---- Pass 2: Quarter-res GPU-upscaled dimming veil + smooth 120fps spotlights ----
  function renderScrim(t, dt) {
    if (L.mode !== 'flank' || !L.stage) {
      if (scrimDirty) {
        scrimCtx.clearRect(0, 0, SW, SH);
        scrimDirty = false;
      }
      return;
    }

    const sameSpot = scene.agent === scene.you;
    const a = sameSpot ? null : anchorOf(scene.agent, t);
    const u = anchorOf(scene.you, t);
    const snap = document.documentElement.classList.contains('held') || reduced.matches;
    const ease = 1 - Math.exp(-dt * 10); // Frame-rate independent smooth 120fps glide

    let moved = false;
    if (a) {
      if (!spotA || snap) { spotA = { x: a.cx, y: a.mid, r: a.r }; moved = true; }
      else {
        const dx = a.cx - spotA.x, dy = a.mid - spotA.y, dr = a.r - spotA.r;
        if (Math.abs(dx) > 0.12 || Math.abs(dy) > 0.12 || Math.abs(dr) > 0.12) {
          spotA.x += dx * ease; spotA.y += dy * ease; spotA.r += dr * ease;
          moved = true;
        }
      }
    } else if (spotA) {
      spotA = null;
      moved = true;
    }

    if (u) {
      if (!spotU || snap) { spotU = { x: u.cx, y: u.mid, r: u.r }; moved = true; }
      else {
        const dx = u.cx - spotU.x, dy = u.mid - spotU.y, dr = u.r - spotU.r;
        if (Math.abs(dx) > 0.12 || Math.abs(dy) > 0.12 || Math.abs(dr) > 0.12) {
          spotU.x += dx * ease; spotU.y += dy * ease; spotU.r += dr * ease;
          moved = true;
        }
      }
    }

    if (!scrimDirty && !moved) return;
    scrimDirty = false;

    scrimCtx.globalCompositeOperation = 'source-over';
    scrimCtx.clearRect(0, 0, SW, SH);

    const topS = (0 - offY) / SCRIM_DIV;
    const botS = (L.heroBottom + 24 - offY) / SCRIM_DIV;
    if (botS <= 0 || topS >= SH) return;

    const veil = scrimCtx.createLinearGradient(0, topS, 0, botS);
    if (theme === 'light') {
      veil.addColorStop(0, 'rgba(18, 28, 56, 0.125)');
      veil.addColorStop(0.84, 'rgba(18, 28, 56, 0.13)');
      veil.addColorStop(1, 'rgba(18, 28, 56, 0)');
    } else {
      veil.addColorStop(0, 'rgba(3, 5, 12, 0.56)');
      veil.addColorStop(0.84, 'rgba(3, 5, 12, 0.60)');
      veil.addColorStop(1, 'rgba(3, 5, 12, 0)');
    }
    scrimCtx.fillStyle = veil;
    scrimCtx.fillRect(0, Math.max(0, topS), SW, Math.min(SH, botS) - Math.max(0, topS));

    // Punch bright hero column + spotlight cutouts
    scrimCtx.globalCompositeOperation = 'destination-out';
    const colPad = 14;
    const xL = Math.max(0, (L.xl - colPad) / SCRIM_DIV);
    const xR = Math.min(SW, (L.xr + colPad) / SCRIM_DIV);
    const colGrad = scrimCtx.createLinearGradient(xL, 0, xR, 0);
    colGrad.addColorStop(0, 'rgba(0,0,0,0)');
    colGrad.addColorStop(0.08, 'rgba(0,0,0,1)');
    colGrad.addColorStop(0.92, 'rgba(0,0,0,1)');
    colGrad.addColorStop(1, 'rgba(0,0,0,0)');
    scrimCtx.fillStyle = colGrad;
    scrimCtx.fillRect(xL, Math.max(0, topS), xR - xL, Math.min(SH, botS) - Math.max(0, topS));

    function punch(s) {
      if (!s) return;
      const sx = s.x / SCRIM_DIV, sy = (s.y - offY) / SCRIM_DIV, sr = (s.r * 1.18) / SCRIM_DIV;
      const g = scrimCtx.createRadialGradient(sx, sy, sr * 0.42, sx, sy, sr);
      g.addColorStop(0, 'rgba(0,0,0,1)');
      g.addColorStop(0.72, 'rgba(0,0,0,0.92)');
      g.addColorStop(1, 'rgba(0,0,0,0)');
      scrimCtx.fillStyle = g;
      scrimCtx.beginPath();
      scrimCtx.arc(sx, sy, sr, 0, Math.PI * 2);
      scrimCtx.fill();
    }
    punch(spotA);
    punch(spotU);

    // Paint subtle bright spotlight pool behind the active characters
    scrimCtx.globalCompositeOperation = 'source-over';
    const rgb = statusRGB();
    function halo(s, muted) {
      if (!s) return;
      const sx = s.x / SCRIM_DIV, sy = (s.y - offY) / SCRIM_DIV, sr = (s.r * 1.08) / SCRIM_DIV;
      const g = scrimCtx.createRadialGradient(sx, sy, sr * 0.1, sx, sy, sr);
      if (theme === 'light') {
        g.addColorStop(0, 'rgba(255, 255, 255, 0.90)');
        g.addColorStop(0.65, muted ? 'rgba(255, 255, 255, 0.62)' : 'rgba(' + rgb + ', 0.08)');
        g.addColorStop(1, 'rgba(255, 255, 255, 0)');
      } else {
        g.addColorStop(0, muted ? 'rgba(130, 150, 210, 0.14)' : 'rgba(' + rgb + ', 0.24)');
        g.addColorStop(0.62, muted ? 'rgba(100, 120, 180, 0.06)' : 'rgba(' + rgb + ', 0.09)');
        g.addColorStop(1, 'rgba(0, 0, 0, 0)');
      }
      scrimCtx.fillStyle = g;
      scrimCtx.beginPath();
      scrimCtx.arc(sx, sy, sr, 0, Math.PI * 2);
      scrimCtx.fill();
    }
    halo(spotA, false);
    halo(spotU, scene.status === 'blocked');
  }

  // ---- Pass 3: Dirty-rect 120fps active actors, wires & ambient walkers/cars ----
  function clearPrevBox(box) {
    if (box[2] <= box[0] || box[3] <= box[1]) return;
    for (let vy = box[1]; vy < box[3]; vy++) {
      const o = vy * W;
      fg32.fill(0, o + box[0], o + box[2]);
    }
  }

  function flushBox(cur, prev) {
    const nx0 = clamp(cur[0], 0, W), ny0 = clamp(cur[1], 0, VH);
    const nx1 = clamp(cur[2], 0, W), ny1 = clamp(cur[3], 0, VH);
    for (let vy = ny0; vy < ny1; vy++) {
      const o = vy * W;
      const by = ((vy + offY) & 3) << 2;
      for (let x = nx0; x < nx1; x++) {
        const i = o + x;
        const d = den[i];
        if (d > 0) {
          if (d > BAYER[by + (x & 3)]) fg32[i] = pal[col[i]];
          den[i] = 0;
          col[i] = 0;
        }
      }
    }
    const hasPrev = prev[2] > prev[0] && prev[3] > prev[1];
    const hasCur = nx1 > nx0 && ny1 > ny0;
    if (hasPrev || hasCur) {
      const ux0 = hasPrev && hasCur ? Math.min(prev[0], nx0) : (hasCur ? nx0 : prev[0]);
      const uy0 = hasPrev && hasCur ? Math.min(prev[1], ny0) : (hasCur ? ny0 : prev[1]);
      const ux1 = hasPrev && hasCur ? Math.max(prev[2], nx1) : (hasCur ? nx1 : prev[2]);
      const uy1 = hasPrev && hasCur ? Math.max(prev[3], ny1) : (hasCur ? ny1 : prev[3]);
      if (ux1 > ux0 && uy1 > uy0) {
        fgCtx.putImageData(fgImg, 0, 0, ux0, uy0, ux1 - ux0, uy1 - uy0);
      }
    }
    prev[0] = nx0; prev[1] = ny0; prev[2] = nx1; prev[3] = ny1;
  }

  function renderForeground(t) {
    clearPrevBox(pL);
    clearPrevBox(pR);

    dL[0] = W; dL[1] = VH; dL[2] = 0; dL[3] = 0;
    dR[0] = W; dR[1] = VH; dR[2] = 0; dR[3] = 0;
    trackDirty = true;
    D = 1;

    if (vy1 > vy0) {
      // Ambient moving cars & tiny walkers
      for (let i = 0; i < dynamicItems.length; i++) {
        const b = dynamicItems[i];
        if (b.bot < vy0 || b.top > vy1) continue;
        b.draw(b, t);
      }

      // Active agent & active person in 100% vivid colour
      const DRAW = { home: drawHome, cloud: drawCloud, desk: drawDesk, toilet: drawToilet };
      const sameSpot = scene.agent === scene.you;
      if (!sameSpot && L.marks[scene.agent] && DRAW[scene.agent]) {
        const m = L.marks[scene.agent];
        scaled(m, m.s, DRAW[scene.agent], t, 1);
      }
      if (scene.you === 'bike' && L.bike) {
        drawBike(null, t);
      } else if (L.marks[scene.you] && DRAW[scene.you]) {
        const m = L.marks[scene.you];
        scaled(m, m.s, DRAW[scene.you], t, 1);
      }

      // Signal wires, ports, pin & you-dot
      if (L.stage) {
        const st = scene.status;
        const a = anchorOf(scene.agent, t);
        const u = anchorOf(scene.you, t);
        const c = st === 'ok' ? P.GREEN : (st === 'deny' || st === 'blocked' ? P.RED : P.BLUE);
        const out = st === 'ask' ? 1 : (st === 'ok' || st === 'deny' ? -1 : 0);

        if (L.mode === 'flank') {
          if (a && !sameSpot && L.chat) {
            const y = clamp(a.mid, L.chat.t + 16, L.chat.b - 16);
            const knee = Math.round((a.right + L.chat.l) / 2);
            wire([[a.right + 2, a.mid], [knee, a.mid], [knee, y], [L.chat.l - 1, y]], c, out, t, st === 'blocked' || st === 'idle');
            drawPort(L.chat.l - 2, y, c, t);
            if (st === 'blocked') {
              const rx = L.device.r + 10, ry = Math.round((L.device.t + L.device.b) / 2);
              for (let k = -3; k <= 3; k++) {
                rect(rx + k, ry + k, 2, 2, P.RED, 255);
                rect(rx + k, ry - k, 2, 2, P.RED, 255);
              }
            }
          }
          if (u && L.device && st !== 'blocked') {
            const y = clamp(u.mid, L.device.t + 16, L.device.b - 16);
            const knee = Math.round((L.device.r + u.left) / 2);
            wire([[L.device.r + 1, y], [knee, y], [knee, u.mid], [u.left - 2, u.mid]], c, out, t, st === 'idle');
            drawPort(L.device.r + 2, y, c, t);
          }
          if (a && !sameSpot) drawAgentPin(a.cx, a.top - 4, t);
          if (u) drawYouDot(u.cx, u.top - 8, t);
        } else if (L.strip) {
          const edge = L.strip.b - 1;
          if (a && !sameSpot) wire([[a.cx, a.bottom], [a.cx, edge]], c, out, t, st === 'blocked' || st === 'idle');
          if (u && st !== 'blocked') wire([[u.cx, edge], [u.cx, u.bottom]], c, out, t, st === 'idle');
        }
      }
    }

    trackDirty = false;
    flushBox(dL, pL);
    flushBox(dR, pR);
  }

  function frame(t, dt) {
    if (!L || !den) return;
    if (L.mode === 'strip' && !L.strip) return;

    const mRect = main.getBoundingClientRect();
    offY = -Math.round(mRect.top / CELL);
    if (offY !== lastOffY) {
      lastOffY = offY;
      bgDirty = true;
      scrimDirty = true;
    }

    vy0 = clamp(offY, 0, docH);
    vy1 = clamp(offY + VH, 0, docH);
    if (L.mode === 'strip' && L.strip) {
      vy0 = Math.max(vy0, L.strip.t);
      vy1 = Math.min(vy1, L.strip.b);
    }

    if (bgDirty) renderBackground(t);
    renderScrim(t, dt);
    renderForeground(t);
    placeTags(t);
  }

  // Native refresh rate (60/120fps) loop with zero artificial FPS cap
  let last = performance.now();
  function tick(now) {
    requestAnimationFrame(tick);
    const dt = Math.min(0.05, Math.max(0.001, (now - last) / 1000));
    last = now;
    if (document.hidden || reduced.matches) return;
    clock += dt;
    frame(clock, dt);
  }

  let pending = 0;
  function relayout() {
    cancelAnimationFrame(pending);
    pending = requestAnimationFrame(function () {
      layout();
      frame(clock, 0.016);
    });
  }

  window.AKRCity = {
    setTheme: function (next) {
      theme = next === 'light' ? 'light' : 'dark';
      setPalette();
      frame(clock, 0.016);
    },
    setScene: function (next) {
      const changed = next.status !== scene.status || next.agent !== scene.agent || next.you !== scene.you;
      scene = {
        agent: next.agent,
        you: next.you,
        status: next.status,
        speaking: Boolean(next.speaking)
      };
      if (changed) {
        statusAt = clock;
        bgDirty = true;
        scrimDirty = true;
      }
      if (reduced.matches) frame(clock, 0.016);
    },
    relayout: relayout
  };

  setPalette();
  layout();
  frame(0, 0.016);
  window.addEventListener('resize', relayout, { passive: true });
  window.addEventListener('scroll', function () {
    bgDirty = true;
    scrimDirty = true;
    if (reduced.matches) frame(clock, 0.016);
  }, { passive: true });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(relayout);
  if (!reduced.matches) requestAnimationFrame(tick);
})();
