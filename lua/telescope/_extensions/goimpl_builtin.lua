#! /usr/bin/env lua
--
-- goimpl_builtin.lua
-- Copyright (C) 2021 edolphin <dngfngyang@gmail.com>
--
-- Distributed under terms of the MIT license.
--

local actions = require 'telescope.actions'
local state = require 'telescope.actions.state'
local actions_set = require 'telescope.actions.set'
local conf = require 'telescope.config'.values
local finders = require 'telescope.finders'
local make_entry = require "telescope.make_entry"
local pickers = require 'telescope.pickers'
local ts_utils = require 'nvim-treesitter.ts_utils'
local channel = require("plenary.async.control").channel

local function prequire(mod)
	local ok, res = pcall(require, mod)
	if ok then
		return res
	end
	return nil
end

local plog = prequire("plenary.log")
local logger
if not plog then
	local emptyFun = function(_) end
	logger = {
		trace = emptyFun,
		debug = emptyFun,
		info = emptyFun,
		warn = emptyFun,
		error = emptyFun,
		fatal = emptyFun,
	}
else
	logger = plog.new {
		plugin = 'goimpl',
		use_console = true,
		use_file = true,
	}
end

local ts = vim.treesitter
local tsq = vim.treesitter.query

local function _get_node_text(node, source, opts)
	return (ts.get_node_text or tsq.get_node_text)(node, source, opts)
end

local M = {}

-- According to LSP spec, if the client set "symbolKind.valueSet",
-- the client must handle it properly even if it receives a value outside the specification.
-- https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_documentSymbol
local function _get_symbol_kind_name(symbol_kind)
	return vim.lsp.protocol.SymbolKind[symbol_kind] or "Unknown"
end

-- containerName
--- Converts symbols to quickfix list items.
--- copied from neovim runtime in order to add the containerName from symbol
---
--@param symbols DocumentSymbol[] or SymbolInformation[]
--@param bufnr number
--@return table[]
local function interfaces_to_items(symbols, bufnr)
	if not symbols or not bufnr then
		return {}
	end
	
	--@private
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
						text = '[' .. kind .. '] ' .. symbol.name,
						containerName = symbol.containerName
					})
				end
			elseif symbol.selectionRange then -- DocumentSymbol type
				local kind = _get_symbol_kind_name(symbol.kind) -- 修复：使用正确的函数名
				if kind == "Interface" then
					table.insert(_items, {
						filename = vim.api.nvim_buf_get_name(_bufnr),
						lnum = symbol.selectionRange.start.line + 1,
						col = symbol.selectionRange.start.character + 1,
						kind = kind,
						text = '[' .. kind .. '] ' .. symbol.name,
						containerName = symbol.containerName
					})
				end
				if symbol.children then
					-- 修复：正确处理递归调用
					_interfaces_to_items(symbol.children, _items, _bufnr)
				end
			end
		end
		return _items
	end
	return _interfaces_to_items(symbols, {}, bufnr)
end

local function get_workspace_symbols_requester(bufnr, opts)
	if not bufnr then
		return function() return {} end
	end
	
	local cancel = function() end
	return function(prompt)
		local tx, rx = channel.oneshot()
		cancel()
		_, cancel = vim.lsp.buf_request(bufnr, "workspace/symbol", { query = prompt or "" }, tx)

		-- Handle 0.5 / 0.5.1 handler situation
		local err, res = rx()
		if err then
			logger.error("LSP request failed: " .. tostring(err))
			return {}
		end

		local locations = interfaces_to_items(res or {}, bufnr) or {}
		return locations
	end
end

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

