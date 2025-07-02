-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
-- Eval var under cursor
vim.keymap.set("n", "<space>?", function()
  require("dapui").eval(nil, { enter = true })
end)

-- move 5 lines up/down with arrow keys
vim.keymap.set("n", "<Down>", "5j")
vim.keymap.set("n", "<Up>", "5k")

-- CodeCompanion keymaps
vim.keymap.set("n", "<leader>cg", ":CodeCompanionAgent<CR>", { desc = "CodeCompanion Agent" })
vim.keymap.set("n", "<leader>ac", ":CodeCompanionChat<CR>", { desc = "CodeCompanion Chat" })
vim.keymap.set("n", "<leader>ci", ":CodeCompanionInline<CR>", { desc = "CodeCompanion Inline" })
vim.keymap.set("n", "<leader>c?", ":CodeCompanionHelp<CR>", { desc = "CodeCompanion Help" })

vim.keymap.set("i", "jj", "<esc>", { desc = "Exit insert mode with <leader>jj" })
