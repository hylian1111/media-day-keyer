// Media Day Keyer — step 1: Select Subject on one photo.
// run by bin/mdkeyer, which defines JOB = { input, maskOut }.
// Leaves the photo open (with the selection stored as a "Subject" channel) for build_psd.jsx.

app.displayDialogs = DialogModes.NO;

function findOpen(path) {
    var want = new File(path).fsName;
    for (var i = 0; i < app.documents.length; i++) {
        try { if (app.documents[i].fullName.fsName == want) return app.documents[i]; } catch (e) {}
    }
    return null;
}

(function () {
    var units = app.preferences.rulerUnits;
    app.preferences.rulerUnits = Units.PIXELS;
    var doc = null;
    try {
        doc = findOpen(JOB.input) || app.open(new File(JOB.input));
        app.activeDocument = doc;
        doc.selection.deselect();

        var d = new ActionDescriptor();
        d.putBoolean(stringIDToTypeID("sampleAllLayers"), false);
        executeAction(stringIDToTypeID("autoCutout"), d, DialogModes.NO);
        try { doc.selection.bounds; } catch (e) { return "NOSUBJECT"; }

        var ch = doc.channels.add();
        ch.name = "Subject";
        doc.selection.store(ch, SelectionType.REPLACE);

        // write the selection out as a black/white file for the engine: paint it onto a temporary
        // full-frame layer and save a copy (no clipboard — scripted paste is unreliable and would
        // wipe whatever the user has copied)
        var black = new SolidColor(); black.rgb.red = black.rgb.green = black.rgb.blue = 0;
        var white = new SolidColor(); white.rgb.red = white.rgb.green = white.rgb.blue = 255;
        var tmp = doc.artLayers.add();
        doc.selection.selectAll();
        doc.selection.fill(black);
        doc.selection.load(ch, SelectionType.REPLACE);
        doc.selection.fill(white);
        doc.selection.deselect();
        var o = new PNGSaveOptions();
        o.compression = 1;
        doc.saveAs(new File(JOB.maskOut), o, true, Extension.LOWERCASE);
        tmp.remove();
        return "OK";
    } catch (e) {
        if (doc) { try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (e2) {} }
        return "ERROR: " + e.message + " (line " + e.line + ")";
    } finally {
        app.preferences.rulerUnits = units;
    }
})();
