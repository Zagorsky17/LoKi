let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");


function link(name, order, uri, extra) {
    return { ".name": name, section: "source", order, uri, name: split(uri, "#")[1], ...(extra ?? {}) };
}

const THROUGH_HOP = { detour_section: "hop" };

function build() {
    fixture.seed({
        settings: { dns_server: "1.1.1.1", service_listen_address: "127.0.0.1" },
        section: [
            { ".name": "hop", label: "Hop", enabled: "1", action: "connection" },
            {
                ".name": "source", enabled: "1", action: "connection",
                outbound_jsons: [
                    "{\"type\":\"socks\",\"tag\":\"JSON plain\",\"server\":\"127.0.0.1\",\"server_port\":1082,\"version\":\"5\"}",
                    "{\"type\":\"socks\",\"tag\":\"JSON explicit\",\"server\":\"127.0.0.1\",\"server_port\":1083,\"version\":\"5\",\"detour\":\"direct-out\"}"
                ]
            }
        ],
        connection_link: [
            ...fixture.links("hop", [ "socks5://127.0.0.1:1080#Hop node" ]),
            link("link_through", "0", "socks5://127.0.0.1:1081#Through", THROUGH_HOP),
            link("link_direct", "1", "socks5://127.0.0.1:1084#Direct")
        ],
        subscription_url: [
            { ".name": "sub_through", section: "source", url: "https://subscription.example/through", tag: "sub1", ...THROUGH_HOP },
            { ".name": "sub_direct", section: "source", url: "https://subscription.example/direct", tag: "sub2" }
        ],
        section_interface: [ { ".name": "source_wg0", section: "source", name: "wg0" } ],
    });
    return generator.build({ service_address: "127.0.0.1" });
}

t.test("a cascade sends the link or subscription that names it through the section", () => {
    let config = build();
    t.eq(q.outbound(config, "source/Through").detour, "Hop");
    t.eq(q.provider(config, "source/sub1").override.detour, "Hop");
});

t.test("a server beside it connects on its own", () => {
    let config = build();
    t.eq(q.outbound(config, "source/Direct").detour, null, "a link without a cascade");
    t.eq(q.provider(config, "source/sub2").override, null, "a subscription without a cascade");
    t.eq(q.outbound(config, "source/wg0").detour, null, "an interface");
    t.eq(q.outbound(config, "source/JSON plain").detour, null, "a plain JSON outbound");
    t.eq(q.outbound(config, "source/JSON explicit").detour, "direct-out", "an explicit JSON detour is kept");
    t.eq(q.outbound(config, "source").detour, null, "the section selector gets no detour of its own");
});

t.done();
