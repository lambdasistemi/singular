/* Render the vendored Mermaid diagrams at their natural size in the selected
   palette, re-rendering when the palette changes, with a full-size viewer. */
(() => {
  if (typeof mermaid === 'undefined') return;
  const sources = [...document.querySelectorAll('pre.mermaid')].map((pre) => {
    const source = pre.textContent;
    const figure = document.createElement('figure');
    figure.className = 'diagram';
    const links = document.createElement('p');
    links.className = 'diagram-links';
    const open = document.createElement('button');
    open.type = 'button';
    open.textContent = 'Open full size';
    links.append(open);
    pre.replaceWith(figure);
    figure.after(links);
    return { source, figure, open };
  });
  if (!sources.length) return;
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const configure = () => {
    const dark = document.documentElement.dataset.singularPalette === 'dark';
    mermaid.initialize({
      startOnLoad: false,
      theme: 'base',
      securityLevel: 'strict',
      flowchart: { useMaxWidth: false },
      sequence: { useMaxWidth: false },
      state: { useMaxWidth: false },
      er: { useMaxWidth: false },
      themeVariables: {
        darkMode: dark,
        background: css('--background-color'),
        fontSize: '15px',
        fontFamily: css('--font-stack') || 'monospace',
        primaryColor: dark ? '#2b3a4a' : '#e8f1fa',
        primaryTextColor: css('--font-color'),
        primaryBorderColor: css('--secondary-color'),
        lineColor: css('--secondary-color'),
        textColor: css('--font-color'),
        secondaryColor: dark ? '#3a3350' : '#f0e8fa',
        tertiaryColor: css('--background-color'),
        edgeLabelBackground: css('--background-color'),
        clusterBkg: css('--background-color'),
        noteBkgColor: dark ? '#3a3350' : '#fff8dc',
        noteTextColor: css('--font-color'),
        actorBkg: dark ? '#2b3a4a' : '#e8f1fa',
        actorTextColor: css('--font-color'),
        actorBorder: css('--secondary-color'),
        signalColor: css('--font-color'),
        signalTextColor: css('--font-color'),
      },
    });
  };
  let serial = 0;
  const render = async () => {
    configure();
    for (const item of sources) {
      try {
        serial += 1;
        const { svg } = await mermaid.render('singular-diagram-' + serial, item.source);
        item.figure.innerHTML = svg;
        item.svg = svg;
      } catch (error) {
        item.figure.textContent = 'Diagram failed to render: ' + error.message;
      }
    }
  };
  const viewer = document.createElement('dialog');
  viewer.className = 'diagram-viewer';
  viewer.id = 'diagram-viewer';
  viewer.setAttribute('aria-label', 'Diagram at full size');
  const close = document.createElement('button');
  close.type = 'button';
  close.textContent = 'Close';
  const scroll = document.createElement('div');
  scroll.className = 'diagram-scroll';
  viewer.append(close, scroll);
  document.body.append(viewer);
  close.addEventListener('click', () => viewer.close());
  viewer.addEventListener('click', (event) => {
    if (event.target === viewer) viewer.close();
  });
  const show = (item) => {
    if (!item.svg) return;
    scroll.innerHTML = item.svg;
    viewer.showModal();
  };
  for (const item of sources) {
    item.open.addEventListener('click', () => show(item));
    item.figure.addEventListener('click', () => show(item));
  }
  document.addEventListener('singular-palette', () => {
    if (viewer.open) viewer.close();
    render();
  });
  render();
})();
