-- install.sh adds these lines to ~/.hammerspoon/init.lua for you.
require("hs.ipc")
package.path = os.getenv("HOME") .. "/xiaoning-translate/?.lua;" .. package.path
xiaoning = require("xiaoning")
xiaoning.start()
