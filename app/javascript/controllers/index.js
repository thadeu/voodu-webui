// Auto-registered Stimulus controllers.
// Run `bin/rails stimulus:manifest:update` after generating new ones,
// or maintain this list by hand (small enough to be obvious).

import { application } from "./application"

import PollingController from "./polling_controller"
application.register("polling", PollingController)

import ToastController from "./toast_controller"
application.register("toast", ToastController)

import DropdownController from "./dropdown_controller"
application.register("dropdown", DropdownController)

import MobileNavController from "./mobile_nav_controller"
application.register("mobile-nav", MobileNavController)

import ClipboardController from "./clipboard_controller"
application.register("clipboard", ClipboardController)

import KvFilterController from "./kv_filter_controller"
application.register("kv-filter", KvFilterController)

import LogStreamController from "./log_stream_controller"
application.register("log-stream", LogStreamController)

import UpdatedAtController from "./updated_at_controller"
application.register("updated-at", UpdatedAtController)

import SparklineTooltipController from "./sparkline_tooltip_controller"
application.register("sparkline-tooltip", SparklineTooltipController)

import MetricsChartController from "./metrics_chart_controller"
application.register("metrics-chart", MetricsChartController)

import ModalController from "./modal_controller"
application.register("modal", ModalController)

import PatRevealController from "./pat_reveal_controller"
application.register("pat-reveal", PatRevealController)
