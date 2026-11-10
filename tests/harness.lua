-- End-to-end harness for the plugin entry file: runs the real export under a
-- mock `maki` and requires every read/write configuration to agree byte for
-- byte.
--
--   lua5.1 tests/harness.lua
--
-- The mock supplies fs, json, base64 and the job calls. The streaming path
-- runs the real `dd ... | base64 | tr` command through bash, so a wrong window
-- command fails here rather than in a session. Five configurations run over
-- two fixtures that differ only in the JSON key order of each record: the
-- streamed read, the whole-file read, tiny write batches, one window per file,
-- and the fallback when dd/base64/tr are missing. The two fixtures make the
-- prefix classifier and the decode fallback prove the same export.
--
-- The JSON codec here sorts keys and is not maki's encoder: this checks the
-- plugin's plumbing, not the shape of a real export.

local here = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
-- `lua/` is the package module root, so the entry file's require of
-- "replay_core" resolves exactly the way it does inside maki.
package.path = here .. "../lua/?.lua;" .. package.path

local ROOT = "/tmp/replay-smoke"
local STATE = ROOT .. "/state"
local SESSIONS = STATE .. "/sessions"
local SID = "CehR8wSm3gwgZqky3Lq29"

local function shell(q)
  return "'" .. tostring(q):gsub("'", "'\\''") .. "'"
end

