#!/usr/bin/env lua
--
-- goimpl_builtin.lua
-- Copyright (C) 2021 edolphin <dngfngyang@gmail.com>
--
-- Distributed under terms of the MIT license.
--

local actions = require("telescope.actions")
local state = require("telescope.actions.state")
local actions_set = require("telescope.actions.set")
local conf = require("telescope.config").values
local finders = require("telescope.finders")
local make_entry = require("telescope.make_entry")
local pickers = require("telescope.pickers")
local ts_utils = require("nvim-treesitter.ts_utils")

-- Logger using vim.notify
local logger = {
	trace = function(msg)
		vim.schedule(function()
			vim.notify(msg, vim.log.levels.TRACE, { title = "goimpl" })
		end)
	end,
	debug = function(msg)
		vim.schedule(function()
			vim.notify(msg, vim.log.levels.DEBUG, { title = "goimpl" })
		end)
	end,
	info = function(msg)
		vim.schedule(function()
			vim.notify(msg, vim.log.levels.INFO, { title = "goimpl" })
		end)
	end,
	warn = function(msg)
		vim.schedule(function()
			vim.notify(msg, vim.log.levels.WARN, { title = "goimpl" })
		end)
	end,
	error = function(msg)
		vim.schedule(function()
			vim.notify(msg, vim.log.levels.ERROR, { title = "goimpl" })
		end)
	end,
	fatal = function(msg)
		vim.schedule(function()
			vim.notify(msg, vim.log.levels.ERROR, { title = "goimpl" })
		end)
	end,
}

local ts = vim.treesitter
local tsq = vim.treesitter.query

-- Helper function to get node text
local function _get_node_text(node, source, opts)
	return (ts.get_node_text or tsq.get_node_text)(node, source, opts)
end

local M = {}

-- Get symbol kind name according to LSP specification
local function _get_symbol_kind_name(symbol_kind)
	return vim.lsp.protocol.SymbolKind[symbol_kind] or "Unknown"
end

-- Convert symbols to quickfix list items
local function interfaces_to_items(symbols, bufnr)
	if not symbols or not bufnr then
		return {}
	end

	local function _interfaces_to_items(_symbols, _items, _bufnr)
		for _, symbol in ipairs(_symbols) do
			if symbol.location then -- SymbolInformation type
				local range = symbol.location.range
				local kind = _get_symbol_kind_name(symbol.kind)
				if kind == "Interface" then
					table.insert(_items, {
						filename = vim.uri_to_fname(symbol.location.uri),
						lnum = range.start.line + 1,
						col = range.start.character + 1,
						kind = kind,
						text = "[" .. kind .. "] " .. symbol.name,
						containerName = symbol.containerName,
						symbol_name = symbol.name,
						value = { containerName = symbol.containerName },
					})
				end
			elseif symbol.selectionRange then -- DocumentSymbol type
				local kind = _get_symbol_kind_name(symbol.kind)
				if kind == "Interface" then
					table.insert(_items, {
						filename = vim.api.nvim_buf_get_name(_bufnr),
						lnum = symbol.selectionRange.start.line + 1,
						col = symbol.selectionRange.start.character + 1,
						kind = kind,
						text = "[" .. kind .. "] " .. symbol.name,
						containerName = symbol.containerName,
						symbol_name = symbol.name,
						value = { containerName = symbol.containerName },
					})
				end
				if symbol.children then
					_interfaces_to_items(symbol.children, _items, _bufnr)
				end
			end
		end
		return _items
	end
	return _interfaces_to_items(symbols, {}, bufnr)
end

-- Create workspace symbols requester with proper async handling for Telescope
local function get_workspace_symbols_requester(bufnr, opts)
	if not bufnr then
		return function(prompt)
			return {}
		end
	end

	local last_request_id = 0
	local pending_requests = {}

	return function(prompt)
		-- Cancel all pending requests
		for request_id, cancel_fn in pairs(pending_requests) do
			if cancel_fn then
				cancel_fn()
			end
			pending_requests[request_id] = nil
		end

		last_request_id = last_request_id + 1
		local current_request_id = last_request_id

		-- Return a promise-like table that Telescope expects
		local results = {}
		local completed = false

		local request_params = { query = prompt or "" }

		local _, cancel_fn = vim.lsp.buf_request(bufnr, "workspace/symbol", request_params, function(err, res)
			-- Clean up this request from pending list
			pending_requests[current_request_id] = nil

			-- Check if this is still the latest request
			if current_request_id ~= last_request_id then
				return -- Ignore outdated response
			end

			if err then
				logger.error("LSP request failed: " .. tostring(err))
				completed = true
				return
			end

			local locations = interfaces_to_items(res or {}, bufnr) or {}
			for _, location in ipairs(locations) do
				table.insert(results, location)
			end
			completed = true
		end)

		-- Store cancel function for this request
		pending_requests[current_request_id] = cancel_fn

		-- Wait for completion with timeout
		local timeout = 5000 -- 5 seconds
		local start_time = vim.uv.now()

		while not completed do
			vim.wait(10, function() return completed end, 10)
			if vim.uv.now() - start_time > timeout then
				logger.warn("LSP workspace symbol request timeout")
				if cancel_fn then
					cancel_fn()
				end
				pending_requests[current_request_id] = nil
				break
			end
		end

		return results
	end
