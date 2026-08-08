# Client type fixtures

`accepts.ts` must compile. The other three must **not**, and the gate asserts
the error rather than only the failure — a client that rejected every call
would also make them fail, and would be useless.

`rejects-capture-template.ts` is the capturing route's version of that claim:
`/things/{id}` is a template, not a path, and the one thing a caller must not
be able to compile is a request for the literal template.

They import `./client`, which the gate copies from the generated
`contracts/client.ts`, so the fixtures type-check against the client a caller
would actually install.
