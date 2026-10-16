// Stage 3: every record today's Swift writes (Web/src/protocol/generated.ts, made from the
// Swift source) is a value of the type made from the schema (wire.ts, quicktype).
import type * as Today from "./generated";
import type * as Schema from "./wire";

type Assignable<From, To> = [From] extends [To] ? true : false;
const checks: [
  Assignable<Today.Agent, Schema.Agent>,
  Assignable<Today.TranscriptEntry, Schema.TranscriptEntry>,
  Assignable<Today.TranscriptPage, Schema.TranscriptPage>,
  Assignable<Today.TurnsPage, Schema.TurnsPage>,
  Assignable<Today.ProjectSummary, Schema.ProjectSummary>,
  Assignable<Today.RuntimeStatus, Schema.RuntimeStatus>,
  Assignable<Today.PermissionRequest, Schema.PermissionRequest>,
  Assignable<Today.ListRequest, Schema.ListRequest>,
  Assignable<Today.StartRequest, Schema.StartRequest>,
  Assignable<Today.PromptRequest, Schema.PromptRequest>,
  Assignable<Today.OptionsResponse, Schema.OptionsResponse>,
] = [true, true, true, true, true, true, true, true, true, true, true];
export default checks;
