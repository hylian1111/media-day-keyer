local LrTasks = import "LrTasks"
LrTasks.startAsyncTask(function() require("Keyer").stop() end)
