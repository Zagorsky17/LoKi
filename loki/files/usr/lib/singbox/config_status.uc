// { exists, type, listen, listen_port } of the item tagged `tag` under
// config[kind] - "inbounds" or "endpoints".
function summary(config, kind, tag) {
    for (let item in config?.[kind] ?? [])
        if (item?.tag == tag)
            return { exists: 1, type: "" + (item.type ?? ""), listen: "" + (item.listen ?? ""), listen_port: int(item.listen_port ?? 0) };
    return { exists: 0 };
}

// Whether a route rule sends the inbound's traffic somewhere.
function routes_inbound(config, inbound) {
    for (let rule in config?.route?.rules ?? []) {
        if (rule?.action != "route" && rule?.action != "reject")
            continue;
        let inbounds = type(rule.inbound) == "array" ? rule.inbound : [ rule.inbound ];
        if (index(inbounds, inbound) >= 0)
            return true;
    }
    return false;
}

return { summary, routes_inbound };
