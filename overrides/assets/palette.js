/* Follow the device preference until the reader chooses a palette. */
(() => {
  const system = window.matchMedia('(prefers-color-scheme: dark)');
  let choice;
  try {
    choice = localStorage.getItem('singular-palette');
  } catch (_) {
    /* Storage is optional. */
  }
  const isDark = () => choice === 'dark' || (choice !== 'light' && system.matches);
  const apply = () => {
    const dark = isDark();
    document.documentElement.dataset.singularPalette = dark ? 'dark' : 'light';
    const sheet = document.getElementById('singular-dark-palette');
    if (sheet) sheet.media = dark ? 'all' : 'not all';
    document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
    const button = document.getElementById('singular-palette-toggle');
    if (button) {
      /* Sun and moon: the icon shows the palette the button switches to. */
      const SVG = 'http://www.w3.org/2000/svg';
      const svg = document.createElementNS(SVG, 'svg');
      svg.setAttribute('viewBox', '0 0 24 24');
      svg.setAttribute('aria-hidden', 'true');
      svg.setAttribute('focusable', 'false');
      const parts = dark
        ? [
            ['circle', { cx: 12, cy: 12, r: 4, fill: 'currentColor' }],
            [
              'path',
              {
                d: 'M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1',
                fill: 'none',
                stroke: 'currentColor',
                'stroke-width': 2,
                'stroke-linecap': 'round',
              },
            ],
          ]
        : [
            [
              'path',
              { d: 'M20 14.5A8.5 8.5 0 0 1 9.5 4 8.5 8.5 0 1 0 20 14.5z', fill: 'currentColor' },
            ],
          ];
      for (const [tag, attributes] of parts) {
        const node = document.createElementNS(SVG, tag);
        for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
        svg.append(node);
      }
      const words = dark ? 'Switch to light mode' : 'Switch to dark mode';
      button.replaceChildren(svg);
      button.setAttribute('aria-label', words);
      button.title = words;
      button.hidden = false;
    }
    document.dispatchEvent(new CustomEvent('singular-palette', { detail: { dark } }));
  };
  apply();
  system.addEventListener('change', apply);
  document.addEventListener('DOMContentLoaded', () => {
    apply();
    document.getElementById('singular-palette-toggle').addEventListener('click', () => {
      choice = isDark() ? 'light' : 'dark';
      try {
        localStorage.setItem('singular-palette', choice);
      } catch (_) {
        /* Storage is optional. */
      }
      apply();
    });
    const navigation = document.getElementById('singular-navigation');
    if (navigation) {
      const wide = window.matchMedia('(min-width: 70em)');
      navigation.open = wide.matches;
      wide.addEventListener('change', () => {
        navigation.open = wide.matches;
      });
    }
  });
})();
