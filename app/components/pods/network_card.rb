# frozen_string_literal: true

# Components::Pods::NetworkCard — primary network + ports.
#
# Bypass: shows whichever network key the PAT plane reports first
# (typically `voodu0`), with its ip_address, gateway, network_id,
# aliases, and the pod's exposed ports.
class Components::Pods::NetworkCard < Components::Base
  def initialize(pod:)
    @pod = pod
  end

  def view_template
    render Components::UI::SectionCard.new(title: "Network") do
      if primary_network_name.blank?
        empty_state
      else
        row("network")    { plain primary_network_name }
        row("ip_address",  copy: true, copy_value: net["ip_address"].to_s) { plain dash(net["ip_address"]) }
        row("gateway")    { plain dash(net["gateway"]) }
        row("network_id",  copy: true, copy_value: net["network_id"].to_s) { network_id_value }
        row("aliases")    { aliases_value }
        row("ports")      { ports_value }
      end
    end
  end

  private

  def row(key, **opts, &)
    render Components::UI::KvRow.new(key: key, **opts), &
  end

  def networks
    @networks ||= @pod["networks"].is_a?(Hash) ? @pod["networks"] : {}
  end

  def primary_network_name
    @primary_network_name ||= networks.keys.first.to_s
  end

  def net
    @net ||= networks[primary_network_name] || {}
  end

  def empty_state
    div(class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]") { "no network attached" }
  end

  def network_id_value
    nid = net["network_id"].to_s
    if nid.length > 20
      plain nid[0, 20]
      span(class: "text-voodu-muted") { plain "…" }
    else
      plain dash(nid)
    end
  end

  def aliases_value
    a = Array(net["aliases"])
    if a.empty?
      plain "—"
    else
      div(class: "flex flex-wrap gap-1") do
        a.each { |name| render Components::UI::Chip.new(mono: true, tone: :subtle) { plain name } }
      end
    end
  end

  def ports_value
    ports = Array(@pod["ports"])
    if ports.empty?
      plain "—"
    else
      div(class: "flex flex-wrap gap-1") do
        ports.each do |p|
          label = p.is_a?(Hash) ? (p["container"] || p["host"]).to_s : p.to_s
          render Components::UI::Chip.new(mono: true, tone: :subtle) { plain label.presence || "—" }
        end
      end
    end
  end

  def dash(v) = v.to_s.presence || "—"
end
