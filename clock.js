/* Rexx Hub - live digital clock (time + today's date) shown at the top of every page.
   Uses the server's clock when it can be reached (so every computer agrees), else the device clock. */
(() => {
  'use strict';
  let offset = 0;                                   // server time minus device time, in ms
  const now = () => new Date(Date.now() + offset);
  try {                                             // one quick sync with the server's Date header
    fetch(location.pathname, { method: 'HEAD', cache: 'no-store', credentials: 'same-origin' })
      .then(r => { const d = Date.parse(r.headers.get('Date')); if (!isNaN(d)) offset = d - Date.now(); })
      .catch(() => {});
  } catch (e) { /* device clock it is */ }

  const box = document.createElement('div');
  box.className = 'rexx-clock';
  box.setAttribute('role', 'timer'); box.setAttribute('aria-label', 'Current date and time');
  const timeEl = document.createElement('span'); timeEl.className = 'rc-time';
  const dateEl = document.createElement('span'); dateEl.className = 'rc-date';
  box.append(timeEl, dateEl);

  const host = document.querySelector('.examtop .inner') || document.querySelector('.topbar .inner');
  if (host) {
    const anchor = host.querySelector('#timer') || host.querySelector('.who');
    anchor ? host.insertBefore(box, anchor) : host.append(box);
  } else {                                          // page without a header: small pill at the top right
    box.classList.add('floating'); document.body.append(box);
  }

  const tfmt = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', second: '2-digit', hour12: true });
  const dfmt = new Intl.DateTimeFormat('en-GB', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  let lastDay = '';
  function tick() {
    const d = now();
    timeEl.textContent = tfmt.format(d);
    const day = dfmt.format(d);
    if (day !== lastDay) { dateEl.textContent = day; lastDay = day; }
  }
  tick();
  setInterval(tick, 500);
})();
