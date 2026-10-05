// A picture from beside a Markdown page, drawn from bytes the host read (#258). The address
// never becomes the image's src: a blob stays inside the page, which is what the CSP allows.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";

export function LocalPicture({ path, alt, revision, read }: {
  path: string;
  alt: string;
  revision: number;
  read: (path: string) => Promise<{ bytes: Uint8Array; type: string } | null>;
}) {
  const src = useSignal<string | null>(null);
  const failed = useSignal(false);
  const readRef = useRef(read);
  readRef.current = read;
  useEffect(() => {
    let current = true;
    let made: string | null = null;
    failed.value = false;
    src.value = null;
    void readRef.current(path).then(
      (got) => {
        if (!current) return;
        if (!got) { failed.value = true; return; }
        made = URL.createObjectURL(new Blob([got.bytes as BlobPart], { type: got.type }));
        src.value = made;
      },
      () => { if (current) failed.value = true; },
    );
    return () => {
      current = false;
      if (made) URL.revokeObjectURL(made);
    };
  }, [path, revision]);
  if (failed.value) return <span class="image-placeholder">{alt ? `[image: ${alt}]` : "[image]"}</span>;
  return src.value ? <img class="page-picture" src={src.value} alt={alt || path.split("/").pop() || "Image"} /> : null;
}
