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
  eq(hint, "sudo pacman -S sox")
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
  local job = r:start("sleep 31.7 & wait")
  os.execute("sleep 0.5")
  job:cancel()
  local res = wait(job)
  eq(res.code, 143)
  eq(platform.run("pgrep -f '[s]leep 31.7'"), false)
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
  eq(deps.ugens.installed({ home = tmp }, "Solo"), true)
  eq(deps.ugens.installed({ home = tmp }, "Nope"), false)
end)

test("ugens: plugins outside the plugin folders don't count", function()
  local home = tmp .. "/home2"
  local dust, ext = home .. "/dust", home .. "/.local/share/SuperCollider/Extensions"
  os.execute("mkdir -p " .. dust .. "/code/x/build " .. ext .. "/x " .. home .. "/.config/SuperCollider")
  local f = io.open(home .. "/.config/SuperCollider/sclang_conf.yaml", "w")
  f:write("includePaths:\n    - " .. dust .. "\nexcludePaths:\n    []\n")
  f:close()
  os.execute("touch " .. dust .. "/code/x/build/Foo.so " .. dust .. "/code/x/Foo.sc")
  local p = { home = home }
  eq(deps.ugens.installed(p, "Foo"), false)     -- scsynth doesn't look in dust
  eq(deps.ugens.installed(p, "Foo.sc"), true)   -- sclang does
  os.execute("touch " .. ext .. "/x/Foo.so " .. ext .. "/x/Foo.sc")
  local dups = deps.ugens.duplicates(p)
  eq(dups["Foo.so"], nil)
  eq(#dups["Foo.sc"], 2)
end)

test("ugens step: per-arch url and checksum, folder from the id", function()
  local d = deps.new { name = "t", dir = tmp .. "/u", platform = apt }
  d:add { id = "pp", check_ugens = "PlaitsPalette",
          ugens = "http://h/PlaitsPalette-{arch}.tar.gz",
          sha256 = { armv7l = "abc" }, manual = "build it" }
  eq(d.specs.pp.restart, true)
  local step = d:session({ "pp" }).queue[1].step
  contains(step.cmd, "http://h/PlaitsPalette-armv7l.tar.gz")
  contains(step.cmd, "abc  ")
  contains(step.cmd, "/Extensions/pp'")
  d.platform = { arch = "x86_64", pm = "pacman", home = tmp }
  local s = d:session { "pp" }
  eq(s.state, "blocked"); eq(s.items[1].blocked, "build it")
  local _, err = steps.build({ ugens = "http://h/a.tgz", into = "../x" }, apt, { dir = tmp })
  contains(err, "into")
end)

test("ugens step installs, and leaves out files that are already there", function()
  if not (platform.have("wget") or platform.have("curl")) or not platform.have("python3") then return end
  local home, web = tmp .. "/home3", tmp .. "/web3"
  local ext = home .. "/.local/share/SuperCollider/Extensions"
  os.execute("mkdir -p " .. web .. "/src/classes " .. ext .. "/other")
  os.execute("cd " .. web .. "/src && touch New.so Old.so classes/New.sc classes/Old.sc README.md"
    .. " && tar -czf ../pack-armv7l.tar.gz . && touch " .. ext .. "/other/Old.so " .. ext .. "/other/Old.sc")
  local sum = platform.capture("sha256sum " .. web .. "/pack-armv7l.tar.gz"):match("^(%x+)")
  local pid = platform.capture("cd " .. web .. "; python3 -m http.server 18766 >/dev/null 2>&1 & echo $!")
  os.execute("sleep 1")
  local p = { arch = "armv7l", pm = "apt", priv = "sudo", home = home, desktop = false }
  local d = deps.new { name = "t", dir = tmp .. "/u3", platform = p }
  d:add { id = "pack", check_ugens = { "New", "Old", "New.sc" },
          ugens = "http://127.0.0.1:18766/pack-{arch}.tar.gz", sha256 = sum }
  local s = d:session { "pack" }
  s:confirm(); finish(s)
  eq(s.state, "done", s.error); eq(s.needs_restart, true)
  local function exists(path) return platform.run("test -f " .. ext .. "/" .. path) end
  eq(exists("pack/New.so"), true); eq(exists("pack/classes/New.sc"), true)
  eq(exists("pack/Old.so"), false); eq(exists("pack/classes/Old.sc"), false)
  eq(next(d:ugen_conflicts()), nil)
  -- a second run overwrites its own files instead of skipping them
  os.execute("rm " .. ext .. "/other/Old.so")
  d.specs.pack.check_fn = function() return false end
  s = d:session { "pack" }
  s:confirm(); finish(s)
  os.execute("kill " .. pid)
  eq(exists("pack/New.so"), true); eq(exists("pack/Old.so"), true)
  eq(platform.capture("ls /tmp | grep -c '^tmp\\..*\\.list$'"), "0")
end)

test("needs are installed first, once", function()
  local d = mkdeps()
  d:add { id = "a", check_file = tmp .. "/na", cmd = "touch " .. tmp .. "/na", needs = { "b" } }
  d:add { id = "b", check_file = tmp .. "/nb", cmd = "touch " .. tmp .. "/nb" }
  d:add { id = "c", check_file = tmp .. "/nc", cmd = "touch " .. tmp .. "/nc", needs = { "b" } }
  local e = d:expand { "a", "c" }
  eq(table.concat(e, ","), "b,a,c")
end)

test("restart: install of a restart dep marks it, pending until sclang restarts", function()
  local d = mkdeps()
  d:add { id = "r", restart = true, check_file = tmp .. "/rr", cmd = "touch " .. tmp .. "/rr" }
  local s = d:session { "r" }
  s:confirm(); finish(s)
  eq(s.state, "done"); eq(s.needs_restart, true)
  d.sclang_uptime = function() return 1000 end   -- started before the install
  eq(d:restart_pending(), true)
  d.sclang_uptime = function() return 0 end      -- restarted afterwards
  os.execute("sleep 1.1")
  eq(d:restart_pending(), false)
  d.sclang_uptime = function() return nil end    -- not running
  eq(d:restart_pending(), false)
end)

test("restart: satisfied deps still prompt while a restart is pending", function()
  local d = mkdeps()
  d:add { id = "r2", restart = true, check_file = tmp .. "/rr", cmd = "true" }
  d.sclang_uptime = function() return 100000 end
  d:mark_restart()
  local s = d:session { "r2" }
  eq(s.state, "done"); eq(s.needs_restart, true)
end)

test("manual hint replaces 'no recipe' on other platforms", function()
  local d = mkdeps()
  d:add { id = "m", check = "nonexistent-tool-xyz", manual = "build it from source",
          install = { { when = { arch = "armv7l" }, steps = { { cmd = "true" } } } } }
  d.platform = { arch = "x86_64", pm = "pacman", priv = nil, home = tmp }
  local s = d:session { "m" }
  eq(s.state, "blocked"); eq(s.items[1].blocked, "build it from source")
end)

test("ui wrap", function()
  local ui = dofile("lib/deps/ui.lua")
  local lines = ui.wrap("mi: build the UGens for your platform from source", 21)
  for _, l in ipairs(lines) do assert(#l <= 21, l) end
  eq(table.concat(lines, " "), "mi: build the UGens for your platform from source")
end)

test("restart: missing JACK files offer a reboot instead", function()
  local ui = dofile("lib/deps/ui.lua")
  local d = mkdeps()
  d:add { id = "j", restart = true, check_file = tmp .. "/jj", cmd = "touch " .. tmp .. "/jj" }
  local s = d:session { "j" }
  s:confirm(); finish(s)
  local calls = {}
  d.restart = function() calls[#calls + 1] = "restart" end
  d.reboot = function() calls[#calls + 1] = "reboot" end
  d.jack_files_missing = function() return true end
  eq(ui.key(s, 3, 1), false); eq(s.state, "reboot"); eq(#calls, 0)
  eq(ui.key(s, 3, 1), true); eq(calls[1], "reboot")
  -- healthy JACK: straight to restart
  s = d:session { "j" }
  d.jack_files_missing = function() return false end
  s.needs_restart = true; s.state = "done"
  eq(ui.key(s, 3, 1), true); eq(calls[2], "restart")
end)

test("capture returns one value under norns too", function()
  util = { os_capture = function() return "42\n" end }
  local n = select("#", platform.capture("true"))
  local v = tonumber(platform.capture("true"))
  util = nil
  eq(n, 1); eq(v, 42)
end)

test("jack_files_missing is false on desktop", function()
  eq(platform.jack_files_missing({ desktop = true }), false)
end)

os.execute("rm -rf " .. tmp)
print(string.format("%d tests, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)
