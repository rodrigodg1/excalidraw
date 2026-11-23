interface RenderLatexOptions {
  displayMode?: boolean;
  color?: string;
  scale?: number;
}

type Tex2SvgFn = (tex: string, displayMode: boolean) => string;

let texToSvgConverter: Tex2SvgFn | null = null;
let converterPromise: Promise<Tex2SvgFn> | null = null;

function loadMathJaxScript(src: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>(
      `script[data-excalidraw-mathjax="true"]`,
    );
    if (existing) {
      if (existing.dataset.loaded === "true") {
        resolve();
        return;
      }
      existing.addEventListener("load", () => resolve(), { once: true });
      existing.addEventListener(
        "error",
        () => reject(new Error("Falha ao carregar MathJax")),
        { once: true },
      );
      return;
    }

    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    script.dataset.excalidrawMathjax = "true";
    script.onload = () => {
      script.dataset.loaded = "true";
      resolve();
    };
    script.onerror = () => {
      reject(new Error("Falha ao carregar /mathjax/tex-svg.js"));
    };
    document.head.appendChild(script);
  });
}

async function getConverter(): Promise<Tex2SvgFn> {
  if (texToSvgConverter) {
    return texToSvgConverter;
  }
  if (converterPromise) {
    return converterPromise;
  }

  converterPromise = (async () => {
    const win = window as unknown as {
      MathJax?: {
        tex?: Record<string, unknown>;
        svg?: Record<string, unknown>;
        startup?: { typeset?: boolean; promise?: Promise<void> };
        tex2svg?: (tex: string, options?: { display?: boolean }) => Element;
      };
    };

    if (!win.MathJax) {
      win.MathJax = {
        tex: {
          packages: { "[+]": ["ams", "newcommand", "boldsymbol"] },
        },
        svg: {
          fontCache: "none",
        },
        startup: {
          typeset: false,
        },
      };
    }

    await loadMathJaxScript("/mathjax/tex-svg.js");

    if (win.MathJax?.startup?.promise) {
      await win.MathJax.startup.promise;
    }

    if (typeof win.MathJax?.tex2svg !== "function") {
      throw new Error("MathJax tex2svg não foi inicializado");
    }

    const tex2svg = win.MathJax.tex2svg;
    const serializer = new XMLSerializer();
    texToSvgConverter = (input: string, displayMode: boolean) => {
      const container = tex2svg(input, { display: displayMode });
      const svgEl = container.querySelector("svg");
      if (!svgEl) {
        throw new Error("MathJax não gerou um elemento SVG");
      }
      return serializer.serializeToString(svgEl);
    };
    return texToSvgConverter;
  })().catch((err) => {
    converterPromise = null;
    throw err;
  });

  return converterPromise;
}

function normalizeLatexInput(raw: string): {
  tex: string;
  inferredDisplay: boolean;
} {
  const trimmed = raw.trim();
  if (trimmed.startsWith("$$") && trimmed.endsWith("$$") && trimmed.length >= 4) {
    return { tex: trimmed.slice(2, -2).trim(), inferredDisplay: true };
  }
  if (trimmed.startsWith("\\[") && trimmed.endsWith("\\]") && trimmed.length >= 4) {
    return { tex: trimmed.slice(2, -2).trim(), inferredDisplay: true };
  }
  if (trimmed.startsWith("$") && trimmed.endsWith("$") && trimmed.length >= 2) {
    return { tex: trimmed.slice(1, -1).trim(), inferredDisplay: false };
  }
  if (trimmed.startsWith("\\(") && trimmed.endsWith("\\)") && trimmed.length >= 4) {
    return { tex: trimmed.slice(2, -2).trim(), inferredDisplay: false };
  }
  return { tex: trimmed, inferredDisplay: true };
}

export async function renderLatexToSvg(
  rawInput: string,
  options: RenderLatexOptions = {},
): Promise<string> {
  const { tex, inferredDisplay } = normalizeLatexInput(rawInput);
  if (!tex) {
    throw new Error("Digite uma expressão LaTeX");
  }

  const displayMode = options.displayMode ?? inferredDisplay;
  const color = options.color ?? "#1e1e1e";
  const scale = options.scale ?? 1.5;

  const convert = await getConverter();
  let svgHtml = convert(tex, displayMode);

  if (svgHtml.includes("data-mjx-error")) {
    const match = svgHtml.match(/data-mjx-error="([^"]+)"/);
    throw new Error(match ? match[1] : "Erro de sintaxe LaTeX");
  }

  // Convert ex units to crisp px dimensions for standalone SVG rendering on canvas
  const pxPerEx = 12 * scale;
  svgHtml = svgHtml.replace(
    /(width|height)="([0-9.]+)ex"/g,
    (_, attr, val) => `${attr}="${(parseFloat(val) * pxPerEx).toFixed(2)}px"`,
  );

  // Ensure standalone SVG namespace and explicit color
  if (!svgHtml.includes("xmlns=")) {
    svgHtml = svgHtml.replace(
      "<svg ",
      '<svg xmlns="http://www.w3.org/2000/svg" ',
    );
  }
  svgHtml = svgHtml.replace(/currentColor/g, color);

  return svgHtml;
}
