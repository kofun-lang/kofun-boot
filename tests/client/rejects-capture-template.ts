import { createClient } from "./client";
const c = createClient({ baseUrl: "http://127.0.0.1:1" });
// The template itself is not a callable path: `{id}` is a hole the dispatcher
// never matches, so a client that accepted it would compile a request that is
// always a 404.
export const bad = c.get("/things/{id}");
