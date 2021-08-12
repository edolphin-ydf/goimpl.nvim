#! /usr/bin/env lua
--
-- goimpl.lua
-- Copyright (C) 2021 edolphin <dngfngyang@gmail.com>
--
-- Distributed under terms of the MIT license.
--

local goimpl_builtin = require'telescope._extensions.goimpl_builtin'

return require'telescope'.register_extension{
  exports = {
    goimpl = goimpl_builtin.goimpl,
  },
}