end

-- Split string by separator
local function split(inputstr, sep)
	if not inputstr or type(inputstr) ~= "string" then
		return {}
	end
	if sep == nil then
		sep = "%s"
	end
	local t = {}
	for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
		table.insert(t, str)
	end
	return t
end

-- Handle job output data
local function handle_job_data(data)
	if not data or type(data) ~= "table" then
		return nil
	end
	if #data > 0 and data[#data] == "" then
		table.remove(data, #data)
	end
	if #data < 1 then
		return nil
	end
	return data
end

-- Treesitter queries for Go interface parsing
local interface_declaration_query = vim.treesitter.query.parse(
	"go",
	[[
(type_declaration
(type_spec
  type: (interface_type))
) @interface_declaration
]]
)

local generic_type_name_parameters_query = vim.treesitter.query.parse(
	"go",
	[[
	[
(type_spec
  name: (type_identifier) @interface.generic.name
  type_parameters: (type_parameter_list) @interface.generic.type_parameters
  type: (interface_type) )
]
	]]
)

local type_parameter_name_query = vim.treesitter.query.parse(
	"go",
	[[(type_parameter_declaration
  name: (identifier) @type_parameter_name)
  ]]
)

-- Extract type parameter names from a node
local function get_type_parameter_name_list(node, buf)
	if not node then
		return {}
	end
	local type_parameter_names = {}
	for _, tnode, _ in type_parameter_name_query:iter_captures(node, buf or 0) do
		type_parameter_names[#type_parameter_names + 1] = _get_node_text(tnode, buf or 0)
	end
	return type_parameter_names
end

-- Format type parameter names as a string
local function format_type_parameter_name_list(type_parameter_names)
	if not type_parameter_names or #type_parameter_names == 0 then
		return ""
	end
	return "[" .. table.concat(type_parameter_names, ", ") .. "]"
end

-- Async file loading
local function load_file_to_buffer_async(filepath, buf, callback)
	if not filepath or not buf or not callback then
		if callback then
			callback(false, "Invalid parameters")
		end
		return
	end

	-- Use vim.uv for async file operations
	vim.uv.fs_open(filepath, "r", 438, function(err, fd)
		if err then
			callback(false, "File not found: " .. filepath)
			return
		end

		vim.uv.fs_fstat(fd, function(stat_err, stat)
			if stat_err then
				vim.uv.fs_close(fd)
				callback(false, "Failed to stat file: " .. filepath)
				return
			end

			vim.uv.fs_read(fd, stat.size, 0, function(read_err, data)
				vim.uv.fs_close(fd)

				if read_err then
					callback(false, "Failed to read file: " .. filepath)
					return
				end

				if not data or data == "" then
					callback(false, "File is empty: " .. filepath)
					return
				end

				-- Schedule buffer operations on main thread
				vim.schedule(function()
					local ok, set_err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(data, "\n"))
					if not ok then
						callback(false, "Failed to load content to buffer: " .. tostring(set_err))
						return
					end
					callback(true)
				end)
			end)
		end)
	end)
end

-- Async interface generic type parameters extraction
local function get_interface_generic_type_parameters_async(file, interface_name, callback)
	if not callback then
		return
	end

	if not file or not interface_name then
		callback("")
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	if not buf or buf == 0 then
		logger.error("Failed to create buffer")
		callback("")
		return
	end

	local function cleanup_and_return(result)
		vim.schedule(function()
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end)
		callback(result or "")
	end

	-- Set filetype async
	vim.schedule(function()
		local ok, errmsg = pcall(vim.api.nvim_set_option_value, "filetype", "go", { buf = buf })
		if not ok then
			logger.info(("can't set filetype to 'go' (%s). Formatting is canceled"):format(errmsg))
			cleanup_and_return("")
			return
		end

		-- Load file async
		load_file_to_buffer_async(file, buf, function(success, err)
			if not success then
				logger.error("Failed to load file: " .. (err or "unknown error"))
				cleanup_and_return("")
				return
			end

			-- Parse treesitter async
			vim.schedule(function()
				local parser_ok, parser = pcall(vim.treesitter.get_parser, buf, "go")
				if not parser_ok or not parser then
					logger.error("Failed to get treesitter parser")
					cleanup_and_return("")
					return
				end

				local tree_ok, trees = pcall(parser.parse, parser)
				if not tree_ok or not trees or #trees == 0 then
					logger.error("Failed to parse tree")
					cleanup_and_return("")
					return
				end

				local tree = trees[1]
				local root = tree:root()

				for _, node, _ in interface_declaration_query:iter_captures(root, buf) do
					local is_check_interface = false
					for iid, inode, _ in generic_type_name_parameters_query:iter_captures(node, buf) do
						local name = generic_type_name_parameters_query.captures[iid]
						if name == "interface.generic.name" then
							local current_interface_name = _get_node_text(inode, buf)
							if current_interface_name == interface_name then
								is_check_interface = true
							end
						end
					end

					if is_check_interface then
						for iid, inode, _ in generic_type_name_parameters_query:iter_captures(node, buf) do
							local name = generic_type_name_parameters_query.captures[iid]
							if name == "interface.generic.type_parameters" then
								local type_parameter_names = get_type_parameter_name_list(inode, buf)
								cleanup_and_return(format_type_parameter_name_list(type_parameter_names))
								return
							end
						end
					end
				end

				cleanup_and_return("")
			end)
		end)
	end)
end

-- Async impl command execution
local function run_impl_command_async(cmd_args, cwd, callback)
	if not callback then
		return
	end

	local stdout = {}
	local stderr = {}

	local stdout_pipe = vim.uv.new_pipe()
	local stderr_pipe = vim.uv.new_pipe()

	local handle, pid = vim.uv.spawn(cmd_args[1], {
		args = vim.list_slice(cmd_args, 2),
		cwd = cwd,
		stdio = { nil, stdout_pipe, stderr_pipe },
	}, function(code)
		stdout_pipe:close()
		stderr_pipe:close()

		callback({
			code = code,
			stdout = table.concat(stdout),
			stderr = table.concat(stderr),
		})
	end)

	if not handle then
		callback({ code = -1, stdout = "", stderr = "Failed to spawn process" })
		return
	end

	-- Read stdout asynchronously
	stdout_pipe:read_start(function(err, data)
		if err then
			logger.error("stdout read error: " .. tostring(err))
		elseif data then
			table.insert(stdout, data)
		end
	end)

	-- Read stderr asynchronously
	stderr_pipe:read_start(function(err, data)
		if err then
			logger.error("stderr read error: " .. tostring(err))
		elseif data then
			table.insert(stderr, data)
		end
	end)
end

-- Insert generated implementation into buffer
local function insert_implementation(tsnode, data, interface_name, result)
	if not data or #data == 0 then
		logger.warn("No implementation generated")
		if result.stderr and result.stderr ~= "" then
			logger.error("impl stderr: " .. result.stderr)
		end
		return
	end

	if data[1] and (string.find(data[1], "unrecognized interface:") or string.find(data[1], "couldn't find")) then
		logger.error("Interface not found: " .. interface_name)
		return
	end

	local parent = tsnode:parent()
	if not parent then
		logger.error("Node has no parent")
		return
	end

	local grandparent = parent:parent()
	if not grandparent then
		logger.error("Node has no grandparent")
		return
	end

	local _, _, pos, _ = grandparent:range()
	pos = pos + 1

	vim.schedule(function()
		vim.fn.append(pos, "")
		pos = pos + 1
		vim.fn.append(pos, data)
		logger.info("Implementation generated successfully")
	end)
end

-- Async Go implementation generator
local function goimpl_async(tsnode, packageName, interface, type_parameter_list, callback)
	if not tsnode or not interface then
		logger.error("Missing required parameters for goimpl")
		if callback then
			callback(false)
		end
		return
	end

	local rec2 = _get_node_text(tsnode, 0)
	if not rec2 or rec2 == "" then
		logger.error("Failed to get node text")
		if callback then
			callback(false)
		end
		return
	end

	local rec1 = string.lower(string.sub(rec2, 1, math.min(2, #rec2)))
	if rec1 == "" then
		rec1 = "r"
	end

	local type_parameter_names = ""
	if tsnode:parent() then
		type_parameter_names = format_type_parameter_name_list(get_type_parameter_name_list(tsnode:parent()))
	end
	rec2 = rec2 .. type_parameter_names

	local dirname = vim.fn.expand("%:p:h")
	if not dirname or dirname == "" then
		logger.error("Failed to get current directory")
		if callback then
			callback(false)
		end
		return
	end

	local receiver = rec1 .. " *" .. rec2
	local interface_name = (packageName and (packageName .. ".") or "") .. interface .. (type_parameter_list or "")

	local cmd_args = {
		"impl",
		"-dir",
		dirname,
		receiver,
		interface_name,
	}

	logger.info("Generating implementation for interface: " .. interface_name)
	-- logger.info('Running command: impl -dir "' .. dirname .. '" "' .. receiver .. '" "' .. interface_name .. '"')

	local function process_result(result)
		local data = result.stdout and vim.split(result.stdout, "\n") or {}
		data = handle_job_data(data)

		local needs_retry = not data
			or #data == 0
			or (data[1] and (string.find(data[1], "unrecognized interface:") or string.find(data[1], "couldn't find")))

		if needs_retry and packageName then
			local fallback_interface = interface .. (type_parameter_list or "")
			local fallback_args = {
				"impl",
				"-dir",
				dirname,
				receiver,
				fallback_interface,
			}

			logger.debug(
				'Trying fallback command: impl -dir "'
					.. dirname
					.. '" "'
					.. receiver
					.. '" "'
					.. fallback_interface
					.. '"'
			)

			run_impl_command_async(fallback_args, dirname, function(fallback_result)
				local fallback_data = fallback_result.stdout and vim.split(fallback_result.stdout, "\n") or {}
				fallback_data = handle_job_data(fallback_data)

				if fallback_data and #fallback_data > 0 then
					data = fallback_data
				end

				insert_implementation(tsnode, data, interface_name, fallback_result)
				if callback then
					callback(true)
				end
			end)
			return
		end

		insert_implementation(tsnode, data, interface_name, result)
		if callback then
			callback(true)
		end
	end

	run_impl_command_async(cmd_args, dirname, process_result)
end

-- Main function to generate Go interface implementation
M.goimpl = function(opts)
	opts = opts or {}
	local curr_bufnr = vim.api.nvim_get_current_buf()
	if not curr_bufnr or curr_bufnr == 0 then
		logger.error("Invalid current buffer")
		return
	end

	local tsnode = ts_utils.get_node_at_cursor()
	if not tsnode then
		print("No node found under cursor")
		return
	end

	if
		tsnode:type() ~= "type_identifier"
		or not tsnode:parent()
		or tsnode:parent():type() ~= "type_spec"
		or not tsnode:parent():parent()
		or tsnode:parent():parent():type() ~= "type_declaration"
	then
		print("No type identifier found under cursor")
		return
	end

	pickers
		.new(opts, {
			prompt_title = "Go Impl",
			finder = finders.new_dynamic({
				entry_maker = opts.entry_maker or make_entry.gen_from_lsp_symbols(opts),
				fn = get_workspace_symbols_requester(curr_bufnr, opts),
			}),
			previewer = conf.qflist_previewer(opts),
			sorter = conf.generic_sorter(),
			attach_mappings = function(prompt_bufnr)
				actions_set.select:replace(function(_, _)
					local entry = state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not entry or not entry.symbol_name then
						logger.warn("No valid entry selected")
						return
					end

					local symbol_name = split(entry.symbol_name, ".")
					symbol_name = symbol_name[#symbol_name]

					if not symbol_name or symbol_name == "" then
						logger.error("Invalid symbol name")
						return
					end

					local containerName = entry.value and entry.value.containerName

					-- Get type parameters async
					if entry.filename then
						get_interface_generic_type_parameters_async(
							entry.filename,
							symbol_name,
							function(type_parameter_list)
								goimpl_async(tsnode, containerName, symbol_name, type_parameter_list, function(success)
									if not success then
										logger.error("Failed to generate implementation")
									end
								end)
							end
						)
					else
						goimpl_async(tsnode, containerName, symbol_name, "", function(success)
							if not success then
								logger.error("Failed to generate implementation")
							end
						end)
					end
				end)
				return true
			end,
		})
		:find()
end

return M

