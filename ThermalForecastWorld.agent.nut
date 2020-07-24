// Thermal Forecast World
// Copyright @{get_year()}, Tony Smith
// @version @{get_version()}
// @build @{update_build()}

// ********** IMPORTS **********
#require "DarkSky.agent.lib.nut:2.0.0"
#require "Rocky.agent.lib.nut:3.0.0"

// If you are NOT using Builder, replace the following @include statement(s)
// with the contents of the named file(s):
@include "submodules/generic-squirrel/simpleslack.nut"      // Source: https://github.com/smittytone/generic
@include "submodules/generic-squirrel/crashreporter.nut"    // Source: https://github.com/smittytone/generic
@include "submodules/Location/location.class.nut"           // Source: https://github.com/smittytone/Location
@include "images.nut"                                       // Source: https://github.com/smittytone/ThermalForecastWorld

const HTML_STRING = @"
@include "thermalforecast_ui.html"
";                                              // Source: https://github.com/smittytone/ThermalForecastWorld


// ********** CONSTANTS **********
const FORECAST_REFRESH = 1800;


// ********** GLOBALS **********
local forecast = null;
local locator = null;
local location = null;
local timezone = null;
local agentRestartTimer = null;
local forecastTimer = null;
local settings = null;
local api = null;
local deviceReadyFlag = false;
local darkSkyCount = 0;


// ********** FORECAST RETRIEVAL FUNCTIONS **********
function getForecast() {
    // Is there another timer? If so cancel it
    if (forecastTimer) {
        imp.cancelwakeup(forecastTimer);
        forecastTimer = null;
    }

    // Request a weather forecast, but only if there are less than 1000 previous requests today
    // NOTE the count is maintined by DarkSky; we reload it every time
    if (darkSkyCount < 990) {
        if (settings.debug) server.log("Requesting weather forecast data from Dark Sky");
        forecast.forecastRequest(location.longitude, location.latitude, forecastCallback);
    }
}

function forecastCallback(err, dayData) {
    if (err) server.error(err);

    if (dayData) {
        if (settings.debug) server.log("Forecast received from Dark Sky");

        if ("callCount" in dayData) {
            if (settings.debug) server.log("Current Dark Sky API call tally: " + dayData.callCount + "/1000");
            darkSkyCount = dayData.callCount;
        }

        // Build the formatted (x:y:z) string for the next 12 hours' temperatures (external)
        // in three-hourly intervals (now:+3:+6:+9:+12)
        local tempString = "";
        local hourData = dayData.hourly.data;

        for (local i = 0 ; i < 13 ; i += 3) {
            local temp = hourData[i].temperature.tofloat();
            tempString += format("%.1f:", temp);
        }

        // Remove the final colon, added in the interation above
        tempString = tempString.slice(0, tempString.len() - 1);

        // Send the formatted data string to the device
        device.send("show.temps", tempString);

        if (settings.debug) server.log("Forecast: " + tempString);
    }

    // Auto-request a forecast in 'FORECAST_REFRESH' seconds' time
    forecastTimer = imp.wakeup(FORECAST_REFRESH, getForecast);
}

function parsePlaceData(data) {
    // Run through the raw place data returned by Google and find what area we're in
    foreach (item in data) {
        foreach (k, v in item) {
            // We're looking for the 'types' array
            if (k == "types") {
                // Got it, so look through the elements for 'neighborhood'
                foreach (entry in v) {
                    if (entry == "neighborhood") return item.formatted_address;
                }

                // No 'neighborhood'? Try 'locality'
                foreach (entry in v) {
                    if (entry == "locality") return item.formatted_address;
                }

                // No 'locality'? Try 'administrative_area_level_2'
                foreach (entry in v) {
                    if (entry == "administrative_area_level_2") return item.formatted_address;
                }
            }
        }
    }

    // No match, so return an unknown locality
    return "Unknown";
}

function initialise() {
    // This method is called in response to the starting device signalling
    // its readiness, or 30s have passed since the agent started and the device
    // is online but has not signalled its readiness
    if (agentRestartTimer) {
        imp.cancelwakeup(agentRestartTimer);
        agentRestartTimer = null;
    }

    if (forecastTimer) {
        imp.cancelwakeup(forecastTimer);
        forecastTimer = null;
    }

    deviceReadyFlag = true;
    device.send("set.debug", settings.debug);
    device.send("set.light", settings.power);
    device.send("set.bright", settings.brightness);
    device.send("set.orientation", settings.ledleft);

    // Get the device's location if we need to
    if ("loc" in settings && settings.loc.tim == -1) {
        locator.locate(true, function() {
            location = locator.getLocation();
            local tz = locator.getTimezone();

            if (!("error" in location)) {
                // Device's location obtained successfully, so get the location name
                location.place <- ("placeData" in location ? parsePlaceData(location.placeData) : "TBD");

                if (settings.debug) {
                    server.log("Co-ordinates: " + location.longitude + ", " + location.latitude);
                    server.log("Location    : " + location.place);
                }

                // Retain the data
                settings.loc.lon = location.longitude;
                settings.loc.lat = location.latitude;
                settings.loc.plc = location.place;
                settings.loc.tim = time();

                // Start the forecasting loop
                getForecast();
            } else {
                // Device's location not obtained, so check again in 30s
                if (settings.debug) server.error(location.error);
                imp.wakeup(30, initialise);
                return;
            }

            if (!("error" in tz)) {
                if (settings.debug) {
                    server.log("Local time  : " + tz.dateStr);
                    server.log("Timezone    : " + tz.gmtOffsetStr);
                }

                timezone = {};
                timezone.date <- tz.dateStr;
                timezone.offset <- ((tz.gmtOffset != 0) ? tz.gmtOffsetStr : "");
            } else {
                // Device's timezone not obtained, so check again in 30s
                if (settings.debug) server.error(tz.error);
                imp.wakeup(30, initialise);
            }
        });
    }
}

