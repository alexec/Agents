// Typed calls over the generated protocol (071, research R6). The wire client (wire/link.ts)
// sends these; nothing here touches a socket.
import type { Methods, Notifications } from "./generated";
import { MethodTarget } from "./generated";

export type Method = keyof Methods;
export type Params<M extends Method> = Methods[M]["params"];
export type Result<M extends Method> = Methods[M]["result"];
export type Notification = keyof Notifications;
export type NotificationParams<N extends Notification> = Notifications[N];

/** Whether a method goes to a host, with `h`, or to the control plane itself. */
export function targetOf(method: Method): "host" | "control" {
  return MethodTarget[method];
}

/** The one thing every caller needs: send `method` to `host` (or the control plane). */
export interface Caller {
  call<M extends Method>(method: M, params: Params<M>, host?: string): Promise<Result<M>>;
}
