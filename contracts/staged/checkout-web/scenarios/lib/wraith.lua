-- lib/wraith.lua -- canonical wraith intent-contract helper, API major 1.
--
-- This file is the SINGLE SOURCE OF TRUTH for the helper bytes embedded in
-- every generated `.wic` package. Its SHA-256 is pinned in the package
-- manifest under `helpers["scenarios/lib/wraith.lua"]`; `wraith contract verify` /
-- `wraith contract accept` reject any package whose helper digest does not
-- match the canonical helper for its declared `wraith_helper_api` major.
--
-- DO NOT EDIT casually: any byte change here changes the canonical digest and
-- invalidates every previously generated package's pin. Changes must move in
-- lockstep with the `wraith_helper_api` major and the golden digest test in
-- `helper.rs`.
--
-- Sandbox constraints (sigil luau sandbox, proposal §5):
--   * `os` is nil -- there is no `os.getenv`.
--   * `math.random` is an error-throwing stub.
--   * The ONLY ambient primitives are `sigil.env(key)` and `sigil.run_id()`,
--     plus the `sigil.get/post/put/patch/delete` HTTP verbs.
-- The helper therefore derives all session/uniqueness state from those two
-- primitives alone -- never from entropy that does not exist in the sandbox.

local wraith = {}

-- Helper API major. Versions BOTH the Lua surface and the wire conventions
-- (`X-Wraith-Session` header, `WRAITH_SESSION_BASE` / `WRAITH_AUTH_*` env
-- names). Additive changes do not bump it; any breaking change does.
wraith.api = 1

-- ---------------------------------------------------------------------------
-- Session derivation (proposal §5 "State isolation")
-- ---------------------------------------------------------------------------

-- Extract the scenario-stable component of a sigil run id.
-- `sigil.run_id()` returns "<service>:<scenario_id>:<seed>". The middle
-- `scenario_id` is per-scenario but stable across invocations under bare
-- `sigil run`; we key isolation on it. The full id is used verbatim if it does
-- not match the expected 3-part shape, so the function degrades safely rather
-- than collapsing distinct scenarios onto one component.
function wraith._scenario_component(run_id)
  if run_id == nil then
    return "scenario"
  end
  -- Split on ':' into at most the service / scenario / seed parts.
  local first = string.find(run_id, ":", 1, true)
  if first == nil then
    return run_id
  end
  local second = string.find(run_id, ":", first + 1, true)
  if second == nil then
    -- Only one separator: treat everything after it as the scenario part.
    return string.sub(run_id, first + 1)
  end
  return string.sub(run_id, first + 1, second - 1)
end

-- Derive the per-scenario session id.
--   * Wrapped flow (`wraith contract verify`): WRAITH_SESSION_BASE is a fresh
--     per-invocation UUID, so the namespace is fresh per run AND per scenario.
--   * Unwrapped flow (bare `sigil run`): no base env; falls back to the
--     scenario component alone -- distinct per scenario, stable across runs.
function wraith._derive_session_id()
  local base = sigil.env("WRAITH_SESSION_BASE")
  local scenario_part = wraith._scenario_component(sigil.run_id())
  if base then
    return base .. ":" .. scenario_part
  end
  return scenario_part
end

-- Computed once at module load; the sandbox loads a fresh module per scenario.
local session_id = wraith._derive_session_id()

-- The current per-scenario session id (debugging / hand-authored use).
function wraith.session_id()
  return session_id
end

-- ---------------------------------------------------------------------------
-- Auth injection (proposal §5 "Auth injection", Pact request-filter pattern)
-- ---------------------------------------------------------------------------

