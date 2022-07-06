![output](https://user-images.githubusercontent.com/4330411/129226108-d23caace-51d4-4261-99b0-ef6deec51ae3.gif)

# Requirements

* neovim >= 5.0
* lsp configured corretlly
* nvim-telescope/telescope.nvim
* nvim-treesitter/nvim-treesitter

# Install

with packer
```
	use {
		'edolphin-ydf/goimpl.nvim',
		requires = {
			{'nvim-lua/plenary.nvim'},
			{'nvim-lua/popup.nvim'},
			{'nvim-telescope/telescope.nvim'},
			{'nvim-treesitter/nvim-treesitter'},
		},
		config = function()
			require'telescope'.load_extension'goimpl'
		end,
	}
```

# Setting

add the key mapping in your init.lua
```
vim.api.nvim_set_keymap('n', '<leader>im', [[<cmd>lua require'telescope'.extensions.goimpl.goimpl{}<CR>]], {noremap=true, silent=true})
```


# FAQ

1. Missing some interfaces?

It's because the gopls search implementation. See [this](https://github.com/edolphin-ydf/goimpl.nvim/issues/5#issuecomment-1175712329)

