local CONFIG_PATH = "nginx.conf"
local COMPILED_CONFIG_PATH = "nginx.conf.compiled"
local path = require("lapis.cmd.path")
local get_free_port, default_environment
do
  local _obj_0 = require("lapis.cmd.util")
  get_free_port, default_environment = _obj_0.get_free_port, _obj_0.default_environment
end
local find_nginx, filters, start_nginx, compile_config, write_config_for, get_pid, send_signal, send_hup, send_term, process_config, server_stack, AttachedServer, attach_server, detach_server, run_with_server
do
  local nginx_bin = "nginx"
  local nginx_search_paths = {
    "/usr/local/openresty/nginx/sbin/",
    "/usr/local/opt/openresty/bin/",
    "/usr/sbin/",
    ""
  }
  local nginx_path
  local is_openresty
  is_openresty = function(path)
    local cmd = tostring(path) .. " -v 2>&1"
    local handle = io.popen(cmd)
    local out = handle:read()
    handle:close()
    local matched = out:match("^nginx version: ngx_openresty/") or out:match("^nginx version: openresty/")
    if matched then
      return path
    end
  end
  find_nginx = function()
    if nginx_path then
      return nginx_path
    end
    do
      local to_check = os.getenv("LAPIS_OPENRESTY")
      if to_check then
        if is_openresty(to_check) then
          nginx_path = to_check
          return nginx_path
        end
      end
    end
    for _index_0 = 1, #nginx_search_paths do
      local prefix = nginx_search_paths[_index_0]
      local to_check = tostring(prefix) .. tostring(nginx_bin)
      if is_openresty(to_check) then
        nginx_path = to_check
        return nginx_path
      end
    end
  end
end
filters = {
  pg = function(val)
    local user, password, host, db
    local _exp_0 = type(val)
    if "table" == _exp_0 then
      db = assert(val.database, "missing database name")
      user, password, host, db = val.user or "postgres", val.password or "", val.host or "127.0.0.1", db
    elseif "string" == _exp_0 then
      user, password, host, db = val:match("^postgres://(.*):(.*)@(.*)/(.*)$")
    end
    if not (user) then
      error("failed to create postgres connect string")
    end
    return ("%s dbname=%s user=%s password=%s"):format(host, db, user, password)
  end
}
start_nginx = function(background)
  if background == nil then
    background = false
  end
  local nginx = find_nginx()
  if not (nginx) then
    return nil, "can't find nginx"
  end
  path.mkdir("logs")
  os.execute("touch logs/error.log")
  os.execute("touch logs/access.log")
  local cmd = nginx .. ' -p "$(pwd)"/ -c "' .. COMPILED_CONFIG_PATH .. '"'
  if background then
    cmd = cmd .. " > /dev/null 2>&1 &"
  end
  return os.execute(cmd)
end
compile_config = function(config, opts)
  if opts == nil then
    opts = { }
  end
  local env = setmetatable({ }, {
    __index = function(self, key)
      local v = os.getenv("LAPIS_" .. key:upper())
      if v ~= nil then
        return v
      end
      return opts[key:lower()]
    end
  })
  local out = config:gsub("(${%b{}})", function(w)
    local name = w:sub(4, -3)
    local filter_name, filter_arg = name:match("^(%S+)%s+(.+)$")
    do
      local filter = filters[filter_name]
      if filter then
        local value = env[filter_arg]
        if value == nil then
          return w
        else
          return filter(value)
        end
      else
        local value = env[name]
        if value == nil then
          return w
        else
          return value
        end
      end
    end
  end)
  local env_header
  if opts._name then
    env_header = "env LAPIS_ENVIRONMENT=" .. tostring(opts._name) .. ";\n"
  else
    env_header = "env LAPIS_ENVIRONMENT;\n"
  end
  return env_header .. out
end
write_config_for = function(environment, process_fn, ...)
  if type(environment) == "string" then
    local config = require("lapis.config")
    environment = config.get(environment)
  end
  local compiled = compile_config(path.read_file(CONFIG_PATH), environment)
  if process_fn then
    compiled = process_fn(compiled, ...)
  end
  return path.write_file(COMPILED_CONFIG_PATH, compiled)
end
get_pid = function()
  local pidfile = io.open("logs/nginx.pid")
  if not (pidfile) then
    return 
  end
  local pid = pidfile:read("*a")
  pidfile:close()
  return pid:match("[^%s]+")
end
send_signal = function(signal)
  do
    local pid = get_pid()
    if pid then
      os.execute("kill -s " .. tostring(signal) .. " " .. tostring(pid))
      return pid
    end
  end
end
send_hup = function()
  do
    local pid = get_pid()
    if pid then
      os.execute("kill -HUP " .. tostring(pid))
      return pid
    end
  end
end
send_term = function()
  do
    local pid = get_pid()
    if pid then
      os.execute("kill " .. tostring(pid))
      return pid
    end
  end
