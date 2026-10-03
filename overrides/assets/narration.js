/* Play the recorded narration of one section at a time. The voice says what the
   page says: the clips are made from the speech companions of the extraction tool,
   one clip per paragraph, list item or heading, and a section's clips are listed
   in audio/index.json. The paragraph being spoken is highlighted only when its
   text on the page equals the clip's text. A failed clip is reported on the
   button; it is never replaced by another voice. */
(() => {
  const here = window.singular;
  if (!here) return;
  const PROSE = 'p, li, blockquote, dd, dt, summary';
  const SILENT =
    'pre, table, svg, script, style, button, nav, dialog, figure, .diagram, .diagram-links, .headerlink';
  const normalise = (text) => text.replace(/\s+/g, ' ').trim();
  const speeds = [1, 1.25, 1.5, 1.75, 2, 0.85];
  let speed = 1;
  let active = null;

  /* The words an element carries itself, without nested prose or silent parts. */
  const ownText = (element) => {
    const copy = element.cloneNode(true);
    for (const inner of copy.querySelectorAll(`${PROSE}, ${SILENT}`)) inner.remove();
    return normalise(copy.textContent);
  };

  /* Elements per owning heading id, in the order the extraction tool speaks them. */
  const elementsBySection = () => {
    const main = document.getElementById('terminal-mkdocs-main-content');
    const sections = {};
    if (!main) return sections;
    let owner = null;
    const pending = [];
    for (const element of main.querySelectorAll(`h1, h2, h3, h4, h5, h6, ${PROSE}`)) {
      if (element.closest(SILENT)) continue;
      const heading = /^H[1-6]$/.test(element.tagName);
      const text = ownText(element);
      if (!text) continue;
      if (heading) {
        if (Number(element.tagName[1]) <= 3 && element.id) {
          owner = element.id;
          sections[owner] = pending.splice(0);
        }
        (owner ? sections[owner] : pending).push({ element, text: `${text}.` });
      } else {
        (owner ? sections[owner] : pending).push({ element, text });
      }
    }
    return sections;
  };

  /* The control is a speaker icon at the heading: waves when idle, a pause mark while
     playing. The words live in the accessible label. The drawing uses the current text
     colour, so it follows both palettes. */
  const SVG = 'http://www.w3.org/2000/svg';
  const ICONS = {
    idle: [
      ['path', { d: 'M3 9v6h4l5 4V5L7 9H3z', fill: 'currentColor' }],
      [
        'path',
        {
          d: 'M16 8.5a5 5 0 0 1 0 7M18.5 6a8.5 8.5 0 0 1 0 12',
          fill: 'none',
          stroke: 'currentColor',
          'stroke-width': 2,
          'stroke-linecap': 'round',
        },
      ],
    ],
    playing: [
      ['rect', { x: 6, y: 5, width: 4, height: 14, fill: 'currentColor' }],
      ['rect', { x: 14, y: 5, width: 4, height: 14, fill: 'currentColor' }],
    ],
    failed: [
      ['path', { d: 'M3 9v6h4l5 4V5L7 9H3z', fill: 'currentColor' }],
      [
        'path',
        {
          d: 'M16 9l5 6M21 9l-5 6',
          fill: 'none',
          stroke: 'currentColor',
          'stroke-width': 2,
          'stroke-linecap': 'round',
        },
      ],
    ],
  };
  const NAMES = {
    idle: 'Play the narration of this section',
    paused: 'Resume the narration of this section',
    playing: 'Pause the narration of this section',
    failed: 'The narration audio failed. Press to try again',
  };
  const draw = (state) => {
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('focusable', 'false');
    for (const [tag, attributes] of ICONS[state === 'paused' ? 'idle' : state]) {
      const node = document.createElementNS(SVG, tag);
      for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
      svg.append(node);
    }
    return svg;
  };
  const show = (controller, state, detail) => {
    controller.button.replaceChildren(draw(state));
    controller.button.dataset.state = state;
    controller.button.setAttribute('aria-pressed', state === 'playing' ? 'true' : 'false');
    controller.button.setAttribute('aria-label', NAMES[state]);
    controller.button.title = detail || NAMES[state];
  };

  const mark = (controller, position) => {
    controller.items.forEach((item, index) => {
      item.element.classList.toggle('narrating', controller.highlight && index === position);
    });
  };

  const release = (controller) => {
    clearTimeout(controller.timer);
    controller.audio.pause();
    mark(controller, -1);
    show(controller, 'idle');
    controller.position = 0;
    controller.state = 'idle';
    if (active === controller) active = null;
  };

  const fail = (controller, message) => {
    clearTimeout(controller.timer);
    mark(controller, -1);
    controller.state = 'idle';
    if (active === controller) active = null;
    show(controller, 'failed', `${message}. Press to try again`);
  };

  const advance = (controller) => {
    if (controller.state !== 'playing') return;
    if (controller.position >= controller.clips.length) {
      release(controller);
      return;
    }
    const clip = controller.clips[controller.position];
    mark(controller, controller.position);
    controller.audio.src = `${here.base}docs/audio/clips/${clip.name}.mp3?v=${clip.v}`;
    controller.audio.playbackRate = speed;
    controller.audio.onended = () => {
      controller.position += 1;
      controller.timer = setTimeout(() => advance(controller), clip.pause_ms / speed);
    };
    controller.audio.onerror = () => fail(controller, 'Audio failed to load');
    controller.audio.play().catch((error) => fail(controller, `Audio failed: ${error.message}`));
  };

  const toggle = (controller) => {
    if (controller.state === 'playing') {
      clearTimeout(controller.timer);
      controller.audio.pause();
      controller.state = 'paused';
      show(controller, 'paused');
      return;
    }
    if (active && active !== controller) release(active);
    active = controller;
    const resuming =
      controller.state === 'paused' && controller.audio.src && !controller.audio.ended;
    controller.state = 'playing';
    show(controller, 'playing');
    if (resuming) {
      controller.audio.playbackRate = speed;
      controller.audio.play().catch((error) => fail(controller, `Audio failed: ${error.message}`));
    } else {
      advance(controller);
    }
  };

  fetch(`${here.base}docs/audio/index.json`, { cache: 'no-cache' })
    .then((response) => response.json())
    .then((index) => {
      const bySection = index[here.source];
      if (!bySection) return;
      const items = elementsBySection();
      const controllers = [];
      for (const [id, clips] of Object.entries(bySection)) {
        const heading = document.getElementById(id);
        if (!heading) continue;
        const own = items[id] || [];
        const highlight =
          own.length === clips.length && clips.every((clip, i) => own[i].text === clip.text);
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'narration-play';
        const controller = {
          button,
          clips,
          items: own,
          highlight,
          audio: new Audio(),
          position: 0,
          timer: null,
          state: 'idle',
        };
        show(controller, 'idle');
        button.addEventListener('click', () => toggle(controller));
        heading.append(button);
        controllers.push(controller);
      }
      if (!controllers.length) return;
      const control = document.getElementById('narration-speed');
      if (!control) return;
      const gauge = () => {
        const svg = document.createElementNS(SVG, 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('aria-hidden', 'true');
        svg.setAttribute('focusable', 'false');
        for (const [tag, attributes] of [
          [
            'path',
            {
              d: 'M4 18a8 8 0 1 1 16 0',
              fill: 'none',
              stroke: 'currentColor',
              'stroke-width': 2,
              'stroke-linecap': 'round',
            },
          ],
          [
            'path',
            {
              d: 'M12 18l4.5-6',
              fill: 'none',
              stroke: 'currentColor',
              'stroke-width': 2,
              'stroke-linecap': 'round',
            },
          ],
          ['circle', { cx: 12, cy: 18, r: 1.6, fill: 'currentColor' }],
        ]) {
          const node = document.createElementNS(SVG, tag);
          for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
          svg.append(node);
        }
        return svg;
      };
      const describe = () => {
        const rate = document.createElement('span');
        rate.textContent = `${speed}×`;
        control.replaceChildren(gauge(), rate);
        const words = `Narration speed ${speed}×. Press to change`;
        control.setAttribute('aria-label', words);
        control.title = words;
      };
      describe();
      control.hidden = false;
      control.addEventListener('click', () => {
        speed = speeds[(speeds.indexOf(speed) + 1) % speeds.length];
        describe();
        if (active) active.audio.playbackRate = speed;
      });
    })
    .catch(() => {
      /* No narration is published for this page. */
    });
})();
