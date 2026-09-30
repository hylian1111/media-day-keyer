// Media Day Keyer — close a photo left open by a failed run. JOB = { input }.
app.displayDialogs = DialogModes.NO;
(function () {
    var want = new File(JOB.input).fsName;
    for (var i = app.documents.length - 1; i >= 0; i--) {
        try {
            if (app.documents[i].fullName.fsName == want) app.documents[i].close(SaveOptions.DONOTSAVECHANGES);
        } catch (e) {}
    }
    return "OK";
})();