function setDefaults() {
    // Reset the agent's app settings table to default values
    // and save over existing ones
    settings = {};
    settings.brightness <- 7;  // Mid-range (0-15)
    settings.debug <- false;
    settings.power <- true;
    settings.ledleft <- true;   // true = LED is on the left, imp on the right
    settings.loc <- { "tim": -1,
                      "plc": "TBD",
                      "lon": 0,
                      "lat": 0};
    server.save(settings);
}

// ********** LOGGING FUNCTIONS **********
function debugAPI(context, next) {
    // Display a UI API activity report
    if (settings.debug) {
        server.log("API received a request at " + time() + ": " + context.req.method.toupper() + " @ " + context.req.path.tolower());
        if (context.req.rawbody.len() > 0) server.log("Request body: " + context.req.rawbody.tolower());
    }

    // Invoke the next middleware
    next();
}


// ********** RUNTIME START **********

// Set up the crash reporter
local slack = SimpleSlack("@{SLACK_KEY}");
crashReporter.init(slack.post.bindenv(slack));

// Handle settings
local loadedSettings = server.load();

if (loadedSettings.len() == 0) {
    // There are no previously saved settings, so reset to defaults...
    setDefaults();
} else {
    // There are previously saved settings, so use them
    settings = loadedSettings;
    local doSave = false;

    // Add handlers for settings not included in the original release
    if (!("debug" in settings)) {
        // There was no 'debug' key in the settings table, so create one...
        settings.debug <- false;
        doSave = true;
    }

    if (!("power" in settings)) {
        // There was no 'power' key in the settings table, so create one...
        settings.power <- true;
        doSave = true;
    }

    if (!("ledleft" in settings)) {
        // There was no 'ledleft' key in the settings table, so create one...
        settings.ledleft <- true;
        doSave = true;
    }

    if (!("loc" in settings)) {
        settings.loc <- { "tim": -1,
                          "plc": "TBD",
                          "lon": 0,
                          "lat": 0};
        doSave = true;
    }

    if (doSave) server.save(settings);
}

// If you are NOT using Squinter or an equivalent tool, comment out the following line...
const APP_CODE = "@{APP_CODE}";
forecast = DarkSky("@{DARKSKY_KEY}", settings.debug);
locator = Location({ "GEOLOCATION_API_KEY" : "@{GEO_KEY_1}",
                     "GEOCODING_API_KEY"   : "@{GEO_KEY_2}",
                     "TIMEZONE_API_KEY"    : "@{GEO_KEY_3}" },
                    settings.debug);

// Specify the region-specific units returned by Dark Sky
forecast.setUnits("uk");

// Prepare for the device signalling its readiness
device.on("ready", function(dummy) {
    // Device has signalled its readiness
    if (!deviceReadyFlag) {
        // Device has not signalled its readiness in this agent run so initialise the forecast loop
        if (settings.debug) server.log("Device signalled readiness; starting forecast loop");
        initialise();
    } else {
        // Device is back online, having previously signalled its readiness
        if (location) {
            // We have a saved location for the device, so just restart the forecast loop
            if (settings.debug) server.log("Restarting forecast loop; device restarted/reconnected");
            getForecast();
        } else {
            // Device is back online but we don't have its location so initialise the forecast loop
            if (settings.debug) server.log("Device signalled readiness; getting location");
            initialise();
        }
    }
});

// Set agent restart handler sequence
agentRestartTimer = imp.wakeup(60, function() {
    agentRestartTimer = null;
    if (!deviceReadyFlag) {
        // If the device hasn't yet signalled its presence in this agent run
        if (device.isconnected()) {
            // The device is online, so initialise the forecast loop for this agent run
            if (settings.debug) server.log("Restarting forecast loop; agent restarted");
            initialise();
        } else {
            // The device is not online, so just report a new agent run and wait
            // for the device to come online and signal its readiness
            if (settings.debug) server.log("Agent restart timer fired but device not online");
        }
    }
});

