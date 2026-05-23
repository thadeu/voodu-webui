// Auto-registered Stimulus controllers.
// Run `bin/rails stimulus:manifest:update` after generating new ones,
// or maintain this list by hand (small enough to be obvious).

import { application } from "./application"

import HelloController from "./hello_controller"
application.register("hello", HelloController)

import PollingController from "./polling_controller"
application.register("polling", PollingController)

import ToastController from "./toast_controller"
application.register("toast", ToastController)

import DropdownController from "./dropdown_controller"
application.register("dropdown", DropdownController)
