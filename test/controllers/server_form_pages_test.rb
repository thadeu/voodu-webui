# frozen_string_literal: true

require "test_helper"

# The server form is a page, not a modal.
#
# It was a modal drawn over the servers list. The route was always a real page —
# /:org_id/servers/new — that happened to render an overlay on top of the
# dashboard, so nothing about navigation changed here; what changed is the
# container. A modal is the wrong one for this form: it holds an endpoint and a
# token people paste from a terminal in another window, it cannot be reloaded
# without losing what was typed, and it has nowhere to put a connection failure
# except on top of the fields that caused it.
class ServerFormPagesTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(email: users(:owner).email) }

  ORG = "acmeorg1"

  def new_page = get(new_server_path(org_id: ORG))

  def edit_page = get(edit_server_path(servers(:alpha), org_id: ORG))

  # The regression this replaces: a dialog with a backdrop, whose only way out
  # was its own close button.
  test "the new-server form is not rendered in a dialog" do
    new_page

    assert_response :success
    # Asked of the FORM, not of the page: the page still carries other dialogs
    # (the org overlay, the command palette), and Modal labels itself with
    # aria-labelledby rather than aria-label — so asserting on a label here
    # passed whether or not the form was inside one.
    assert_select "[role=dialog] form#add-server-form", false
  end

  test "the edit form is not rendered in a dialog either" do
    edit_page

    assert_response :success
    assert_select "[role=dialog] form#edit-server-form", false
  end

  # What a page has that a modal did not: a trail back, and a heading of its own.
  test "the new-server page names itself and offers the way back" do
    new_page

    assert_select "h1", text: "Add server"
    assert_select "nav[aria-label=?] a[href=?]", "Breadcrumb", servers_path(org_id: ORG)
  end

  test "the edit page names itself and offers the way back" do
    edit_page

    assert_select "h1", text: "Edit server"
    assert_select "nav[aria-label=?] a[href=?]", "Breadcrumb", servers_path(org_id: ORG)
  end

  # A modal had the dashboard behind it. A page has only what it is given, and
  # an operator halfway through adding a box still needs to reach the others.
  #
  # Asserted on the NAV, not on the server rows: the rows come from the
  # recent-servers helper and render whatever the view was handed, so they
  # appeared either way. What the view actually decides is which server the nav
  # points at — hand it none and the Server group disappears entirely.
  test "the form pages keep the sidebar pointing at a server" do
    new_page

    assert_select "nav[aria-label=?]", "Primary"
    assert_select "a[href=?]", pods_path(org_id: ORG, server_key: servers(:alpha).key)
  end

  # In the modal the buttons sat in a footer OUTSIDE the form, which is why the
  # submit carried a `form:` attribute and a hidden submit input existed so
  # Enter still worked. Inside the form, neither is needed — and a stray hidden
  # submit is the kind of thing that outlives the reason for it.
  test "the submit button lives inside the form it submits" do
    new_page

    assert_select "form#add-server-form button[type=submit]", 1
    assert_select "input[type=submit]", false
  end

  test "the edit submit button lives inside its form too" do
    edit_page

    assert_select "form#edit-server-form button[type=submit]", 1
    assert_select "input[type=submit]", false
  end

  # Cancel goes back to the list by default, and to wherever the operator came
  # from when they were sent here with a return_to — Settings does that.
  test "cancel returns to the servers list" do
    edit_page

    assert_select "a[href=?]", servers_path(org_id: ORG), text: "Cancel"
  end

  test "cancel honours the page that sent the operator here" do
    destination = settings_path(org_id: ORG, server_key: servers(:alpha).key)

    get edit_server_path(servers(:alpha), org_id: ORG, return_to: destination)

    assert_select "a[href=?]", destination, text: "Cancel"
  end

  # The form still works — the container changed, not the behaviour.
  #
  # The endpoint is stubbed because create PREFLIGHTS it (ServerHealth.probe!
  # calls /system before saving), and a blocked request would fail the save for
  # a reason that has nothing to do with the page.
  test "the page still creates a server" do
    stub_request(:get, %r{box\.example:8687}).to_return(
      status: 200, body: {status: "ok", data: {}}.to_json,
      headers: {"Content-Type" => "application/json"}
    )

    assert_difference -> { Server.count }, 1 do
      post servers_path(org_id: ORG), params: {
        server: {
          name: "new-box", endpoint: "http://box.example:8687",
          pat_ciphertext: "pat_#{"a" * 28}", org_id: orgs(:acme).id
        }
      }
    end
  end
end
