#! /usr/bin/env lua
--
-- goimpl_buildin.lua
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

-- Acording to LSP spec, if the client set "symbolKind.valueSet",
-- the client must handle it properly even if it receives a value outside the specification.
-- https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_documentSymbol
local function _get_symbol_kind_name(symbol_kind)
	return vim.lsp.protocol.SymbolKind[symbol_kind] or "Unknown"
end

-- containerName
--- Converts symbols to quickfix list items.
--- copyed from neovim runtime inorder to add the containerName from symbol
---
--@param symbols DocumentSymbol[] or SymbolInformation[]
local function interfaces_to_items(symbols, bufnr)
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
			elseif symbol.selectionRange then -- DocumentSymbole type
				local kind = M._get_symbol_kind_name(symbol.kind)
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
					for _, v in ipairs(_interfaces_to_items(symbol.children, _items, _bufnr)) do
						vim.list_extend(_items, v)
					end
				end
			end
		end
		return _items
	end
	return _interfaces_to_items(symbols, {}, bufnr)
end

local function get_workspace_symbols_requester(bufnr, opts)
	local cancel = function() end
	return function(prompt)
		local tx, rx = channel.oneshot()
		cancel()
		_, cancel = vim.lsp.buf_request(bufnr, "workspace/symbol", { query = prompt }, tx)

		-- Handle 0.5 / 0.5.1 handler situation
		local err, res = rx()
		assert(not err, err)

		local locations = interfaces_to_items(res or {}, bufnr) or {}
		return locations
	end
end

local function split(inputstr, sep)
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
	if not data then
		return nil
	end
	-- Because the nvim.stdout's data will have an extra empty line at end on some OS (e.g. maxOS), we should remove it.
	if data[#data] == '' then
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

local generyc_type_name_parameters_query = vim.treesitter.query.parse("go", [[
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
	local type_parameter_names = {}
	for _, tnode, _ in type_parameter_name_query:iter_captures(node, buf or 0) do
		type_parameter_names[#type_parameter_names + 1] = vim.treesitter.get_node_text(tnode, buf or 0)
	end

	return type_parameter_names
end

local function format_type_parameter_name_list(type_parameter_names)
	if #type_parameter_names == 0 then
		return ""
	end
	return "[" .. table.concat(type_parameter_names, ", ") .. "]"
end

local function load_file_to_buffer(filepath, buf)
	local file = io.open(filepath, "r")
	if not file then
		logger.info("file not found: " .. filepath)
		return false
	end

	local content = file:read("*all")
	file:close()
	logger.info(content)

	-- 将内容写入缓冲区
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))

	return true
end

local function get_interface_generic_type_parameters(file, interface_name)
	local buf = vim.api.nvim_create_buf(false, true)
	local ok, errmsg = pcall(vim.api.nvim_set_option_value, "filetype", "go", { buf = buf })
	if not ok then
		local msg = ("can't set filetype to 'go' (%s). Formatting is canceled"):format(errmsg)
		logger.info(msg)
		return ""
	end

	if not load_file_to_buffer(file, buf) then
		return ""
	end

	local parser = vim.treesitter.get_parser(buf, "go")
	local tree = parser:parse()[1]
	local root = tree:root()

	for _, node, _ in interface_declaration_query:iter_captures(root, buf) do
		local is_check_interface = false
		for iid, inode, _ in generyc_type_name_parameters_query:iter_captures(node, buf) do
			local name = generyc_type_name_parameters_query.captures[iid]
			if name == "interface.generic.name" then
				local current_interface_name = vim.treesitter.get_node_text(inode, buf)
				if current_interface_name == interface_name then
					is_check_interface = true
				end
			end
		end

		if is_check_interface then
			for iid, inode, _ in generyc_type_name_parameters_query:iter_captures(node, buf) do
				local name = generyc_type_name_parameters_query.captures[iid]
				if name == "interface.generic.type_parameters" then
					local type_parameter_names = get_type_parameter_name_list(inode, buf)

					vim.api.nvim_buf_delete(buf, { force = true })
					return format_type_parameter_name_list(type_parameter_names)
				end
			end
		end
	end

	vim.api.nvim_buf_delete(buf, { force = true })

	return ""
end


local function goimpl(tsnode, packageName, interface, type_parameter_list)
	local rec2 = _get_node_text(tsnode, 0)
	local rec1 = string.lower(string.sub(rec2, 1, 2))
	local type_parameter_names = format_type_parameter_name_list(get_type_parameter_name_list(tsnode:parent()))
	rec2 = rec2 .. type_parameter_names

	-- get the package source directory
	local dirname = vim.fn.fnameescape(vim.fn.expand('%:p:h'))

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
		.. packageName
		.. '.'
		.. interface
		.. type_parameter_list
		.. '"'

	logger.info(setup)
	local data = vim.fn.systemlist(setup)

	data = handle_job_data(data)
	if not data or #data == 0 then
		return
	end

	-- if not found the '$packageName.$interface' type, then try without the packageName
	-- this works when in a main package, it's containerName will return the directory name which the interface file exist in.
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
			.. type_parameter_list
			.. '"'

		logger.debug(setup)
		data = vim.fn.systemlist(setup)

		data = handle_job_data(data)
		if not data or #data == 0 then
			return
		end
	end

	local _, _, pos, _ = tsnode:parent():parent():range()
	pos = pos + 1
	vim.fn.append(pos, "") -- insert an empty line
	pos = pos + 1
	vim.fn.append(pos, data)
end

M.goimpl = function(opts)
	opts = opts or {}
	local curr_bufnr = vim.api.nvim_get_current_buf()

	local tsnode = ts_utils.get_node_at_cursor()
	if tsnode:type() ~= 'type_identifier' or tsnode:parent():type() ~= 'type_spec'
		or tsnode:parent():parent():type() ~= 'type_declaration' then
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
				if not entry then
					return
				end

				-- if prompt is eg: sort.Interface, the symbol_name will contain the sort package name,
				-- so only use the real interface name
				local symbol_name = split(entry.symbol_name, ".")
				symbol_name = symbol_name[#symbol_name]

				local type_parameter_list = get_interface_generic_type_parameters(entry.filename, symbol_name)

				goimpl(tsnode, entry.value.containerName, symbol_name, type_parameter_list)
			end)
			return true
		end,
	}):find()
end

return M
