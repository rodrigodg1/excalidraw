import {
  fileOpen as _fileOpen,
  fileSave as _fileSave,
  supported as nativeFileSystemSupported,
} from "browser-fs-access";

import { MIME_TYPES } from "@excalidraw/common";

import { normalizeFile } from "./blob";

type FILE_EXTENSION = Exclude<keyof typeof MIME_TYPES, "binary">;

interface DesktopFileHandle extends FileSystemFileHandle {
  path: string;
}

interface DesktopBridgeMessageHandler {
  postMessage: (message: Record<string, unknown>) => void;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        excalidrawDesktop?: DesktopBridgeMessageHandler;
      };
    };
    __excalidrawDesktopCallbacks?: Map<
      string,
      { resolve: (value: any) => void; reject: (reason?: any) => void }
    >;
    __excalidrawDesktopResolve?: (
      requestId: string,
      result: any,
      error?: string | null,
    ) => void;
  }
}

const getDesktopBridge = (): DesktopBridgeMessageHandler | null => {
  if (typeof window === "undefined") {
    return null;
  }
  return window.webkit?.messageHandlers?.excalidrawDesktop ?? null;
};

const invokeDesktopBridge = <T = any>(
  action: string,
  payload: Record<string, unknown>,
): Promise<T> => {
  const bridge = getDesktopBridge();
  if (!bridge) {
    return Promise.reject(new Error("Desktop bridge not available"));
  }

  if (!window.__excalidrawDesktopCallbacks) {
    window.__excalidrawDesktopCallbacks = new Map();
  }
  if (!window.__excalidrawDesktopResolve) {
    window.__excalidrawDesktopResolve = (requestId, result, error) => {
      const cb = window.__excalidrawDesktopCallbacks?.get(requestId);
      if (!cb) {
        return;
      }
      window.__excalidrawDesktopCallbacks?.delete(requestId);
      if (error) {
        cb.reject(new Error(error));
      } else {
        cb.resolve(result);
      }
    };
  }

  const requestId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return new Promise<T>((resolve, reject) => {
    window.__excalidrawDesktopCallbacks!.set(requestId, { resolve, reject });
    bridge.postMessage({ requestId, action, ...payload });
  });
};

const blobToBase64 = async (blob: Blob): Promise<string> => {
  const buffer = await blob.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
};

const base64ToUint8Array = (base64: string): Uint8Array => {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
};

const createDesktopFileHandle = (
  name: string,
  path: string,
): DesktopFileHandle => {
  const handle = {
    kind: "file" as const,
    name,
    path,
    isSameEntry: async (other: FileSystemHandle) =>
      (other as DesktopFileHandle)?.path === path,
    getFile: async () => {
      throw new Error("getFile is not implemented on DesktopFileHandle");
    },
    createWritable: async () => {
      let chunks: BlobPart[] = [];
      return {
        write: async (data: FileSystemWriteChunkType) => {
          if (
            data &&
            typeof data === "object" &&
            "type" in data &&
            data.type === "write" &&
            "data" in data &&
            data.data !== undefined
          ) {
            chunks.push(data.data as BlobPart);
          } else {
            chunks.push(data as BlobPart);
          }
        },
        close: async () => {
          const blob = new Blob(chunks);
          chunks = [];
          const contentBase64 = await blobToBase64(blob);
          const res = await invokeDesktopBridge<{
            cancelled?: boolean;
            path?: string;
            name?: string;
          }>("saveFile", {
            suggestedName: name,
            contentBase64,
            path,
          });
          if (res?.cancelled) {
            throw new DOMException(
              "The user aborted a request.",
              "AbortError",
            );
          }
        },
        abort: async () => {
          chunks = [];
        },
      };
    },
  };
  return handle as unknown as DesktopFileHandle;
};

