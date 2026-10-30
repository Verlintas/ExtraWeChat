/* SPDX-FileCopyrightText: 2026 Verlintas */
/* SPDX-License-Identifier: AGPL-3.0-only */

(function () {
  "use strict";

  var root = document.documentElement;
  var themes = ["wechat", "ocean", "sunset", "violet", "graphite"];
  var dots = Array.prototype.slice.call(document.querySelectorAll(".theme-dot"));

  function setTheme(name, persist) {
    if (themes.indexOf(name) === -1) name = "wechat";
    root.dataset.theme = name;
    dots.forEach(function (dot) {
      dot.classList.toggle("active", dot.dataset.theme === name);
    });
    if (persist) {
      try { localStorage.setItem("extrawechat-site-theme", name); } catch (e) {}
    }
  }

  var saved = null;
  try { saved = localStorage.getItem("extrawechat-site-theme"); } catch (e) {}
  setTheme(saved || "wechat", false);

  dots.forEach(function (dot) {
    dot.addEventListener("click", function () {
      setTheme(dot.dataset.theme, true);
    });
  });

  var nav = document.getElementById("nav");
  function onScroll() {
    if (!nav) return;
    nav.classList.toggle("scrolled", window.scrollY > 12);
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  var params = new URLSearchParams(window.location.search);
  var scrollTarget = params.get("scroll");
  if (scrollTarget) {
    window.setTimeout(function () {
      var target = document.getElementById(scrollTarget);
      if (target) {
        var previous = document.documentElement.style.scrollBehavior;
        document.documentElement.style.scrollBehavior = "auto";
        target.scrollIntoView({ block: "start" });
        document.documentElement.style.scrollBehavior = previous;
      }
    }, 150);
  }

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var reveals = Array.prototype.slice.call(document.querySelectorAll(".reveal"));
  var staticPreview = window.location.search.indexOf("static=1") !== -1;
  if (staticPreview || reduceMotion || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("visible"); });
  } else {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
          observer.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach(function (el) { observer.observe(el); });
    // Make anything already in the viewport visible immediately, without
    // waiting for the first intersection callback.
    window.setTimeout(function () {
      reveals.forEach(function (el) {
        if (el.getBoundingClientRect().top < window.innerHeight * 0.95) {
          el.classList.add("visible");
        }
      });
    }, 80);
  }

  var lightbox = document.getElementById("lightbox");
  var lightboxImg = lightbox ? lightbox.querySelector("img") : null;
  var closeButton = lightbox ? lightbox.querySelector(".lightbox-close") : null;

  function openLightbox(src, alt) {
    if (!lightbox || !lightboxImg) return;
    lightboxImg.src = src;
    lightboxImg.alt = alt || "";
    lightbox.classList.add("open");
    lightbox.setAttribute("aria-hidden", "false");
    if (closeButton) closeButton.focus();
  }

  function closeLightbox() {
    if (!lightbox) return;
    lightbox.classList.remove("open");
    lightbox.setAttribute("aria-hidden", "true");
    if (lightboxImg) lightboxImg.removeAttribute("src");
  }

  document.querySelectorAll(".shot").forEach(function (shot) {
    var img = shot.querySelector("img");
    if (!img) return;
    shot.setAttribute("tabindex", "0");
    shot.setAttribute("role", "button");
    shot.setAttribute("aria-label", "查看大图：" + (img.alt || ""));
    shot.addEventListener("click", function () { openLightbox(img.src, img.alt); });
    shot.addEventListener("keydown", function (event) {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        openLightbox(img.src, img.alt);
      }
    });
  });

  if (lightbox) {
    lightbox.addEventListener("click", function (event) {
      if (event.target === lightbox) closeLightbox();
    });
  }
  if (closeButton) closeButton.addEventListener("click", closeLightbox);
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closeLightbox();
  });
})();
