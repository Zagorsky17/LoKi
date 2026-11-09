// Shared lookup for LoKi's versioned configuration model.
function settings(model) {
    for (let section in model.sections)
        if (section[".name"] == "settings" && section[".type"] == "settings")
            return section;
    return null;
}

return { settings };
