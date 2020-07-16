function version() {
    var version = fileIn();
    let parts = version.split('.');
    return (parts[0] + "." +parts[1] + "." + parts[2]);
}

function build() {
    var version = fileIn();
    let parts = version.split('.');
    var build = parseInt(parts[3], 10);
    build += 1;
    version = (parts[0] + "." +parts[1] + "." + parts[2] + "." + build.toString());
    fileOut(version);
    return build;
}

function fileIn() {
    var fs = require('fs');
    return fs.readFileSync('version', 'utf-8');
}

function fileOut(data) {
    var fs = require('fs');
    fs.writeFileSync('version', data);
}

function year() {
    var d = new Date();
    return d.getFullYear();
}

module.exports = {
    get_version: version,
    update_build: build,
    get_year: year
}