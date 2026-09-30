local LrTasks = import "LrTasks"
LrTasks.startAsyncTask(function() require("Keyer").start(false, "blue") end)
