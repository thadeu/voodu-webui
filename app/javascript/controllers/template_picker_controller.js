import { Controller } from "@hotwired/stimulus"

// template-picker — fills the body-template textarea with a starter
// template when the operator picks a provider from the popover. The
// template JSON rides on each menu item's data-template attribute
// (server-rendered), so adding a provider is a view change, no JS.
//
//   <div data-controller="template-picker">
//     <button data-template="{...}" data-action="template-picker#fill">Slack</button>
//     <textarea data-template-picker-target="textarea"></textarea>
//   </div>
export default class extends Controller {
  static targets = ["textarea"]

  fill(event) {
    event.preventDefault()
    const tmpl = event.currentTarget.dataset.template

    if (tmpl == null) return

    this.textareaTarget.value = tmpl
    // Let the json-editor re-paint its highlight layer (setting .value
    // doesn't fire input on its own).
    this.textareaTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
