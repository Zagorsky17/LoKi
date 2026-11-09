let t = require("t");
let v = require("validation");
let common = require("core.common");
let constants = require("core.constants");

const TAILSCALE_FWMARK_MASK = 0x00ff0000;

t.test("the Loki marks stay clear of the Tailscale fwmark mask and of each other", () => {
    let fakeip = common.parse_number(constants.NFT_FAKEIP_MARK);
    let outbound = common.parse_number(constants.NFT_OUTBOUND_MARK);
    let router = common.parse_number(constants.NFT_ROUTER_MARK);
    t.eq(fakeip & TAILSCALE_FWMARK_MASK, 0);
    t.eq(outbound & TAILSCALE_FWMARK_MASK, 0);
    t.eq(router & TAILSCALE_FWMARK_MASK, 0);
    t.ok(fakeip != outbound);
    t.eq(router & (fakeip | outbound), 0);
    v.accepts({});
});

t.test("marks overlapping Tailscale's or each other are refused", () => {
    v.refuses({}, "FakeIP mark overlaps Tailscale fwmark mask", { nft_fakeip_mark: "0x00100000" });
    v.refuses({}, "Outbound mark overlaps Tailscale fwmark mask", { nft_outbound_mark: "0x00200000" });
    v.refuses({}, "Router mark overlaps Tailscale fwmark mask", { nft_router_mark: "0x00400000" });
    v.refuses({}, "the same value", { nft_fakeip_mark: "0x00000400", nft_outbound_mark: "0x00000400" });
    v.refuses({}, "Router mark shares bits", { nft_router_mark: "0x04000000" });
});

t.done();
