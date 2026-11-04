#!/usr/bin/env ucode

let common = require("core.common");
let connections = require("config.connections");
let runtime_constants = require("singbox.constants");

let option = common.option;
let bool_option = common.bool_option;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function tproxy_inbounds() {
    return [
        runtime_constants.TPROXY_INBOUND_TAG,
        runtime_constants.TPROXY_INBOUND6_TAG,
        runtime_constants.SYSTEM_TPROXY_INBOUND_TAG,
        runtime_constants.SYSTEM_TPROXY_INBOUND6_TAG
    ];
}

// No auto_detect_interface: it binds loki-core's own connections to the device of the default route,
// past every other route (a host route, policy routing, mwan3). default_mark keeps them out of the capture.
function config(settings, runtime) {
    let output_network_interface = option(settings, "output_network_interface", "");
    let sniff_inbounds = tproxy_inbounds();
    push(sniff_inbounds, runtime_constants.DNS_INBOUND_TAG, runtime_constants.SOURCE_DNS_INBOUND_TAG, runtime_constants.SYSTEM_DNS_INBOUND_TAG);
    let result = {
        rules: [
            { action: "sniff", inbound: sniff_inbounds },
            { action: "hijack-dns", protocol: "dns" }
        ],
        rule_set: [],
        final: runtime_constants.DIRECT_OUTBOUND_TAG,
        default_domain_resolver: type(runtime) == "object" && as_string(runtime.default_domain_resolver) != ""
            ? as_string(runtime.default_domain_resolver)
            : runtime_constants.DNS_SERVER_TAG,
        default_mark: runtime_constants.OUTBOUND_MARK
    };

    // the direct outbound would send what is no query back to the listen address of the inbound
    push(result.rules, { action: "reject", inbound: runtime_constants.DNS_INBOUND_TAG });
    push(result.rules, { action: "reject", inbound: runtime_constants.SOURCE_DNS_INBOUND_TAG });
    push(result.rules, { action: "reject", inbound: runtime_constants.SYSTEM_DNS_INBOUND_TAG });
    if (output_network_interface != "")
        result.default_interface = output_network_interface;
    if (bool_option(settings, "disable_quic", false))
        push(result.rules, { action: "reject", inbound: tproxy_inbounds(), protocol: "quic" });
    if (bool_option(settings, "bittorrent_direct", false))
        push(result.rules, { action: "route", inbound: tproxy_inbounds(), protocol: "bittorrent", outbound: runtime_constants.DIRECT_OUTBOUND_TAG });

    return result;
}

function target(section, outbound_tag_name) {
    let action = option(section, "action", "");
    if (connections.is_connections_action(action))
        return { action: "route", outbound: outbound_tag_name };
    if (action == "bypass")
        return { action: "route", outbound: runtime_constants.DIRECT_OUTBOUND_TAG };
    if (action == "block")
        return { action: "reject" };
    return { unsupported: "unsupported action " + action };
}

return {
    config,
    target
};
