return {
  "olimorris/codecompanion.nvim",
  opts = {},
  dependencies = {
    "ravitemer/mcphub.nvim",
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
    "hrsh7th/nvim-cmp", -- Optional: for completion
    "nvim-telescope/telescope.nvim", -- Optional: for slash command
    "github/copilot.vim", -- Required for Copilot authentication
  },
  config = function()
    require("codecompanion").setup({
      adapters = {
        -- Choose your preferred adapter
        copilot = function()
          return require("codecompanion.adapters").extend("copilot", {
            -- Copilot doesn't require API key setup if authenticated via copilot.vim
          })
        end,
        anthropic = function()
          return require("codecompanion.adapters").extend("anthropic", {
            env = {
              api_key = "YOUR_ANTHROPIC_API_KEY",
            },
          })
        end,
        openai = function()
          return require("codecompanion.adapters").extend("openai", {
            env = {
              api_key = "YOUR_OPENAI_API_KEY",
            },
          })
        end,
        -- Or use Ollama for local models
        ollama = function()
          return require("codecompanion.adapters").extend("ollama", {
            name = "llama3.2", -- or your preferred model
          })
        end,
      },
      strategies = {
        chat = {
          adapter = "copilot", -- Change to your preferred adapter
        },
        inline = {
          adapter = "copilot",
        },
        agent = {
          adapter = "copilot",
        },
      },
    })
  end,
}