local function slurp(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function spit(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

-- ---------------------------------------------------------------- json stub

local json = {}

local function encode_value(value, out, keys)
  local t = type(value)
  if t == "nil" then
    out[#out + 1] = "null"
  elseif t == "boolean" or t == "number" then
    out[#out + 1] = tostring(value)
  elseif t == "string" then
    out[#out + 1] = '"'
      .. value:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return map[c] or string.format("\\u%04x", string.byte(c))
      end)
      .. '"'
  elseif t == "table" then
    local array = #value > 0 or next(value) == nil
    if array and #value > 0 then
      out[#out + 1] = "["
      for i, item in ipairs(value) do
        if i > 1 then
          out[#out + 1] = ","
        end
        encode_value(item, out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local names = {}
      for k in pairs(value) do
        names[#names + 1] = k
      end
      table.sort(names, function(a, b)
        return tostring(a) < tostring(b)
      end)
      for i, k in ipairs(names) do
        if i > 1 then
          out[#out + 1] = ","
        end
        encode_value(tostring(k), out)
        out[#out + 1] = ":"
        encode_value(value[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("cannot encode " .. t)
  end
end

function json.encode(value)
  local out = {}
  encode_value(value, out)
  return table.concat(out)
end

local decode = {}

local function skip_ws(s, i)
  while s:sub(i, i):match("%s") do
    i = i + 1
  end
  return i
end

local CHAR_ESCAPES = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" }

local function decode_string(s, i)
  local out = {}
  i = i + 1
  while true do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16))
        i = i + 6
      else
        out[#out + 1] = CHAR_ESCAPES[e] or e
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

local function decode_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then
      return obj, i + 1
    end
    while true do
      local key
      key, i = decode_string(s, skip_ws(s, i))
      -- i now sits on the colon between the key and its value.
      i = skip_ws(s, i + 1)
      local value
      value, i = decode_value(s, i)
      obj[key] = value
      i = skip_ws(s, i)
      if s:sub(i, i) == "," then
        i = i + 1
      else
        break
      end
    end
    return obj, i + 1
  elseif c == "[" then
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then
      return arr, i + 1
    end
    while true do
      local value
      value, i = decode_value(s, i)
      arr[#arr + 1] = value
      i = skip_ws(s, i)
      if s:sub(i, i) == "," then
        i = i + 1
      else
        break
      end
    end
    return arr, i + 1
  elseif c == '"' then
    return decode_string(s, i)
  elseif c == "t" then
    return true, i + 4
  elseif c == "f" then
    return false, i + 5
  elseif c == "n" then
    return nil, i + 4
  end
  local digits = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  return tonumber(digits), i + #digits
end

function json.decode(s)
  if type(s) ~= "string" then
    return nil
  end
  local ok, value = pcall(decode_value, s, 1)
  if not ok then
    return nil
  end
  return value
end

-- -------------------------------------------------------------- base64 stub

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do
  B64_INDEX[B64:sub(i, i)] = i - 1
end

local function b64_decode(text)
  local out = {}
  local bits, count = 0, 0
  local function emit()
    -- count chars of 6 bits each hold count * 6 / 8 whole bytes, high bits first.
    local total = count * 6
    for byte = 1, math.floor(total / 8) do
      local shift = total - byte * 8
      out[#out + 1] = string.char(math.floor(bits / 2 ^ shift) % 256)
    end
    bits, count = 0, 0
  end
  for i = 1, #text do
    local value = B64_INDEX[text:sub(i, i)]
    if value then
      bits = bits * 64 + value
      count = count + 1
      if count == 4 then
        emit()
      end
    end
  end
  if count > 0 then
    emit()
  end
  return table.concat(out)
end

-- ------------------------------------------------------------------- maki

local flashes = {}
local commands = {}
local jobs = {}
local broken_tools = false

local next_job = 0

local function read_lines_rust_style(path)
  local text = slurp(path)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
    table.remove(lines)
  end
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("\r$", "")
  end
  return lines
end

maki = {
  ui = {
    flash = function(msg)
      flashes[#flashes + 1] = msg
    end,
  },
  env = { state_dir = function() return STATE end },
  session = { current = function() return SID end },
  json = json,
  base64 = { decode = function(s) return b64_decode(s) end },
  api = {
    register_command = function(spec)
      commands[spec.name] = spec
    end,
  },
  fs = {
    joinpath = function(a, b, c)
      local path = a
      for _, part in ipairs({ b, c }) do
        if part then
          path = (path:gsub("/$", "")) .. "/" .. part
        end
      end
      return path
    end,
    abspath = function(path) return path end,
    metadata = function(path)
      local probe = io.open(path, "rb")
      if not probe then
        return nil
      end
      probe:close()
      local size = #slurp(path)
      local is_dir = false
      local handle = io.popen("test -d " .. shell(path) .. " && echo dir || echo file")
      is_dir = handle:read("*a"):match("dir") ~= nil
      handle:close()
      if is_dir then
        size = 0
      end
      return { size = size, is_file = not is_dir, is_dir = is_dir }
    end,
    read = function(path)
      local f = io.open(path, "rb")
      if not f then
        return nil, "no such file: " .. path
      end
      local data = f:read("*a")
      f:close()
      return data
    end,
    write = function(path, content)
      local ok, err = pcall(spit, path, content)
      return ok and true or nil, err
    end,
    append = function(path, content)
      local f = io.open(path, "ab")
      if not f then
        return nil, "cannot open " .. path
      end
      f:write(content)
      f:close()
      return true
    end,
    mkdir = function(path)
      os.execute("mkdir -p " .. shell(path))
      return true
    end,
    dir = function(path)
      local handle = io.popen("ls -1 " .. shell(path) .. " 2>/dev/null")
      if not handle then
        return nil
      end
      local entries = {}
      for name in handle:read("*a"):gmatch("([^\n]+)") do
        local kind = "file"
        local check = io.popen("test -d " .. shell(path .. "/" .. name) .. " && echo dir || echo file")
        if check:read("*a"):match("dir") then
          kind = "dir"
        end
        check:close()
        entries[#entries + 1] = { name, kind }
      end
      handle:close()
      return #entries > 0 and entries or nil
    end,
  },
  fn = {
    jobstart = function(cmd, opts)
      next_job = next_job + 1
      jobs[next_job] = { cmd = cmd, env = opts and opts.env or {} }
      return next_job
    end,
    jobwait = function(id)
      if broken_tools then
        return { stdout = "", stderr = "dd: command not found", exit_code = 127, truncated = false }
      end
      local job = jobs[id]
      if not job then
        error("unknown job id")
      end
      local out, err, code = os.tmpname(), os.tmpname(), os.tmpname()
      local assignment = ""
      for k, v in pairs(job.env) do
        assignment = assignment .. k .. "=" .. shell(v) .. " "
      end
      os.execute(
        assignment .. "bash -c " .. shell(job.cmd) .. " >" .. shell(out) .. " 2>" .. shell(err) .. "; echo $? >"
          .. shell(code)
      )
      local lines = read_lines_rust_style(out)
      local result = {
        stdout = table.concat(lines, "\n"),
        stderr = slurp(err),
        exit_code = tonumber(slurp(code)),
        truncated = false,
      }
      os.remove(out)
      os.remove(err)
      os.remove(code)
      return result
    end,
    jobstop = function() end,
  },
}

-- ---------------------------------------------------------------- fixtures

-- Two encodings of the same session: one with keys in the order maki writes
-- (so core.classify answers from the prefix and most lines are never parsed
-- for their type), one with keys sorted (so every line falls through to the
-- decode). Both must export identically, streamed and whole-file alike.
local function text(str)
  return { type = "text", text = str }
end

local function tool_use(id, name, input)
  return { type = "tool_use", id = id, name = name, input = input }
end

local function tool_result(id, content)
  return { type = "tool_result", tool_use_id = id, content = content }
end

local LONG = string.rep("x", 400)

local function header(ordered)
  if ordered then
    return [[{"t":"header","v":2,"id":"]] .. SID .. [[","model":"test","cwd":"/tmp","created_at":1000}]]
  end
  return json.encode({ t = "header", v = 2, id = SID, model = "test", cwd = "/tmp", created_at = 1000 })
end

local function meta(ordered, title, updated_at)
  if ordered then
    return [[{"t":"meta","title":]] .. json.encode(title) .. [[,"updated_at":]] .. updated_at .. [[}]]
  end
  return json.encode({ t = "meta", title = title, updated_at = updated_at })
end

local function out_record(ordered)
  if ordered then
    return [[{"t":"out","id":"task-C","d":{"Diff":{"path":"/tmp/x","before":]] .. json.encode(LONG) .. [[}}}]]
  end
  return json.encode({ t = "out", id = "task-C", d = { Diff = { path = "/tmp/x", before = LONG } } })
end

local function msg(ordered, role, content, display_text)
  if ordered then
    local d = json.encode({ role = role, content = content, display_text = display_text })
    return [[{"t":"msg","d":]] .. d .. "}"
  end
  return json.encode({ t = "msg", d = { role = role, content = content, display_text = display_text } })
end

local function sub_msg(ordered, key, role, content)
  if ordered then
    return [[{"t":"sub_msg","sub":"]] .. key .. [[","d":]] .. json.encode({ role = role, content = content }) .. "}"
  end
  return json.encode({ t = "sub_msg", sub = key, d = { role = role, content = content } })
end

local function dropped(ordered)
  if ordered then
    return [[{"t":"msg","d":{"content":[{"data":"hidden","type":"redacted_thinking"}],"role":"assistant"}}]]
  end
  return json.encode({
    t = "msg",
    d = { role = "assistant", content = { { type = "redacted_thinking", data = "hidden" } } },
  })
end

local function session_files(ordered)
  local shared_a = msg(ordered, "user", { text("first question " .. LONG) })
  local shared_b = msg(ordered, "assistant", { text("second answer"), tool_use("task-C", "task", { prompt = "work" }) })
  return {
    [SESSIONS .. "/archive/" .. SID .. "/10.jsonl"] = table.concat({
      header(ordered),
      shared_a,
      shared_b,
      msg(ordered, "user", { tool_result("task-C", "stale result") }),
      sub_msg(ordered, "task-C", "user", { text("sub start " .. LONG) }),
      sub_msg(ordered, "task-C", "assistant", { text("sub middle") }),
      meta(ordered, "stale", 1500),
      "",
    }, "\n"),
    [SESSIONS .. "/archive/" .. SID .. "/4.jsonl"] = table.concat({
      header(ordered),
      shared_a,
      shared_b,
      msg(ordered, "user", { text("rewound away " .. LONG) }),
      meta(ordered, "older", 1200),
      "",
    }, "\n"),
    [SESSIONS .. "/" .. SID .. ".jsonl"] = table.concat({
      header(ordered),
      shared_a,
      shared_b,
      dropped(ordered),
      msg(ordered, "user", { tool_result("task-C", "current result " .. LONG) }),
      msg(ordered, "assistant", { text("done " .. LONG) }),
      out_record(ordered),
      sub_msg(ordered, "orphan-A", "user", { text("orphan turn " .. LONG) }),
      sub_msg(ordered, "orphan-A", "assistant", { text("orphan reply") }),
      sub_msg(ordered, "orphan-A", "user", { text("orphan tail " .. LONG) }),
      sub_msg(ordered, "task-C", "user", { text("sub start " .. LONG) }),
      sub_msg(ordered, "task-C", "assistant", { text("sub middle") }),
      sub_msg(ordered, "task-C", "user", { text("sub long tail " .. LONG .. LONG) }),
      sub_msg(ordered, "task-C", "assistant", { { type = "redacted_thinking", data = "hidden" } }),
      sub_msg(ordered, "task-C", "user", { text("sub end " .. LONG) }),
      meta(ordered, "the flightsim/ directory", 2000),
      "",
    }, "\n"),
  }
end

-- -------------------------------------------------------------------- runs

-- The entry file is plugin/init.lua: maki runs it, it is not a module, so
-- load it by path and keep the table it returns.
local tuning = assert(loadfile(here .. "../plugin/init.lua"))()

local failures = {}


local function check(ok, msg)
  if not ok then
    failures[#failures + 1] = msg
  end
end

local function run_export(out_dir, sizes)
  tuning.whole_read_bytes = sizes.whole_read_bytes
  tuning.window_bytes = sizes.window_bytes
  tuning.group_bytes = sizes.group_bytes
  local before = #flashes
  commands.replay.handler({ fargs = { SID, out_dir } })
  if #flashes == before then
    error("the export flashed nothing")
  end
  return flashes[#flashes]
end

local function snapshot(dir)
  local names = {}
  local handle = io.popen("ls -1 " .. shell(dir) .. " 2>/dev/null")
  for name in handle:read("*a"):gmatch("([^\n]+)") do
    names[#names + 1] = name
  end
  handle:close()
  table.sort(names)
  local dump = {}
  for _, name in ipairs(names) do
    dump[#dump + 1] = "=== " .. name .. "\n" .. slurp(dir .. "/" .. name)
  end
  return table.concat(dump, "\n"), names
end

local function body(path)
  local lines = {}
  for line in slurp(path):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

local function export_once(ordered)
  -- Guard: this test rewrites its session directory over and over. Make sure it
-- never points at the store maki really keeps sessions in.
local REAL_SESSIONS = (os.getenv("HOME") or "") .. "/.local/state/maki/sessions"
assert(SESSIONS ~= REAL_SESSIONS, "the test must not write the real session store")
assert(STATE ~= (os.getenv("HOME") or "") .. "/.local/state/maki", "the test state dir must be elsewhere")

os.execute("rm -rf " .. shell(ROOT))
  os.execute("mkdir -p " .. shell(SESSIONS .. "/archive/" .. SID))
  for path, content in pairs(session_files(ordered)) do
    spit(path, content)
  end
  local runs = {}
  runs[1] = run_export(ROOT .. "/streamed", { whole_read_bytes = -1, window_bytes = 64, group_bytes = 128 })
  runs[2] = run_export(ROOT .. "/whole", { whole_read_bytes = 1024 * 1024, window_bytes = 64, group_bytes = 128 })
  runs[3] = run_export(ROOT .. "/small_group", { whole_read_bytes = -1, window_bytes = 32, group_bytes = 8 })
  runs[4] = run_export(ROOT .. "/one_window", { whole_read_bytes = -1, window_bytes = 1024 * 1024, group_bytes = 128 })
  broken_tools = true
  runs[5] = run_export(ROOT .. "/no_tools", { whole_read_bytes = -1, window_bytes = 64, group_bytes = 128 })
  broken_tools = false
  local dumps, names = {}, nil
  for _, dir in ipairs({ "streamed", "whole", "small_group", "one_window", "no_tools" }) do
    dumps[dir] = snapshot(ROOT .. "/" .. dir)
    names = names or select(2, snapshot(ROOT .. "/" .. dir))
  end
  return runs, dumps, names
end

local ordered_runs, ordered_dumps, ordered_names = export_once(true)
local sorted_runs, sorted_dumps = export_once(false)

check(#ordered_names == 3, "expected 3 output files, got " .. table.concat(ordered_names, " "))
check(
  ordered_names[1] == SID .. ".jsonl"
    and ordered_names[2] == SID .. ".sub-1.jsonl"
    and ordered_names[3] == SID .. ".sub-2.jsonl",
  "unexpected output file names: " .. table.concat(ordered_names, " ")
)
for name, dump in pairs(ordered_dumps) do
  check(dump == ordered_dumps.streamed, name .. " export differs from the streamed one")
  check(dump == sorted_dumps.streamed, name .. " export differs from the sorted-key fixture")
end
check(
  tonumber(ordered_runs[1]:match("(%d+) files")) == 3 and tonumber(ordered_runs[1]:match("(%d+) turns")) == 11,
  "flash summary wrong: " .. tostring(ordered_runs[1])
)

-- The parent stream keeps every merged turn but the one that maps to nothing.
-- The task tool_use in parent turn 2 opens sub-1; the orphan stream that only
-- an archive still carries is sub-2, and spans the whole session window.
local dir = ROOT .. "/streamed"
local parent = body(dir .. "/" .. SID .. ".jsonl")
check(parent[1]:find("session-id", 1, true) ~= nil, "first parent line is not the session id")
check(#parent == 5, "parent has " .. #parent .. " lines, expected the session-id plus 4 turns")
local sub1 = body(dir .. "/" .. SID .. ".sub-1.jsonl")
check(#sub1 == 5, "task-C file has " .. #sub1 .. " lines, expected the session-id plus 4 turns")
local sub2 = body(dir .. "/" .. SID .. ".sub-2.jsonl")
check(#sub2 == 4, "orphan file has " .. #sub2 .. " lines, expected the session-id plus 3 turns")
check(slurp(dir .. "/" .. SID .. ".sub-2.jsonl"):find("orphan reply", 1, true) ~= nil, "orphan stream missing")
check(slurp(dir .. "/" .. SID .. ".sub-2.jsonl"):find("sub middle", 1, true) == nil, "wrong stream in the orphan file")
check(
  slurp(dir .. "/" .. SID .. ".sub-1.jsonl"):find("stale result", 1, true) == nil,
  "the archive copy of task-C leaked into the export"
)

local function stamp(line)
  return json.decode(line).timestamp
end

local parent_stamp = {}
for i = 2, #parent do
  parent_stamp[i - 1] = stamp(parent[i])
end
check(parent_stamp[1] == "1970-01-01T00:16:40Z", "parent turn 1 is not at the session start: " .. parent_stamp[1])
check(parent_stamp[4] == "1970-01-01T00:33:20Z", "last parent turn is not at the meta time: " .. parent_stamp[4])
for i = 2, #sub1 do
  check(
    stamp(sub1[i]) >= parent_stamp[2] and stamp(sub1[i]) <= parent_stamp[3],
    "task stamp " .. stamp(sub1[i]) .. " outside its parent window"
  )
end
for i = 2, #sub2 do
  check(
    stamp(sub2[i]) >= parent_stamp[1] and stamp(sub2[i]) <= parent_stamp[4],
    "orphan stamp " .. stamp(sub2[i]) .. " outside the session window"
  )
end

if #failures > 0 then
  print(table.concat(failures, "\n"))
  os.exit(1)
end
print("replay harness passed under " .. _VERSION)
