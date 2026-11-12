-- Copy this file to config.lua and fill in your own settings.
-- config.lua is in .gitignore, so your key never gets committed.
return {
  -- Anthropic Messages API endpoint. Use your own gateway/proxy URL here if you have one.
  endpoint = "https://api.anthropic.com/v1/messages",

  -- Option A: put your API key here.
  apiKey = "",

  -- Option B: reuse the token Claude Code uses (ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY
  -- in ~/.claude/settings.json). Handy if you already run Claude Code with a gateway.
  useClaudeCodeSettings = false,

  model = "claude-sonnet-5-5",    -- for write/replace hotkeys
  -- readModel = "claude-haiku-4-5", -- optional: separate model for translate popups
  timeout = 45,
}