-- Mutate `headers` in place, adding the injected auth header when the
-- environment supplies one. Against the composite twin in
-- `wraith contract verify` these env vars are absent and nothing changes;
-- in provider CI they carry the real credential (bare-key `--env` form so the
-- secret never lands on argv). Returns the same table for chaining.
--
-- Precedence: the injected auth header takes the env-named key
-- `WRAITH_AUTH_HEADER`; if a caller's own headers table also carries that key
-- the injected value wins (auth injection is the filter point -- see
-- `merge_opts`, which overlays the injected headers last).
--
-- Partial-config guard: supplying exactly ONE of the pair is always an
-- operator error (a typo'd or half-set CI secret). Injecting nothing silently
-- would surface later as an unexplained 401 misread as a provider break, so we
-- fail loudly and name the missing variable instead.
local function inject_auth(headers)
  local h = sigil.env("WRAITH_AUTH_HEADER")
  local v = sigil.env("WRAITH_AUTH_VALUE")
  if h and not v then
    error(
      "wraith auth injection: WRAITH_AUTH_HEADER is set but WRAITH_AUTH_VALUE "
        .. "is missing; set WRAITH_AUTH_VALUE (bare-key --env form) or unset both"
    )
  end
  if v and not h then
    error(
      "wraith auth injection: WRAITH_AUTH_VALUE is set but WRAITH_AUTH_HEADER "
        .. "is missing; set WRAITH_AUTH_HEADER (e.g. --env WRAITH_AUTH_HEADER=Authorization) "
        .. "or unset both"
    )
  end
  if h and v then
    headers[h] = v
  end
  return headers
end

-- ---------------------------------------------------------------------------
-- Request options (proposal §5 "request_opts")
-- ---------------------------------------------------------------------------

-- The session-injection options table. Exported as an escape hatch for
-- hand-authored scenarios that call `sigil.*` directly:
--   sigil.post(path, body, opts ∪ wraith.request_opts())
function wraith.request_opts()
  return {
    headers = inject_auth({
      ["X-Wraith-Session"] = session_id,
    }),
  }
end

-- Shallow-merge caller `opts` with the helper's request options. Caller keys
-- win for everything except `headers`, where the two header tables are merged
-- and the helper's X-Wraith-Session / auth headers take precedence (they are
-- load-bearing for isolation and must not be silently overridden).
local function merge_opts(opts)
  local merged = {}
  if opts ~= nil then
    for k, v in pairs(opts) do
      merged[k] = v
    end
  end
  local injected = wraith.request_opts()
  local headers = {}
  if opts ~= nil and type(opts.headers) == "table" then
    for k, v in pairs(opts.headers) do
      headers[k] = v
    end
  end
  for k, v in pairs(injected.headers) do
    headers[k] = v
  end
  merged.headers = headers
  return merged
end

-- ---------------------------------------------------------------------------
-- Session-isolated HTTP wrappers (proposal §5 "wrappers")
-- ---------------------------------------------------------------------------

function wraith.get(path, opts)
  return sigil.get(path, merge_opts(opts))
end

function wraith.post(path, body, opts)
  return sigil.post(path, body, merge_opts(opts))
end

function wraith.put(path, body, opts)
  return sigil.put(path, body, merge_opts(opts))
end

function wraith.patch(path, body, opts)
  return sigil.patch(path, body, merge_opts(opts))
end

function wraith.delete(path, opts)
  return sigil.delete(path, merge_opts(opts))
end

-- ---------------------------------------------------------------------------
-- Uniqueness affordance (proposal §5 "wraith.unique", Q17 guard)
-- ---------------------------------------------------------------------------

-- The per-run uniqueness suffix. Incorporates WRAITH_SESSION_BASE when present
-- (fresh per wrapped run) and falls back to the scenario component otherwise
-- (deterministic per scenario against the twin).
function wraith._suffix()
  local base = sigil.env("WRAITH_SESSION_BASE")
  if base then
    return base
  end
  return wraith._scenario_component(sigil.run_id())
end

