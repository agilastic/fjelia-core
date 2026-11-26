/// The map the apps show under routes and courses, in one place so the
/// phone and the computer change provider together. OpenStreetMap's own
/// tiles suit light use by an app that names itself; a busier app moves to
/// a hosted provider (with a topographic style for trails).
const mapTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// How the apps name themselves to the tile server.
const mapUserAgentPackage = 'de.ebeling-hoppe.fjelia';

/// The credit the tiles require, shown on every map (after a ©).
const mapCredit = 'OpenStreetMap contributors';
