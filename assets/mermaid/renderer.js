'use strict';
window.diagramStatus = 'ready';
window.renderDiagram = async (source, dark) => {
  window.diagramStatus = 'rendering';
  const container = document.getElementById('diagram');
  try {
    if (typeof source !== 'string' || source.length > 65536 ||
        /^\s*---/m.test(source) || /%%\s*\{/.test(source) ||
        !/^\s*(?:(?:%%[^\n]*\n)\s*)*(?:flowchart|graph|sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|erDiagram|pie)\b/.test(source)) {
      throw new Error('Unsupported diagram');
    }
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict',
      suppressErrorRendering: true, theme: dark ? 'dark' : 'default',
      fontFamily: 'Open Sans', htmlLabels: false,
      flowchart: { htmlLabels: false }, maxTextSize: 65536,
      secure: ['securityLevel', 'startOnLoad', 'maxTextSize', 'suppressErrorRendering', 'htmlLabels', 'fontFamily'] });
    await document.fonts.ready;
    const { svg } = await mermaid.render('answer-diagram', source);
    // Mermaid generates SVG under strict security. No bindings or callbacks
    // are installed. CSP also denies remote resources and navigation is native-blocked.
    container.innerHTML = svg;
    window.diagramStatus = 'complete';
  } catch (_) {
    container.replaceChildren();
    window.diagramStatus = 'failed';
  }
};
document.addEventListener('click', event => event.preventDefault(), true);
