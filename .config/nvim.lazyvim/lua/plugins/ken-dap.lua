-- File: ~/.config/nvim/lua/plugins/ken-dap.lua

return {
  "rcarriga/nvim-dap-ui",
  lazy = false, -- always load
  dependencies = {
    "mfussenegger/nvim-dap",
    "nvim-telescope/telescope.nvim",
    "jbyuki/one-small-step-for-vimkind",
  },
  config = function()
    local dap = require("dap")
    local dapui = require("dapui")
    local telescope = require("telescope.builtin")

    local dap = require("dap")
    dap.configurations.lua = {
      {
        type = "nlua",
        request = "attach",
        name = "Attach to running Neovim instance",
      },
    }

    dap.adapters.nlua = function(callback, config)
      callback({ type = "server", host = config.host or "127.0.0.1", port = config.port or 8086 })
    end
    dapui.setup({
      icons = { expanded = "▾", collapsed = "▸", current_frame = "▸" },
      mappings = {
        expand = { "<CR>", "<2-LeftMouse>" },
        open = "o",
        remove = "d",
        edit = "e",
        repl = "r",
        toggle = "t",
      },
      layouts = {
        {
          elements = {
            { id = "scopes", size = 0.25 },
            "breakpoints",
            "stacks",
            "watches",
          },
          size = 0.25,
          position = "left",
        },
        {
          elements = { "repl", "console" },
          size = 0.25,
          position = "bottom",
        },
      },
      -- controls = {
      --   enabled = true,
      --   element = "repl",
      --   icons = {
      --     pause = "",
      --     play = "",
      --     step_into = "",
      --     step_over = "",
      --     step_out = "",
      --     step_back = "",
      --     run_last = "↻",
      --     terminate = "□",
      --   },
      -- },
      floating = {
        border = "single",
        mappings = {
          close = { "q", "<Esc>" },
        },
      },
      windows = { indent = 1 },
      render = {
        max_value_lines = 100,
      },
    })

    -- Automatically open/close dapui when debugging starts/stops
    dap.listeners.after.event_initialized["dapui_config"] = function()
      vim.schedule(function()
        dapui.open()
      end)
    end
    dap.listeners.before.event_terminated["dapui_config"] = function()
      vim.schedule(function()
        dapui.close()
      end)
    end
    dap.listeners.before.event_exited["dapui_config"] = function()
      vim.schedule(function()
        dapui.close()
      end)
    end

    -- Signs
    vim.fn.sign_define("DapBreakpoint", { text = "", texthl = "DapBreakpoint", linehl = "", numhl = "" })
    vim.fn.sign_define("DapStopped", { text = "", texthl = "DapStopped", linehl = "", numhl = "" })
    vim.fn.sign_define(
      "DapBreakpointRejected",
      { text = "", texthl = "DapBreakpointRejected", linehl = "", numhl = "" }
    )

    -- .NET Debugger config
    dap.adapters.coreclr = {
      type = "executable",
      command = "/home/kenr/Documents/debuggers/netcoredbg/netcoredbg",
      args = { "--interpreter=vscode" },
    }

    -- Utility functions for .NET project detection
    local function find_project_root(path)
      local sep = package.config:sub(1, 1)
      local dir = vim.fn.fnamemodify(path, ":p:h")
      while dir ~= "" and dir ~= sep do
        -- Look for .csproj, .sln, or .git
        local csproj = vim.fn.globpath(dir, "*.csproj", false, false)
        local sln = vim.fn.globpath(dir, "*.sln", false, false)
        if csproj ~= "" or sln ~= "" then
          return dir
        end
        if vim.fn.isdirectory(dir .. sep .. ".git") == 1 then
          return dir
        end
        dir = vim.fn.fnamemodify(dir, ":h")
      end
      return vim.fn.getcwd()
    end

    local function get_project_info(project_root)
      -- Find all .csproj files in the project
      local csproj_files = vim.fn.globpath(project_root, "**/*.csproj", false, true)
      local projects = {}
      
      for _, csproj in ipairs(csproj_files) do
        local project_name = vim.fn.fnamemodify(csproj, ":t:r")
        local project_dir = vim.fn.fnamemodify(csproj, ":h")
        
        -- Read project information from .csproj
        local target_framework = "net6.0" -- default
        local target_frameworks = {}
        local output_type = "Exe" -- default
        local is_web_app = false
        
        local content = vim.fn.readfile(csproj)
        for _, line in ipairs(content) do
          -- Single target framework
          local tf = line:match("<TargetFramework>([^<]+)</TargetFramework>")
          if tf then
            target_framework = tf
            table.insert(target_frameworks, tf)
          end
          
          -- Multiple target frameworks
          local tfs = line:match("<TargetFrameworks>([^<]+)</TargetFrameworks>")
          if tfs then
            for framework in tfs:gmatch("[^;]+") do
              table.insert(target_frameworks, framework)
            end
            target_framework = target_frameworks[1] -- Use first as default
          end
          
          -- Output type
          local ot = line:match("<OutputType>([^<]+)</OutputType>")
          if ot then
            output_type = ot
          end
          
          -- Check for web application references
          if line:match("Microsoft%.AspNetCore") or line:match("Microsoft%.Extensions%.Hosting") then
            is_web_app = true
          end
        end
        
        -- Read launchSettings.json if it exists
        local launch_settings_path = project_dir .. "/Properties/launchSettings.json"
        local launch_profiles = {}
        if vim.fn.filereadable(launch_settings_path) == 1 then
          local launch_content = table.concat(vim.fn.readfile(launch_settings_path), "\n")
          -- Basic JSON parsing for profiles (simplified)
          local profiles_section = launch_content:match('"profiles"%s*:%s*{([^}]+)}"')
          if profiles_section then
            for profile_name in profiles_section:gmatch('"([^"]+)"%s*:') do
              table.insert(launch_profiles, profile_name)
            end
          end
        end
        
        table.insert(projects, {
          name = project_name,
          path = project_dir,
          csproj = csproj,
          target_framework = target_framework,
          target_frameworks = target_frameworks,
          output_type = output_type,
          is_web_app = is_web_app,
          launch_profiles = launch_profiles,
        })
      end
      
      return projects
    end

    local function build_project(project_csproj)
      local build_cmd = "dotnet build \"" .. project_csproj .. "\""
      vim.notify("Building project: " .. vim.fn.fnamemodify(project_csproj, ":t"))
      
      local handle = io.popen(build_cmd .. " 2>&1")
      if handle then
        local result = handle:read("*a")
        local success = handle:close()
        
        if success then
          vim.notify("Build completed successfully", vim.log.levels.INFO)
          return true
        else
          vim.notify("Build failed:\n" .. result, vim.log.levels.ERROR)
          return false
        end
      end
      return false
    end

    local function find_dll_files(project_root)
      local files = {}
      local search_paths = {
        project_root .. "/bin/Debug/",
        project_root .. "/bin/Release/",
        -- Add artifact folders
        project_root .. "/artifacts/",
        project_root .. "/artifacts/bin/",
        project_root .. "/artifacts/publish/",
        project_root .. "/publish/",
        project_root .. "/out/",
        project_root .. "/dist/",
      }
      
      -- Add target framework specific paths
      local projects = get_project_info(project_root)
      for _, proj in ipairs(projects) do
        table.insert(search_paths, proj.path .. "/bin/Debug/" .. proj.target_framework .. "/")
        table.insert(search_paths, proj.path .. "/bin/Release/" .. proj.target_framework .. "/")
        -- Add artifact paths for each project
        table.insert(search_paths, proj.path .. "/artifacts/bin/" .. proj.name .. "/debug/" .. proj.target_framework .. "/")
        table.insert(search_paths, proj.path .. "/artifacts/bin/" .. proj.name .. "/release/" .. proj.target_framework .. "/")
        table.insert(search_paths, proj.path .. "/artifacts/publish/" .. proj.name .. "/debug/" .. proj.target_framework .. "/")
        table.insert(search_paths, proj.path .. "/artifacts/publish/" .. proj.name .. "/release/" .. proj.target_framework .. "/")
      end
      
      for _, search_path in ipairs(search_paths) do
        if vim.fn.isdirectory(search_path) == 1 then
          local handle = io.popen('find "' .. search_path .. '" -name "*.dll" 2>/dev/null')
          if handle then
            local result = handle:read("*a")
            handle:close()
            for file in result:gmatch("[^\r\n]+") do
              -- Skip system DLLs and test files
              local filename = vim.fn.fnamemodify(file, ":t")
              if not filename:match("^Microsoft%.") 
                and not filename:match("^System%.") 
                and not filename:match("^Newtonsoft%.") 
                and not filename:match("%.Test%.") 
                and not filename:match("%.Tests%.") then
                table.insert(files, file)
              end
            end
          end
        end
      end
      
      return files
    end

    local function get_dotnet_processes()
      local handle = io.popen('ps aux | grep "dotnet" | grep -v grep | awk \'{print $2 " " $11 " " $12 " " $13}\'')
      local processes = {}
      if handle then
        local result = handle:read("*a")
        handle:close()
        for line in result:gmatch("[^\r\n]+") do
          local pid, cmd = line:match("(%d+) (.+)")
          if pid and cmd then
            table.insert(processes, { pid = pid, command = cmd })
          end
        end
      end
      return processes
    end

    local function find_project_entry_point(project_root)
      -- Look for Program.cs or other entry points
      local entry_files = {
        project_root .. "/Program.cs",
        project_root .. "/Main.cs",
      }
      
      for _, file in ipairs(entry_files) do
        if vim.fn.filereadable(file) == 1 then
          return file
        end
      end
      
      -- Look for any .cs file with Main method
      local handle = io.popen('find "' .. project_root .. '" -name "*.cs" -exec grep -l "static.*Main" {} \\; 2>/dev/null')
      if handle then
        local result = handle:read("*a")
        handle:close()
        local first_match = result:match("[^\r\n]+")
        if first_match then
          return first_match
        end
      end
      
      return nil
    end

    dap.configurations.cs = {
      {
        type = "coreclr",
        name = "Build and Launch .NET Application (with args)",
        request = "launch",
        program = function()
          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local projects = get_project_info(project_root)
          
          -- Select project to build and run
          local selected_project = nil
          if #projects == 1 then
            selected_project = projects[1]
          elseif #projects > 1 then
            local pickers = require("telescope.pickers")
            local finders = require("telescope.finders")
            local actions = require("telescope.actions")
            local action_state = require("telescope.actions.state")
            local conf = require("telescope.config").values
            
            local co = coroutine.running()
            pickers
              .new({}, {
                prompt_title = "Select Project to Build and Debug",
                finder = finders.new_table({
                  results = projects,
                  entry_maker = function(entry)
                    return {
                      value = entry,
                      display = entry.name .. " (" .. entry.target_framework .. ")",
                      ordinal = entry.name,
                    }
                  end,
                }),
                sorter = conf.generic_sorter({}),
                attach_mappings = function(prompt_bufnr, map)
                  actions.select_default:replace(function()
                    actions.close(prompt_bufnr)
                    local selection = action_state.get_selected_entry()
                    coroutine.resume(co, selection.value)
                  end)
                  return true
                end,
              })
              :find()
            selected_project = coroutine.yield()
          else
            vim.notify("No .NET projects found", vim.log.levels.ERROR)
            return nil
          end
          
          -- Build the selected project
          if not build_project(selected_project.csproj) then
            return nil
          end
          
          -- Find the built DLL
          local dll_path = selected_project.path .. "/bin/Debug/" .. selected_project.target_framework .. "/" .. selected_project.name .. ".dll"
          if vim.fn.filereadable(dll_path) == 0 then
            -- Try release folder
            dll_path = selected_project.path .. "/bin/Release/" .. selected_project.target_framework .. "/" .. selected_project.name .. ".dll"
            if vim.fn.filereadable(dll_path) == 0 then
              -- Search in artifact folders
              local artifact_paths = {
                selected_project.path .. "/artifacts/bin/" .. selected_project.name .. "/debug/" .. selected_project.target_framework .. "/" .. selected_project.name .. ".dll",
                selected_project.path .. "/artifacts/bin/" .. selected_project.name .. "/release/" .. selected_project.target_framework .. "/" .. selected_project.name .. ".dll",
                selected_project.path .. "/artifacts/publish/" .. selected_project.name .. "/debug/" .. selected_project.target_framework .. "/" .. selected_project.name .. ".dll",
                selected_project.path .. "/artifacts/publish/" .. selected_project.name .. "/release/" .. selected_project.target_framework .. "/" .. selected_project.name .. ".dll",
              }
              
              for _, path in ipairs(artifact_paths) do
                if vim.fn.filereadable(path) == 1 then
                  dll_path = path
                  break
                end
              end
              
              if vim.fn.filereadable(dll_path) == 0 then
                vim.notify("Could not find built DLL for " .. selected_project.name, vim.log.levels.ERROR)
                return nil
              end
            end
          end
          
          vim.notify("Using DLL: " .. dll_path)
          return dll_path
        end,
        cwd = "${workspaceFolder}",
        stopAtEntry = false,
        console = "integratedTerminal",
        args = function()
          -- Prompt for command line arguments
          local args_input = vim.fn.input("Command line arguments (space-separated): ")
          if args_input and args_input ~= "" then
            -- Split arguments by spaces, respecting quoted strings
            local args = {}
            for arg in args_input:gmatch('%S+') do
              table.insert(args, arg)
            end
            return args
          end
          return {}
        end,
        env = function()
          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local launch_settings_path = project_root .. "/Properties/launchSettings.json"
          
          if vim.fn.filereadable(launch_settings_path) == 1 then
            local launch_content = table.concat(vim.fn.readfile(launch_settings_path), "\n")
            local env_vars = {}
            local env_section = launch_content:match('"environmentVariables"%s*:%s*{([^}]+)}')
            if env_section then
              for key, value in env_section:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
                env_vars[key] = value
              end
            end
            return env_vars
          end
          
          return {}
        end,
      },
      {
        type = "coreclr",
        name = "Launch .NET Application (DLL)",
        request = "launch",
        program = function()
          local pickers = require("telescope.pickers")
          local finders = require("telescope.finders")
          local actions = require("telescope.actions")
          local action_state = require("telescope.actions.state")
          local conf = require("telescope.config").values

          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local projects = get_project_info(project_root)
          
          vim.notify("Project root: " .. project_root)
          if #projects > 0 then
            vim.notify("Found " .. #projects .. " project(s)")
          end

          local files = find_dll_files(project_root)
          
          if #files == 0 then
            vim.notify("No DLL files found. Build your project first.", vim.log.levels.WARN)
            return nil
          end

          -- Sort files with project DLLs first
          table.sort(files, function(a, b)
            local a_name = vim.fn.fnamemodify(a, ":t:r")
            local b_name = vim.fn.fnamemodify(b, ":t:r")
            local a_is_project = false
            local b_is_project = false
            
            for _, proj in ipairs(projects) do
              if a_name == proj.name then a_is_project = true end
              if b_name == proj.name then b_is_project = true end
            end
            
            if a_is_project and not b_is_project then return true end
            if b_is_project and not a_is_project then return false end
            return a < b
          end)

          -- Preselect the first project DLL
          local preselect_idx = 1

          local co = coroutine.running()
          pickers
            .new({}, {
              prompt_title = "Select .NET Application to Debug",
              finder = finders.new_table({
                results = files,
                entry_maker = function(entry)
                  local name = vim.fn.fnamemodify(entry, ":t")
                  local dir = vim.fn.fnamemodify(entry, ":h")
                  local rel_dir = dir:gsub(vim.fn.getcwd() .. "/", "")
                  return {
                    value = entry,
                    display = name .. " (" .. rel_dir .. ")",
                    ordinal = name,
                  }
                end,
              }),
              sorter = conf.generic_sorter({}),
              default_selection_index = preselect_idx,
              attach_mappings = function(prompt_bufnr, map)
                actions.select_default:replace(function()
                  actions.close(prompt_bufnr)
                  local selection = action_state.get_selected_entry()
                  coroutine.resume(co, selection.value)
                end)
                return true
              end,
            })
            :find()
          return coroutine.yield()
        end,
        cwd = "${workspaceFolder}",
        stopAtEntry = false,
        console = "integratedTerminal",
        env = function()
          -- Read environment variables from launchSettings.json if available
          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local launch_settings_path = project_root .. "/Properties/launchSettings.json"
          
          if vim.fn.filereadable(launch_settings_path) == 1 then
            local launch_content = table.concat(vim.fn.readfile(launch_settings_path), "\n")
            -- Try to extract environment variables (simplified JSON parsing)
            local env_vars = {}
            local env_section = launch_content:match('"environmentVariables"%s*:%s*{([^}]+)}')
            if env_section then
              for key, value in env_section:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
                env_vars[key] = value
              end
            end
            return env_vars
          end
          
          return {}
        end,
      },
      {
        type = "coreclr",
        name = "Launch with dotnet run",
        request = "launch",
        program = "dotnet",
        args = function()
          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local projects = get_project_info(project_root)
          
          if #projects == 1 then
            return { "run", "--project", projects[1].csproj }
          elseif #projects > 1 then
            -- Let user select which project to run
            local pickers = require("telescope.pickers")
            local finders = require("telescope.finders")
            local actions = require("telescope.actions")
            local action_state = require("telescope.actions.state")
            local conf = require("telescope.config").values
            
            local co = coroutine.running()
            pickers
              .new({}, {
                prompt_title = "Select Project to Run",
                finder = finders.new_table({
                  results = projects,
                  entry_maker = function(entry)
                    return {
                      value = entry,
                      display = entry.name .. " (" .. entry.target_framework .. ")",
                      ordinal = entry.name,
                    }
                  end,
                }),
                sorter = conf.generic_sorter({}),
                attach_mappings = function(prompt_bufnr, map)
                  actions.select_default:replace(function()
                    actions.close(prompt_bufnr)
                    local selection = action_state.get_selected_entry()
                    coroutine.resume(co, { "run", "--project", selection.value.csproj })
                  end)
                  return true
                end,
              })
              :find()
            return coroutine.yield()
          else
            return { "run" }
          end
        end,
        cwd = "${workspaceFolder}",
        stopAtEntry = false,
        console = "integratedTerminal",
        env = function()
          -- Read environment variables from launchSettings.json if available
          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local launch_settings_path = project_root .. "/Properties/launchSettings.json"
          
          if vim.fn.filereadable(launch_settings_path) == 1 then
            local launch_content = table.concat(vim.fn.readfile(launch_settings_path), "\n")
            -- Try to extract environment variables (simplified JSON parsing)
            local env_vars = {}
            local env_section = launch_content:match('"environmentVariables"%s*:%s*{([^}]+)}')
            if env_section then
              for key, value in env_section:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
                env_vars[key] = value
              end
            end
            return env_vars
          end
          
          return {}
        end,
      },
      {
        type = "coreclr",
        name = "Attach to .NET Process",
        request = "attach",
        processId = function()
          local processes = get_dotnet_processes()
          
          if #processes == 0 then
            vim.notify("No .NET processes found", vim.log.levels.WARN)
            return nil
          end
          
          local pickers = require("telescope.pickers")
          local finders = require("telescope.finders")
          local actions = require("telescope.actions")
          local action_state = require("telescope.actions.state")
          local conf = require("telescope.config").values
          
          local co = coroutine.running()
          pickers
            .new({}, {
              prompt_title = "Select .NET Process to Attach",
              finder = finders.new_table({
                results = processes,
                entry_maker = function(entry)
                  return {
                    value = entry.pid,
                    display = entry.pid .. " - " .. entry.command,
                    ordinal = entry.pid .. " " .. entry.command,
                  }
                end,
              }),
              sorter = conf.generic_sorter({}),
              attach_mappings = function(prompt_bufnr, map)
                actions.select_default:replace(function()
                  actions.close(prompt_bufnr)
                  local selection = action_state.get_selected_entry()
                  coroutine.resume(co, tonumber(selection.value))
                end)
                return true
              end,
            })
            :find()
          return coroutine.yield()
        end,
      },
      {
        type = "coreclr",
        name = "Launch .NET Application (with stdin file)",
        request = "launch",
        program = function()
          local pickers = require("telescope.pickers")
          local finders = require("telescope.finders")
          local actions = require("telescope.actions")
          local action_state = require("telescope.actions.state")
          local conf = require("telescope.config").values

          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local files = find_dll_files(project_root)
          
          if #files == 0 then
            vim.notify("No DLL files found. Build your project first.", vim.log.levels.WARN)
            return nil
          end

          local co = coroutine.running()
          pickers
            .new({}, {
              prompt_title = "Select .NET Application to Debug",
              finder = finders.new_table({
                results = files,
                entry_maker = function(entry)
                  local name = vim.fn.fnamemodify(entry, ":t")
                  local dir = vim.fn.fnamemodify(entry, ":h")
                  local rel_dir = dir:gsub(vim.fn.getcwd() .. "/", "")
                  return {
                    value = entry,
                    display = name .. " (" .. rel_dir .. ")",
                    ordinal = name,
                  }
                end,
              }),
              sorter = conf.generic_sorter({}),
              attach_mappings = function(prompt_bufnr, map)
                actions.select_default:replace(function()
                  actions.close(prompt_bufnr)
                  local selection = action_state.get_selected_entry()
                  coroutine.resume(co, selection.value)
                end)
                return true
              end,
            })
            :find()
          return coroutine.yield()
        end,
        cwd = "${workspaceFolder}",
        stopAtEntry = false,
        console = "integratedTerminal",
        args = function()
          local args_input = vim.fn.input("Command line arguments (space-separated): ")
          local args = {}
          if args_input and args_input ~= "" then
            for arg in args_input:gmatch('%S+') do
              table.insert(args, arg)
            end
          end
          
          -- Ask for stdin input file
          local stdin_file = vim.fn.input("Path to stdin input file (optional): ")
          if stdin_file and stdin_file ~= "" and vim.fn.filereadable(stdin_file) == 1 then
            -- Add input redirection
            table.insert(args, 1, "<")
            table.insert(args, 2, stdin_file)
          end
          
          return args
        end,
        env = function()
          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local launch_settings_path = project_root .. "/Properties/launchSettings.json"
          
          if vim.fn.filereadable(launch_settings_path) == 1 then
            local launch_content = table.concat(vim.fn.readfile(launch_settings_path), "\n")
            local env_vars = {}
            local env_section = launch_content:match('"environmentVariables"%s*:%s*{([^}]+)}')
            if env_section then
              for key, value in env_section:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
                env_vars[key] = value
              end
            end
            return env_vars
          end
          
          return {}
        end,
      },
      {
        type = "coreclr",
        name = "Interactive Debug Session",
        request = "launch",
        program = function()
          local pickers = require("telescope.pickers")
          local finders = require("telescope.finders")
          local actions = require("telescope.actions")
          local action_state = require("telescope.actions.state")
          local conf = require("telescope.config").values

          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local files = find_dll_files(project_root)
          
          if #files == 0 then
            vim.notify("No DLL files found. Build your project first.", vim.log.levels.WARN)
            return nil
          end

          local co = coroutine.running()
          pickers
            .new({}, {
              prompt_title = "Select .NET Application for Interactive Debug",
              finder = finders.new_table({
                results = files,
                entry_maker = function(entry)
                  local name = vim.fn.fnamemodify(entry, ":t")
                  local dir = vim.fn.fnamemodify(entry, ":h")
                  local rel_dir = dir:gsub(vim.fn.getcwd() .. "/", "")
                  return {
                    value = entry,
                    display = name .. " (" .. rel_dir .. ")",
                    ordinal = name,
                  }
                end,
              }),
              sorter = conf.generic_sorter({}),
              attach_mappings = function(prompt_bufnr, map)
                actions.select_default:replace(function()
                  actions.close(prompt_bufnr)
                  local selection = action_state.get_selected_entry()
                  coroutine.resume(co, selection.value)
                end)
                return true
              end,
            })
            :find()
          return coroutine.yield()
        end,
        cwd = "${workspaceFolder}",
        stopAtEntry = true,  -- Always stop at entry for interactive session
        console = "integratedTerminal",
        args = function()
          -- Interactive prompt for multiple types of input
          local input_method = vim.fn.input("Input method: [1] Args [2] Stdin file [3] Both [4] None: ")
          local args = {}
          
          if input_method == "1" or input_method == "3" then
            local args_input = vim.fn.input("Command line arguments: ")
            if args_input and args_input ~= "" then
              for arg in args_input:gmatch('%S+') do
                table.insert(args, arg)
              end
            end
          end
          
          if input_method == "2" or input_method == "3" then
            local stdin_file = vim.fn.input("Stdin input file path: ")
            if stdin_file and stdin_file ~= "" and vim.fn.filereadable(stdin_file) == 1 then
              table.insert(args, 1, "<")
              table.insert(args, 2, stdin_file)
            end
          end
          
          return args
        end,
        env = function()
          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          local launch_settings_path = project_root .. "/Properties/launchSettings.json"
          
          local env_vars = {}
          
          -- Load from launchSettings.json first
          if vim.fn.filereadable(launch_settings_path) == 1 then
            local launch_content = table.concat(vim.fn.readfile(launch_settings_path), "\n")
            local env_section = launch_content:match('"environmentVariables"%s*:%s*{([^}]+)}')
            if env_section then
              for key, value in env_section:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
                env_vars[key] = value
              end
            end
          end
          
          -- Ask for additional environment variables
          local add_env = vim.fn.input("Add environment variables? [y/N]: ")
          if add_env:lower() == "y" or add_env:lower() == "yes" then
            while true do
              local env_var = vim.fn.input("Environment variable (KEY=VALUE, empty to finish): ")
              if env_var == "" then break end
              
              local key, value = env_var:match("([^=]+)=(.+)")
              if key and value then
                env_vars[key] = value
                vim.notify("Added: " .. key .. "=" .. value)
              else
                vim.notify("Invalid format. Use KEY=VALUE", vim.log.levels.WARN)
              end
            end
          end
          
          return env_vars
        end,
      },
      {
        type = "coreclr",
        name = "Debug .NET Tests",
        request = "launch",
        program = "dotnet",
        args = function()
          local buf_path = vim.api.nvim_buf_get_name(0)
          local project_root = find_project_root(buf_path)
          
          -- Look for test projects
          local test_projects = {}
          local projects = get_project_info(project_root)
          
          for _, proj in ipairs(projects) do
            if proj.name:match("%.Test") or proj.name:match("%.Tests") then
              table.insert(test_projects, proj)
            end
          end
          
          if #test_projects == 0 then
            vim.notify("No test projects found", vim.log.levels.WARN)
            return { "test" }
          elseif #test_projects == 1 then
            return { "test", test_projects[1].csproj }
          else
            local pickers = require("telescope.pickers")
            local finders = require("telescope.finders")
            local actions = require("telescope.actions")
            local action_state = require("telescope.actions.state")
            local conf = require("telescope.config").values
            
            local co = coroutine.running()
            pickers
              .new({}, {
                prompt_title = "Select Test Project",
                finder = finders.new_table({
                  results = test_projects,
                  entry_maker = function(entry)
                    return {
                      value = entry,
                      display = entry.name,
                      ordinal = entry.name,
                    }
                  end,
                }),
                sorter = conf.generic_sorter({}),
                attach_mappings = function(prompt_bufnr, map)
                  actions.select_default:replace(function()
                    actions.close(prompt_bufnr)
                    local selection = action_state.get_selected_entry()
                    coroutine.resume(co, { "test", selection.value.csproj })
                  end)
                  return true
                end,
              })
              :find()
            return coroutine.yield()
          end
        end,
        cwd = "${workspaceFolder}",
        stopAtEntry = false,
        console = "integratedTerminal",
      },
    }

    -- Keybindings
    local map = vim.keymap.set
    local opts = { noremap = true, silent = true }
    map("n", "<F5>", function()
      require("dap").continue()
    end, opts)
    map("n", "<F9>", function()
      require("dap").toggle_breakpoint()
    end, opts)
    map("n", "<F10>", function()
      require("dap").step_over()
    end, opts)
    map("n", "<F11>", function()
      require("dap").step_into()
    end, opts)
    map("n", "<F8>", function()
      require("dap").step_out()
    end, opts)
    map("n", "<leader>dr", function()
      require("dap").repl.open()
    end, opts)
    map("n", "<leader>dl", function()
      require("dap").run_last()
    end, opts)
    map("n", "<space>?", function()
      require("dapui").eval(nil, { enter = true })
    end, opts)
    -- vim.api.nvim_create_autocmd("CursorHold", {
    --   pattern = "*",
    --   callback = function()
    --     local dapui = require("dapui")
    --     dapui.eval(nil, { enter = true, context = nil, width = nil, height = nil })
    --   end,
    --   desc = "Show DAP eval on hover",
    -- })
  end,
}
