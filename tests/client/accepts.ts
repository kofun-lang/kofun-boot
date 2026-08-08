import { createClient } from "./client";
const c = createClient({ baseUrl: "http://127.0.0.1:1" });
export const a = c.get("/hello");
export const b = c.post("/sum", { left: 1, right: 2 });
export const d = c.get("/bench");
export const e = c.post("/bench");
// A capturing route takes the captured segment as a value, not as the
// template: this is the call a caller can actually perform.
const id = 7;
export const f = c.get(`/things/${id}`);
