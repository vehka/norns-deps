-- run from the repo root: lua5.3 tests/run.lua
package.path = "./?.lua;" .. package.path
local deps = require "lib/deps"
local platform, steps, runner = deps.platform, deps.steps, deps.runner

local failures, count = 0, 0
local function test(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  print((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ("\n     " .. tostring(err))))
  if not ok then failures = failures + 1 end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function contains(s, sub)
  if not s or not s:find(sub, 1, true) then error("missing " .. sub .. " in " .. tostring(s), 2) end
end

local tmp = platform.capture("mktemp -d")
local function wait(job)
  for _ = 1, 100 do
    local r = job:poll()
    if r.done then return r end
    os.execute("sleep 0.1")
  end
  error("job did not finish")
end
local function finish(s)
  for _ = 1, 200 do
    if s.state ~= "running" then return end
    s:tick()
    os.execute("sleep 0.1")
  end
  error("session stuck in running")
end

local apt = { arch = "armv7l", pm = "apt", priv = "sudo", home = tmp, desktop = false }
local arch = { arch = "x86_64", pm = "pacman", priv = nil, home = tmp, desktop = true }

test("apt step uses sudo and status fd", function()
  local s = assert(steps.build({ pkg = "sox" }, apt, { dir = tmp }))
  contains(s.run, "sudo -n sh -c")
  contains(s.cmd, "APT::Status-Fd=1 sox")
  eq(s.progress, "apt")
end)

test("per-package-manager names", function()
  local spec = { pkg = { apt = "espeak-ng", pacman = "espeak-ng-pkg" } }
  local p = { pm = "pacman", priv = "root", home = tmp }
  contains(assert(steps.build(spec, p, { dir = tmp })).cmd, "espeak-ng-pkg")
end)

test("missing root gives reason and manual command", function()
  local s, err, hint = steps.build({ pkg = "sox" }, arch, { dir = tmp })
  eq(s, nil)
  contains(err, "needs root")
  contains(hint, "sudo pacman -S --needed")
end)

test("pkexec wrapper", function()
  local p = { pm = "apt", priv = "pkexec", home = tmp }
  contains(assert(steps.build({ pkg = "sox" }, p, { dir = tmp })).run, "pkexec sh -c")
end)

test("recipe selection by arch", function()
  local d = deps.new { name = "t", dir = tmp .. "/d", platform = apt }
  d:add { id = "x", check = "nonexistent-tool-xyz", install = {
    { when = { arch = "armv7l" }, steps = { { cmd = "echo arm" } } },
    { steps = { { cmd = "echo other" } } },
  } }
  local s = d:session { "x" }
  eq(s.queue[1].step.cmd, "echo arm")
  d.platform = arch
  eq(d:session({ "x" }).queue[1].step.cmd, "echo other")
end)

test("runner: exit code and log", function()
  local r = runner.new(tmp .. "/r")
  local res = wait(r:start("echo hello; echo oops >&2; exit 3"))
  eq(res.code, 3)
  contains(res.tail, "hello")
  contains(res.tail, "oops")
end)

test("runner: cancel kills the whole group", function()
  local r = runner.new(tmp .. "/r")
  local job = r:start("sleep 30 & wait")
  os.execute("sleep 0.5")
  job:cancel()
  local res = wait(job)
  eq(res.code, 143)
  eq(platform.run("pgrep -f '[s]leep 30'"), false)
end)

test("runner: apt and percent progress parsing", function()
  local r = runner.new(tmp .. "/r")
  local res = wait(r:start("printf 'dlstatus:1:50.0:Retrieving\\npmstatus:libc6:armhf:50.0:Unpacking\\n'", { progress = "apt" }))
  assert(math.abs(res.progress - 0.7) < 1e-6, "apt progress " .. tostring(res.progress))
  res = wait(r:start("printf ' 1024K .... 37%% 1M 2s\\n'", { progress = "percent" }))
  eq(res.progress, 0.37)
end)

local function mkdeps(p)
  return deps.new { name = "t", dir = tmp .. "/s", platform = p or apt }
end

test("session: install, verify, done", function()
  local marker = tmp .. "/marker1"
  local d = mkdeps()
  d:add { id = "m", check_file = marker, cmd = "touch " .. marker }
  local s = d:session { "m" }
  eq(s.state, "review")
  s:confirm(); finish(s)
  eq(s.state, "done"); eq(s.results.m, true)
  eq(d:ok("m"), true)
end)

test("session: nothing missing is done at once", function()
  local d = mkdeps()
  d:add { id = "sh", check = "sh", cmd = "true" }
  eq(d:session({ "sh" }).state, "done")
end)

test("session: failure then retry succeeds", function()
  local marker, flag = tmp .. "/marker2", tmp .. "/flag2"
  local d = mkdeps()
  d:add { id = "m", check_file = marker, cmd = "test -f " .. flag .. " && touch " .. marker }
  local s = d:session { "m" }
  s:confirm(); finish(s)
  eq(s.state, "failed"); contains(s.error, "exit code 1")
  os.execute("touch " .. flag)
  s:retry(); finish(s)
  eq(s.state, "done")
end)

test("session: success but check still failing is a failure", function()
  local d = mkdeps()
  d:add { id = "m", check_file = tmp .. "/never", cmd = "true" }
  local s = d:session { "m" }
  s:confirm(); finish(s)
  eq(s.state, "failed"); contains(s.error, "check still fails")
end)

test("session: optional failure is skipped", function()
  local d = mkdeps()
  d:add { id = "opt", optional = true, check_file = tmp .. "/never2", cmd = "false" }
  d:add { id = "m", check_file = tmp .. "/marker3", cmd = "touch " .. tmp .. "/marker3" }
  local s = d:session { "opt", "m" }
  s:confirm(); finish(s)
  eq(s.state, "done"); eq(s.results.opt, false); eq(s.results.m, true)
end)

test("session: required dep without root blocks", function()
  local d = mkdeps(arch)
  d:add { id = "p", check = "nonexistent-tool-xyz", pkg = "foo" }
  local s = d:session { "p" }
  eq(s.state, "blocked")
  contains(s.items[1].hint, "sudo pacman")
end)

test("url step downloads, verifies sha256, extracts", function()
  if not (platform.have("wget") or platform.have("curl")) or not platform.have("python3") then return end
  local web = tmp .. "/web"
  os.execute("mkdir -p " .. web .. "/pkg && echo hi > " .. web .. "/pkg/a.txt && tar -czf " .. web .. "/a.tgz -C " .. web .. " pkg")
  local sum = platform.capture("sha256sum " .. web .. "/a.tgz"):match("^(%x+)")
  local pid = platform.capture("cd " .. web .. "; python3 -m http.server 18765 >/dev/null 2>&1 & echo $!")
  os.execute("sleep 1")
  local d = mkdeps()
  d:add { id = "u", check_file = tmp .. "/out/pkg/a.txt",
          url = "http://127.0.0.1:18765/a.tgz", sha256 = sum, extract = tmp .. "/out" }
  local s = d:session { "u" }
  s:confirm(); finish(s)
  eq(s.state, "done", s.error)
  -- wrong checksum fails
  os.execute("rm -rf " .. tmp .. "/out")
  d.specs.u.install[1].steps[1].sha256 = string.rep("0", 64)
  s = d:session { "u" }
  s:confirm(); finish(s)
  os.execute("kill " .. pid)
  eq(s.state, "failed")
end)

test("ugens: duplicates across roots", function()
  local ext = tmp .. "/.local/share/SuperCollider/Extensions"
  os.execute("mkdir -p " .. ext .. "/a " .. ext .. "/b && touch " .. ext .. "/a/MiPlaits.scx " .. ext .. "/b/MiPlaits.scx " .. ext .. "/a/Solo.scx")
  local dups = deps.ugens.duplicates({ home = tmp })
  eq(#dups["MiPlaits.scx"], 2)
  eq(dups["Solo.scx"], nil)
  eq(deps.ugens.installed({ home = tmp }, "Solo.scx"), true)
end)

test("needs are installed first, once", function()
  local d = mkdeps()
  d:add { id = "a", check_file = tmp .. "/na", cmd = "touch " .. tmp .. "/na", needs = { "b" } }
  d:add { id = "b", check_file = tmp .. "/nb", cmd = "touch " .. tmp .. "/nb" }
  d:add { id = "c", check_file = tmp .. "/nc", cmd = "touch " .. tmp .. "/nc", needs = { "b" } }
  local e = d:expand { "a", "c" }
  eq(table.concat(e, ","), "b,a,c")
end)

os.execute("rm -rf " .. tmp)
print(string.format("%d tests, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)
