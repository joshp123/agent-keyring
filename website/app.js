/*
 * Agent Keyring site interactions:
 * 1. Light / dark theme sync
 * 2. The keyhole mascot
 * 3. The walkthrough: one clock, four scenes, looping
 * 4. The email sign-up form
 */
(function () {
  'use strict';

  // ---- 1. Theme toggle ---------------------------------------------------
  const root = document.documentElement;
  const themeBtn = document.getElementById('theme-toggle');
  const storedTheme = localStorage.getItem('akr-theme');
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)');

  function applyTheme(theme, persist) {
    root.setAttribute('data-theme', theme);
    if (persist) localStorage.setItem('akr-theme', theme);
    if (themeBtn) {
      themeBtn.textContent = theme === 'dark' ? 'Light mode' : 'Dark mode';
      themeBtn.setAttribute('aria-label', 'Switch to ' + (theme === 'dark' ? 'light' : 'dark') + ' mode');
    }
    if (window.AKRCity) window.AKRCity.setTheme(theme);
  }

  applyTheme(storedTheme || (prefersDark.matches ? 'dark' : 'light'), false);

  prefersDark.addEventListener('change', function (e) {
    if (!localStorage.getItem('akr-theme')) {
      applyTheme(e.matches ? 'dark' : 'light', false);
    }
  });

  if (themeBtn) {
    themeBtn.addEventListener('click', function () {
      const current = root.getAttribute('data-theme') || 'dark';
      applyTheme(current === 'dark' ? 'light' : 'dark', true);
    });
  }

  // ---- 2. The keyhole mascot ---------------------------------------------
  const mascotSvgs = Array.from(document.querySelectorAll('.js-mascot'));
  const mascotWrap = document.getElementById('mascot-wrap');
  const mascotRig = document.getElementById('mascot-body-rig');
  const sparkleLayer = document.getElementById('mascot-sparkles');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const pointer = { x: window.innerWidth * 0.5, y: window.innerHeight * 0.25, vx: 0, lastMove: Date.now() };
  let lastPtrX = pointer.x;
  let zoomieCooldown = 0;
  let nearMascot = false;
  let hoverMascot = false;
  let clickCount = 0;
  let baseMood = 'happy';

  const eyeItems = mascotSvgs.map(function (svg) {
    return { svg: svg, group: svg.querySelector('.mascot-eyes'), cx: 0, cy: 0 };
  });

  function spawnSparkles(count) {
    if (!sparkleLayer || reducedMotion.matches) return;
    const cols = ['#35E8FF', '#FF4FD8', '#4C7DFF', '#3FE0AE', '#FFD166'];
    for (let i = 0; i < count; i++) {
      const el = document.createElement('span');
      el.className = 'sparkle-px';
      const angle = (Math.PI * 2 * i) / count + (Math.random() - 0.5) * 0.55;
      const dist = 46 + Math.random() * 54;
      el.style.setProperty('--sx', Math.round(Math.cos(angle) * dist) + 'px');
      el.style.setProperty('--sy', Math.round(Math.sin(angle) * dist) + 'px');
      el.style.background = cols[i % cols.length];
      sparkleLayer.appendChild(el);
      setTimeout(function () { el.remove(); }, 760);
    }
  }

  function setMood(mood, remember) {
    if (mascotWrap) mascotWrap.setAttribute('data-mood', mood);
    if (remember !== false) baseMood = mood;
  }

  window.addEventListener('pointermove', function (e) {
    pointer.vx = Math.abs(e.clientX - lastPtrX);
    lastPtrX = e.clientX;
    pointer.x = e.clientX;
    pointer.y = e.clientY;
    pointer.lastMove = Date.now();

    if (mascotWrap) {
      const r = mascotWrap.getBoundingClientRect();
      const d = Math.hypot(e.clientX - (r.left + r.width / 2), e.clientY - (r.top + r.height / 2));
      if (pointer.vx > 70 && Date.now() > zoomieCooldown && d < 320) {
        zoomieCooldown = Date.now() + 1400;
        setMood('giggle', false);
        spawnSparkles(11);
        setTimeout(function () {
          if (!hoverMascot) setMood(nearMascot ? 'excited' : baseMood, false);
        }, 850);
      } else if (!hoverMascot) {
        if (d < 220 && !nearMascot) {
          nearMascot = true;
          if (baseMood === 'happy') setMood('excited', false);
        } else if (d >= 240 && nearMascot) {
          nearMascot = false;
          setMood(baseMood, false);
        }
      }
    }
  }, { passive: true });

  setInterval(function () {
    if (document.hidden || reducedMotion.matches || hoverMascot) return;
    if (baseMood === 'happy' && Date.now() - pointer.lastMove > 3200) {
      setMood('giggle', false);
      spawnSparkles(6);
      setTimeout(function () {
        if (!hoverMascot) setMood(baseMood, false);
      }, 780);
    }
  }, 6400);

  let rigTilt = 0;
  let rigX = 0;
  let rigY = 0;
  let idleX = 0;
  let idleY = 0;

  setInterval(function () {
    if (Date.now() - pointer.lastMove > 2400) {
      idleX = (Math.random() - 0.5) * 6.5;
      idleY = (Math.random() - 0.5) * 4.5;
    }
  }, 1800);

  function animateEyes() {
    if (!reducedMotion.matches) {
      const idle = Date.now() - pointer.lastMove > 2400;
      eyeItems.forEach(function (item) {
        if (!item.group) return;
        const r = item.svg.getBoundingClientRect();
        if (!r.width) return;
        let tx, ty;
        if (idle) {
          tx = idleX;
          ty = idleY;
        } else {
          const dx = pointer.x - (r.left + r.width * 0.5);
          const dy = pointer.y - (r.top + r.height * 0.4);
          const dist = Math.hypot(dx, dy) || 1;
          const mag = Math.min(5.2, dist / 46);
          tx = (dx / dist) * mag;
          ty = (dy / dist) * mag * 0.85;
        }
        item.cx += (tx - item.cx) * 0.18;
        item.cy += (ty - item.cy) * 0.18;
        item.group.style.transform = 'translate(' + item.cx.toFixed(2) + 'px,' + item.cy.toFixed(2) + 'px)';

        if (item.svg.id === 'hero-mascot-svg' && mascotRig) {
          rigTilt += (item.cx * 1.75 - rigTilt) * 0.14;
          rigX += (item.cx * 0.7 - rigX) * 0.14;
          rigY += (item.cy * 0.5 - rigY) * 0.14;
          mascotRig.style.transform =
            'translate(' + rigX.toFixed(2) + 'px,' + rigY.toFixed(2) + 'px) rotate(' + rigTilt.toFixed(2) + 'deg)';
        }
      });
    }
    requestAnimationFrame(animateEyes);
  }
  requestAnimationFrame(animateEyes);

  function scheduleBlink() {
    setTimeout(function () {
      if (!document.hidden && !reducedMotion.matches) {
        const dbl = Math.random() < 0.35;
        const blink = function () {
          mascotSvgs.forEach(function (svg) {
            const el = svg.querySelector('.mascot-eyes-blink');
            if (!el) return;
            el.style.transition = 'transform 80ms ease';
            el.style.transformOrigin = '53px 37.5px';
            el.style.transform = 'scaleY(0.1)';
            setTimeout(function () { el.style.transform = 'scaleY(1)'; }, 115);
          });
        };
        blink();
        if (dbl) setTimeout(blink, 200);
      }
      scheduleBlink();
    }, 2400 + Math.random() * 2800);
  }
  scheduleBlink();

  const mascotBtn = document.getElementById('mascot-poke');
  if (mascotBtn) {
    mascotBtn.addEventListener('pointerenter', function () {
      hoverMascot = true;
      setMood('giggle', false);
      spawnSparkles(9);
    });
    mascotBtn.addEventListener('pointerleave', function () {
      hoverMascot = false;
      setMood(nearMascot ? 'excited' : baseMood, false);
    });
    mascotBtn.addEventListener('click', function () {
      clickCount += 1;
      const partyMode = clickCount % 2 === 0;
      setMood(partyMode ? 'party' : 'approved', false);
      spawnSparkles(partyMode ? 18 : 14);
      setTimeout(function () { setMood(hoverMascot ? 'giggle' : baseMood, false); }, 900);
    });
  }

  document.querySelectorAll('.hero-cta .btn-primary').forEach(function (cta) {
    cta.addEventListener('pointerenter', function () {
      setMood('approved', false);
      spawnSparkles(8);
    });
    cta.addEventListener('pointerleave', function () {
      setMood(baseMood, false);
    });
  });

  // ---- 3. The walkthrough: one clock, four scenes, looping ---------------
  const film = document.getElementById('film');
  if (film) {
    const $ = function (id) { return document.getElementById(id); };
    const mainEl = $('main');
    const chatAgent = $('chat-agent');
    const chatWhere = $('chat-where');
    const chatBody = $('chat-body');
    const deviceWhere = $('device-where');
    const wait = $('wait');
    const waitLabel = wait.querySelector('.wait-label');
    const waitValue = $('wait-value');
    const waitWas = $('wait-was');
    const device = $('film-device');
    const rigWatch = $('rig-watch');
    const watchEl = rigWatch.querySelector('.watch');
    const faceTime = $('wface-time');
    const noteClock = rigWatch.querySelector('.wnote-clock');
    const wApprove = $('w-approve');
    const rigMac = $('rig-mac');
    const macApprove = $('mac-approve');
    const macLabel = $('mac-approve-label');
    const tid = $('tid');
    const pointerEl = $('mac-pointer');
    const rigPhone = $('rig-phone');
    const reply = $('app-reply');
    const replyText = $('app-reply-text');
    const denyBtn = $('app-deny');
    const tabs = Array.from(document.querySelectorAll('.film-tab'));
    const fills = [0, 1, 2, 3].map(function (i) { return $('tab-fill-' + i); });
    const pauseBtn = $('film-pause');
    const tagAgent = $('tag-agent');
    const tagYou = $('tag-you');

    const SPOKEN = 'No. Use the gh CLI.';
    const PLACEHOLDER = 'What should Claude Code do instead?';
    const BLOCKED_MINUTES = 134;
    const FACE_START = 15 * 60 + 46;

    let scene = 0;
    let elapsed = 0;
    let beat = 0;
    let paused = false;
    let lastNow = performance.now();
    let waitFrom = -1;
    let waitTo = -1;
    let status = 'idle';
    let beatAt = 0;

    function say(cls, text) {
      const p = document.createElement('p');
      p.className = 'msg ' + cls;
      p.textContent = text;
      chatBody.appendChild(p);
    }

    function tap(id) {
      const el = $(id);
      if (!el) return;
      el.classList.remove('go');
      void el.offsetWidth;
      el.classList.add('go');
    }

    function setStatus(next, speaking) {
      status = next;
      film.setAttribute('data-status', next);
      if (mainEl) mainEl.setAttribute('data-status', next);
      if (window.AKRCity) {
        const c = SCENES[scene].city;
        window.AKRCity.setScene({ agent: c.agent, you: c.you, status: next, speaking: Boolean(speaking) });
      }
    }

    function clockText(minutes) {
      const m = (FACE_START + minutes) % 1440;
      return String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0');
    }

    function longDuration(minutes) {
      const h = Math.floor(minutes / 60), m = minutes % 60;
      const hours = h ? h + (h === 1 ? ' hour' : ' hours') : '';
      const mins = m || !h ? m + (m === 1 ? ' minute' : ' minutes') : '';
      return hours && mins ? hours + ' ' + mins : hours + mins;
    }

    function startWait() { waitFrom = beatAt; waitTo = -1; }

    function stopWait() {
      waitTo = beatAt;
      wait.setAttribute('data-tone', 'good');
    }

    function showFace(minutes) {
      const text = clockText(minutes);
      faceTime.textContent = text;
      noteClock.textContent = text;
    }

    const SCENES = [
      {
        dur: 10200, hold: 3200, agent: 'Claude Code', where: 'Mac mini at home',
        youWhere: 'Out on your bike',
        city: { agent: 'home', you: 'bike' },
        tagAgent: 'Claude Code, on the Mac mini at home', tagYou: 'You, out on your bike',
        beats: [
          [150, function () { say('you', 'Top up our OpenAI API credits by $50 and restart the eval run.'); }],
          [1250, function () {
            say('agent', 'I need to sign in to openai.com. Asking Agent Keyring for the password.');
            setStatus('ask');
            setMood('excited', true);
          }],
          [1900, function () {
            startWait();
            rigWatch.setAttribute('data-face', 'request');
            watchEl.classList.remove('buzz');
            void watchEl.offsetWidth;
            watchEl.classList.add('buzz');
          }],
          [4600, function () { wApprove.classList.add('pressed'); tap('tap-watch'); }],
          [5150, function () {
            rigWatch.setAttribute('data-face', 'answered');
            setStatus('ok');
            stopWait();
            waitWas.textContent = 'Without Agent Keyring, this waits until you\u2019re home.';
            setMood('approved', true);
            spawnSparkles(12);
          }],
          [6400, function () { say('agent good', 'Signed in. Added $50 of credits and restarted the eval run.'); setMood('happy', true); }]
        ]
      },
      {
        dur: 11200, hold: 3600, agent: 'Codex', where: 'your MacBook',
        youWhere: 'At your desk',
        city: { agent: 'desk', you: 'desk' },
        tagAgent: '', tagYou: 'You and Codex, at your desk',
        beats: [
          [200, function () { say('you', 'Download last month\u2019s Hetzner invoices for the accountant.'); }],
          [1500, function () {
            say('agent', 'hetzner.com wants a password and a two-factor code. Asking Agent Keyring for both.');
            setStatus('ask');
            setMood('excited', true);
          }],
          [2150, function () { startWait(); rigMac.setAttribute('data-state', 'asking'); }],
          [3850, function () { pointerEl.classList.add('at-button'); }],
          [4850, function () { pointerEl.classList.add('click'); macApprove.classList.add('pressed'); }],
          [5150, function () {
            pointerEl.classList.remove('click');
            pointerEl.classList.add('away');
            macApprove.classList.remove('pressed');
            rigMac.setAttribute('data-state', 'waiting');
            macLabel.textContent = 'Use Touch ID to approve';
            tid.classList.add('show');
          }],
          [7150, function () {
            tid.classList.add('matched');
            setStatus('ok');
            stopWait();
            setMood('approved', true);
            spawnSparkles(12);
          }],
          [8050, function () { tid.classList.remove('show'); rigMac.setAttribute('data-state', 'answered'); }],
          [8700, function () { say('agent good', 'Signed in. The invoices are in ~/Downloads.'); setMood('happy', true); }]
        ]
      },
      {
        dur: 13200, hold: 8200, agent: 'Claude Code', where: 'Linux server',
        youWhere: 'On the toilet',
        city: { agent: 'cloud', you: 'toilet' },
        tagAgent: 'Claude Code, on a Linux server', tagYou: 'You, on the toilet',
        beats: [
          [200, function () { say('you', 'Fix the build badge in the README.'); }],
          [1500, function () {
            say('agent warn', 'I need a new GitHub token to push. Asking Agent Keyring for your github.com password.');
            setStatus('ask');
            setMood('alert', true);
          }],
          [2300, function () { startWait(); rigPhone.setAttribute('data-banner', 'in'); }],
          [4100, function () { tap('tap-banner'); }],
          [4550, function () { rigPhone.setAttribute('data-step', 'app'); device.setAttribute('data-zoom', '1'); }],
          [6150, function () { tap('tap-mic'); }],
          [6450, function () { reply.classList.add('listening'); setStatus('ask', true); }],
          [8700, function () { reply.classList.remove('listening'); setStatus('ask', false); }],
          [9150, function () { denyBtn.classList.add('pressed'); tap('tap-deny'); }],
          [9650, function () {
            rigPhone.setAttribute('data-state', 'answered');
            setStatus('deny', false);
            stopWait();
            setMood('denied', true);
          }],
          [10700, function () { say('agent good', 'OK. gh is already signed in here, so I\u2019ll push with that.'); setMood('happy', true); spawnSparkles(8); }]
        ],
        frame: function () {
          if (elapsed < 6600) return;
          const q = Math.min(1, (elapsed - 6600) / 1900);
          replyText.textContent = SPOKEN.slice(0, Math.max(1, Math.ceil(SPOKEN.length * q)));
          reply.classList.add('spoken');
        }
      },
      {
        dur: 9800, hold: 7200, agent: 'Claude Code', where: 'Mac mini at home',
        youWhere: 'Out on your bike',
        city: { agent: 'home', you: 'bike' },
        tagAgent: 'Claude Code, on the Mac mini at home', tagYou: 'You, out on your bike',
        waitLabel: 'Without Agent Keyring, Claude Code waits', tone: 'bad',
        beats: [
          [200, function () { say('you', 'Top up our OpenAI API credits by $50 and restart the eval run.'); }],
          [1400, function () {
            say('agent bad', 'openai.com wants a password I don\u2019t have. Sign in on the Mac mini and tell me when you\u2019re done.');
            waitWas.textContent = 'Until you get home and sign in yourself.';
            setStatus('blocked');
            setMood('alert', true);
          }],
          [6900, function () { say('agent bad', 'Still can\u2019t sign in. The eval run hasn\u2019t started.'); }]
        ],
        frame: function () {
          const q = Math.min(1, Math.max(0, (elapsed - 1600) / 5000));
          const minutes = Math.round(BLOCKED_MINUTES * q * q * (3 - 2 * q));
          waitValue.textContent = longDuration(minutes);
          showFace(minutes);
        }
      }
    ];

    function resetRigs() {
      rigWatch.setAttribute('data-face', 'clock');
      wApprove.classList.remove('pressed');
      showFace(0);
      rigMac.setAttribute('data-state', 'hidden');
      macLabel.textContent = 'Click to approve with Touch ID';
      macApprove.classList.remove('pressed');
      tid.classList.remove('show', 'matched');
      pointerEl.classList.remove('at-button', 'click', 'away');
      rigPhone.setAttribute('data-step', 'lock');
      rigPhone.setAttribute('data-state', 'asking');
      rigPhone.setAttribute('data-banner', 'out');
      device.setAttribute('data-zoom', '0');
      reply.classList.remove('listening', 'spoken');
      replyText.textContent = PLACEHOLDER;
      denyBtn.classList.remove('pressed');
    }

    function renderFrame() {
      const s = SCENES[scene];
      if (fills[scene]) fills[scene].style.width = Math.min(100, (elapsed / s.dur) * 100).toFixed(1) + '%';
      while (beat < s.beats.length && elapsed >= s.beats[beat][0]) {
        beatAt = s.beats[beat][0];
        s.beats[beat][1]();
        beat += 1;
      }
      if (s.frame) s.frame();
      if (waitFrom >= 0) {
        const until = waitTo >= 0 ? waitTo : elapsed;
        const secs = Math.max(1, Math.round((until - waitFrom) / 1000));
        waitValue.textContent = secs + (secs === 1 ? ' second' : ' seconds');
      }
    }

    // With reduced motion the walkthrough does not play: each scene is shown held at its `hold` time.
    function enterScene(next, atEnd) {
      scene = next;
      elapsed = 0;
      beat = 0;
      waitFrom = -1;
      waitTo = -1;
      const s = SCENES[scene];
      film.setAttribute('data-scene', String(scene));
      tabs.forEach(function (t, i) { t.setAttribute('aria-current', String(i === scene)); });
      fills.forEach(function (f, i) { if (f) f.style.width = i < scene ? '100%' : '0%'; });
      chatAgent.textContent = s.agent;
      chatWhere.textContent = s.where;
      if (deviceWhere) deviceWhere.textContent = s.youWhere || '';
      chatBody.textContent = '';
      waitLabel.textContent = s.waitLabel || 'You answered in';
      wait.setAttribute('data-tone', s.tone || 'run');
      waitValue.textContent = s.tone === 'bad' ? longDuration(0) : '0 seconds';
      waitWas.textContent = '';
      if (tagAgent) tagAgent.textContent = s.tagAgent;
      if (tagYou) tagYou.textContent = s.tagYou;
      resetRigs();
      setStatus('idle');
      setMood('happy', true);
      if (atEnd) elapsed = s.hold;
      renderFrame();
    }

    function tick(now) {
      requestAnimationFrame(tick);
      const dt = Math.min(100, Math.max(0, now - lastNow));
      lastNow = now;
      if (document.hidden || paused) return;
      elapsed += dt;
      if (elapsed >= SCENES[scene].dur) enterScene((scene + 1) % SCENES.length, false);
      else renderFrame();
    }

    tabs.forEach(function (tab) {
      tab.addEventListener('click', function () {
        enterScene(Number(tab.dataset.scene) || 0, reducedMotion.matches);
      });
    });

    if (pauseBtn) {
      pauseBtn.addEventListener('click', function () {
        paused = !paused;
        pauseBtn.textContent = paused ? 'Play' : 'Pause';
        pauseBtn.setAttribute('aria-pressed', String(paused));
        pauseBtn.setAttribute('aria-label', paused ? 'Play the walkthrough' : 'Pause the walkthrough');
      });
    }

    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) lastNow = performance.now();
    });

    // ?scene=2&at=4600 opens the walkthrough held still at that moment.
    const held = new URLSearchParams(window.location.search);
    if (held.has('scene')) {
      root.classList.add('held');
      enterScene(Math.min(SCENES.length - 1, Math.max(0, Number(held.get('scene')) || 0)), false);
      elapsed = Math.min(SCENES[scene].dur - 1, Math.max(0, Number(held.get('at')) || 0));
      renderFrame();
      paused = true;
      if (pauseBtn) { pauseBtn.textContent = 'Play'; pauseBtn.setAttribute('aria-pressed', 'true'); }
      requestAnimationFrame(tick);
    } else if (reducedMotion.matches) {
      enterScene(0, true);
    } else {
      enterScene(0, false);
      requestAnimationFrame(tick);
    }
  }

  // ---- 4. One-click agent setup prompt copy ------------------------------
  const copyButtons = Array.from(document.querySelectorAll('.js-copy-prompt'));
  copyButtons.forEach(function (btn) {
    const defaultLabel = btn.textContent;
    let resetTimer = null;
    btn.addEventListener('click', async function () {
      const promptText = btn.getAttribute('data-prompt') || '';
      if (!promptText) return;
      let copied = false;
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          await navigator.clipboard.writeText(promptText);
          copied = true;
        }
      } catch (_) {}
      if (!copied) {
        try {
          const ta = document.createElement('textarea');
          ta.value = promptText;
          ta.setAttribute('readonly', '');
          ta.style.position = 'fixed';
          ta.style.left = '-9999px';
          document.body.appendChild(ta);
          ta.select();
          copied = document.execCommand('copy');
          document.body.removeChild(ta);
        } catch (_) {}
      }
      btn.textContent = copied ? 'Copied!' : 'Copy failed';
      if (resetTimer) clearTimeout(resetTimer);
      resetTimer = setTimeout(function () {
        btn.textContent = defaultLabel;
      }, 2000);
    });
  });
})();