-- Return `tag .. "-" .. suffix`, a value unique enough to avoid 409/422 from a
-- real provider that rejects duplicate client-supplied unique fields
-- (idempotency keys, generated emails) on a second run.
--
-- Runtime guard (Q17): a real-provider run is detectable as
-- WRAITH_AUTH_HEADER/WRAITH_AUTH_VALUE set while WRAITH_SESSION_BASE is absent.
-- In that case the deterministic fallback would collide one run later and the
-- provider's 409 would be misclassified as a provider break. Raise an
-- immediate, actionable error instead.
function wraith.unique(tag)
  local auth_h = sigil.env("WRAITH_AUTH_HEADER")
  local auth_v = sigil.env("WRAITH_AUTH_VALUE")
  local base = sigil.env("WRAITH_SESSION_BASE")
  if auth_h and auth_v and not base then
    error(
      "wraith.unique: real-provider run without WRAITH_SESSION_BASE; "
        .. "set it to a fresh value per run "
        .. "(e.g. --env WRAITH_SESSION_BASE=$(uuidgen))"
    )
  end
  return tag .. "-" .. wraith._suffix()
end

-- ---------------------------------------------------------------------------
-- Default volatile field/header ignore list (proposal §5 "default_volatile_paths")
-- ---------------------------------------------------------------------------

-- The default ignore list for `wraith.assert_matches`. Mirrors wraith's
-- conformance volatile/timestamp heuristics: volatile response headers plus
-- common timestamp/counter leaf-name patterns. v0 list -- extend at the
-- helper-API major boundary, never in place.
function wraith.default_volatile_paths()
  return {
    -- Volatile response headers (case-insensitive on the wire).
    "Date",
    "Server",
    "X-Request-Id",
    "Request-Id",
    "X-Amz-Request-Id",
    "X-Amzn-RequestId",
    "CF-Ray",
    "CF-Cache-Status",
    "X-Runtime",
    "X-Served-By",
    "ETag",
    -- Timestamp leaf-name suffix/exact patterns.
    "*_at",
    "*_date",
    "*_time",
    "*_timestamp",
    "created",
    "updated",
    "modified",
    "expires",
    "timestamp",
  }
end

-- ---------------------------------------------------------------------------
-- Package data module (evidence + provenance, proposal §5/§9)
-- ---------------------------------------------------------------------------
-- The canonical helper bytes are digest-pinned and IDENTICAL across every
-- `.wic`, so per-package evidence and manifest provenance cannot be baked into
-- this file. They are instead emitted by the generator into a sibling
-- package-local data module, `scenarios/lib/wraith_data.lua`, which `return`s a
-- pure-Lua table:
--
--   return {
--     evidence_mode  = "include_scrubbed_excerpts", -- or "reference_only" / "include_recordings"
--     symbols        = { ["$charge_id_1"] = "ch_abc" },
--     base_digest    = "sha256:...",
--     overlay_digest = "sha256:...",
--     exchanges      = {
--       ["create-charge"] = {
--         request  = { method = "POST", path = "/charges", headers = {...}, body = {...} },
--         response = { status = 200, headers = {...}, body = {...} },
--       },
--     },
--   }
--
-- WHY a require'd module and not io.open: the sigil scenario sandbox NILs `io`
-- and `os` (no `os.getenv`, no `io.open`) and stubs `load`. Its ONLY
-- file-reading primitive is `require('lib.<name>')`, which the sandbox resolves
-- to the package-local `lib/<name>.lua` and which already rejects `..` /
-- absolute / cross-directory module names (path-escape is a runtime error at
-- the sandbox boundary). Loading evidence through `require` therefore reads a
-- "package-local file only" (proposal §9) WITHOUT walking the caller's
-- filesystem, and keeps THIS helper's bytes deterministic (the per-package data
-- lives in the separate, separately-digestible data module).
--
-- The load is pcall-guarded: a `reference_only` package or a bare `sigil run`
-- carries no data module, so `_data` is the empty table and every evidence
-- function takes its mode-gated "unavailable" path quietly.
local function load_package_data()
  local ok, mod = pcall(require, "lib.wraith_data")
  if ok and type(mod) == "table" then
    return mod
  end
  return {}
end

local _data = load_package_data()

-- The package evidence mode (proposal §9). Defaults to "reference_only" -- the
-- mode that carries no exchanges -- so an absent/old data module degrades to
-- the safe, evidence-free behavior rather than erroring.
local function evidence_mode()
  local m = _data.evidence_mode
  if type(m) == "string" then
    return m
  end
  return "reference_only"
end

