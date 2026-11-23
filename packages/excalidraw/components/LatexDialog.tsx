import React, { useEffect, useRef, useState } from "react";
import { THEME, viewportCoordsToSceneCoords } from "@excalidraw/common";

import { renderLatexToSvg } from "../latex";

import { useApp, useExcalidrawAppState, useExcalidrawSetAppState } from "./App";
import { Dialog } from "./Dialog";
import { FilledButton } from "./FilledButton";

import "./LatexDialog.scss";

const SNIPPETS: Array<{ label: string; tex: string }> = [
  { label: "a/b", tex: "\\frac{a}{b}" },
  { label: "√x", tex: "\\sqrt{x}" },
  { label: "∑", tex: "\\sum_{i=1}^{n} x_i" },
  { label: "∫", tex: "\\int_{a}^{b} f(x)\\,dx" },
  { label: "lim", tex: "\\lim_{x \\to \\infty} " },
  { label: "Matriz", tex: "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}" },
  { label: "α β θ π", tex: "\\alpha, \\beta, \\theta, \\pi" },
  { label: "∈ ∀ ∃", tex: "\\forall x \\in \\mathbb{R}, \\exists y" },
];

const COLORS = [
  { label: "Preto", value: "#1e1e1e" },
  { label: "Branco", value: "#ffffff" },
  { label: "Azul", value: "#1971c2" },
  { label: "Vermelho", value: "#e03131" },
  { label: "Verde", value: "#2f9e44" },
];

export const LatexDialog = () => {
  const app = useApp();
  const appState = useExcalidrawAppState();
  const setAppState = useExcalidrawSetAppState();

  const defaultColor = appState.theme === THEME.DARK ? "#ffffff" : "#1e1e1e";
  const [tex, setTex] = useState(
    "\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}",
  );
  const [color, setColor] = useState(defaultColor);
  const [svgPreview, setSvgPreview] = useState<string>("");
  const [error, setError] = useState<string | null>(null);
  const [isRendering, setIsRendering] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    textareaRef.current?.focus();
    textareaRef.current?.select();
  }, []);

  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(async () => {
      if (!tex.trim()) {
        setSvgPreview("");
        setError(null);
        return;
      }
      setIsRendering(true);
      try {
        const svg = await renderLatexToSvg(tex, { color, scale: 1.6 });
        if (!cancelled) {
          setSvgPreview(svg);
          setError(null);
        }
      } catch (err: any) {
        if (!cancelled) {
          setSvgPreview("");
          setError(err?.message || "Erro ao renderizar LaTeX");
        }
      } finally {
        if (!cancelled) {
          setIsRendering(false);
        }
      }
    }, 150);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [tex, color]);

  const closeDialog = () => {
    setAppState({ openDialog: null });
  };

  const handleInsert = async () => {
    if (!tex.trim() || error) {
      return;
    }
    try {
      const svg =
        svgPreview || (await renderLatexToSvg(tex, { color, scale: 1.6 }));
      const file = new File([svg], "latex-formula.svg", {
        type: "image/svg+xml",
      });
      const { x: sceneX, y: sceneY } = viewportCoordsToSceneCoords(
        {
          clientX: appState.offsetLeft + appState.width / 2,
          clientY: appState.offsetTop + appState.height / 2,
        },
        appState,
      );
      closeDialog();
      await app.insertImages([file], sceneX, sceneY);
    } catch (err: any) {
      setError(err?.message || "Erro ao inserir fórmula");
    }
  };

  const insertSnippet = (snippet: string) => {
    const el = textareaRef.current;
    if (!el) {
      setTex((prev) => prev + snippet);
      return;
    }
    const start = el.selectionStart ?? tex.length;
    const end = el.selectionEnd ?? tex.length;
    const next = tex.slice(0, start) + snippet + tex.slice(end);
    setTex(next);
    requestAnimationFrame(() => {
      el.focus();
      const pos = start + snippet.length;
      el.setSelectionRange(pos, pos);
    });
  };

  return (
    <Dialog
      title="LaTeX Math"
      onCloseRequest={closeDialog}
      size="regular"
    >
      <div className="LatexDialog">
        <div className="LatexDialog__snippets">
          {SNIPPETS.map((s) => (
            <button
              key={s.label}
              type="button"
              className="LatexDialog__snippet"
              onClick={() => insertSnippet(s.tex)}
              title={s.tex}
            >
              {s.label}
            </button>
          ))}
        </div>

        <textarea
          ref={textareaRef}
          className="LatexDialog__textarea"
          value={tex}
          onChange={(e) => setTex(e.target.value)}
          placeholder="Ex: E = mc^2 ou \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"
          onKeyDown={(e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
              e.preventDefault();
              handleInsert();
            }
          }}
        />

        <div className="LatexDialog__controls">
          <div className="LatexDialog__colors">
            <span>Cor:</span>
            {COLORS.map((c) => (
              <button
                key={c.value}
                type="button"
                className={`LatexDialog__color-btn ${
                  color === c.value ? "LatexDialog__color-btn--active" : ""
                }`}
                style={{ backgroundColor: c.value }}
                title={c.label}
                aria-label={c.label}
                onClick={() => setColor(c.value)}
              />
            ))}
          </div>
        </div>

        <div
          className="LatexDialog__preview"
          style={{
            backgroundColor:
              color === "#ffffff" ? "#1e1e1e" : undefined,
          }}
        >
          {error ? (
            <div className="LatexDialog__error">{error}</div>
          ) : svgPreview ? (
            <div dangerouslySetInnerHTML={{ __html: svgPreview }} />
          ) : (
            <span className="LatexDialog__hint">
              {isRendering ? "Renderizando..." : "Pré-visualização"}
            </span>
          )}
        </div>

        <div className="LatexDialog__actions">
          <span className="LatexDialog__hint">Cmd/Ctrl + Enter para inserir</span>
          <div className="LatexDialog__buttons">
            <FilledButton
              size="medium"
              variant="outlined"
              color="muted"
              label="Cancelar"
              onClick={closeDialog}
            />
            <FilledButton
              size="medium"
              label="Inserir no canvas"
              onClick={handleInsert}
              disabled={!svgPreview || !!error}
            />
          </div>
        </div>
      </div>
    </Dialog>
  );
};
