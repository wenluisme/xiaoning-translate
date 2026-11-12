-- Add these lines to ~/.hammerspoon/init.lua (change the path to where you cloned the repo).
require("hs.ipc")
package.path = os.getenv("HOME") .. "/claude-translator-mac/?.lua;" .. package.path
claudeReplace = require("claude_replace")
claudeReplace.start()
