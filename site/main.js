/* RepoBar site — the menu bar demo, scroll reveals and the copy button.
   No dependencies, no inline styles (the host sends script-src 'self'; style-src 'self'). */
(function () {
  "use strict";
  var root = document.documentElement;
  root.className += " js";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var announce = document.querySelector("[data-announce]");
  var say = function (text) { if (announce) announce.textContent = text; };

  /* ── 1. the menu bar demo ─────────────────────────────────────────────── */
  var trigger = document.getElementById("rb-trigger");
  var pop = document.getElementById("rb-panel");

  if (trigger && pop) {
    var bar = document.querySelector("[data-strip]");
    var panel = pop.querySelector(".rb-panel");
    var repos = [].slice.call(pop.querySelectorAll(".rb-repo"));
    var statusLine = pop.querySelector("[data-status]");
    var initial = repos.map(function (el) {
      return {
        el: el,
        name: el.getAttribute("data-repo"),
        behind: parseInt(el.getAttribute("data-behind") || "0", 10),
        unseen: parseInt(el.getAttribute("data-unseen") || "0", 10),
        error: el.hasAttribute("data-error")
      };
    });
    var state = initial.map(function (r) { return { behind: r.behind, unseen: r.unseen, error: r.error }; });

    function render() {
      var withNews = 0, failed = 0;
      initial.forEach(function (repo, i) {
        var s = state[i];
        var rowDot = repo.el.querySelector("[data-rowdot]");
        var barDot = document.querySelector('[data-dot="' + repo.name + '"]');
        var behindCap = repo.el.querySelector("[data-behind]");
        if (s.unseen > 0) withNews++;
        if (s.error) failed++;
        [rowDot, barDot].forEach(function (dot) {
          if (!dot) return;
          dot.classList.toggle("is-new", s.unseen > 0 && !s.error);
          dot.classList.toggle("is-error", !!s.error);
        });
        if (behindCap) {
          behindCap.textContent = "↓" + s.behind;
          behindCap.hidden = s.behind === 0;
        }
        repo.el.classList.toggle("is-seen", s.unseen === 0 && repo.unseen > 0);
        var pull = repo.el.querySelector('[data-action="pull"]');
        if (pull && !pull.hasAttribute("title")) pull.disabled = s.behind === 0;
      });
      if (statusLine) {
        var parts = [];
        parts.push(withNews === 0
          ? "All " + initial.length + " repositories up to date"
          : withNews + " of " + initial.length + " repositories have new commits");
        if (failed) parts.push(failed + " failed");
        if (pop.classList.contains("is-paused")) parts.push("checks paused");
        if (pop.classList.contains("is-silenced")) parts.push("silenced");
        if (parts.length === 1) parts.push("just now");
        statusLine.textContent = parts.join(" · ");
      }
      if (trigger) {
        trigger.setAttribute("aria-label",
          "RepoBar: " + (statusLine ? statusLine.textContent : "") + ". Open the demo panel.");
      }
    }

    /* a check: the header and every row spin, exactly as the app does it */
    var checking = null;
    function check() {
      if (checking || pop.classList.contains("is-paused")) return;
      panel.classList.add("is-checking");
      if (statusLine) statusLine.textContent = "Checking…";
      checking = window.setTimeout(function () {
        panel.classList.remove("is-checking");
        checking = null;
        render();
        say("All repositories checked.");
      }, 1500);
    }

    /* the panel hangs from the status item, the way an NSPopover does */
    function place() {
      var t = trigger.getBoundingClientRect();
      var width = pop.offsetWidth;
      var margin = 8;
      var centre = t.left + t.width / 2;
      var left = Math.max(margin, Math.min(centre - width / 2, window.innerWidth - width - margin));
      pop.style.setProperty("--pop-left", left + "px");
      pop.style.setProperty("--arrow-x", (centre - left) + "px");
    }

    function openPop() {
      pop.hidden = false;
      place();
      root.classList.add("panel-open");
      trigger.setAttribute("aria-expanded", "true");
      document.addEventListener("click", onOutside, true);
      document.addEventListener("keydown", onKey);
    }
    function closePop(focusBack) {
      pop.hidden = true;
      root.classList.remove("panel-open");
      trigger.setAttribute("aria-expanded", "false");
      closeDropdowns();
      document.removeEventListener("click", onOutside, true);
      document.removeEventListener("keydown", onKey);
      if (focusBack) trigger.focus();
    }
    function onOutside(e) {
      if (pop.contains(e.target) || trigger.contains(e.target)) return;
      if (e.target.closest && e.target.closest('[data-action="appearance"]')) return;
      closePop(false);
    }
    function onKey(e) { if (e.key === "Escape") { closePop(true); } }
    function closeDropdowns() {
      [].forEach.call(pop.querySelectorAll(".rb-dropdown"), function (d) { d.hidden = true; });
      [].forEach.call(pop.querySelectorAll('[data-action="open"]'), function (b) { b.setAttribute("aria-expanded", "false"); });
    }

    window.addEventListener("resize", function () { if (!pop.hidden) place(); });

    /* the still of the panel in the hero belongs to the same simulated Mac */
    window.__rbSimShot = function simShot(mode) {
      var shot = document.querySelector("[data-sim-shot]");
      if (!shot) return;
      var source = shot.querySelector("source");
      var img = shot.querySelector("img");
      if (source) source.srcset = "/assets/panel-" + mode + ".webp";
      if (img) img.src = "/assets/panel-" + mode + ".png";
    };


    trigger.addEventListener("click", function () {
      pop.hidden ? openPop() : closePop(false);
    });
    [].forEach.call(document.querySelectorAll("[data-open-panel]"), function (btn) {
      btn.addEventListener("click", function () {
        if (pop.hidden) openPop();
        trigger.focus();
        say("RepoBar panel opened.");
      });
    });

    pop.addEventListener("click", function (e) {
      var row = e.target.closest(".rb-row");
      if (row) {
        var repo = row.closest(".rb-repo");
        var open = repo.classList.toggle("is-open");
        row.setAttribute("aria-expanded", open ? "true" : "false");
        return;
      }
      var btn = e.target.closest("button");
      if (!btn) return;
      var action = btn.getAttribute("data-action");
      var host = btn.closest(".rb-repo");
      var index = host ? repos.indexOf(host) : -1;

      if (action === "pull" && index > -1) {
        var pulled = state[index].behind;
        state[index].behind = 0;
        state[index].unseen = 0;
        render();
        say("Fast-forwarded " + pulled + " commits in " + initial[index].name + ".");
        flash(btn, "Pulled " + pulled);
      } else if (action === "seen" && index > -1) {
        state[index].unseen = 0;
        render();
        say(initial[index].name + " marked as seen.");
      } else if (action === "open") {
        var list = btn.nextElementSibling;
        var wasOpen = !list.hidden;
        closeDropdowns();
        list.hidden = wasOpen;
        btn.setAttribute("aria-expanded", wasOpen ? "false" : "true");
      } else if (action === "refresh") {
        check();
      } else if (action === "silence") {
        var silenced = pop.classList.toggle("is-silenced");
        btn.setAttribute("aria-pressed", silenced ? "true" : "false");
        btn.setAttribute("aria-label", silenced ? "Turn notifications back on" : "Silence notifications");
        btn.title = silenced ? "Silenced until tomorrow" : "Silence notifications";
        render();
        say(silenced ? "Notifications silenced." : "Notifications back on.");
      } else if (action === "pause") {
        var paused = pop.classList.toggle("is-paused");
        bar.classList.toggle("is-paused", paused);
        btn.setAttribute("aria-pressed", paused ? "true" : "false");
        btn.setAttribute("aria-label", paused ? "Resume checks" : "Pause checks");
        btn.title = paused ? "Resume checks" : "Pause checks";
        render();
        say(paused ? "Checks paused." : "Checks resumed.");
      } else if (btn.closest(".rb-dropdown")) {
        var menu = btn.closest(".rb-dropdown");
        var menuButton = btn.closest(".rb-open").querySelector('[data-action="open"]');
        var label = btn.querySelector("span").textContent;
        [].forEach.call(menu.querySelectorAll("button"), function (b) { b.classList.remove("is-current"); });
        btn.classList.add("is-current");
        [].forEach.call(menuButton.childNodes, function (node) {
          if (node.nodeType === 3 && node.nodeValue.trim()) node.nodeValue = "Open in " + label;
        });
        closeDropdowns();
        say("Default set to " + label + ".");
      }
    });

    function flash(btn, text) {
      var original = btn.getAttribute("data-label") || btn.textContent;
      btn.setAttribute("data-label", original);
      btn.textContent = text;
      window.setTimeout(function () { btn.textContent = original; }, 1400);
    }

    render();

    /* the one authored moment: two dots fill in, once */
    if (!reduced) {
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          root.setAttribute("data-play", "1");
        });
      });
    }
  }


  /* ── 2. the simulated bar: on every page, panel or not ────────────────── */
  var appearance = document.querySelector('[data-action="appearance"]');
  if (appearance) {
    appearance.addEventListener("click", function () {
      var dark = root.getAttribute("data-appearance") === "dark";
      root.setAttribute("data-appearance", dark ? "light" : "dark");
      if (window.__rbSimShot) window.__rbSimShot(dark ? "light" : "dark");
      appearance.setAttribute("aria-label", dark
        ? "Show the menu bar in the dark appearance"
        : "Show the menu bar in the light appearance");
      say(dark ? "Menu bar switched to the light appearance."
               : "Menu bar switched to the dark appearance.");
    });
  }
  /* the clock is the visitor's own, the way it would be on their Mac */
  var clock = document.querySelector("[data-clock]");
  if (clock) {
    var tick = function () {
      var now = new Date();
      clock.textContent =
        now.toLocaleDateString([], { weekday: "short" }) + " " +
        now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
      window.setTimeout(tick, (61 - now.getSeconds()) * 1000);
    };
    tick();
  }


  /* ── 3. the toolbar grows a hairline once the page has moved ──────────── */
  var head = document.querySelector(".masthead");
  if (head && "IntersectionObserver" in window) {
    var sentinel = document.createElement("span");
    sentinel.setAttribute("aria-hidden", "true");
    sentinel.className = "vh";
    document.body.insertBefore(sentinel, document.body.firstChild);
    new IntersectionObserver(function (entries) {
      head.classList.toggle("is-stuck", !entries[0].isIntersecting);
    }, { threshold: 0 }).observe(sentinel);
  }
})();
