// Media Day Keyer — step 2: build the layered PSD.
// run by bin/mdkeyer, which defines JOB = { input, subjectMask, persons: [{ mask, name }], psd }.
// One layer per person: the full, untouched photo with that person's editable layer mask, so an
// edge can be painted back in. The combined Select Subject result is kept as the "Subject" alpha
// channel. Saved without "maximize compatibility" (no flattened copy) to keep files small.

app.displayDialogs = DialogModes.NO;

function findOpen(path) {
    var want = new File(path).fsName;
    for (var i = 0; i < app.documents.length; i++) {
        try { if (app.documents[i].fullName.fsName == want) return app.documents[i]; } catch (e) {}
    }
    return null;
}

function findChannel(doc, name) {
    for (var i = 0; i < doc.channels.length; i++) if (doc.channels[i].name == name) return doc.channels[i];
    return null;
}

// Bring a black/white mask file into doc as an alpha channel. Channel.duplicate copies it across
// directly — no clipboard (scripted paste was unreliable and would wipe the user's clipboard).
function addChannel(doc, path, name) {
    var m = app.open(new File(path));
    if (m.mode != DocumentMode.GRAYSCALE) m.changeMode(ChangeMode.GRAYSCALE);
    var ch = m.channels[0].duplicate(doc);
    m.close(SaveOptions.DONOTSAVECHANGES);
    app.activeDocument = doc;
    ch.name = name;
    doc.activeChannels = doc.componentChannels;
    return ch;
}

function maskFromSelection() {
    var d = new ActionDescriptor();
    d.putClass(charIDToTypeID("Nw  "), charIDToTypeID("Chnl"));
    var r = new ActionReference();
    r.putEnumerated(charIDToTypeID("Chnl"), charIDToTypeID("Chnl"), charIDToTypeID("Msk "));
    d.putReference(charIDToTypeID("At  "), r);
    d.putEnumerated(charIDToTypeID("Usng"), charIDToTypeID("UsrM"), charIDToTypeID("RvlS"));
    executeAction(charIDToTypeID("Mk  "), d, DialogModes.NO);
}

(function () {
    var doc = null;
    try {
        doc = findOpen(JOB.input) || app.open(new File(JOB.input));
        app.activeDocument = doc;
        if (!findChannel(doc, "Subject") && JOB.subjectMask) addChannel(doc, JOB.subjectMask, "Subject");

        var base = doc.layers[doc.layers.length - 1];
        if (base.isBackgroundLayer) base.isBackgroundLayer = false;
        var layers = [base];
        for (var i = 1; i < JOB.persons.length; i++) layers.push(base.duplicate());
        for (var i = 0; i < JOB.persons.length; i++) {
            var tmp = addChannel(doc, JOB.persons[i].mask, "tmp");
            layers[i].name = JOB.persons[i].name;
            doc.activeLayer = layers[i];
            doc.selection.load(tmp, SelectionType.REPLACE);
            maskFromSelection();
            doc.selection.deselect();
            tmp.remove();
        }

        var o = new PhotoshopSaveOptions();
        o.embedColorProfile = true;
        o.alphaChannels = true;
        o.layers = true;
        var compat = app.preferences.maximizeCompatibility;
        app.preferences.maximizeCompatibility = QueryStateType.NEVER;
        try {
            doc.saveAs(new File(JOB.psd), o, true, Extension.LOWERCASE);
        } finally {
            app.preferences.maximizeCompatibility = compat;
        }
        doc.close(SaveOptions.DONOTSAVECHANGES);
        return "OK";
    } catch (e) {
        if (doc) { try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (e2) {} }
        return "ERROR: " + e.message + " (line " + e.line + ")";
    }
})();
