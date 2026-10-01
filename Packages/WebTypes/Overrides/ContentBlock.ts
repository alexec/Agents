// uses: ContentBlock.Annotations
/**
 * ContentBlock (ACP/ContentBlock.swift): the protocol's own block shapes, as sent. A block of a
 * kind this build doesn't know is written back as it came, so any other `type` may arrive.
 */
export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; mimeType: string; data: string; uri?: string }
  | { type: "audio"; mimeType: string; data: string }
  | {
      type: "resource_link";
      uri: string;
      name: string;
      mimeType?: string;
      size?: number;
      annotations?: ContentBlockAnnotations;
    }
  | {
      type: "resource";
      resource: { uri: string; text?: string; blob?: string; mimeType?: string };
      annotations?: ContentBlockAnnotations;
    };
