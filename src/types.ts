// ─── Re-exports from core modules for backward compatibility ─────────
//
// Components import from "./types" — this file forwards to the
// platform-agnostic core modules. Keeps the migration zero-impact.

export {
  isUserEchoTag,
} from "./core/protocol";

export {
  echoTagToMediaType,
  echoTagToLabel,
} from "./core/session";

export type {
  DeltaEvent,
  FrameEvent,
  StatusEvent,
} from "./core/protocol";

export type {
  MediaItem,
  StagedMedia,
  Message,
  ToolCall,
  NotificationItem,
  PendingUserPart,
  SessionState,
} from "./core/session";

export {
  createSessionState,
} from "./core/session";

// ─── MIME handling (UI-specific, stays here) ─────────────────────────

const MIME_ALIAS: Record<string, string> = {
  "audio/vnd.wave": "audio/wav",
  "audio/x-wav": "audio/wav",
  "audio/x-mpeg": "audio/mpeg",
  "audio/mpeg3": "audio/mpeg",
  "audio/x-mpeg-3": "audio/mpeg",
  "audio/x-m4a": "audio/mp4",
  "video/x-msvideo": "video/avi",
  "video/x-matroska": "video/mkv",
  "image/jpg": "image/jpeg",
  "image/x-png": "image/png",
  "image/x-ms-bmp": "image/bmp",
  "image/x-icon": "image/vnd.microsoft.icon",
  "application/x-javascript": "text/javascript",
  "text/x-typescript": "text/typescript",
};

function normalizeMime(mime: string, fileName: string): string {
  const lower = mime.toLowerCase();
  if (MIME_ALIAS[lower]) return MIME_ALIAS[lower];
  if (lower.includes("/vnd.")) {
    const ext = fileName.split(".").pop()?.toLowerCase();
    if (ext === "wav") return "audio/wav";
    if (ext === "mp3") return "audio/mpeg";
    if (ext === "mp4") return "video/mp4";
    if (ext === "webm") return "video/webm";
    if (ext === "ogg" || ext === "oga") return "audio/ogg";
    if (ext === "ogv") return "video/ogg";
    if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
    if (ext === "png") return "image/png";
    if (ext === "gif") return "image/gif";
    if (ext === "webp") return "image/webp";
  }
  return mime;
}

export function fileToDataUri(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const dataUri = reader.result as string;
      const comma = dataUri.indexOf(",");
      const header = dataUri.slice(0, comma);
      const rawMime = header.replace("data:", "");
      const normalized = normalizeMime(rawMime, file.name);
      if (normalized !== rawMime) {
        resolve(`data:${normalized};base64,${dataUri.slice(comma + 1)}`);
      } else {
        resolve(dataUri);
      }
    };
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

// ─── Media helpers (UI-specific) ─────────────────────────────────────

export const MEDIA_ACCEPT: Record<string, string> = {
  image: "image/*",
  audio: "audio/*",
  video: "video/*",
  document: ".pdf,.txt,.md,.json,.csv,.xml,.yaml,.yml,.toml,.html,.css,.js,.ts,.rs,.py,.go,.java,.c,.cpp,.h,.hpp",
};

export const MEDIA_ICON: Record<string, string> = {
  image: "🖼", audio: "🎵", video: "🎬", document: "📄",
};

export const uploadItems = [
  { icon: "🖼", label: "Image", accept: MEDIA_ACCEPT.image, type: "image" as const },
  { icon: "🎵", label: "Audio", accept: MEDIA_ACCEPT.audio, type: "audio" as const },
  { icon: "🎬", label: "Video", accept: MEDIA_ACCEPT.video, type: "video" as const },
  { icon: "📄", label: "Document", accept: MEDIA_ACCEPT.document, type: "document" as const },
  { icon: "🔗", label: "From URL", accept: "", type: "url" as const },
];

export function shortName(uri: string, name?: string): string {
  if (name) return name;
  if (uri.startsWith("data:")) {
    const mime = uri.split(";")[0]?.replace("data:", "") || "file";
    return `[${mime}]`;
  }
  try {
    const u = new URL(uri);
    const parts = u.pathname.split("/").filter(Boolean);
    return parts.pop() || uri;
  } catch {
    return uri.length > 40 ? uri.slice(0, 40) + "…" : uri;
  }
}
