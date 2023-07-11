#! /usr/bin/env lua
--
-- goimpl_buildin.lua
-- Copyright (C) 2021 edolphin <dngfngyang@gmail.com>
--
-- Distributed under terms of the MIT license.
--

local actions = require'telescope.actions'
local state = require'telescope.actions.state'
local actions_set = require'telescope.actions.set'
local conf = require'telescope.config'.values
local finders = require'telescope.finders'
local make_entry = require "telescope.make_entry"
local pickers = require'telescope.pickers'
local ts_utils = require 'nvim-treesitter.ts_utils'
local channel = require("plenary.async.control").channel

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
						text = '['..kind..'] '..symbol.name,
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
						text = '['..kind..'] '..symbol.name,
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
	local t={}
	for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
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

local function goimpl(tsnode, packageName, interface)
	local rec2 = _get_node_text(tsnode, 0)
	local rec1 = string.lower(string.sub(rec2, 1, 2))

	-- get the package source directory
	local dirname = vim.fn.fnameescape(vim.fn.expand('%:p:h'))

	local setup = 'impl' .. ' -dir ' .. " '" .. dirname .. "' " .. " '" .. rec1 .. " *" .. rec2 .. "' " .. packageName .. '.' .. interface
	local data = vim.fn.systemlist(setup)

	data = handle_job_data(data)
	if not data or #data == 0 then
		return
	end

	-- if not found the '$packageName.$interface' type, then try without the packageName
	-- this works when in a main package, it's containerName will return the directory name which the interface file exist in.
	if string.find(data[1], "unrecognized interface:") or string.find(data[1], "couldn't find") then
		setup = 'impl' .. ' -dir ' .. dirname  .. " '" .. rec1 .. " *" .. rec2 .. "' " .. interface
		data = vim.fn.systemlist(setup)

		data = handle_job_data(data)
		if not data or #data == 0 then
			return
		end
	end

	local _, _, pos, _ = tsnode:parent():parent():range()
	pos = pos+1
	vim.fn.append(pos, "") -- insert an empty line
	pos = pos+1
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

				goimpl(tsnode, entry.value.containerName, symbol_name)
			end)
			return true
		end,
	}):find()
end

return M