// Set up the agent API and UI
api = Rocky.init();
api.use(debugAPI);

// Set up UI access security: HTTPS only
api.authorize(function(context) {
    // Mandate HTTPS connections
    if (context.getHeader("x-forwarded-proto") != "https") return false;
    return true;
});

api.onUnauthorized(function(context) {
    // Incorrect level of access security
    context.send(401, "Insecure access forbidden");
});

// GET request to root: just return standard HTML string
api.get("/", function(context) {
    context.send(200, format(HTML_STRING, http.agenturl()));
});

// GET request to /settings: return app settings
api.get("/settings", function(context) {
    local data = {};
    data.brightness <- settings.brightness;
    data.debug <- settings.debug;
    data.power <- settings.power;
    data.orient <- settings.ledleft;
    data.connected <- device.isconnected();

    if ("place" in location) {
        // We have a place name, so display it
        data.place <- location.place;
    } else {
        // We have no place name, but report if device is offline
        data.place <- (data.connected ? "Unknown" : "Device Offline");
    }

    if (timezone != null) {
        // We have a timezone, but report if the device is offline
        local ts = timezone.date + (timezone.offset.len() != 0 ? (" (" + timezone.offset + ")") : "");
        data.timezone <- (data.connected ? ts : "Device Offline");
    } else {
        // Device is online, but we don't know where it is
        data.timezone <- "Unknown";
    }

    context.send(200, http.jsonencode(data));
});

// POST request to /settings: update settings as required
api.post("/settings", function(context) {
    local data;

    try {
        data = http.jsondecode(context.req.rawbody);
    } catch (err) {
        server.error(err);
        context.send(400, "Bad data posted");
        return;
    }

    if ("bright" in data) {
        local bright = data.bright.tointeger();
        if (settings.brightness != bright) {
            if (settings.debug) server.log("Display brightness changed to " + bright);
            device.send("set.bright", bright);
            settings.brightness = bright;
            local result = server.save(settings);
            if (result != 0) server.error("Could not save settings (code: " + result + ")");
        }

        context.send(202, "OK");
        return;
    }

    context.send(400, "Bad command posted");
});

// POST request to /actions: apply action
api.post("/actions", function(context) {
    local data;

    try {
        data = http.jsondecode(context.req.rawbody);
    } catch (err) {
        server.error(err);
        context.send(400, "Bad data posted");
        return;
    }

    if ("action" in data) {
        // Does the 'action' value indicate a requested reboot?
        if (data.action == "reboot") {
            if (settings.debug) server.log("Rebooting device");
            setDefaults();
            device.send("do.reboot", true);
        }

        // Does the 'action' value indicate setting or unsetting debug mode?
        if (data.action == "debug") {
            if ("debug" in data) {
                if (settings.debug != data.debug) {
                    settings.debug = data.debug;
                    server.log("Debug " + (settings.debug ? "enabled" : "disabled"));
                    device.send("set.debug", settings.debug);
                    server.save(settings);
                }
            }
        }

        // Does the 'action' value indicate setting or unsetting the device LED mode?
        if (data.action == "power") {
            if ("power" in data) {
                if (data.power != settings.power) {
                    settings.power = data.power;
                    if (settings.debug) server.log("LED power " + (data.power ? "on" : "off"));
                    device.send("set.light", data.power);
                    server.save(settings);
                }
            }
        }

        if (data.action == "orient") {
            if ("ledleft" in data) {
                if (data.ledleft != settings.ledleft) {
                    settings.ledleft = data.ledleft;
                    if (settings.debug) server.log("LED orientation " + (data.ledleft ? "left" : "right"));
                    device.send("set.orientation", data.ledleft);
                    server.save(settings);
                }
            }
        }
    }

    context.send(200, "OK");
});

// ADDED IN 1.8.0
// Any call to the endpoint /images is sent the correct PNG data
api.get("/images/([^/]*)", function(context) {
    // Determine which image has been requested and send the appropriate
    // stored data back to the requesting web browser
    local path = context.path;
    local name = path[path.len() - 1];
    local image = HIGH_PNG;
    if (name == "low.png") image = LOW_PNG;
    if (name == "mid.png") image = MID_PNG;
    if (name == "left.png") image = LEFT_PNG;
    if (name == "right.png") image = RIGHT_PNG;
    context.setHeader("Content-Type", "image/png");
    context.send(200, image);
});

// GET at /controller/info returns Controller app UUID
api.get("/controller/info", function(context) {
    local info = { "appcode": APP_CODE,
                   "watchsupported": "true",
                   "version": "@{get_version()}" };
    context.send(200, http.jsonencode(info));
});

// GET at /controller/state returns device state information
api.get("/controller/state", function(context) {
    local data =  {};
    data.ispowered <- settings.power;
    data.isconnected <- device.isconnected();
    data.brightness <- settings.brightness;
    data.ledorient <- settings.ledleft ? "left" : "right";
    context.send(200, http.jsonencode(data));
});