-- True when the current mode embeds replayable exchanges under `evidence/`.
local function mode_has_exchanges()
  local m = evidence_mode()
  return m == "include_scrubbed_excerpts" or m == "include_recordings"
end

-- ---------------------------------------------------------------------------
-- Evidence access (proposal §5 "Evidence access", §9 evidence modes)
-- ---------------------------------------------------------------------------

-- Read a package-local scrubbed exchange by name.
--
-- Mode gating (proposal §9 table):
--   * reference_only           -> returns nil (no evidence is carried).
--   * include_scrubbed_excerpts / include_recordings -> returns the named
--     exchange table, or errors naming the missing exchange.
--
-- Boundary: `name` is a flat exchange key looked up in the package data module;
-- it is never a path. A `name` that smells like a path traversal (`..`, `/`,
-- `\`, or a leading drive/`~`) is a runtime error, mirroring sigil's own
-- require/upload path-escape guards -- the helper never walks the filesystem
-- outside the package root.
function wraith.exchange(name)
  if type(name) ~= "string" then
    error("wraith.exchange(name): name must be a string")
  end
  if
    string.find(name, "..", 1, true)
    or string.find(name, "/", 1, true)
    or string.find(name, "\\", 1, true)
    or string.sub(name, 1, 1) == "~"
  then
    error(
      "wraith.exchange(" .. name .. "): exchange names are package-local keys, "
        .. "not paths; path traversal is not allowed"
    )
  end
  if not mode_has_exchanges() then
    -- reference_only: the contract carries no exchanges. Per proposal §9 this
    -- returns nil (not an error) so a scenario can branch on availability.
    return nil
  end
  local exchanges = _data.exchanges
  if type(exchanges) ~= "table" then
    return nil
  end
  local ex = exchanges[name]
  if ex == nil then
    error(
      "wraith.exchange(" .. name .. "): no such exchange in this package "
        .. "(evidence.mode = " .. evidence_mode() .. ")"
    )
  end
  return ex
end

-- Re-send a recorded exchange's request through the session-injecting wrappers.
--
-- Mode gating: replay requires embedded exchanges. Under reference_only it is
-- unavailable and raises a clear, mode-naming error (proposal §9: "wraith.replay()
-- unavailable"). The recorded request is sent via the wraith.* wrappers so the
-- X-Wraith-Session header and any env auth are injected exactly as for a
-- hand-authored call -- a replay is just a recorded request with injection.
function wraith.replay(exchange)
  if not mode_has_exchanges() then
    error(
      "wraith.replay: unavailable under evidence.mode = " .. evidence_mode()
        .. " (replay requires include_scrubbed_excerpts or include_recordings)"
    )
  end
  if type(exchange) ~= "table" or type(exchange.request) ~= "table" then
    error("wraith.replay(exchange): expected an exchange table with a .request")
  end
  local req = exchange.request
  local method = req.method
  if type(method) ~= "string" then
    error("wraith.replay: exchange.request.method must be a string")
  end
  local path = req.path
  if type(path) ~= "string" then
    error("wraith.replay: exchange.request.path must be a string")
  end
  -- Carry the recorded request headers as caller opts; merge_opts overlays the
  -- injected X-Wraith-Session / auth headers on top (injected wins).
  local opts = { headers = req.headers }
  local m = string.lower(method)
  if m == "get" then
    return wraith.get(path, opts)
  elseif m == "delete" then
    return wraith.delete(path, opts)
  elseif m == "post" then
    return wraith.post(path, req.body, opts)
  elseif m == "put" then
    return wraith.put(path, req.body, opts)
  elseif m == "patch" then
    return wraith.patch(path, req.body, opts)
  end
  error("wraith.replay: unsupported recorded method '" .. method .. "'")
end

-- ---------------------------------------------------------------------------
-- Structural comparison (proposal §5 "assert_matches")
-- ---------------------------------------------------------------------------

-- True when `leaf` (a JSON object key or response header name) matches one of
-- the ignore patterns. A pattern is either an exact name or a `*_suffix` glob
-- (e.g. "*_at" matches "created_at"). Matching is case-insensitive so volatile
-- header names ("Date" vs "date") and casing-variant timestamp keys are caught.
local function leaf_is_ignored(leaf, patterns)
  local lname = string.lower(tostring(leaf))
  for _, pat in ipairs(patterns) do
    local lpat = string.lower(pat)
    local star = string.sub(lpat, 1, 1) == "*"
    if star then
      local suffix = string.sub(lpat, 2)
      local at = #lname - #suffix + 1
      if at >= 1 and string.sub(lname, at) == suffix then
        return true
      end
    elseif lname == lpat then
      return true
    end
  end
  return false
end

-- Recursive structural equality with leaf-name-based ignores. Tables are
-- compared key-by-key (order-insensitive); ignored keys are skipped on BOTH
-- sides. Returns (true) on match or (false, path) naming the first divergence.
local function deep_match(expected, actual, patterns, path)
  if type(expected) ~= type(actual) then
    return false, path .. " (type " .. type(expected) .. " vs " .. type(actual) .. ")"
  end
  if type(expected) ~= "table" then
    if expected == actual then
      return true
    end
    return false, path
  end
  -- Compare every key present on either side, skipping ignored leaf names.
  local seen = {}
  for k, v in pairs(expected) do
    seen[k] = true
    if not leaf_is_ignored(k, patterns) then
      local child = (path == "") and tostring(k) or (path .. "." .. tostring(k))
      local ok, where = deep_match(v, actual[k], patterns, child)
      if not ok then
        return false, where
      end
    end
  end
  for k in pairs(actual) do
    if not seen[k] and not leaf_is_ignored(k, patterns) then
      local child = (path == "") and tostring(k) or (path .. "." .. tostring(k))
      return false, child .. " (unexpected key)"
    end
  end
  return true
end

-- Assert that `actual` structurally matches `expected`, ignoring volatile
-- leaves. The ignore list is `wraith.default_volatile_paths()` unioned with any
-- caller-supplied `opts.ignore` array; pass `opts = { ignore = {} }` to use ONLY
-- the defaults, or add entries to extend them. Raises a Lua error naming the
-- divergent path on mismatch (so it lands as a failed assertion, not a silent
-- pass); returns true on match.
function wraith.assert_matches(expected, actual, opts)
  local patterns = {}
  for _, p in ipairs(wraith.default_volatile_paths()) do
    patterns[#patterns + 1] = p
  end
  if type(opts) == "table" and type(opts.ignore) == "table" then
    for _, p in ipairs(opts.ignore) do
      patterns[#patterns + 1] = p
    end
  end
  local ok, where = deep_match(expected, actual, patterns, "")
  if not ok then
    error("wraith.assert_matches: mismatch at " .. tostring(where))
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Provenance helpers (proposal §5 "Inference + provenance")
-- ---------------------------------------------------------------------------

-- Look up a value-flow-derived symbol's concrete value from the package data
-- module (the generator pins these from the manifest's `inference.edges`).
-- Errors when the symbol is unknown so a typo'd `$symbol` fails loudly rather
-- than silently substituting nil into a request body.
function wraith.symbol(name)
  if type(name) ~= "string" then
    error("wraith.symbol(name): name must be a string")
  end
  local symbols = _data.symbols
  if type(symbols) == "table" then
    local v = symbols[name]
    if v ~= nil then
      return v
    end
  end
  error("wraith.symbol(" .. name .. "): no such symbol pinned in this package")
end

-- The base + overlay artifact digests pinned at scenario-pack time, as a table
-- `{ base = "sha256:...", overlay = "sha256:..." }`. Either field may be nil if
-- the package did not pin it. Pure provenance: NO twin introspection (Q6).
function wraith.digest()
  return {
    base = _data.base_digest,
    overlay = _data.overlay_digest,
  }
end

-- HARD REJECTION (proposal §5, Q6): there is deliberately NO twin-introspection
-- helper here and there never will be -- no wraith.routes(), no querying of
-- twin-internal route/metadata endpoints. Scenarios are pure HTTP clients over
-- the wire surface so the same `.wic` runs against the consumer twin, the
-- provider twin, and the real provider API unchanged.

return wraith
