// Playwright MCP --init-script for code-review.yml's preview site review: runs in every page the
// review opens, before the page's own scripts, and logs Core Web Vitals to the console, where the
// review reads them with browser_console_messages:
//
//   [cwv:<tag>] LCP_ms=<ms>   largest contentful paint
//   [cwv:<tag>] CLS=<score>   cumulative layout shift: the largest session window, shifts without
//                             recent input only
//   [cwv:<tag>] INP_ms=<ms>   interaction to next paint: the longest interaction so far (after a click)
//
// <tag> is random per run: resolve-preview-site.sh rewrites the PREFIX line below when it copies
// this file, and hands the tag to the prompt, so the page cannot forge these lines with its own
// console.log. Untagged, as in this file, the prefix is a bare [cwv].
//
// Each metric is logged only when its value changes: a live probe logged CLS eleven times. It
// never throws: a page where an observer is unsupported just logs less. The review prompt tells
// the agent the tagged lines come from the platform, because their console source is this local
// file.
//
// Copied to $RUNNER_TEMP/code-review/ by resolve-preview-site.sh; tested by
// test-resolve-preview-site.sh (`vitals`).
(() => {
  // Inside the closure, never a global: a top-level const in an init script is a global binding
  // the page could read (and one that clashes with a page's own PREFIX).
  const PREFIX = '[cwv]';
  // Taken before the page's scripts run, which could otherwise replace console.log and read the
  // tag from the first line logged through it.
  const log = console.log.bind(console);
  // Top frame only: an init script also runs in every iframe (video, form and chat embeds),
  // whose own [cwv] lines would read as the page's vitals.
  try {
    if (window !== window.top) return;
  } catch {
    return; // a cross-origin top that cannot even be compared is not the page either
  }
  const last = {};
  const report = (name, value) => {
    if (last[name] === value) return;
    last[name] = value;
    log(`${PREFIX} ${name}=${value}`);
  };
  const observe = (type, options, onEntries) => {
    try {
      new PerformanceObserver((list) => {
        try {
          onEntries(list.getEntries());
        } catch (e) {
          // A malformed entry must not break the page.
        }
      }).observe({ type, buffered: true, ...options });
    } catch (e) {
      // PerformanceObserver or this entry type is unsupported here.
    }
  };

  observe('largest-contentful-paint', {}, (entries) => {
    const entry = entries[entries.length - 1];
    if (entry) report('LCP_ms', Math.round(entry.startTime));
  });

  // CLS as Chrome and Lighthouse define it, which is what the 0.1 and 0.25 thresholds mean: the
  // largest session window, not the sum of every shift since load. A window groups shifts less
  // than 1 s apart and lasts at most 5 s, so a page that shifts a little now and then (lazy
  // images, late embeds) does not read as one large shift.
  let cls = 0;
  let windowValue = 0;
  let windowStart = -Infinity;
  let windowLast = -Infinity;
  observe('layout-shift', {}, (entries) => {
    for (const entry of entries) {
      if (entry.hadRecentInput) continue;
      const t = entry.startTime;
      if (t - windowLast < 1000 && t - windowStart < 5000) {
        windowValue += entry.value;
      } else {
        windowValue = entry.value;
        windowStart = t;
      }
      windowLast = t;
      if (windowValue > cls) cls = windowValue;
    }
    report('CLS', Number(cls.toFixed(4)));
  });

  let inp = 0;
  observe('event', { durationThreshold: 16 }, (entries) => {
    for (const entry of entries) {
      if (entry.interactionId && entry.duration > inp) inp = entry.duration;
    }
    if (inp > 0) report('INP_ms', Math.round(inp));
  });
})();
