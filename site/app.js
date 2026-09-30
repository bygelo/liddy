/* Liddy — liddy.bygelo.com
 *
 * Three things happen here, and nothing else: the night cross-fades as you
 * scroll, sections reveal once, and the hero rig runs the real deadman state
 * machine. The rig uses the product's actual numbers — a 5s heartbeat and a
 * 15s gap before the helper gives up — because a demo that lies about its
 * own timings is worse than no demo.
 */

(function () {
  'use strict';

  var calm = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ── the night ─────────────────────────────────────────────── */

  var smallHours = document.querySelector('.night-small-hours');
  var dawn = document.querySelector('.night-dawn');
  var bar = document.querySelector('.bar');
  var rail = document.querySelector('.rail');
  var railFill = document.getElementById('rail-fill');
  var railClock = document.getElementById('rail-clock');
  var railState = document.getElementById('rail-state');

  // The clock the rail reports, keyed to how far down the night you are.
  var HOUR = [
    { at: 0.00, clock: '23:41', state: 'holding' },
    { at: 0.20, clock: '23:42', state: 'guarded' },
    { at: 0.36, clock: '00:02', state: 'claimed' },
    { at: 0.52, clock: '02:14', state: 'soft floor' },
    { at: 0.66, clock: '03:50', state: 'very hot' },
    { at: 0.78, clock: '06:12', state: 'finished' },
    { at: 0.90, clock: '06:12', state: 'awake' }
  ];

  function ramp(value, from, to) {
    return Math.max(0, Math.min(1, (value - from) / (to - from)));
  }

  var ticking = false;

  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () {
      ticking = false;
      var max = document.body.scrollHeight - window.innerHeight;
      var p = max > 0 ? window.scrollY / max : 0;

      // Dusk holds, the small hours take over across the middle, dawn arrives last.
      smallHours.style.opacity = ramp(p, 0.14, 0.42) * (1 - ramp(p, 0.6, 0.82));
      dawn.style.opacity = ramp(p, 0.62, 0.88);

      bar.classList.toggle('is-stuck', window.scrollY > 24);

      if (rail) {
        rail.classList.toggle('is-shown', p > 0.06 && p < 0.97);
        railFill.style.height = (p * 100).toFixed(1) + '%';
        for (var i = HOUR.length - 1; i >= 0; i--) {
          if (p >= HOUR[i].at) {
            railClock.textContent = HOUR[i].clock;
            railState.textContent = HOUR[i].state;
            break;
          }
        }
      }
    });
  }

  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll);
  onScroll();

  /* ── reveal ────────────────────────────────────────────────── */

  var revealable = document.querySelectorAll(
    '.section > *, .hero-pitch > *, .rig-stage, .hero-foot > *'
  );

  if (calm || !('IntersectionObserver' in window)) {
    revealable.forEach(function (el) { el.classList.add('is-in'); });
  } else {
    var seen = new IntersectionObserver(function (entry) {
      entry.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.classList.add('is-in');
          seen.unobserve(e.target);
        }
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

    revealable.forEach(function (el, i) {
      el.classList.add('reveal');
      el.style.transitionDelay = Math.min(i % 6, 5) * 55 + 'ms';
      seen.observe(el);
    });
  }

  /* ── the rig ───────────────────────────────────────────────── */

  var rig = document.getElementById('rig');
  if (!rig) return;

  var beat = document.getElementById('rig-beat');
  var value = document.getElementById('rig-value');
  var state = document.getElementById('rig-state');
  var log = document.getElementById('deadman-log').querySelector('code');
  var killButton = document.getElementById('act-kill');
  var hangButton = document.getElementById('act-hang');
  var resetButton = document.getElementById('act-reset');

  var CIRCUMFERENCE = 2 * Math.PI * 94;
  var HEARTBEAT_MS = 5000;   // the app's real heartbeat interval
  var DEADMAN_MS = 15000;    // the helper's real patience for a missing one

  var mode = 'holding';      // holding · hanging · reverted
  var since = performance.now();
  var frame = null;

  // A clock that starts where the page's night starts, so the rig's log lines
  // and the section stamps are telling the same story.
  var clockBase = 23 * 3600 + 41 * 60 + 2;
  var clockStart = Date.now();

  function stamp() {
    var t = clockBase + Math.floor((Date.now() - clockStart) / 1000);
    var h = Math.floor(t / 3600) % 24, m = Math.floor(t / 60) % 60, s = t % 60;
    return [h, m, s].map(function (n) { return n < 10 ? '0' + n : '' + n; }).join(':');
  }

  function write(html) {
    var line = document.createElement('span');
    line.innerHTML = '\n<span class="ts">' + stamp() + '</span> ' + html;
    log.appendChild(line);
    log.parentNode.scrollTop = log.parentNode.scrollHeight;
  }

  function arc(fraction) {
    var shown = Math.max(0, Math.min(1, fraction)) * CIRCUMFERENCE;
    beat.setAttribute('stroke-dasharray', shown + ' ' + CIRCUMFERENCE);
  }

  function tick(now) {
    var elapsed = now - since;

    if (mode === 'holding') {
      arc((elapsed % HEARTBEAT_MS) / HEARTBEAT_MS);
      var left = Math.ceil((HEARTBEAT_MS - (elapsed % HEARTBEAT_MS)) / 1000);
      state.textContent = 'HOLDING · HEARTBEAT IN ' + left + 'S';
    } else if (mode === 'hanging') {
      var gone = Math.min(elapsed, DEADMAN_MS);
      arc(1 - gone / DEADMAN_MS);
      var patience = Math.ceil((DEADMAN_MS - gone) / 1000);
      state.textContent = 'NO HEARTBEAT · REVERTS IN ' + patience + 'S';
      if (gone >= DEADMAN_MS) {
        revert('helper: 15s without a heartbeat');
        return;
      }
    }

    frame = requestAnimationFrame(tick);
  }

  function revert(reason) {
    cancelAnimationFrame(frame);
    mode = 'reverted';
    rig.classList.remove('is-hanging');
    rig.classList.add('is-reverted');
    arc(0);
    value.textContent = '0';
    state.textContent = 'REVERTED · NORMAL SLEEP RESTORED';

    write(reason);
    write('helper: <span class="ok">pmset -a disablesleep 0</span>');
    write('<span class="ok">the Mac can sleep on the lid again</span>');

    killButton.classList.add('is-hidden');
    hangButton.classList.add('is-hidden');
    resetButton.classList.remove('is-hidden');
  }

  killButton.addEventListener('click', function () {
    write('<span class="warn">kill -9 &lt;Liddy pid&gt;</span>');
    revert('helper: socket closed — the app is gone');
  });

  hangButton.addEventListener('click', function () {
    if (mode !== 'holding') return;
    mode = 'hanging';
    since = performance.now();
    rig.classList.add('is-hanging');
    write('<span class="warn">app wedged — heartbeat stopped</span>');
    write('helper: waiting <span class="warn">15s</span> before it gives up');
    hangButton.classList.add('is-hidden');
  });

  resetButton.addEventListener('click', function () {
    mode = 'holding';
    since = performance.now();
    rig.classList.remove('is-reverted', 'is-hanging');
    value.textContent = '1';
    write('app reconnected · heartbeat every 5s');
    write('helper: <span class="ok">pmset -a disablesleep 1</span>');
    resetButton.classList.add('is-hidden');
    killButton.classList.remove('is-hidden');
    hangButton.classList.remove('is-hidden');
    frame = requestAnimationFrame(tick);
  });

  if (calm) {
    arc(1);
    state.textContent = 'HOLDING · LID CLOSED';
  } else {
    frame = requestAnimationFrame(tick);
  }
})();
