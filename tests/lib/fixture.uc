// Seeds the fake uci from the fixture shape the tests describe a configuration
// in: { settings: {...}, section: [...], server: [...], ... } for /etc/config/loki,
// plus dhcp_dnsmasq for the first dnsmasq section of /etc/config/dhcp.

let fs = require("fs");
let uci = require("uci");
let core_uci = require("core.uci");
let core_url = require("core.url");

const TYPES = [
    "settings", "section", "server", "server_client", "subscription_url", "section_interface",
    "connection_link", "urltest", "fallback_group", "fallback_level", "tunnel", "tunnel_peer"
];

// Named as the page names a pasted link: after the link, or "Node #N", numbered on a clash.
function links(section_name, uris, extra) {
    let result = [];
    let taken = {};
    for (let i = 0; i < length(uris); i++) {
        let base = core_url.link_name(uris[i]) || "Node #" + (i + 1);
        let name = base;
        for (let number = 1; taken[name]; number++)
            name = base + " #" + number;
        taken[name] = true;
        push(result, {
            ".name": section_name + "_link" + (i + 1),
            section: section_name,
            uri: uris[i],
            name,
            order: "" + i,
            ...(extra ?? {})
        });
    }
    return result;
}

function listed(data, type_name) {
    let value = data[type_name] ?? data[type_name + "s"];
    if (type(value) == "object")
        return [ value ];
    return type(value) == "array" ? value : [];
}

function seed(data) {
    data = data ?? {};
    uci.__reset();
    core_uci.reset();

    let sections = [];
    for (let type_name in TYPES)
        for (let section in listed(data, type_name)) {
            let entry = { ...section };
            entry[".type"] = entry[".type"] ?? type_name;
            if (type_name == "settings")
                entry[".name"] = entry[".name"] ?? "settings";
            push(sections, entry);
        }
    uci.__seed("loki", sections);

    if (data.dhcp_dnsmasq != null)
        uci.__seed("dhcp", [ { ".type": "dnsmasq", ...data.dhcp_dnsmasq } ]);
    if (data.system_ntp != null)
        uci.__seed("system", [ { ".type": "timeserver", ".name": "ntp", ...data.system_ntp } ]);
}

// The settings every generated configuration needs, merged with the test's own.
function settings(extra) {
    return {
        config_path: "/etc/loki-core/config.json",
        dns_server: "1.1.1.1",
        ...(extra ?? {})
    };
}

// The kernel's IPv6 switches, { lo: "0", "br-lan": "1" } as disable_ipv6 holds them; null
// for a kernel without IPv6. "all" and "default" read 0 whatever the interfaces say.
function kernel_ipv6(interfaces) {
    let dir = require("stub").tmpdir() + "/conf";
    require("nft.state").paths.ipv6_conf = dir;
    if (interfaces == null)
        return;
    fs.mkdir(dir);
    for (let name in [ "all", "default", ...keys(interfaces) ]) {
        fs.mkdir(dir + "/" + name);
        fs.writefile(dir + "/" + name + "/disable_ipv6", (interfaces[name] ?? "0") + "\n");
    }
}

return { seed, settings, links, kernel_ipv6 };
