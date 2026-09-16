/**
 * Whether a request came from this machine, and not merely from something on
 * this machine forwarding on someone else's behalf.
 *
 * Split out of index.ts so it can be tested directly. The distinction is the
 * whole point of the module: a socket check alone is correct only while the
 * service is reachable *only* over loopback, and that stops being true the
 * moment a reverse proxy is put in front of it.
 */

/** The subset of a request this check reads. */
export interface ForwardableRequest {
  headers: Record<string, unknown>;
  socket: { remoteAddress?: string };
}

const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);

/**
 * True only for a caller that connected to this process itself.
 *
 * A reverse proxy connects from 127.0.0.1 on the caller's behalf, so the
 * socket address cannot distinguish "someone on this machine" from "anyone the
 * proxy will relay for". Put this service behind a Caddy vhost and a
 * socket-only guard does not fail — it INVERTS, handing every tailnet caller
 * whatever it was guarding, while looking exactly as healthy as before.
 *
 * Presence of a forwarding header is therefore treated as proof of relaying.
 * The value is deliberately not parsed: it is caller-appendable, so it cannot
 * be trusted to say who the origin was. A direct caller who forges one only
 * denies itself.
 */
export function isDirectLoopback(req: ForwardableRequest): boolean {
  if (req.headers["x-forwarded-for"] || req.headers["x-forwarded-host"] || req.headers["forwarded"]) {
    return false;
  }
  return LOOPBACK.has(req.socket.remoteAddress ?? "");
}