local function handle_job_data(data)
	if not data or type(data) ~= "table" then
		return nil
	end
	-- Because the nvim.stdout's data will have an extra empty line at end on some OS (e.g. macOS), we should remove it.
	if #data > 0 and data[#data] == '' then
		table.remove(data, #data)
	end
	if #data < 1 then
		return nil
	end
	return data
end

local interface_declaration_query = vim.treesitter.query.parse("go", [[
(type_declaration
(type_spec
  type: (interface_type))
) @interface_declaration
]])

local generic_type_name_parameters_query = vim.treesitter.query.parse("go", [[
	[
(type_spec
  name: (type_identifier) @interface.generic.name
  type_parameters: (type_parameter_list) @interface.generic.type_parameters
  type: (interface_type) )
]
	]])

local type_parameter_name_query = vim.treesitter.query.parse("go", [[(type_parameter_declaration
  name: (identifier) @type_parameter_name)
  ]])

local function get_type_parameter_name_list(node, buf)
	if not node then
		return {}
	end
	local type_parameter_names = {}
	for _, tnode, _ in type_parameter_name_query:iter_captures(node, buf or 0) do
		-- 修复：使用一致的API调用
		type_parameter_names[#type_parameter_names + 1] = _get_node_text(tnode, buf or 0)
	end

	return type_parameter_names
end

local function format_type_parameter_name_list(type_parameter_names)
	if not type_parameter_names or #type_parameter_names == 0 then
		return ""
	end
	return "[" .. table.concat(type_parameter_names, ", ") .. "]"
end

local function load_file_to_buffer(filepath, buf)
	if not filepath or not buf then
		return false
	end
	
	local file = io.open(filepath, "r")
	if not file then
		logger.info("file not found: " .. filepath)
		return false
	end

	local content = file:read("*all")
	file:close()
	
	if not content then
		logger.warn("file is empty: " .. filepath)
		return false
	end
	
	logger.debug("Loading file content: " .. filepath)

	-- 将内容写入缓冲区
	local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(content, "\n"))
	if not ok then
		logger.error("Failed to load content to buffer: " .. tostring(err))
		return false
	end

	return true
end

local function get_interface_generic_type_parameters(file, interface_name)
	if not file or not interface_name then
		return ""
	end
	
	local buf = vim.api.nvim_create_buf(false, true)
	if not buf or buf == 0 then
		logger.error("Failed to create buffer")
		return ""
	end
	
	-- 使用pcall保护资源清理
	local function cleanup_and_return(result)
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		return result or ""
	end
	
	local ok, errmsg = pcall(vim.api.nvim_set_option_value, "filetype", "go", { buf = buf })
	if not ok then
		local msg = ("can't set filetype to 'go' (%s). Formatting is canceled"):format(errmsg)
		logger.info(msg)
		return cleanup_and_return("")
	end

	if not load_file_to_buffer(file, buf) then
		return cleanup_and_return("")
	end

	local parser_ok, parser = pcall(vim.treesitter.get_parser, buf, "go")
	if not parser_ok or not parser then
		logger.error("Failed to get treesitter parser")
		return cleanup_and_return("")
	end
	
	local tree_ok, trees = pcall(parser.parse, parser)
	if not tree_ok or not trees or #trees == 0 then
		logger.error("Failed to parse tree")
		return cleanup_and_return("")
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
					return cleanup_and_return(format_type_parameter_name_list(type_parameter_names))
				end
			end
		end
	end

	return cleanup_and_return("")
end

local function goimpl(tsnode, packageName, interface, type_parameter_list)
	if not tsnode or not interface then
		logger.error("Missing required parameters for goimpl")
		return
	end
	
	local rec2 = _get_node_text(tsnode, 0)
	if not rec2 or rec2 == "" then
		logger.error("Failed to get node text")
		return
	end
	
	-- 修复：添加边界检查
	local rec1 = string.lower(string.sub(rec2, 1, math.min(2, #rec2)))
	if rec1 == "" then
		rec1 = "r" -- 默认接收者名称
	end
	
	local type_parameter_names = ""
	if tsnode:parent() then
		type_parameter_names = format_type_parameter_name_list(get_type_parameter_name_list(tsnode:parent()))
	end
	rec2 = rec2 .. type_parameter_names

	-- get the package source directory
	local dirname = vim.fn.fnameescape(vim.fn.expand('%:p:h'))
	if not dirname or dirname == "" then
		logger.error("Failed to get current directory")
		return
	end

	local setup = 'cd '
		.. dirname
		.. ' && impl'
		.. ' -dir '
		.. ' "'
		.. dirname
		.. '" '
		.. ' "'
		.. rec1
		.. ' *'
		.. rec2
		.. '" "'
		.. (packageName or "")
		.. (packageName and '.' or '')
		.. interface
		.. (type_parameter_list or "")
		.. '"'

	logger.info(setup)
	local data = vim.fn.systemlist(setup)

	data = handle_job_data(data)
	if not data or #data == 0 then
		logger.warn("No implementation generated")
		return
	end

	-- if not found the '$packageName.$interface' type, then try without the packageName
	-- this works when in a main package, its containerName will return the directory name which the interface file exist in.
	if string.find(data[1], "unrecognized interface:") or string.find(data[1], "couldn't find") then
		setup = 'impl'
			.. ' -dir '
			.. dirname
			.. ' "'
			.. rec1
			.. ' *'
			.. rec2
			.. '" "'
			.. interface
			.. (type_parameter_list or "")
			.. '"'

		logger.debug(setup)
		data = vim.fn.systemlist(setup)

		data = handle_job_data(data)
		if not data or #data == 0 then
			logger.warn("No implementation generated on second attempt")
			return
		end
	end

	-- 添加边界检查
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
	vim.fn.append(pos, "") -- insert an empty line
	pos = pos + 1
	vim.fn.append(pos, data)
end

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
	
	if tsnode:type() ~= 'type_identifier' or 
	   not tsnode:parent() or tsnode:parent():type() ~= 'type_spec' or
	   not tsnode:parent():parent() or tsnode:parent():parent():type() ~= 'type_declaration' then
		print("No type identifier found under cursor")
		return
	end

	pickers.new(opts, {
		prompt_title = "Go Impl",
		finder = finders.new_dynamic {
			entry_maker = opts.entry_maker or make_entry.gen_from_lsp_symbols(opts),
			fn = get_workspace_symbols_requester(curr_bufnr, opts),
		},
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

				-- if prompt is eg: sort.Interface, the symbol_name will contain the sort package name,
				-- so only use the real interface name
				local symbol_name = split(entry.symbol_name, ".")
				symbol_name = symbol_name[#symbol_name]
				
				if not symbol_name or symbol_name == "" then
					logger.error("Invalid symbol name")
					return
				end

				local type_parameter_list = ""
				if entry.filename then
					type_parameter_list = get_interface_generic_type_parameters(entry.filename, symbol_name)
				end

				local containerName = entry.value and entry.value.containerName
				goimpl(tsnode, containerName, symbol_name, type_parameter_list)
			end)
			return true
		end,
	}):find()
end

return M

