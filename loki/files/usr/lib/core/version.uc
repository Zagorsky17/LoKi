function as_string(value) {
    return value == null ? "" : "" + value;
}

function digit_char(value) {
    return match(as_string(value), /^[0-9]$/) != null;
}

function strip_leading_zeroes(value) {
    value = as_string(value);
    let i = 0;
    while (i < length(value) - 1 && substr(value, i, 1) == "0")
        i++;
    return substr(value, i);
}

// opkg's ordering: "1.13.18-extended-2.6.5" after "1.13.18", a "~" segment before everything.
function version_compare(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);

    let li = 0, ri = 0;
    while (li < length(lhs) || ri < length(rhs)) {
        if (li >= length(lhs))
            return substr(rhs, ri, 1) == "~" ? 1 : -1;
        if (ri >= length(rhs))
            return substr(lhs, li, 1) == "~" ? -1 : 1;

        let lc = substr(lhs, li, 1);
        let rc = substr(rhs, ri, 1);
        if (lc == rc) {
            li++;
            ri++;
            continue;
        }

        if (lc == "~" || rc == "~")
            return lc == "~" ? -1 : 1;

        if (digit_char(lc) && digit_char(rc)) {
            let ls = li, rs = ri;
            while (li < length(lhs) && digit_char(substr(lhs, li, 1)))
                li++;
            while (ri < length(rhs) && digit_char(substr(rhs, ri, 1)))
                ri++;

            let lnum = strip_leading_zeroes(substr(lhs, ls, li - ls));
            let rnum = strip_leading_zeroes(substr(rhs, rs, ri - rs));
            if (length(lnum) != length(rnum))
                return length(lnum) < length(rnum) ? -1 : 1;
            if (lnum != rnum)
                return lnum < rnum ? -1 : 1;
            continue;
        }

        return lc < rc ? -1 : 1;
    }

    return 0;
}

function version_at_least(current, required) {
    return version_compare(current, required) >= 0;
}

return { version_compare, version_at_least };
