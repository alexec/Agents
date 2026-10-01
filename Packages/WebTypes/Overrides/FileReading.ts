// uses: FileStamp
/** FileReading (Model/FileReading.swift), as its encode(to:) writes it: one shape per `kind`. */
export type FileReading =
  | { kind: "text"; stamp: FileStamp; text: string; isTruncated: boolean; size: number }
  | { kind: "image"; stamp: FileStamp; bytes: Base64; describedAs: string }
  | { kind: "other"; stamp: FileStamp; describedAs: string; size: number }
  | { kind: "unchanged"; stamp: FileStamp };
