"use strict";

const mathOptions = Object.freeze({
  throwOnError: false,
  errorColor: "#a11",
  strict: "warn",
  trust: false,
  maxSize: 50,
  maxExpand: 1000,
  output: "html"
});

const md = window.markdownit({
  html: false,
  linkify: false,
  typographer: false,
  breaks: false
});

let activePipeToken = null;

md.use(window.mdItPluginTex.tex, {
  delimiters: "all",
  mathFence: true,
  allowInlineWithSpace: false,
  render(content, displayMode) {
    const latex = activePipeToken
      ? content.split(activePipeToken).join("|")
      : content;
    const className = displayMode ? "math-display" : "math-inline";
    if (latex.length > 4096) {
      return `<span class="${className} math-error">${md.utils.escapeHtml(latex)}</span>`;
    }
    try {
      return `<span class="${className}">${window.katex.renderToString(latex, {
        ...mathOptions,
        displayMode
      })}</span>`;
    } catch (_) {
      const escaped = md.utils.escapeHtml(latex);
      return `<span class="${className} math-error">${escaped}</span>`;
    }
  }
});

// Images and raw HTML are out of product scope. Keep only image alt text;
// markdown-it already escapes raw HTML because `html` is false.
md.renderer.rules.image = (tokens, index) => md.utils.escapeHtml(tokens[index].content || "");
md.renderer.rules.link_open = () => "<span class=\"markdown-link\">";
md.renderer.rules.link_close = () => "</span>";

// markdown-it's table rule splits on every raw pipe before its inline code
// rule runs. Model answers commonly contain `a|b` in a cell without escaping
// the pipe, which would otherwise shift columns and silently drop the last
// cell. Temporarily replace pipes inside matching backtick spans, then restore
// them only after markdown-it has produced escaped HTML.
function renderMarkdown(source) {
  let pipeToken = "\uE000CODEX_TABLE_CODE_PIPE\uE001";
  while (source.includes(pipeToken)) pipeToken += "_";

  const isEscaped = index => {
    let slashCount = 0;
    for (let i = index - 1; i >= 0 && source[i] === "\\"; i--) slashCount += 1;
    return slashCount % 2 === 1;
  };
  const findClosing = (delimiter, from) => {
    let candidate = source.indexOf(delimiter, from);
    while (candidate >= 0 && isEscaped(candidate)) {
      candidate = source.indexOf(delimiter, candidate + delimiter.length);
    }
    return candidate;
  };

  let protectedSource = "";
  let cursor = 0;
  while (cursor < source.length) {
    if (source[cursor] === "`") {
      let delimiterEnd = cursor;
      while (source[delimiterEnd] === "`") delimiterEnd += 1;
      const delimiter = source.slice(cursor, delimiterEnd);
      const closing = source.indexOf(delimiter, delimiterEnd);
      if (closing < 0) {
        protectedSource += source.slice(cursor);
        break;
      }
      protectedSource += delimiter;
      protectedSource += source.slice(delimiterEnd, closing).replaceAll("|", pipeToken);
      protectedSource += delimiter;
      cursor = closing + delimiter.length;
      continue;
    }

    let mathMatch = null;
    for (const delimiter of [
      { open: "$$", close: "$$", inline: false },
      { open: "\\[", close: "\\]", inline: false },
      { open: "\\(", close: "\\)", inline: true },
      { open: "$", close: "$", inline: true }
    ]) {
      if (!source.startsWith(delimiter.open, cursor) || isEscaped(cursor)) continue;
      const contentStart = cursor + delimiter.open.length;
      const closing = findClosing(delimiter.close, contentStart);
      if (closing < 0) continue;
      const content = source.slice(contentStart, closing);
      if (delimiter.inline && (
        content.length === 0
        || content.includes("\n")
        || /^\s|\s$/.test(content)
      )) continue;
      mathMatch = { ...delimiter, contentStart, closing };
      break;
    }
    if (mathMatch) {
      protectedSource += mathMatch.open;
      protectedSource += source
        .slice(mathMatch.contentStart, mathMatch.closing)
        .replaceAll("|", pipeToken);
      protectedSource += mathMatch.close;
      cursor = mathMatch.closing + mathMatch.close.length;
      continue;
    }

    protectedSource += source[cursor++];
  }

  activePipeToken = pipeToken;
  try {
    return md.render(protectedSource).split(pipeToken).join("|");
  } finally {
    activePipeToken = null;
  }
}

function renderTaskMarkers(root) {
  for (const item of root.querySelectorAll("li")) {
    const first = item.firstChild;
    if (!first || first.nodeType !== Node.TEXT_NODE) continue;
    const match = first.textContent.match(/^\[([ xX])\]\s+/);
    if (!match) continue;
    first.textContent = `${match[1] === " " ? "☐" : "☑"} ${first.textContent.slice(match[0].length)}`;
  }
}

function wrapTables(root) {
  for (const table of Array.from(root.querySelectorAll("table"))) {
    const wrapper = document.createElement("div");
    wrapper.className = "table-wrap";
    table.replaceWith(wrapper);
    wrapper.appendChild(table);
  }
}

function fitWideTables(root) {
  for (const wrapper of root.querySelectorAll(".table-wrap")) {
    const table = wrapper.querySelector(":scope > table");
    if (!table) continue;
    table.classList.remove("table-fixed");
    if (table.scrollWidth > wrapper.clientWidth + 1) {
      table.classList.add("table-fixed");
    }
  }
}

function fitWideMath(root) {
  for (const container of root.querySelectorAll(".math-display")) {
    const katex = container.querySelector(".katex");
    if (!katex) continue;
    katex.classList.remove("math-fit");
    katex.style.transform = "";
    container.style.height = "";
    const available = container.clientWidth;
    const required = katex.scrollWidth;
    if (required > available && available > 0) {
      const scale = available / required;
      katex.classList.add("math-fit");
      katex.style.transform = `scale(${scale})`;
      container.style.height = `${Math.ceil(katex.getBoundingClientRect().height)}px`;
    }
  }
}

function resetViewport() {
  window.scrollTo(0, 0);
}

async function renderTranscript(messages) {
  const transcript = document.getElementById("transcript");
  transcript.replaceChildren();
  const fragment = document.createDocumentFragment();

  for (const message of messages) {
    const article = document.createElement("article");
    article.className = message.role === "user" ? "message user" : "message assistant";
    // Only parser-produced markup reaches innerHTML. User HTML is escaped.
    article.innerHTML = renderMarkdown(String(message.text || ""));
    renderTaskMarkers(article);
    wrapTables(article);
    fragment.appendChild(article);
  }

  transcript.appendChild(fragment);
  await document.fonts.ready;
  fitWideTables(transcript);
  fitWideMath(transcript);
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const transcriptBottom = window.scrollY + transcript.getBoundingClientRect().bottom;
  return Math.ceil(transcriptBottom + 64);
}

window.codexRenderer = Object.freeze({
  renderTranscript,
  resetViewport
});