end
process_config = function(cfg, port)
  local run_code_action = [[    ngx.req.read_body()

    -- hijack print to write to buffer
    local old_print = print

    local buffer = {}
    print = function(...)
      local str = table.concat({...}, "\t")
      io.stdout:write(str .. "\n")
      table.insert(buffer, str)
    end

    local success, err = pcall(loadstring(ngx.var.request_body))

    if not success then
      ngx.status = 500
      print(err)
    end

    ngx.print(table.concat(buffer, "\n"))
    print = old_print
  ]]
  run_code_action = run_code_action:gsub("\\", "\\\\"):gsub('"', '\\"')
  local test_server = {
    [[      server {
        allow 127.0.0.1;
        deny all;
        listen ]] .. port .. [[;

        location = /run_lua {
          client_body_buffer_size 10m;
          client_max_body_size 10m;
          content_by_lua "
            ]] .. run_code_action .. [[
          ";
        }
    ]]
  }
  if cfg:match("upstream%s+database") then
    table.insert(test_server, [[      location = /http_query {
        postgres_pass database;
        set_decode_base64 $query $http_x_query;
        log_by_lua '
          local logger = require "lapis.logging"
          logger.query(ngx.var.query)
        ';
        postgres_query $query;
        rds_json on;
      }

      location = /query {
        internal;
        postgres_pass database;
        postgres_query $echo_request_body;
      }
    ]])
  end
  table.insert(test_server, "}")
  return cfg:gsub("%f[%a]http%s-{", "http { " .. table.concat(test_server, "\n"))
end
server_stack = nil
do
  local _base_0 = {
    wait_until_ready = function(self)
      local socket = require("socket")
      local max_tries = 1000
      while true do
        local status = socket.connect("127.0.0.1", self.port)
        if status then
          break
        end
        max_tries = max_tries - 1
        if max_tries == 0 then
          error("Timed out waiting for server to start")
        end
        socket.sleep(0.001)
      end
    end,
    detach = function(self)
      path.write_file(COMPILED_CONFIG_PATH, assert(self.existing_config))
      if self.fresh then
        send_term()
      else
        send_hup()
      end
      server_stack = self.previous
      if server_stack then
        server_stack:wait_until_ready()
      end
      local db = require("lapis.nginx.postgres")
      db.set_backend("raw", self.old_backend)
      return server_stack
    end,
    query = function(self, q)
      local ltn12 = require("ltn12")
      local http = require("socket.http")
      local mime = require("mime")
      local json = require("cjson")
      local buffer = { }
      http.request({
        url = "http://127.0.0.1:" .. tostring(self.port) .. "/http_query",
        sink = ltn12.sink.table(buffer),
        headers = {
          ["x-query"] = mime.b64(q)
        }
      })
      return json.decode(table.concat(buffer))
    end,
    exec = function(self, lua_code)
      assert(loadstring(lua_code))
      local ltn12 = require("ltn12")
      local http = require("socket.http")
      local buffer = { }
      http.request({
        url = "http://127.0.0.1:" .. tostring(self.port) .. "/run_lua",
        sink = ltn12.sink.table(buffer),
        source = ltn12.source.string(lua_code),
        headers = {
          ["content-length"] = #lua_code
        }
      })
      return table.concat(buffer)
    end
  }
  _base_0.__index = _base_0
  local _class_0 = setmetatable({
    __init = function(self, opts)
      for k, v in pairs(opts) do
        self[k] = v
      end
      local db = require("lapis.nginx.postgres")
      local pg_config = self.environment.postgres
      if pg_config and pg_config.backend == "pgmoon" then
        local Postgres
        do
          local _obj_0 = require("pgmoon")
          Postgres = _obj_0.Postgres
        end
        local pgmoon = Postgres(pg_config)
        assert(pgmoon:connect())
        local logger = require("lapis.db").get_logger()
        if not (os.getenv("LAPIS_SHOW_QUERIES")) then
          logger = nil
        end
        self.old_backend = db.set_backend("raw", function(...)
          if logger then
            logger.query(...)
          end
          return assert(pgmoon:query(...))
        end)
      else
        self.old_backend = db.set_backend("raw", (function()
          local _base_1 = self
          local _fn_0 = _base_1.query
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)())
      end
    end,
    __base = _base_0,
    __name = "AttachedServer"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  AttachedServer = _class_0
end
attach_server = function(environment, env_overrides)
  local pid = get_pid()
  local existing_config = path.read_file(COMPILED_CONFIG_PATH)
  local port = get_free_port()
  if type(environment) == "string" then
    environment = require("lapis.config").get(environment)
  end
  if env_overrides then
    assert(not getmetatable(env_overrides), "env_overrides already has metatable, aborting")
    environment = setmetatable(env_overrides, {
      __index = environment
    })
  end
  write_config_for(environment, process_config, port)
  if pid then
    send_hup()
  else
    start_nginx(true)
  end
  local server = AttachedServer({
    environment = environment,
    previous = server_stack,
    fresh = not pid,
    port = port,
    existing_config = existing_config
  })
  server:wait_until_ready()
  server_stack = server
  return server
end
detach_server = function()
  if not (server_stack) then
    error("no server was pushed")
  end
  return server_stack:detach()
end
run_with_server = function(fn)
  local port = get_free_port()
  local current_server = attach_server(default_environment(), {
    port = port
  })
  current_server.app_port = port
  fn()
  return current_server:detach()
end
return {
  compile_config = compile_config,
  filters = filters,
  find_nginx = find_nginx,
  start_nginx = start_nginx,
  send_hup = send_hup,
  send_term = send_term,
  get_pid = get_pid,
  write_config_for = write_config_for,
  attach_server = attach_server,
  detach_server = detach_server,
  send_signal = send_signal,
  run_with_server = run_with_server
}
