local LrTasks = import "LrTasks"
LrTasks.startAsyncTask(function() require("Keyer").start(true, "blue") end)