export const fileOpen = async <M extends boolean | undefined = false>(opts: {
  extensions?: FILE_EXTENSION[];
  description: string;
  multiple?: M;
}): Promise<M extends false | undefined ? File : File[]> => {
  // an unsafe TS hack, alas not much we can do AFAIK
  type RetType = M extends false | undefined ? File : File[];

  const mimeTypes = opts.extensions?.reduce((mimeTypes, type) => {
    mimeTypes.push(MIME_TYPES[type]);

    return mimeTypes;
  }, [] as string[]);

  const extensions = opts.extensions?.reduce((acc, ext) => {
    if (ext === "jpg") {
      return acc.concat(".jpg", ".jpeg");
    }
    return acc.concat(`.${ext}`);
  }, [] as string[]);

  if (getDesktopBridge()) {
    const res = await invokeDesktopBridge<{
      cancelled?: boolean;
      files?: Array<{ name: string; path: string; contentBase64: string }>;
    }>("openFile", {
      extensions: extensions?.map((e) => e.replace(/^\./, "")) ?? [],
      multiple: opts.multiple ?? false,
    });
    if (res?.cancelled || !res?.files?.length) {
      throw new DOMException("The user aborted a request.", "AbortError");
    }
    const openedFiles = await Promise.all(
      res.files.map(async (item) => {
        const bytes = base64ToUint8Array(item.contentBase64);
        const file = new File([bytes.buffer as ArrayBuffer], item.name);
        const normalized = await normalizeFile(file);
        (normalized as File & { handle?: FileSystemFileHandle }).handle =
          createDesktopFileHandle(item.name, item.path);
        return normalized;
      }),
    );
    return (opts.multiple ? openedFiles : openedFiles[0]) as RetType;
  }

  const files = await _fileOpen({
    description: opts.description,
    extensions,
    mimeTypes,
    multiple: opts.multiple ?? false,
  });

  if (Array.isArray(files)) {
    return (await Promise.all(
      files.map((file) => normalizeFile(file)),
    )) as RetType;
  }
  return (await normalizeFile(files)) as RetType;
};

export const fileSave = async (
  blob: Blob | Promise<Blob>,
  opts: {
    /** supply without the extension */
    name: string;
    /** file extension */
    extension: FILE_EXTENSION;
    mimeTypes?: string[];
    description: string;
    /** existing FileSystemFileHandle */
    fileHandle?: FileSystemFileHandle | null;
  },
) => {
  if (getDesktopBridge()) {
    const resolvedBlob = await Promise.resolve(blob);
    const contentBase64 = await blobToBase64(resolvedBlob);
    const existingPath =
      (opts.fileHandle as DesktopFileHandle | null | undefined)?.path ?? null;

    const res = await invokeDesktopBridge<{
      cancelled?: boolean;
      path?: string;
      name?: string;
    }>("saveFile", {
      suggestedName: `${opts.name}.${opts.extension}`,
      contentBase64,
      path: existingPath,
    });

    if (res?.cancelled || !res?.path || !res?.name) {
      throw new DOMException("The user aborted a request.", "AbortError");
    }

    return createDesktopFileHandle(res.name, res.path);
  }

  return _fileSave(
    blob,
    {
      fileName: `${opts.name}.${opts.extension}`,
      description: opts.description,
      extensions: [`.${opts.extension}`],
      mimeTypes: opts.mimeTypes,
    },
    opts.fileHandle,
    false,
  );
};

export const loadLastDesktopFile = async (): Promise<File | null> => {
  if (!getDesktopBridge()) {
    return null;
  }
  try {
    const res = await invokeDesktopBridge<{
      found?: boolean;
      name?: string;
      path?: string;
      contentBase64?: string;
    }>("getLastFile", {});
    if (!res?.found || !res.name || !res.path || !res.contentBase64) {
      return null;
    }
    const bytes = base64ToUint8Array(res.contentBase64);
    const file = new File([bytes.buffer as ArrayBuffer], res.name);
    const normalized = await normalizeFile(file);
    (normalized as File & { handle?: FileSystemFileHandle }).handle =
      createDesktopFileHandle(res.name, res.path);
    return normalized;
  } catch {
    return null;
  }
};

export { nativeFileSystemSupported };
